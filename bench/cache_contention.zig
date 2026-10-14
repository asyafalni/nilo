//! What the shard lock costs when more threads want it than there are cores
//! (ADR 109).
//!
//! ```
//! zig build bench-cache-contention -Doptimize=ReleaseFast -- [threads] [seconds]
//! ```
//!
//! `bench-cache` runs one thread per core at most and spreads its keys over
//! 64 shards, so the lock is rarely contended and never held by a thread the
//! OS has descheduled. This is the other case: **one shard, writes only,
//! `threads` defaulting to four times the cores**, so every put queues behind
//! the same lock and a holder is often not running. That is the load the
//! spin lock's test-and-test-and-set and its yield are for, and the one the
//! module's own soak tests run.
//!
//! Two rows. `put` is the lock taken and the copy under it. `refuse` is a
//! value too large for the shard, which used to take the lock to bump a
//! counter and now takes none, so it is the row that shows the lock dropped.
//!
//! Compare two builds of the same command, a `git archive` of the commit
//! before and the working tree, interleaved and each pinned to the same
//! cores. A margin inside the spread between runs is "unchanged".

const std = @import("std");
const cache = @import("nilo_cache");

const Cart = struct { owner: u64, items: u32, total: u64 };
const Carts = cache.Space("cart", Cart, .{});
const Pages = cache.Space("page", []const u8, .{ .max_bytes = 32 << 10 });

const keys_n = 4096;

fn monotonicMicros() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => |e| std.debug.panic("clock: {s}", .{@tagName(e)}),
    }
    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s +
        @divFloor(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}

const Row = enum { put, refuse };

const Runner = struct {
    carts: Carts,
    pages: Pages,
    keys: []const []const u8,
    row: Row,
    stop: *std.atomic.Value(bool),
    ops: u64 = 0,

    fn run(self: *Runner, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        // Over a quarter of this 64 KiB shard's ring, so refused.
        const big = &@as([16 << 10]u8, @splat('p'));
        while (!self.stop.load(.monotonic)) {
            for (0..256) |_| {
                const key = self.keys[rand.uintLessThan(usize, self.keys.len)];
                switch (self.row) {
                    .put => self.carts.put(key, .{ .owner = 1, .items = 2, .total = 3 }),
                    .refuse => self.pages.put(key, big) catch {},
                }
                self.ops += 1;
            }
        }
    }
};

fn measure(gpa: std.mem.Allocator, keys: []const []const u8, row: Row, threads_n: usize, seconds: u64) !void {
    // One shard: the whole point is that every thread meets the same lock.
    var store = try cache.open(gpa, .{ .bytes = 64 << 10, .shards = 1, .seed = 0x6e696c6f });
    defer store.deinit();

    const runners = try gpa.alloc(Runner, threads_n);
    defer gpa.free(runners);
    const threads = try gpa.alloc(std.Thread, threads_n);
    defer gpa.free(threads);

    var stop: std.atomic.Value(bool) = .init(false);
    for (runners) |*r| r.* = .{
        .carts = Carts.open(&store),
        .pages = Pages.open(&store),
        .keys = keys,
        .row = row,
        .stop = &stop,
    };

    const began = monotonicMicros();
    for (threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Runner.run, .{ &runners[i], 7 + i });
    const until = began + @as(i64, @intCast(seconds)) * std.time.us_per_s;
    while (monotonicMicros() < until) std.Thread.yield() catch {};
    stop.store(true, .monotonic);
    for (threads) |t| t.join();
    const took = monotonicMicros() - began;

    var ops: u64 = 0;
    var most: u64 = 0;
    var fewest: u64 = std.math.maxInt(u64);
    for (runners) |r| {
        ops += r.ops;
        most = @max(most, r.ops);
        fewest = @min(fewest, r.ops);
    }
    const per_s = @as(f64, @floatFromInt(ops)) * 1_000_000.0 / @as(f64, @floatFromInt(took));
    // A thread that starved shows as a fewest far under the most.
    std.debug.print(
        "  {s: <7} {d: >3} threads  {d: >12.0} ops/s  ops a thread: most {d}, fewest {d}\n",
        .{ @tagName(row), threads_n, per_s, most, fewest },
    );
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var it: std.process.Args.Iterator = .init(init.args);
    _ = it.skip();
    const cores = std.Thread.getCpuCount() catch 1;
    const threads_n: usize = if (it.next()) |a| try std.fmt.parseInt(usize, a, 10) else cores * 4;
    const seconds: u64 = if (it.next()) |a| try std.fmt.parseInt(u64, a, 10) else 5;

    const backing = try gpa.alloc(u8, keys_n * 16);
    defer gpa.free(backing);
    const text = try gpa.alloc([]const u8, keys_n);
    defer gpa.free(text);
    var at: usize = 0;
    for (text, 0..) |*k, i| {
        const written = try std.fmt.bufPrint(backing[at..], "cart:{d}", .{i});
        k.* = written;
        at += written.len;
    }

    std.debug.print("nilo_cache: one shard, {d} cores, {d} threads, {d} s a row\n", .{ cores, threads_n, seconds });
    for ([_]Row{ .put, .refuse }) |row| try measure(gpa, text, row, threads_n, seconds);
}
