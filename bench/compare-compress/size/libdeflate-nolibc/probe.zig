//! libdeflate with no libc: its allocator is handed in through
//! libdeflate_alloc_compressor_ex, and memcpy/memset come from compiler_rt.
const std = @import("std");
const LdfOptions = extern struct {
    sizeof_options: usize,
    malloc_func: ?*const fn (usize) callconv(.c) ?*anyopaque,
    free_func: ?*const fn (?*anyopaque) callconv(.c) void,
};
extern fn libdeflate_alloc_compressor_ex(level: c_int, opts: *const LdfOptions) ?*anyopaque;
extern fn libdeflate_gzip_compress(c: *anyopaque, in: [*]const u8, n: usize, out: [*]u8, avail: usize) usize;
var out: [1 << 20]u8 = undefined;
var heap: [1 << 20]u8 align(64) = undefined;
var used: usize = 0;
fn bump(n: usize) callconv(.c) ?*anyopaque {
    const at = std.mem.alignForward(usize, used, 64);
    if (at + n > heap.len) return null;
    used = at + n;
    return &heap[at];
}
fn noFree(_: ?*anyopaque) callconv(.c) void {}
// The library's default allocator names these; never called here.
export fn malloc(n: usize) ?*anyopaque { return bump(n); }
export fn free(p: ?*anyopaque) void { noFree(p); }
pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    if (args.len < 2) return 0;
    const in = std.mem.span(args[1]);
    const o: LdfOptions = .{ .sizeof_options = @sizeOf(LdfOptions), .malloc_func = bump, .free_func = noFree };
    const c = libdeflate_alloc_compressor_ex(@intCast(args.len + 4), &o) orelse return 1;
    return @truncate(libdeflate_gzip_compress(c, in.ptr, in.len, &out, out.len));
}
