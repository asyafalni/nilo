//! What gzipping an answer costs, per level, on the bodies the benchmark
//! arena's `json-comp` profile asks for (ADR 211).
//!
//! ```
//! zig build bench-compress
//! ```
//!
//! Always `ReleaseFast`: a Debug deflate is a different program. No server
//! and no socket, because the number wanted is the compressor's alone: the
//! microseconds one `Pool.gzip` takes on one thread, and the bytes it hands
//! back, for a JSON body of 25, 40 and 50 items (the shapes the arena
//! rotates through) at each of the three levels `app.compress` offers.
//! Everything else a compressed answer costs is one arena allocation, which
//! `test "a compressed answer costs one allocation"` holds rather than
//! this.
//!
//! Two numbers are worth reading side by side: the microseconds, which are
//! what the CPU column of a fixed-rate profile pays, and the bytes, which
//! the arena scores quadratically: a body a fifth larger is a score a
//! third lower.

const std = @import("std");
const nilo = @import("nilo_http");

const Item = struct {
    id: u32,
    name: []const u8,
    category: []const u8,
    price: u32,
    quantity: u32,
    active: bool,
    tags: []const []const u8,
    rating: struct { score: u32, count: u32 },
    total: u64,
};

const names = [_][]const u8{ "Alpha Widget", "Beta Gadget", "Gamma Gizmo", "Delta Device", "Epsilon Engine" };
const categories = [_][]const u8{ "electronics", "home", "garden", "toys", "office" };
const tag_sets = [_][]const []const u8{ &.{ "fast", "new" }, &.{"sale"}, &.{ "popular", "bulk", "eco" } };

fn body(arena: std.mem.Allocator, count: usize, m: u32) ![]const u8 {
    const items = try arena.alloc(Item, count);
    for (items, 0..) |*it, i| {
        const price: u32 = @intCast(100 + (i * 37) % 900);
        const quantity: u32 = @intCast(1 + (i * 7) % 40);
        it.* = .{
            .id = @intCast(i + 1),
            .name = names[i % names.len],
            .category = categories[i % categories.len],
            .price = price,
            .quantity = quantity,
            .active = i % 3 != 0,
            .tags = tag_sets[i % tag_sets.len],
            .rating = .{ .score = @intCast(10 + (i * 13) % 40), .count = @intCast((i * 53) % 500) },
            .total = @as(u64, price) * quantity * m,
        };
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .items = items, .count = count }, .{}, &out.writer);
    return out.written();
}

fn monotonicNanos() u64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => |e| std.debug.panic("clock: {s}", .{@tagName(e)}),
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shapes = [_]struct { count: usize, m: u32 }{ .{ .count = 25, .m = 4 }, .{ .count = 40, .m = 8 }, .{ .count = 50, .m = 6 } };
    const levels = [_]nilo.compress.Level{ .fastest, .default, .best };
    const rounds = 2000;

    const print = std.debug.print;
    print("{s:>6} {s:>8} {s:>9} {s:>9} {s:>7} {s:>9}\n", .{ "items", "level", "in B", "out B", "ratio", "us/body" });

    for (shapes) |shape| {
        const plain = try body(arena, shape.count, shape.m);
        for (levels) |level| {
            var pool = try nilo.compress.Pool.init(gpa, 1, .{ .level = level });
            defer pool.deinit(gpa);

            // The same arena a request has: reset after every body, so the
            // output allocation is the one a request pays and not a growing
            // heap.
            var request_arena = std.heap.ArenaAllocator.init(gpa);
            defer request_arena.deinit();

            // Warm, then time.
            var squeezed_len: usize = 0;
            for (0..100) |_| {
                squeezed_len = pool.gzip(request_arena.allocator(), plain).?.len;
                _ = request_arena.reset(.retain_capacity);
            }
            const started = monotonicNanos();
            for (0..rounds) |_| {
                _ = pool.gzip(request_arena.allocator(), plain).?;
                _ = request_arena.reset(.retain_capacity);
            }
            const ns = monotonicNanos() - started;
            print("{d:>6} {s:>8} {d:>9} {d:>9} {d:>6.1}% {d:>9.1}\n", .{
                shape.count,
                @tagName(level),
                plain.len,
                squeezed_len,
                @as(f64, @floatFromInt(squeezed_len)) * 100.0 / @as(f64, @floatFromInt(plain.len)),
                @as(f64, @floatFromInt(ns)) / @as(f64, rounds) / 1000.0,
            });
        }
    }
}
