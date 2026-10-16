//! The reading side of a gzip answer, for the builds that asked for it
//! ([ADR 292](../docs/adr/292-a-fetch-build-can-read-a-gzip-answer.md)).
//!
//! Nothing here is reached unless `decode.zig` names `Gunzip` under its
//! `reads_gzip` constant, and that constant is `-Dfetch_gzip`. So a program
//! that did not pass the flag links no flate, holds no window and allocates
//! nothing for a decoder, and this file is analysed only as far as its imports.
//!
//! **Where the state lives.** `std.http.Decompress` holds a flate window of
//! 64 KiB (`flate.max_window_len`) and the code tables, and on a handler's
//! stack that is held per *inbound connection* for as long as the fiber
//! sleeps (ADR 062). So the whole decoder is one allocation from the
//! client's allocator, made when an answer announces `Content-Encoding:
//! gzip` and given back by `Exchange.end`. The stack of a call grows by one
//! pointer, and an answer that is not gzip pays nothing at all.
//!
//! **A second coding is a case in `decode.zig`**, and zstd is the second
//! (`zstd_read.zig`).

const std = @import("std");
const flate = std.compress.flate;
const decode = @import("decode.zig");

/// The bytes asked of the connection at a time. flate asserts its input holds
/// ten bytes and the body reader keeps no buffer of its own for the
/// framings `take` serves from the connection's, so the decoder brings one:
/// a size that costs a handful of reads for a megabyte and no more.
const input_len = 4096;

/// One answer being decoded. Address sensitive (the readers find it by
/// `@fieldParentPtr`), so it is made on the heap and never moved.
pub const Gunzip = struct {
    /// First, so that the front of the allocation is the `Reading` the
    /// caller holds. Its `out` is the decoded body as the caller reads it:
    /// flate's own reader seen through a CRC-32 and a byte count, because
    /// `std.compress.flate` reads the gzip footer and compares nothing in it.
    /// Unbuffered, so every byte flows through `decoded` once.
    head: decode.Reading,
    gpa: std.mem.Allocator,
    /// A buffered face for `source`, which flate needs and which the body
    /// reader (empty buffer, bytes straight from the socket) is not.
    input: std.Io.Reader,
    flate: flate.Decompress,
    crc: std.hash.Crc32,
    count: u32,
    /// The stream ended and its footer is not what was decoded.
    mismatch: bool,
    input_buffer: [input_len]u8,
    window: [flate.max_window_len]u8,

    /// Nothing is read from `source` until the first read of the result's
    /// `reader()`.
    pub fn open(gpa: std.mem.Allocator, source: *std.Io.Reader) error{OutOfMemory}!*decode.Reading {
        const self = try gpa.create(Gunzip);
        self.gpa = gpa;
        self.head = .{
            .source = source,
            .out = .{ .vtable = &.{ .stream = decoded }, .buffer = &.{}, .seek = 0, .end = 0 },
            .vtable = &reading_vtable,
        };
        self.input = .{ .vtable = &.{ .stream = pass }, .buffer = &self.input_buffer, .seek = 0, .end = 0 };
        self.flate = .init(&self.input, .gzip, &self.window);
        self.crc = .init();
        self.count = 0;
        self.mismatch = false;
        return &self.head;
    }

    const reading_vtable: decode.Reading.VTable = .{
        .close = close,
        .undecodable = undecodable,
        .outOfMemory = outOfMemory,
    };

    fn close(head: *decode.Reading) void {
        const self: *Gunzip = @fieldParentPtr("head", head);
        self.gpa.destroy(self);
    }

    /// A header that is not gzip, a block that does not decode, a checksum
    /// or a length that disagrees with the footer, a body that ends before
    /// the stream does. A failure of the connection is the same error flate
    /// gets from `source`.
    fn undecodable(head: *const decode.Reading) bool {
        const self: *const Gunzip = @fieldParentPtr("head", head);
        if (self.mismatch) return true;
        const err = self.flate.err orelse return false;
        return err != error.ReadFailed;
    }

    fn outOfMemory(_: *const decode.Reading) bool {
        return false;
    }

    fn decoded(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const head: *decode.Reading = @alignCast(@fieldParentPtr("out", r));
        const self: *Gunzip = @fieldParentPtr("head", head);
        var hashed: std.Io.Writer.Hashed(std.hash.Crc32) = .initHasher(w, self.crc, &.{});
        defer self.crc = hashed.hasher;
        const n = self.flate.reader.stream(&hashed.writer, limit) catch |err| {
            if (err == error.EndOfStream) {
                // The footer was read as the stream ended, and is checked
                // here, against what went by.
                const footer = self.flate.container_metadata.gzip;
                if (footer.crc != hashed.hasher.final() or footer.count != self.count) {
                    self.mismatch = true;
                    return error.ReadFailed;
                }
            }
            return err;
        };
        self.count +%= @truncate(n);
        return n;
    }

    fn pass(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Gunzip = @alignCast(@fieldParentPtr("input", r));
        return self.head.source.stream(w, limit);
    }
};

/// A gzip stream of `plain`, into the allocator's memory. For a test that
/// serves one, and for the benchmark; it is not part of the reading side.
pub fn compressed(gpa: std.mem.Allocator, plain: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .gzip, .default);
    try c.writer.writeAll(plain);
    try c.finish();
    return out.toOwnedSlice();
}

test "a gzip stream reads back as what it was" {
    const gpa = std.testing.allocator;
    var built: std.Io.Writer.Allocating = .init(gpa);
    defer built.deinit();
    for (0..500) |_| try built.writer.writeAll("{\"a\":1}");
    const plain = built.written();
    const packed_bytes = try compressed(gpa, plain);
    defer gpa.free(packed_bytes);
    try std.testing.expect(packed_bytes.len < plain.len / 10);

    var source: std.Io.Reader = .fixed(packed_bytes);
    const reading = try decode.Reading.open(gpa, &source, .gzip);
    defer reading.close();
    const got = try reading.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(plain, got);
}

test "bytes that are not gzip are undecodable and a dead connection is not" {
    const gpa = std.testing.allocator;
    var source: std.Io.Reader = .fixed("this is not gzip at all, not at all");
    const reading = try decode.Reading.open(gpa, &source, .gzip);
    defer reading.close();
    try std.testing.expectError(error.ReadFailed, reading.reader().allocRemaining(gpa, .unlimited));
    try std.testing.expect(reading.undecodable());
}

test "a footer that disagrees with the body is undecodable" {
    const gpa = std.testing.allocator;
    const plain = "the quick brown fox jumps over the lazy dog, the quick brown fox jumps over the lazy dog, again and again";
    for ([_]usize{ 8, 4 }) |from_end| {
        const packed_bytes = try compressed(gpa, plain);
        defer gpa.free(packed_bytes);
        // The CRC-32 and then the length, which std reads and compares to nothing.
        packed_bytes[packed_bytes.len - from_end] ^= 0x01;

        var source: std.Io.Reader = .fixed(packed_bytes);
        const reading = try decode.Reading.open(gpa, &source, .gzip);
        defer reading.close();
        try std.testing.expectError(error.ReadFailed, reading.reader().allocRemaining(gpa, .unlimited));
        try std.testing.expect(reading.undecodable());
    }
}
