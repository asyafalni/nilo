//! The reading side of a zstd answer, for the builds that asked for it
//! ([ADR 295](../docs/adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md),
//! item 5).
//!
//! Nothing here is reached unless `decode.zig` names `Unzstd` under its
//! `reads_zstd` constant, and that constant is `-Dfetch_zstd`. So a program
//! that did not pass the flag links no libzstd and allocates nothing for a
//! decoder.
//!
//! **Where the state lives, and when it is sized.** A streaming decoder holds
//! the frame's window, and a fiber keeps its stack at its high-water mark
//! (ADR 062), so none of it is on the stack: the header and a 16 KiB input
//! buffer are one allocation from the client's allocator, made when an
//! answer announces `Content-Encoding: zstd`, and the decoder's context is a
//! second one, **made at the first read, once the first bytes of the body say
//! what the frame needs** (`StreamDecoder.sizeFrom`: a frame that announces
//! its size is sized to it, 112 KB for a small answer). The first read is
//! inside the clocks a body read is under, which `begin` is not, so a peer
//! that sends a head and then nothing is stopped by the stall bound and not
//! waited for in `begin`. The window a frame may ask for is capped at the
//! 8 MB RFC 9659 requires every HTTP decoder to accept, so the most a peer
//! can make a call hold is that and a block, never what its header claims.
//!
//! **The decoded bytes are counted by the caller's reader**: `take` reads
//! this one under `Limit.limited(max_body)` and so a small answer cannot
//! inflate past it (a bomb is `BodyTooLarge`); `pipe` and `stream` are the
//! caller's own writer, as they are for gzip. The frame's checksum, when it
//! carries one, is checked by libzstd.

const std = @import("std");
const zstd = @import("nilo_zstd");
const decode = @import("decode.zig");

/// The bytes asked of the connection at a time. `sizeFromSource` peeks up to
/// `frame_header_max` of them, and libzstd decodes from whatever is there.
const input_len = 16 << 10;

/// The largest window a frame may ask for: RFC 9659's 8 MB.
const options: zstd.DecodeOptions = .{ .window_log_max = zstd.http_window_log };

pub const Unzstd = struct {
    /// First field, so the `Reading` the caller holds is the front of the
    /// allocation.
    head: decode.Reading,
    gpa: std.mem.Allocator,
    /// A buffered face for `head.source`, which libzstd's reader needs and
    /// which the body reader (empty buffer, bytes straight from the socket)
    /// is not.
    input: std.Io.Reader,
    /// Null until the first read.
    memory: ?zstd.Workspace,
    decoder: zstd.StreamDecoder,
    /// The bytes are not a frame this build decodes, as opposed to the
    /// connection failing under the decoder.
    bytes_failed: bool,
    memory_failed: bool,
    input_buffer: [input_len]u8,

    /// Nothing is read from `source` until the first read of the result's
    /// `reader()`.
    pub fn open(gpa: std.mem.Allocator, source: *std.Io.Reader) error{OutOfMemory}!*decode.Reading {
        const self = try gpa.create(Unzstd);
        self.gpa = gpa;
        self.head = .{
            .source = source,
            .out = .{ .vtable = &.{ .stream = decoded }, .buffer = &.{}, .seek = 0, .end = 0 },
            .vtable = &reading_vtable,
        };
        self.input = .{ .vtable = &.{ .stream = pass }, .buffer = &self.input_buffer, .seek = 0, .end = 0 };
        self.memory = null;
        self.decoder = undefined;
        self.bytes_failed = false;
        self.memory_failed = false;
        return &self.head;
    }

    const reading_vtable: decode.Reading.VTable = .{
        .close = close,
        .undecodable = undecodable,
        .outOfMemory = outOfMemory,
    };

    fn close(head: *decode.Reading) void {
        const self: *Unzstd = @fieldParentPtr("head", head);
        if (self.memory) |m| self.gpa.free(m);
        self.gpa.destroy(self);
    }

    fn undecodable(head: *const decode.Reading) bool {
        const self: *const Unzstd = @fieldParentPtr("head", head);
        return self.bytes_failed;
    }

    fn outOfMemory(head: *const decode.Reading) bool {
        const self: *const Unzstd = @fieldParentPtr("head", head);
        return self.memory_failed;
    }

    /// Size the decoder from the first bytes of the body and make it.
    /// `error.EndOfStream` is a body of no bytes at all, which is an empty
    /// answer and not a damaged one.
    fn start(self: *Unzstd) std.Io.Reader.StreamError!void {
        _ = self.input.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        const need = zstd.StreamDecoder.sizeFromSource(&self.input, options) catch |err| {
            // `Failed` is the source's `ReadFailed`: the connection, whose
            // clock is the caller's to name. Anything else is the frame.
            if (err != error.Failed) self.bytes_failed = true;
            return error.ReadFailed;
        };
        const memory = self.gpa.alignedAlloc(u8, zstd.workspace_alignment, need) catch {
            self.memory_failed = true;
            return error.ReadFailed;
        };
        self.memory = memory;
        self.decoder = zstd.StreamDecoder.init(memory, &self.input, &.{}, .{ .window_log_max = options.window_log_max }) catch {
            self.bytes_failed = true;
            return error.ReadFailed;
        };
    }

    fn decoded(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const head: *decode.Reading = @alignCast(@fieldParentPtr("out", r));
        const self: *Unzstd = @fieldParentPtr("head", head);
        if (self.bytes_failed or self.memory_failed) return error.ReadFailed;
        if (self.memory == null) try self.start();
        if (limit == .nothing) return 0;
        // A read that only consumed frame bytes returns zero, which is not
        // the end; the next call goes on. Looping here keeps a caller that
        // reads until zero (`Exchange.stream`) from taking it for one.
        while (true) {
            const n = self.decoder.reader.stream(w, limit) catch |err| switch (err) {
                error.ReadFailed => {
                    // `Failed` with no libzstd code behind it is the source.
                    if (self.decoder.err) |why| {
                        if (why != error.Failed or self.decoder.detail != 0) self.bytes_failed = true;
                    }
                    return error.ReadFailed;
                },
                else => |e| return e,
            };
            if (n != 0) return n;
        }
    }

    fn pass(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Unzstd = @alignCast(@fieldParentPtr("input", r));
        return self.head.source.stream(w, limit);
    }
};

fn compressed(gpa: std.mem.Allocator, plain: []const u8, content_size: bool) ![]u8 {
    const level = 3;
    const options_: zstd.EncodeOptions = .{ .level = level, .content_size = if (content_size) plain.len else null };
    const mem = try gpa.alignedAlloc(u8, zstd.workspace_alignment, zstd.StreamCompressor.contextSize(options_));
    defer gpa.free(mem);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    errdefer out.deinit();
    var c = try zstd.StreamCompressor.init(mem, &out.writer, &.{}, options_);
    try c.writer.writeAll(plain);
    try c.finish();
    return out.toOwnedSlice();
}

test "a zstd frame reads back as what it was, announced size or not" {
    const gpa = std.testing.allocator;
    var built: std.Io.Writer.Allocating = .init(gpa);
    defer built.deinit();
    for (0..500) |_| try built.writer.writeAll("{\"a\":1}");
    const plain = built.written();
    for ([_]bool{ true, false }) |announce| {
        const frame = try compressed(gpa, plain, announce);
        defer gpa.free(frame);
        try std.testing.expect(frame.len < plain.len / 10);

        var source: std.Io.Reader = .fixed(frame);
        const reading = try decode.Reading.open(gpa, &source, .zstd);
        defer reading.close();
        const got = try reading.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(plain, got);
    }
}

test "bytes that are not zstd are undecodable" {
    const gpa = std.testing.allocator;
    var source: std.Io.Reader = .fixed("this is not zstd at all, not at all, not at all");
    const reading = try decode.Reading.open(gpa, &source, .zstd);
    defer reading.close();
    try std.testing.expectError(error.ReadFailed, reading.reader().allocRemaining(gpa, .unlimited));
    try std.testing.expect(reading.undecodable());
}

test "a frame cut short is undecodable and an empty body is an empty answer" {
    const gpa = std.testing.allocator;
    const frame = try compressed(gpa, "the quick brown fox jumps over the lazy dog, the quick brown fox jumps over the lazy dog, the quick brown fox", true);
    defer gpa.free(frame);
    var cut: std.Io.Reader = .fixed(frame[0 .. frame.len - 6]);
    const reading = try decode.Reading.open(gpa, &cut, .zstd);
    defer reading.close();
    try std.testing.expectError(error.ReadFailed, reading.reader().allocRemaining(gpa, .unlimited));
    try std.testing.expect(reading.undecodable());

    var nothing: std.Io.Reader = .fixed("");
    const empty = try decode.Reading.open(gpa, &nothing, .zstd);
    defer empty.close();
    const got = try empty.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
