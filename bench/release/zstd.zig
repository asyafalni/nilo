//! nilo_zstd: a 4 KB JSON body compressed at level 3 into a caller's buffer
//! and decoded back into one allocation of its announced size, which is what
//! a response compressed on a pool slot and a request body read from the
//! arena cost between them (ADR 295).
//!
//! The compressor and the decompressor are placed once in `init`, in memory
//! the program owns, as a server's pool would hold them; the operation then
//! allocates only what `Decompressor.decode` asks the arena for, the output.

const std = @import("std");
const zstd = @import("nilo_zstd");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const body_len = 4096;

const Program = struct {
    gpa: std.mem.Allocator,
    body: []u8,
    out: []u8,
    cmem: zstd.Workspace,
    dmem: zstd.Workspace,
    compressor: zstd.Compressor,
    decompressor: zstd.Decompressor,

    pub fn init(gpa: std.mem.Allocator) !Program {
        const body = try gpa.alloc(u8, body_len);
        var at: usize = 0;
        var i: u32 = 0;
        while (at < body_len) : (i += 1) {
            const line = std.fmt.bufPrint(body[at..], "{{\"id\":{d},\"name\":\"item-{d}\",\"tags\":[\"a\",\"b\"],\"price\":{d}}},", .{ i, i % 17, 100 + i * 37 % 900 }) catch {
                @memset(body[at..], ' ');
                break;
            };
            at += line.len;
        }
        const cmem = try gpa.alignedAlloc(u8, zstd.workspace_alignment, zstd.Compressor.contextSize(.{}, body_len));
        const dmem = try gpa.alignedAlloc(u8, zstd.workspace_alignment, zstd.Decompressor.contextSize());
        return .{
            .gpa = gpa,
            .body = body,
            .out = try gpa.alloc(u8, zstd.compressBound(body_len)),
            .cmem = cmem,
            .dmem = dmem,
            .compressor = try .init(cmem, .{}, body_len),
            .decompressor = try .init(dmem, .{}),
        };
    }

    pub fn deinit(self: *Program) void {
        self.gpa.free(self.body);
        self.gpa.free(self.out);
        self.gpa.free(self.cmem);
        self.gpa.free(self.dmem);
    }

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        const frame = try self.compressor.compress(self.out, self.body);
        const back = try self.decompressor.decode(scratch, frame, body_len);
        harness.keep(back.ptr);
    }
};
