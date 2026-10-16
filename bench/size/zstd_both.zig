//! `size-zstd`: a program that compresses and decompresses (ADR 295).

const std = @import("std");
const zstd = @import("nilo_zstd");

var src: [4096]u8 = undefined;
var dst: [8192]u8 = undefined;
var back: [4096]u8 = undefined;
var cmemory: [96 * 1024]u8 align(8) = undefined;
var dmemory: [96 * 1024]u8 align(8) = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    var args: std.process.Args.Iterator = .init(init.args);
    var n: usize = 0;
    while (args.next()) |_| n += 1;
    @memset(&src, @truncate(n));
    var c = zstd.Compressor.init(&cmemory, .{}, src.len) catch return 1;
    const frame = c.compress(&dst, &src) catch return 2;
    var d = zstd.Decompressor.init(&dmemory, .{}) catch return 3;
    const got = d.decompress(&back, frame) catch return 4;
    return got[n % got.len];
}
