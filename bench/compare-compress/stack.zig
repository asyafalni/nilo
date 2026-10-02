//! Stack a compression call touches, the way ADR 062 counts it: paint the
//! stack below the caller, compress once, and find the deepest byte that
//! changed. Run on a thread with a known stack so the painted range exists.

const std = @import("std");
const flate = std.compress.flate;

const LdfOptions = extern struct {
    sizeof_options: usize,
    malloc_func: ?*const fn (usize) callconv(.c) ?*anyopaque,
    free_func: ?*const fn (?*anyopaque) callconv(.c) void,
};
extern fn libdeflate_alloc_compressor(level: c_int) ?*anyopaque;
extern fn libdeflate_gzip_compress(c: *anyopaque, in: [*]const u8, n: usize, out: [*]u8, avail: usize) usize;

const small = @embedFile("bodies/arena-25.json");
const mid = @embedFile("bodies/bench-400.json");
const large = @embedFile("bodies/arenalarge-all.json");

const depth = 512 * 1024;
const paint_byte: u8 = 0xA5;
var out_buf: [2 << 20]u8 = undefined;

/// Paints below its own frame and returns that frame's address. The
/// compressor is called next from the same caller at the same depth, so
/// its frame starts at the same address and that is what depth is from.
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

const Slot = struct {
    state: flate.Compress,
    window: [flate.max_window_len]u8,
    vtable: *const std.Io.Writer.VTable,
};

fn reset(slot: *Slot, output: *std.Io.Writer, opts: flate.Compress.Options) std.Io.Writer.Error!void {
    const c = &slot.state;
    try output.writeAll(flate.Container.gzip.header());
    c.writer = .{ .buffer = &slot.window, .vtable = slot.vtable, .end = 0 };
    c.history_len = 0;
    c.history_end_unhashed = false;
    c.bit_writer.output = output;
    c.bit_writer.buffered = 0;
    c.bit_writer.buffered_n = 0;
    c.buffered_tokens.pos = 0;
    c.buffered_tokens.n = 0;
    @memset(&c.buffered_tokens.lit_freqs, 0);
    @memset(&c.buffered_tokens.dist_freqs, 0);
    @memset(&c.lookup.head, .{ .value = std.math.maxInt(u15), .is_null = true });
    c.lookup.chain_pos = std.math.maxInt(u15);
    c.container = .gzip;
    c.opts = opts;
    c.hasher = .init(.gzip);
}

noinline fn viaLibdeflate(c: *anyopaque, body: []const u8) usize {
    return libdeflate_gzip_compress(c, body.ptr, body.len, &out_buf, out_buf.len);
}

noinline fn viaStd(slot: *Slot, opts: flate.Compress.Options, body: []const u8) usize {
    var w: std.Io.Writer = .fixed(&out_buf);
    reset(slot, &w, opts) catch unreachable;
    slot.state.writer.writeAll(body) catch unreachable;
    slot.state.finish() catch unreachable;
    return w.end;
}

fn run(slot: *Slot) void {
    const top = @frameAddress();
    const bodies = [_]struct { []const u8, []const u8 }{ .{ "4 KB", small }, .{ "64 KB", mid }, .{ "1 MB", large } };
    for ([_]c_int{ 1, 6, 9 }) |level| {
        const c = libdeflate_alloc_compressor(level).?;
        for (bodies) |b| {
            const from = paint(top);
            std.debug.assert(viaLibdeflate(c, b[1]) != 0);
            std.debug.print("libdeflate-{d}  {s:<6} {d:>7} bytes\n", .{ level, b[0], deepest(top, from) });
        }
    }
    for ([_]struct { []const u8, flate.Compress.Options }{ .{ "std-flate-1", .fastest }, .{ "std-flate-6", .default } }) |o| {
        var scratch: [16]u8 = undefined;
        var discard: std.Io.Writer = .fixed(&scratch);
        slot.state = flate.Compress.init(&discard, &slot.window, .gzip, o[1]) catch unreachable;
        slot.vtable = slot.state.writer.vtable;
        for (bodies) |b| {
            const from = paint(top);
            std.debug.assert(viaStd(slot, o[1], b[1]) != 0);
            std.debug.print("{s:<13} {s:<6} {d:>7} bytes\n", .{ o[0], b[0], deepest(top, from) });
        }
    }
}

pub fn main() !void {
    const slot = try std.heap.c_allocator.create(Slot);
    const t = try std.Thread.spawn(.{ .stack_size = 2 << 20 }, run, .{slot});
    t.join();
}
