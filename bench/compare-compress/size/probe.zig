//! One program, one codec chosen at build time with -Dcodec via a root
//! option file (codec.zig). It compresses argv[1] and exits with the
//! length's low byte, so nothing is folded away and nothing else is linked.
const std = @import("std");
const codec = @import("codec.zig").codec;

extern fn libdeflate_alloc_compressor(level: c_int) ?*anyopaque;
extern fn libdeflate_gzip_compress(c: *anyopaque, in: [*]const u8, n: usize, out: [*]u8, avail: usize) usize;
extern fn ZSTD_createCCtx() ?*anyopaque;
extern fn ZSTD_compressCCtx(c: *anyopaque, dst: [*]u8, cap: usize, src: [*]const u8, n: usize, level: c_int) usize;
extern fn BrotliEncoderCompress(quality: c_int, lgwin: c_int, mode: c_int, in_size: usize, in: [*]const u8, out_size: *usize, out: [*]u8) c_int;

var out: [1 << 20]u8 = undefined;
var window: [std.compress.flate.max_window_len]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    if (args.len < 2) return 0;
    const in = std.mem.span(args[1]);
    const lv: c_int = @intCast(args.len); // runtime level, as a server option would be
    var n: usize = in.len;
    switch (codec) {
        .base => {},
        .std_flate => {
            var w: std.Io.Writer = .fixed(&out);
            var c = std.compress.flate.Compress.init(&w, &window, .gzip, if (lv > 3) .best else .default) catch return 1;
            c.writer.writeAll(in) catch return 1;
            c.finish() catch return 1;
            n = w.end;
        },
        .libdeflate => {
            const c = libdeflate_alloc_compressor(lv + 4) orelse return 1;
            n = libdeflate_gzip_compress(c, in.ptr, in.len, &out, out.len);
        },
        .zstd => {
            const c = ZSTD_createCCtx() orelse return 1;
            n = ZSTD_compressCCtx(c, &out, out.len, in.ptr, in.len, lv + 1);
        },
        .brotli => {
            n = out.len;
            _ = BrotliEncoderCompress(lv + 3, 22, 0, in.len, in.ptr, &n, &out);
        },
        .libdeflate_brotli => {
            const c = libdeflate_alloc_compressor(lv + 4) orelse return 1;
            n = libdeflate_gzip_compress(c, in.ptr, in.len, &out, out.len);
            var m: usize = out.len;
            _ = BrotliEncoderCompress(lv + 3, 22, 0, in.len, in.ptr, &m, &out);
            n +%= m;
        },
    }
    return @truncate(n);
}
