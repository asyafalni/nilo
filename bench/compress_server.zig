//! What response compression keeps resident on a running server, per
//! backend (ADR 211, ADR 248).
//!
//! `bench/compress_bench.zig` times one `Pool.gzip` with no server under it;
//! this is the other half, the pool as `listen()` builds it, one compressor
//! per executor thread, and the pages those compressors hold once every
//! thread has gzipped something. `bench/compress_rss.py` drives it and reads
//! `/proc/<pid>/smaps_rollup` before and after.
//!
//! One route, `/json`, answering the same 8 KB JSON body (the 50-item body
//! `bench-compress` times) to every request. A client that sends
//! `Accept-Encoding: gzip` gets it gzipped and one that does not gets it as
//! it is, so the same server, driven both ways, is its own control: what
//! the plain run holds is everything but the compressors.
//!
//! ```
//! zig build -Doptimize=ReleaseFast bench-compress-server               # std.flate
//! zig build -Doptimize=ReleaseFast bench-compress-server -Dlibdeflate  # libdeflate
//! python3 bench/compress_rss.py ./zig-out/bin/nilo-bench-compress-server
//! ```

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

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

/// `bench/compress_bench.zig`'s body at 50 items, built once at start.
var json_body: []const u8 = "";

fn build(gpa: std.mem.Allocator, count: usize, m: u32) ![]const u8 {
    const items = try gpa.alloc(Item, count);
    defer gpa.free(items);
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
    var out: std.Io.Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(.{ .items = items, .count = count }, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn json(c: *nilo.Ctx) !void {
    try c.send(200, "application/json", json_body);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    json_body = try build(gpa, 50, 6);

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/json", json);

    // Sixteen executor threads whatever the machine, so the pool is the same
    // size on every run and the figure divides by a known count.
    try app.listen(.{ .port = 8795, .threads = 16 });
}
