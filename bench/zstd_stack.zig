//! The stack one zstd call writes below its caller (ADR 062, ADR 295).
//!
//! A fiber holds its stack at the deepest byte it ever wrote, for the life of
//! the connection, so what compressing or decoding costs a connection is how
//! deep the call goes. Measured the way `bench-compress-stack` measures
//! gzip: the stack below the caller painted, one call, the deepest byte that
//! changed. Through the module's own calls, so the figure is what a handler
//! or the Engine would pay.
//!
//! ```
//! zig build bench-zstd-stack -Doptimize=ReleaseSafe
//! ```
//!
//! Built in the mode asked for, because the question is what each mode costs;
//! the C is `ReleaseFast` in all of them.

const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("nilo_zstd");

const depth = 512 * 1024;
const paint_byte: u8 = 0xA5;

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

noinline fn compressCall(c: *zstd.Compressor, dst: []u8, src: []const u8) usize {
    return (c.compress(dst, src) catch unreachable).len;
}

noinline fn decompressCall(d: *zstd.Decompressor, dst: []u8, src: []const u8) usize {
    return (d.decompress(dst, src) catch unreachable).len;
}

noinline fn streamDecodeCall(mem: zstd.Workspace, frame: []const u8, out: []u8) usize {
    var in: std.Io.Reader = .fixed(frame);
    var d = zstd.StreamDecoder.init(mem, &in, &.{}, .{}) catch unreachable;
    var w: std.Io.Writer = .fixed(out);
    return d.reader.streamRemaining(&w) catch unreachable;
}

noinline fn streamEncodeCall(mem: zstd.Workspace, level: i32, src: []const u8, out: []u8) usize {
    var sink: std.Io.Writer = .fixed(out);
    var buf: [1024]u8 = undefined;
    var s = zstd.StreamCompressor.init(mem, &sink, &buf, .{ .level = level, .window_log = 17 }) catch unreachable;
    var at: usize = 0;
    while (at < src.len) : (at += 1000) {
        s.writer.writeAll(src[at..@min(at + 1000, src.len)]) catch unreachable;
        s.writer.flush() catch unreachable;
    }
    s.finish() catch unreachable;
    return sink.end;
}

fn alignedMem(gpa: std.mem.Allocator, n: usize) zstd.Workspace {
    return gpa.alignedAlloc(u8, zstd.workspace_alignment, n) catch unreachable;
}

fn run(gpa: std.mem.Allocator) void {
    const bodies = [_][]const u8{
        text(gpa, 40) catch unreachable,
        text(gpa, 600) catch unreachable,
        text(gpa, 9000) catch unreachable,
    };
    const print = std.debug.print;
    print("mode {s}\n", .{@tagName(builtin.mode)});
    const top = @frameAddress();
    for ([_]i32{ 1, 3, 6, 12 }) |level| {
        for (bodies) |body| {
            const mem = alignedMem(gpa, zstd.Compressor.contextSize(.{ .level = level }, body.len));
            defer gpa.free(mem);
            var c = zstd.Compressor.init(mem, .{ .level = level }, body.len) catch unreachable;
            const dst = gpa.alloc(u8, zstd.compressBound(body.len)) catch unreachable;
            defer gpa.free(dst);
            const from = paint(top);
            const n = compressCall(&c, dst, body);
            print("compress     level {d:>2} {d:>9} B in {d:>8} B out {d:>6} B of stack\n", .{ level, body.len, n, deepest(top, from) });
        }
    }
    for (bodies) |body| {
        const mem = alignedMem(gpa, zstd.Compressor.contextSize(.{}, body.len));
        defer gpa.free(mem);
        var c = zstd.Compressor.init(mem, .{}, body.len) catch unreachable;
        const frame_buf = gpa.alloc(u8, zstd.compressBound(body.len)) catch unreachable;
        defer gpa.free(frame_buf);
        const frame = c.compress(frame_buf, body) catch unreachable;
        const dmem = alignedMem(gpa, zstd.Decompressor.contextSize());
        defer gpa.free(dmem);
        var d = zstd.Decompressor.init(dmem, .{}) catch unreachable;
        const out = gpa.alloc(u8, body.len) catch unreachable;
        defer gpa.free(out);
        var from = paint(top);
        var n = decompressCall(&d, out, frame);
        print("decompress   one-shot  {d:>9} B out                  {d:>6} B of stack\n", .{ n, deepest(top, from) });
        const smem = alignedMem(gpa, zstd.StreamDecoder.sizeFrom(frame, .{}) catch unreachable);
        defer gpa.free(smem);
        from = paint(top);
        n = streamDecodeCall(smem, frame, out);
        print("decompress   streaming {d:>9} B out                  {d:>6} B of stack\n", .{ n, deepest(top, from) });
        const emem = alignedMem(gpa, zstd.StreamCompressor.contextSize(.{ .level = 3, .window_log = 17 }));
        defer gpa.free(emem);
        const sink_buf = gpa.alloc(u8, zstd.compressBound(body.len) + 4096) catch unreachable;
        defer gpa.free(sink_buf);
        from = paint(top);
        n = streamEncodeCall(emem, 3, body, sink_buf);
        print("compress     stream+flush {d:>7} B in {d:>8} B out {d:>6} B of stack\n", .{ body.len, n, deepest(top, from) });
    }
}

pub fn main() !void {
    // A thread with a stack of known size, so the painted range is mapped.
    const t = try std.Thread.spawn(.{ .stack_size = 2 << 20 }, run, .{std.heap.smp_allocator});
    t.join();
}
