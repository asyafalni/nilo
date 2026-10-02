//! The stack one `Pool.gzip` writes below its caller, per backend and per
//! optimize mode (ADR 062, ADR 211, ADR 248).
//!
//! A fiber holds its stack at the deepest byte it ever wrote, for the life
//! of the connection, so what gzipping an answer costs a connection is how
//! deep the call goes. Measured the way `bench/compare-compress/stack.zig`
//! measures the codecs alone: the stack below the caller painted, one call,
//! the deepest byte that changed. Through nilo's own `Pool`, so the figure
//! includes the borrow and, for the standard library, `reset`.
//!
//! ```
//! zig build bench-compress-stack -Dlibdeflate -Doptimize=ReleaseSafe
//! ```
//!
//! Without `-Dlibdeflate` only the standard library's row is printed. Built
//! in the mode asked for, unlike `bench-compress`, because the question is
//! what each mode costs; the C is `ReleaseFast` in all of them.

const std = @import("std");
const builtin = @import("builtin");
const nilo = @import("nilo_http");
const compress = nilo.compress;

const depth = 512 * 1024;
const paint_byte: u8 = 0xA5;

/// Paints below its own frame and returns that frame's address. The call
/// measured is made next, from the same caller, so it starts there too.
noinline fn paint(top: usize) usize {
    const own = @frameAddress();
    const p: [*]volatile u8 = @ptrFromInt(top - depth);
    for (0..own - 512 - (top - depth)) |i| p[i] = paint_byte;
    return own;
}

fn deepest(top: usize, from: usize) usize {
    const p: [*]const u8 = @ptrFromInt(top - depth);
    var i: usize = 0;
    while (i < depth and p[i] == paint_byte) i += 1;
    return from - (top - depth + i);
}

fn text(gpa: std.mem.Allocator, items: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try out.writer.writeAll("{\"items\":[");
    for (0..items) |i| {
        if (i != 0) try out.writer.writeAll(",");
        try out.writer.print("{{\"id\":{d},\"name\":\"Alpha Widget\",\"category\":\"electronics\",\"price\":{d},\"quantity\":{d},\"active\":true}}", .{ i + 1, 100 + (i * 37) % 900, 1 + (i * 7) % 40 });
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn measure(comptime which: compress.Backend, gpa: std.mem.Allocator, bodies: []const []const u8) !void {
    const Pool = compress.PoolOf(which);
    const call = struct {
        noinline fn gzip(pool: *const Pool, arena: std.mem.Allocator, body: []const u8) usize {
            return (pool.gzip(arena, body) orelse unreachable).len;
        }
    }.gzip;
    for ([_]compress.Level{ .fastest, .default, .best }) |level| {
        var pool = try Pool.init(gpa, 1, .{ .level = level, .max_bytes = 0 });
        defer pool.deinit(gpa);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const top = @frameAddress();
        for (bodies) |body| {
            const from = paint(top);
            const n = call(&pool, arena.allocator(), body);
            const used = deepest(top, from);
            std.debug.print("{s:<11} {s:<8} {d:>9} B in  {d:>8} B out  {d:>6} B of stack\n", .{ @tagName(which), @tagName(level), body.len, n, used });
            _ = arena.reset(.retain_capacity);
        }
    }
}

fn run(gpa: std.mem.Allocator) void {
    const bodies = [_][]const u8{
        text(gpa, 40) catch unreachable,
        text(gpa, 600) catch unreachable,
        text(gpa, 9000) catch unreachable,
    };
    std.debug.print("mode {s}\n", .{@tagName(builtin.mode)});
    measure(.std, gpa, &bodies) catch |e| std.debug.panic("{s}", .{@errorName(e)});
    if (compress.libdeflate_linked) measure(.libdeflate, gpa, &bodies) catch |e| std.debug.panic("{s}", .{@errorName(e)});
}

pub fn main() !void {
    // A thread with a stack of known size, so the painted range is mapped.
    const t = try std.Thread.spawn(.{ .stack_size = 2 << 20 }, run, .{std.heap.smp_allocator});
    t.join();
}
