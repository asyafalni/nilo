//! `size-zstd`: a program that only decompresses (ADR 295). The frame is a
//! constant, so nothing in it asks for the encoder.

const std = @import("std");
const zstd = @import("nilo_zstd");

var out: [8192]u8 = undefined;
var memory: [96 * 1024]u8 align(8) = undefined;

/// `"hello"` repeated, as `zstd -3` writes it.
const frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x0f, 0x41, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x01, 0x00, 0x00 };

pub fn main(init: std.process.Init.Minimal) u8 {
    var args: std.process.Args.Iterator = .init(init.args);
    var n: usize = 0;
    while (args.next()) |_| n += 1;
    var d = zstd.Decompressor.init(&memory, .{}) catch return 1;
    var input = frame;
    input[0] +%= @truncate(n -| 1);
    const back = d.decompress(&out, &input) catch return 2;
    return back[n % @max(back.len, 1)];
}
