//! nilo_pw: checking a sign-in's password against the hash stored for it, at
//! the default Cost. The hash is made once from a fixed salt, so every call
//! does the same work; the 19 MiB comes out of the counted scratch.

const std = @import("std");
const pw = @import("nilo_pw");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const password = "correct horse battery staple";

const Program = struct {
    stored: pw.Hash,

    pub fn init(gpa: std.mem.Allocator) !Program {
        const salt: [pw.salt_len]u8 = @splat(0x5a);
        return .{ .stored = try pw.hash(gpa, password, salt) };
    }

    pub fn deinit(_: *Program) void {}

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        const ok = try pw.verify(scratch, self.stored.text(), password);
        if (!ok) return error.PasswordRefused;
        harness.keep(ok);
    }
};
