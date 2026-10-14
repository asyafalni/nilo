//! nilo_id: a v7 key made from entropy already in hand, printed, and parsed
//! back, which is a key's whole life on the way into a row and out of a URL,
//! and one made by `v7Now`, which also reads the clock and steps the counter
//! that keeps a burst of keys in order (ADR 143).

const std = @import("std");
const id = @import("nilo_id");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

/// The least that has `entropy`, which is all `v7Now` asks of its argument.
const Scope = struct {
    byte: u8,

    pub fn entropy(self: *Scope, comptime n: usize) ![n]u8 {
        return @splat(self.byte);
    }
};

const Program = struct {
    pub fn init(_: std.mem.Allocator) !Program {
        return .{};
    }

    pub fn deinit(_: *Program) void {}

    pub fn op(_: *Program, _: std.mem.Allocator, i: usize) !void {
        var entropy: [10]u8 = @splat(@truncate(i));
        harness.keep(&entropy);
        const key = id.v7(entropy, 1_759_300_000_000 + i);
        var scope: Scope = .{ .byte = @truncate(i) };
        const minted = try id.Uuid.v7Now(&scope);
        harness.keep(&minted);
        const text = key.toText();
        const back = try id.Uuid.parse(&text);
        harness.keep(&back);
    }
};
