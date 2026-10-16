//! `size-zstd`: a program that only compresses (ADR 295).

const std = @import("std");
const zstd = @import("nilo_zstd");

var src: [4096]u8 = undefined;
var dst: [8192]u8 = undefined;
var memory: [96 * 1024]u8 align(8) = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    var args: std.process.Args.Iterator = .init(init.args);
    var n: usize = 0;
    while (args.next()) |_| n += 1;
    @memset(&src, @truncate(n));
    var c = zstd.Compressor.init(&memory, .{}, src.len) catch return 1;
    const frame = c.compress(&dst, &src) catch return 2;
    return frame[n % frame.len];
}
