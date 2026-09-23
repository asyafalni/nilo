//! A queue in this process, on a fixed budget.
//!
//! For a test, and for a program with no database that can live with losing
//! its queue at a restart. All the memory is taken at `open`, nothing is
//! allocated per operation, and when the slots are gone `push` fails with
//! `error.QueueFull` — **it does not write over an older row**, which is the
//! one thing separating this from `nilo_cache` and the reason the two are
//! not one module ([ADR 0198](../docs/adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)).
//! A cache that forgets is doing its job; a queue that forgets has lost
//! somebody's email.
//!
//! One lock, and it spins, for the reason `nilo_cache`'s does: this layer
//! has no `Io` in hand at `push` time, so `std.Io.Mutex` cannot be taken, and
//! every critical section here is a scan of a few thousand fixed-size slots
//! with nothing that waits inside it.
//!
//! Not a store for several processes. Two servers each holding one of these
//! are two queues, and a schedule declared in both runs twice.

const std = @import("std");
const contract = @import("contract.zig");

pub const Memory = struct {
    gpa: std.mem.Allocator,
    slots: []Slot,
    payloads: []u8,
    max_payload: usize,
    lock: Lock = .{},
    next_id: contract.Id = 1,

    pub const Settings = struct {
        /// All of it, taken at `open`. Slots are carved out of this: one slot
        /// is `@sizeOf(Slot) + max_payload` bytes, so 1 MiB with the default
        /// payload ceiling is about 240 rows.
        bytes: usize,
        /// The largest payload one row may carry. A `push` past it is
        /// `error.PayloadTooLarge` rather than a truncated document.
        max_payload: usize = 4096,
    };

    pub const Error = error{
        /// Every slot is taken. Nothing was written over.
        QueueFull,
        /// The payload is longer than `Settings.max_payload`.
        PayloadTooLarge,
        /// The unique key is longer than `contract.max_unique`.
        UniqueTooLong,
        OutOfMemory,
    };

    pub fn open(gpa: std.mem.Allocator, settings: Settings) !Memory {
        const per_slot = @sizeOf(Slot) + settings.max_payload;
        const count = @max(settings.bytes / per_slot, 1);
        const slots = try gpa.alloc(Slot, count);
        errdefer gpa.free(slots);
        for (slots) |*s| s.* = .{};
        const payloads = try gpa.alloc(u8, count * settings.max_payload);
        return .{
            .gpa = gpa,
            .slots = slots,
            .payloads = payloads,
            .max_payload = settings.max_payload,
        };
    }

    pub fn deinit(self: *Memory) void {
        self.gpa.free(self.payloads);
        self.gpa.free(self.slots);
    }

    /// How many rows this can hold at once.
    pub fn capacity(self: *const Memory) usize {
        return self.slots.len;
    }

    // -- the contract ------------------------------------------------------

    pub fn push(self: *Memory, scope: anytype, kind: []const u8, payload: []const u8, at: contract.Enqueue) Error!?contract.Id {
        _ = scope;
        if (payload.len > self.max_payload) return error.PayloadTooLarge;
        if (at.unique) |u| if (u.len > contract.max_unique) return error.UniqueTooLong;
        std.debug.assert(kind.len <= contract.max_kind);

        self.lock.take();
        defer self.lock.release();

        var free: ?usize = null;
        for (self.slots, 0..) |*s, i| {
            switch (s.state) {
                .free => if (free == null) {
                    free = i;
                },
                .queued, .running => if (at.unique) |u| {
                    if (s.kindIs(kind) and s.uniqueIs(u)) return null;
                },
                .dead => {},
            }
        }
        const i = free orelse return error.QueueFull;
        const s = &self.slots[i];
        s.* = .{
            .state = .queued,
            .id = self.next_id,
            .run_at = at.run_at,
            .created_at = at.run_at,
            .priority = at.priority,
        };
        self.next_id += 1;
        s.setKind(kind);
        if (at.unique) |u| s.setUnique(u);
        @memcpy(self.payloadOf(i)[0..payload.len], payload);
        s.payload_len = @intCast(payload.len);
        return s.id;
    }

    /// The most urgent due row — earliest `run_at` among equals — or a
    /// running row whose lease is over. The same question `job.Table` asks
    /// in one statement.
    /// Narrowed to the kinds this program can run, as the table's claim is:
    /// a row of a kind nobody here knows is left where it is, for the binary
    /// that does know it, rather than claimed and handed back forever.
    pub fn claim(self: *Memory, scope: anytype, comptime kinds: []const []const u8, now: i64, lease_until: i64) !?contract.Claimed {
        self.lock.take();
        defer self.lock.release();

        var best: ?usize = null;
        for (self.slots, 0..) |*s, i| {
            const due = switch (s.state) {
                .queued => s.run_at <= now,
                .running => s.lease_until <= now,
                else => false,
            };
            if (!due) continue;
            const mine = inline for (kinds) |k| {
                if (s.kindIs(k)) break true;
            } else false;
            if (!mine) continue;
            // The same order the table claims in: the most urgent due row,
            // and among equals the one that has been due longest.
            if (best) |b| {
                const cur = self.slots[b];
                const better = @intFromEnum(s.priority) < @intFromEnum(cur.priority) or
                    (s.priority == cur.priority and s.run_at < cur.run_at);
                if (better) best = i;
            } else best = i;
        }
        const i = best orelse return null;
        const s = &self.slots[i];
        s.state = .running;
        s.lease_until = lease_until;
        s.attempts += 1;

        const arena = scope.arena();
        return .{
            .id = s.id,
            .kind = try arena.dupe(u8, s.kind()),
            .payload = try arena.dupe(u8, self.payloadOf(i)[0..s.payload_len]),
            .attempts = s.attempts,
            .run_at = s.run_at,
        };
    }

    /// A finished row gives its slot back at once. There is nothing to keep
    /// it for: a status somebody may poll lives in the Space a `Jobs` was
    /// given, not here.
    pub fn done(self: *Memory, scope: anytype, id: contract.Id) !void {
        _ = scope;
        self.lock.take();
        defer self.lock.release();
        if (self.find(id)) |s| s.* = .{};
    }

    pub fn retry(self: *Memory, scope: anytype, id: contract.Id, run_at: i64, err: []const u8) !void {
        _ = scope;
        self.lock.take();
        defer self.lock.release();
        const s = self.find(id) orelse return;
        s.state = .queued;
        s.run_at = run_at;
        s.lease_until = 0;
        s.setError(err);
    }

    pub fn dead(self: *Memory, scope: anytype, id: contract.Id, err: []const u8) !void {
        _ = scope;
        self.lock.take();
        defer self.lock.release();
        const s = self.find(id) orelse return;
        s.state = .dead;
        s.lease_until = 0;
        s.unique_len = 0;
        s.setError(err);
    }

    pub fn release(self: *Memory, scope: anytype, id: contract.Id) !void {
        _ = scope;
        self.lock.take();
        defer self.lock.release();
        const s = self.find(id) orelse return;
        s.state = .queued;
        s.lease_until = 0;
        // Not this worker's attempt any more: it never ran.
        s.attempts -|= 1;
    }

    pub fn stats(self: *Memory, scope: anytype) !contract.Stats {
        _ = scope;
        self.lock.take();
        defer self.lock.release();
        var out: contract.Stats = .{ .queued = 0, .running = 0, .dead = 0 };
        for (self.slots) |s| switch (s.state) {
            .queued => out.queued += 1,
            .running => out.running += 1,
            .dead => out.dead += 1,
            .free => {},
        };
        return out;
    }

    /// The rows that failed for the last time, newest first, into the
    /// Scope's arena.
    pub fn deadOnes(self: *Memory, scope: anytype) ![]contract.Dead {
        self.lock.take();
        defer self.lock.release();
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.state == .dead) n += 1;
        }
        const arena = scope.arena();
        const out = try arena.alloc(contract.Dead, n);
        var at: usize = 0;
        for (self.slots) |s| {
            if (s.state != .dead) continue;
            out[at] = .{
                .id = s.id,
                .kind = try arena.dupe(u8, s.kind()),
                .attempts = s.attempts,
                .err = try arena.dupe(u8, s.err()),
            };
            at += 1;
        }
        std.mem.sort(contract.Dead, out, {}, struct {
            fn newestFirst(_: void, a: contract.Dead, b: contract.Dead) bool {
                return a.id > b.id;
            }
        }.newestFirst);
        return out;
    }

    /// Queue a dead row again, from the first attempt. `false` when no dead
    /// row has that id.
    pub fn retryDead(self: *Memory, scope: anytype, id: contract.Id, now: i64) !bool {
        _ = scope;
        self.lock.take();
        defer self.lock.release();
        const s = self.find(id) orelse return false;
        if (s.state != .dead) return false;
        s.state = .queued;
        s.run_at = now;
        s.attempts = 0;
        s.err_len = 0;
        return true;
    }

    /// Take a queued row out before it runs. `true` when a `queued` row was
    /// removed; `false` when it is running, finished or absent, since a
    /// row a worker holds is that worker's to finish
    /// ([ADR 0257](../docs/adr/0257-a-queued-row-can-be-taken-back.md)).
    pub fn cancel(self: *Memory, scope: anytype, id: contract.Id) !bool {
        _ = scope;
        self.lock.take();
        defer self.lock.release();
        const s = self.find(id) orelse return false;
        if (s.state != .queued) return false;
        s.state = .free;
        return true;
    }

    // -- inside -----------------------------------------------------------

    fn find(self: *Memory, id: contract.Id) ?*Slot {
        for (self.slots) |*s| {
            if (s.state != .free and s.id == id) return s;
        }
        return null;
    }

    fn payloadOf(self: *Memory, i: usize) []u8 {
        return self.payloads[i * self.max_payload ..][0..self.max_payload];
    }

    /// Fixed width on purpose: a slot that pointed anywhere would need an
    /// allocation per row, and this store's promise is that it makes none.
    const Slot = struct {
        state: enum { free, queued, running, dead } = .free,
        id: contract.Id = 0,
        run_at: i64 = 0,
        lease_until: i64 = 0,
        priority: contract.Priority = .normal,
        created_at: i64 = 0,
        attempts: u32 = 0,
        payload_len: u32 = 0,
        kind_len: u8 = 0,
        unique_len: u8 = 0,
        err_len: u8 = 0,
        kind_buf: [contract.max_kind]u8 = undefined,
        unique_buf: [contract.max_unique]u8 = undefined,
        err_buf: [contract.max_error]u8 = undefined,

        fn kind(s: *const Slot) []const u8 {
            return s.kind_buf[0..s.kind_len];
        }
        fn kindIs(s: *const Slot, name: []const u8) bool {
            return std.mem.eql(u8, s.kind(), name);
        }
        fn setKind(s: *Slot, name: []const u8) void {
            @memcpy(s.kind_buf[0..name.len], name);
            s.kind_len = @intCast(name.len);
        }
        fn uniqueIs(s: *const Slot, u: []const u8) bool {
            return s.unique_len != 0 and std.mem.eql(u8, s.unique_buf[0..s.unique_len], u);
        }
        fn setUnique(s: *Slot, u: []const u8) void {
            @memcpy(s.unique_buf[0..u.len], u);
            s.unique_len = @intCast(u.len);
        }
        fn err(s: *const Slot) []const u8 {
            return s.err_buf[0..s.err_len];
        }
        fn setError(s: *Slot, e: []const u8) void {
            const n = @min(e.len, contract.max_error);
            @memcpy(s.err_buf[0..n], e[0..n]);
            s.err_len = @intCast(n);
        }
    };

    const Lock = struct {
        held: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),

        fn take(l: *Lock) void {
            while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
        }

        fn release(l: *Lock) void {
            l.held.store(false, .release);
        }
    };
};

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const core = @import("nilo_core");

/// The kinds the tests below push, so a claim in a test sees all of them.
/// A worker passes its own `kind_names`.
const test_kinds: []const []const u8 = &.{ "a", "backfill", "digest", "first", "other", "revalidate-a", "revalidate-b", "second", "sweep" };

test "a kind this program does not know is never claimed, however due it is" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // The stranger is due first and would win every ordering.
    const stranger = (try store.push(&run, "stranger", "{}", .{ .run_at = 10 })).?;
    const mine = (try store.push(&run, "a", "{}", .{ .run_at = 20 })).?;

    const got = (try store.claim(&run, &.{"a"}, 100, 1_000)).?;
    try testing.expectEqual(mine, got.id);
    // And nothing is left to claim: the stranger is not picked up, handed
    // back, and picked up again — which is what made it spin, and what made
    // its `attempts` climb towards dead in a binary that could never run it.
    try testing.expect((try store.claim(&run, &.{"a"}, 100, 1_000)) == null);

    // A program that does know it takes it, still at nought attempts.
    const theirs = (try store.claim(&run, &.{ "a", "stranger" }, 100, 1_000)).?;
    try testing.expectEqual(stranger, theirs.id);
    try testing.expectEqual(@as(u32, 1), theirs.attempts);
}

test "a pushed row is claimed once, in run_at order, and not before it is due" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const later = try store.push(&run, "a", "{\"n\":2}", .{ .run_at = 200 });
    const sooner = try store.push(&run, "a", "{\"n\":1}", .{ .run_at = 100 });
    try testing.expect(later != null and sooner != null);

    // Nothing is due at 50.
    try testing.expect((try store.claim(&run, test_kinds, 50, 1_000)) == null);

    const first = (try store.claim(&run, test_kinds, 150, 1_000)).?;
    try testing.expectEqual(sooner.?, first.id);
    try testing.expectEqualStrings("{\"n\":1}", first.payload);
    try testing.expectEqual(@as(u32, 1), first.attempts);

    // The row is running now and not claimable again while its lease holds.
    try testing.expect((try store.claim(&run, test_kinds, 150, 1_000)) == null);

    const second = (try store.claim(&run, test_kinds, 250, 1_000)).?;
    try testing.expectEqual(later.?, second.id);

    try store.done(&run, first.id);
    try store.done(&run, second.id);
    const s = try store.stats(&run);
    try testing.expectEqual(@as(u64, 0), s.queued + s.running + s.dead);
}

test "a lease that ran out hands the row to the next claim, counting the attempt" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    _ = try store.push(&run, "a", "{}", .{ .run_at = 0 });
    const first = (try store.claim(&run, test_kinds, 10, 100)).?;
    try testing.expectEqual(@as(u32, 1), first.attempts);
    // Lease is until 100; at 101 it is somebody else's.
    const again = (try store.claim(&run, test_kinds, 101, 200)).?;
    try testing.expectEqual(first.id, again.id);
    try testing.expectEqual(@as(u32, 2), again.attempts);
}

test "a unique key admits one queued row and another once it is done" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const a = try store.push(&run, "digest", "{}", .{ .run_at = 0, .unique = "u42" });
    try testing.expect(a != null);
    try testing.expect((try store.push(&run, "digest", "{}", .{ .run_at = 0, .unique = "u42" })) == null);
    // A different kind with the same key is a different row.
    try testing.expect((try store.push(&run, "other", "{}", .{ .run_at = 0, .unique = "u42" })) != null);

    const claimed = (try store.claim(&run, test_kinds, 1, 100)).?;
    // Still held while running.
    try testing.expect((try store.push(&run, "digest", "{}", .{ .run_at = 0, .unique = "u42" })) == null);
    try store.done(&run, claimed.id);
    try testing.expect((try store.push(&run, "digest", "{}", .{ .run_at = 0, .unique = "u42" })) != null);
}

test "a full queue refuses rather than writing over a row" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 4 * (@sizeOf(Memory.Slot) + 64), .max_payload = 64 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    try testing.expectEqual(@as(usize, 4), store.capacity());
    for (0..4) |_| _ = try store.push(&run, "a", "{}", .{ .run_at = 0 });
    try testing.expectError(error.QueueFull, store.push(&run, "a", "{}", .{ .run_at = 0 }));
    // And every one of the four is still there.
    try testing.expectEqual(@as(u64, 4), (try store.stats(&run)).queued);

    try testing.expectError(error.PayloadTooLarge, store.push(&run, "a", "x" ** 65, .{ .run_at = 0 }));
}

test "retry, dead and retryDead move a row through its states" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const id = (try store.push(&run, "a", "{}", .{ .run_at = 0 })).?;
    _ = (try store.claim(&run, test_kinds, 1, 100)).?;
    try store.retry(&run, id, 500, "Boom");
    try testing.expect((try store.claim(&run, test_kinds, 100, 200)) == null);
    const again = (try store.claim(&run, test_kinds, 500, 600)).?;
    try testing.expectEqual(@as(u32, 2), again.attempts);

    try store.dead(&run, id, "StillBoom");
    try testing.expectEqual(@as(u64, 1), (try store.stats(&run)).dead);
    const listed = try store.deadOnes(&run);
    try testing.expectEqual(@as(usize, 1), listed.len);
    try testing.expectEqualStrings("StillBoom", listed[0].err);
    try testing.expectEqualStrings("a", listed[0].kind);

    try testing.expect(try store.retryDead(&run, id, 700));
    try testing.expect(!(try store.retryDead(&run, id, 700)));
    const third = (try store.claim(&run, test_kinds, 700, 800)).?;
    try testing.expectEqual(@as(u32, 1), third.attempts);
}

test "cancel takes a queued row out, and leaves one that is running or finished" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const id = (try store.push(&run, "a", "{}", .{ .run_at = 0, .unique = "k" })).?;
    try testing.expect(try store.cancel(&run, id));
    try testing.expect(!(try store.cancel(&run, id)));
    try testing.expect((try store.claim(&run, test_kinds, 1, 100)) == null);
    // The unique key is free again: "move it to tomorrow" is a cancel and
    // a push.
    const later = (try store.push(&run, "a", "{}", .{ .run_at = 0, .unique = "k" })).?;

    _ = (try store.claim(&run, test_kinds, 1, 100)).?;
    try testing.expect(!(try store.cancel(&run, later)));
    try store.done(&run, later);
    try testing.expect(!(try store.cancel(&run, later)));
    try testing.expect(!(try store.cancel(&run, 999)));
}

test "release puts a claimed row back without spending the attempt" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    const id = (try store.push(&run, "a", "{}", .{ .run_at = 0 })).?;
    _ = (try store.claim(&run, test_kinds, 1, 100)).?;
    try store.release(&run, id);
    const again = (try store.claim(&run, test_kinds, 2, 100)).?;
    try testing.expectEqual(@as(u32, 1), again.attempts);
}

test "a high-priority row goes first, and among equals the one due longest" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // Pushed in the order a backfill and the small jobs behind it arrive:
    // the backfill is due first, and by `run_at` alone it would be claimed
    // first and hold the worker for as long as it runs.
    _ = (try store.push(&run, "backfill", "{}", .{ .run_at = 10, .priority = .low })).?;
    _ = (try store.push(&run, "sweep", "{}", .{ .run_at = 20 })).?;
    _ = (try store.push(&run, "revalidate-b", "{}", .{ .run_at = 40, .priority = .high })).?;
    _ = (try store.push(&run, "revalidate-a", "{}", .{ .run_at = 30, .priority = .high })).?;

    // Urgency first; among equals, the one that has been due longest.
    const order = [_][]const u8{ "revalidate-a", "revalidate-b", "sweep", "backfill" };
    for (order) |want| {
        const c = (try store.claim(&run, test_kinds, 100, 1000)).?;
        try testing.expectEqualStrings(want, c.kind);
        try store.done(&run, c.id);
    }
    try testing.expect((try store.claim(&run, test_kinds, 100, 1000)) == null);
}

test "a kind that declares no priority is normal, and sorts by run_at as before" {
    var store = try Memory.open(testing.allocator, .{ .bytes = 64 << 10 });
    defer store.deinit();
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    _ = (try store.push(&run, "second", "{}", .{ .run_at = 20 })).?;
    _ = (try store.push(&run, "first", "{}", .{ .run_at = 10 })).?;
    const a = (try store.claim(&run, test_kinds, 100, 1000)).?;
    try testing.expectEqualStrings("first", a.kind);
    const b = (try store.claim(&run, test_kinds, 100, 1000)).?;
    try testing.expectEqualStrings("second", b.kind);
}
