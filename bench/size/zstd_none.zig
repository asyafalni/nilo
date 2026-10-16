//! The control for `size-zstd`: a program that does what the others do around
//! libzstd and nothing with it (ADR 295).

const std = @import("std");

var src: [4096]u8 = undefined;
var dst: [8192]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    var args: std.process.Args.Iterator = .init(init.args);
    var n: usize = 0;
    while (args.next()) |_| n += 1;
    @memset(&src, @truncate(n));
    @memcpy(dst[0..src.len], &src);
    return dst[n % dst.len];
}
