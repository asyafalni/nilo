//! The signatures a ring has already checked, by the token's digest — so a
//! bearer token that comes back on the next request costs a hash rather
//! than the elliptic-curve arithmetic again
//! ([ADR 0285](../docs/adr/0285-a-verified-signature-is-remembered-by-the-tokens-digest.md)).
//!
//! What is remembered is exactly "these bytes verified under the set the
//! ring held". The claims are still read and checked on every call — `exp`,
//! `nbf`, `iss`, `aud` — because those are about *now*, and a memo says
//! nothing about now. The memo is emptied when the ring has drained the
//! readers of an old set, because a token verified under a key that is
//! gone has not been verified.
//!
//! Fixed size, full SHA-256 digests, open addressing on the digest's first
//! eight bytes with a bounded probe, a spin lock: a lookup is at most
//! `probes` comparisons whatever the capacity, an insert that finds its
//! window full evicts the home slot, and nothing here allocates or parks.

const std = @import("std");

pub const Digest = [32]u8;

pub const Memo = struct {
    /// Twice the capacity asked for, rounded up to a power of two, so the
    /// table is never more than half full and a probe window finds a free
    /// slot almost always.
    slots: []Digest,
    used: []bool,
    /// Slots that hold a digest.
    filled: usize = 0,
    held: std.atomic.Value(bool) = .init(false),
    /// Lookups that skipped the signature check, and lookups that did not;
    /// what the memo is worth on this ring.
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),

    /// How far a lookup or an insert walks from the digest's home slot. A
    /// table at half load has an empty slot within eight of any home with
    /// probability well past 0.99; past the window an insert evicts.
    pub const probes = 8;

    pub fn init(gpa: std.mem.Allocator, capacity: usize) error{OutOfMemory}!Memo {
        const n = std.math.ceilPowerOfTwo(usize, @max(capacity, 1) * 2) catch return error.OutOfMemory;
        const slots = try gpa.alloc(Digest, n);
        errdefer gpa.free(slots);
        const used = try gpa.alloc(bool, n);
        @memset(used, false);
        return .{ .slots = slots, .used = used };
    }

    pub fn deinit(self: *Memo, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
        gpa.free(self.used);
        self.* = undefined;
    }

    pub fn digestOf(token: []const u8) Digest {
        var d: Digest = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &d, .{});
        return d;
    }

    /// The slot a digest lives in if it is here at all: its first eight
    /// bytes, which are as uniform as the rest of a SHA-256, masked to the
    /// table.
    fn home(self: *const Memo, d: Digest) usize {
        const prefix = std.mem.readInt(u64, d[0..8], .little);
        return @intCast(prefix & (self.slots.len - 1));
    }

    /// Whether these bytes verified before, under the set the ring holds now.
    pub fn has(self: *Memo, d: Digest) bool {
        self.lock();
        defer self.unlock();
        var i = self.home(d);
        for (0..probes) |_| {
            if (!self.used[i]) break;
            if (std.mem.eql(u8, &self.slots[i], &d)) {
                _ = self.hits.fetchAdd(1, .monotonic);
                return true;
            }
            i = (i + 1) & (self.slots.len - 1);
        }
        _ = self.misses.fetchAdd(1, .monotonic);
        return false;
    }

    pub fn remember(self: *Memo, d: Digest) void {
        self.lock();
        defer self.unlock();
        const start = self.home(d);
        var i = start;
        for (0..probes) |_| {
            if (!self.used[i]) {
                self.slots[i] = d;
                self.used[i] = true;
                self.filled += 1;
                return;
            }
            if (std.mem.eql(u8, &self.slots[i], &d)) return;
            i = (i + 1) & (self.slots.len - 1);
        }
        // The window is full: the home slot's tenant goes. A memo forgets
        // by design; what it never does is answer for a digest it was not
        // handed.
        self.slots[start] = d;
    }

    /// Forget everything: the keys changed.
    pub fn clear(self: *Memo) void {
        self.lock();
        defer self.unlock();
        @memset(self.used, false);
        self.filled = 0;
    }

    fn lock(self: *Memo) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Memo) void {
        self.held.store(false, .release);
    }
};

const testing = std.testing;

test "a remembered digest is found, one never handed over is not, and a clear forgets all" {
    var memo = try Memo.init(testing.allocator, 2);
    defer memo.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), memo.slots.len);
    const a = Memo.digestOf("a.b.c");
    const b = Memo.digestOf("a.b.d");
    const c = Memo.digestOf("a.b.e");
    try testing.expect(!memo.has(a));
    memo.remember(a);
    try testing.expect(memo.has(a));
    memo.remember(b);
    memo.remember(b); // twice is once
    try testing.expectEqual(@as(usize, 2), memo.filled);
    try testing.expect(memo.has(a));
    try testing.expect(memo.has(b));
    try testing.expect(!memo.has(c));
    memo.clear();
    try testing.expect(!memo.has(a));
    try testing.expect(!memo.has(b));
    try testing.expectEqual(@as(u64, 3), memo.hits.load(.monotonic));
    try testing.expectEqual(@as(u64, 4), memo.misses.load(.monotonic));
}

test "a lookup is bounded by the probe window whatever the capacity, and a full window evicts rather than grows" {
    // Every digest here is forced into one home slot, which is the worst
    // case the window bounds.
    var memo = try Memo.init(testing.allocator, 64);
    defer memo.deinit(testing.allocator);
    var digests: [Memo.probes + 4]Digest = undefined;
    for (&digests, 0..) |*d, i| {
        d.* = Memo.digestOf(&[_]u8{@intCast(i)});
        @memset(d[0..8], 0); // home slot 0 for all of them
        memo.remember(d.*);
    }
    // The window holds `probes`; the rest evicted the home slot's tenant
    // in turn, and nothing is ever answered for that was not remembered.
    try testing.expectEqual(@as(usize, Memo.probes), memo.filled);
    try testing.expect(memo.has(digests[digests.len - 1]));
    for (digests[1..Memo.probes]) |d| try testing.expect(memo.has(d));
    var stranger = Memo.digestOf("nobody");
    @memset(stranger[0..8], 0);
    try testing.expect(!memo.has(stranger));
}
