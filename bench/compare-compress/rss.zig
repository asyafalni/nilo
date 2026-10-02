//! How much of a compressor's memory a small body actually touches.
//! Each compressor lives alone in its own anonymous mapping, and mincore
//! counts the resident pages after each step: after the allocation, after
//! one 4 KB body, after ten more small bodies, and after a 1 MB body.
//! The std.flate slot is built the way nilo's Pool builds it (Compress.init
//! once, then the in-place reset per body), copied from harness.zig.

const std = @import("std");
const flate = std.compress.flate;
const linux = std.os.linux;

const LdfOptions = extern struct {
    sizeof_options: usize,
    malloc_func: ?*const fn (usize) callconv(.c) ?*anyopaque,
    free_func: ?*const fn (?*anyopaque) callconv(.c) void,
};
extern fn libdeflate_alloc_compressor_ex(level: c_int, opts: *const LdfOptions) ?*anyopaque;
extern fn libdeflate_gzip_compress(c: *anyopaque, in: [*]const u8, n: usize, out: [*]u8, avail: usize) usize;

const small = [_][]const u8{
    @embedFile("bodies/arena-25.json"), @embedFile("bodies/arena-40.json"),
    @embedFile("bodies/arena-50.json"), @embedFile("bodies/bench-25.json"),
    @embedFile("bodies/bench-40.json"), @embedFile("bodies/bench-50.json"),
    @embedFile("bodies/bench-6.json"),
};
const large = @embedFile("bodies/arenalarge-all.json");

const region_len = 8 << 20;
const page = 4096;

fn mapRegion() [*]align(page) u8 {
    const r = linux.mmap(null, region_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    // Without this a fresh anonymous mapping is backed by 2 MB huge pages
    // and mincore reports the whole huge page for one byte touched.
    _ = linux.madvise(@ptrFromInt(r), region_len, linux.MADV.NOHUGEPAGE);
    return @ptrFromInt(r);
}

fn resident(base: [*]align(page) u8) usize {
    var vec: [region_len / page]u8 = undefined;
    _ = linux.syscall3(.mincore, @intFromPtr(base), region_len, @intFromPtr(&vec));
    var n: usize = 0;
    for (vec) |v| n += v & 1;
    return n * page;
}

var bump_base: [*]align(page) u8 = undefined;
var bump_used: usize = 0;
fn bump(n: usize) callconv(.c) ?*anyopaque {
    const at = std.mem.alignForward(usize, bump_used, 64);
    if (at + n > region_len) return null;
    bump_used = at + n;
    return bump_base + at;
}
fn noFree(_: ?*anyopaque) callconv(.c) void {}

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

var out_buf: [2 << 20]u8 = undefined;

fn row(name: []const u8, size: usize, steps: [4]usize) void {
    std.debug.print("{s:<14} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9}\n", .{ name, size, steps[0], steps[1], steps[2], steps[3] });
}

fn libdeflate(level: c_int) void {
    bump_base = mapRegion();
    bump_used = 0;
    const o: LdfOptions = .{ .sizeof_options = @sizeOf(LdfOptions), .malloc_func = bump, .free_func = noFree };
    const c = libdeflate_alloc_compressor_ex(level, &o) orelse @panic("alloc");
    var s: [4]usize = undefined;
    s[0] = resident(bump_base);
    std.debug.assert(libdeflate_gzip_compress(c, small[0].ptr, small[0].len, &out_buf, out_buf.len) != 0);
    s[1] = resident(bump_base);
    for (0..10) |i| {
        const b = small[(i + 1) % small.len];
        std.debug.assert(libdeflate_gzip_compress(c, b.ptr, b.len, &out_buf, out_buf.len) != 0);
    }
    s[2] = resident(bump_base);
    std.debug.assert(libdeflate_gzip_compress(c, large.ptr, large.len, &out_buf, out_buf.len) != 0);
    s[3] = resident(bump_base);
    var name_buf: [32]u8 = undefined;
    row(std.fmt.bufPrint(&name_buf, "libdeflate-{d}", .{level}) catch unreachable, bump_used, s);
}

fn stdFlate(name: []const u8, opts: flate.Compress.Options) !void {
    const base = mapRegion();
    const slot: *Slot = @ptrCast(base);
    var s: [4]usize = undefined;
    var scratch: [16]u8 = undefined;
    var discard: std.Io.Writer = .fixed(&scratch);
    slot.state = try flate.Compress.init(&discard, &slot.window, .gzip, opts);
    slot.vtable = slot.state.writer.vtable;
    s[0] = resident(base);
    const once = struct {
        fn f(sl: *Slot, o: flate.Compress.Options, body: []const u8) !void {
            var w: std.Io.Writer = .fixed(&out_buf);
            try reset(sl, &w, o);
            try sl.state.writer.writeAll(body);
            try sl.state.finish();
        }
    }.f;
    try once(slot, opts, small[0]);
    s[1] = resident(base);
    for (0..10) |i| try once(slot, opts, small[(i + 1) % small.len]);
    s[2] = resident(base);
    try once(slot, opts, large);
    s[3] = resident(base);
    row(name, @sizeOf(Slot), s);
}

pub fn main() !void {
    std.debug.print("{s:<14} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9}\n", .{ "codec", "allocated", "idle", "1x4KB", "+10small", "+1MB" });
    try stdFlate("std-flate-1", .fastest);
    try stdFlate("std-flate-6", .default);
    try stdFlate("std-flate-9", .best);
    for ([_]c_int{ 1, 2, 4, 5, 6, 9 }) |l| libdeflate(l);
}
