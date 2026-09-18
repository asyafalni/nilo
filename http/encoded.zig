//! A request body under `Content-Encoding: gzip`, decoded into the arena
//! ([ADR 0251](../docs/adr/0251-a-gzipped-body-is-inflated-into-the-buffer-that-holds-it.md)).
//!
//! The roadmap held this behind a pool of 64 KB windows shared with response
//! compression, and the pool turned out to be the wrong half of the answer
//! for this direction. A deflate *compressor* needs a window and a hash chain
//! of its own; a *decompressor* needs only the last 32 KiB of what it has
//! written, to copy back-references from — and `std.compress.flate.Decompress`
//! has a mode in which that history is the destination writer's own buffer.
//! Handed no window at all, it writes straight into the writer and reaches
//! back into it for matches. The request arena is going to hold the decoded
//! body anyway, so the buffer that holds the body *is* the window, and there
//! is nothing to pool.
//!
//! The other thing a gzip stream carries is its own answer to "how big":
//! the last four bytes are the uncompressed length, modulo 2³². Reading
//! them first is what makes the allocation exact — one `alloc` of the
//! announced size, no growth loop — and what makes the ceiling a check
//! against a number rather than a limit hit halfway through inflating.
//! A stream that lies about that number in either direction fails to
//! decode, and is refused as one that could not be read.

const std = @import("std");

pub const Error = error{
    /// The decoded body would be over the ceiling, by the stream's own
    /// account of its length. Nothing was inflated.
    BodyTooLarge,
    /// The bytes are not a gzip stream this server could decode to the
    /// length it claimed: a truncated stream, a corrupt one, a trailer that
    /// disagrees with the bytes in front of it, or two members where one
    /// was announced.
    BadEncodedBody,
    OutOfMemory,
};

/// A gzip member is a ten-byte header and an eight-byte trailer around the
/// deflate stream; anything shorter cannot be one.
const frame_len = 10 + 8;

/// `raw`, inflated into `arena`, at most `limit` bytes.
///
/// `arena` is meant to be the request arena, on the terms `readSizedBody`
/// states: a stream that fails partway leaves what was allocated, which
/// against an arena is free.
pub fn inflate(arena: std.mem.Allocator, raw: []const u8, limit: usize) Error![]const u8 {
    if (raw.len < frame_len) return error.BadEncodedBody;
    // The magic and the method, before the trailer is believed: the last
    // four bytes of a JSON body somebody forgot to compress are a number
    // too, and reading them as a length would turn "not gzip" into "too
    // large", which sends the reader to the wrong header.
    if (!std.mem.eql(u8, raw[0..3], "\x1f\x8b\x08")) return error.BadEncodedBody;

    // ISIZE, the last four bytes: what the stream says it will come to.
    const announced = std.mem.readInt(u32, raw[raw.len - 4 ..][0..4], .little);
    // Deflate cannot expand past about 1032 to one — 258 bytes for a
    // two-bit symbol is the ceiling of the format — so a trailer claiming
    // more than that is not a trailer. It is the last four bytes of a
    // stream that was cut off, and the right answer for that is the one
    // for every other broken stream, not a 413 about a size nobody sent.
    if (announced > raw.len * 1032) return error.BadEncodedBody;
    if (announced > limit) return error.BodyTooLarge;

    const out = try arena.alloc(u8, announced);
    var in: std.Io.Reader = .fixed(raw);
    // No window: the destination is the history (see the header).
    var inflating: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var w: std.Io.Writer = .fixed(out);

    // A stream producing more than it announced runs the fixed writer out
    // of room, which is `WriteFailed`; one producing less, or corrupt, is
    // `ReadFailed`. Both are the stream's fault and one answer.
    _ = inflating.reader.streamRemaining(&w) catch return error.BadEncodedBody;
    if (w.end != announced) return error.BadEncodedBody;
    return out;
}

const testing = std.testing;

/// `text`, gzipped by std's own compressor — so the test is std reading
/// what std wrote, and the property under test is this file's, not the
/// codec's.
fn gzipped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    // `Compress.init` asserts its output has somewhere to write, and an
    // `Allocating` starts with a buffer of nothing at all (see `static.zig`).
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&out.writer, &window, .gzip, .default);
    try compress.writer.writeAll(text);
    try compress.finish();
    return out.toOwnedSlice();
}

test "a gzipped body comes back as the bytes that were compressed, in one allocation of their size" {
    const gpa = testing.allocator;
    const text = "{\"name\":\"wati\",\"tags\":[\"a\",\"b\",\"a\",\"b\",\"a\",\"b\"]}" ** 40;
    const packed_bytes = try gzipped(gpa, text);
    defer gpa.free(packed_bytes);
    try testing.expect(packed_bytes.len < text.len);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const out = try inflate(arena.allocator(), packed_bytes, 1 << 20);
    try testing.expectEqualStrings(text, out);
}

test "an empty body gzips to a frame and inflates to nothing" {
    const gpa = testing.allocator;
    const packed_bytes = try gzipped(gpa, "");
    defer gpa.free(packed_bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expectEqualStrings("", try inflate(arena.allocator(), packed_bytes, 16));
}

test "the ceiling is checked against the announced length before a byte is inflated" {
    const gpa = testing.allocator;
    const text = "x" ** 5000;
    const packed_bytes = try gzipped(gpa, text);
    defer gpa.free(packed_bytes);
    // Under it, whole. At it, whole. One under, refused — and refused by
    // the number, which is why a limit of 4999 costs no inflating at all.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 5000), (try inflate(arena.allocator(), packed_bytes, 5000)).len);
    try testing.expectError(error.BodyTooLarge, inflate(arena.allocator(), packed_bytes, 4999));
}

test "a stream that is not what it says it is, is refused rather than read as far as it goes" {
    const gpa = testing.allocator;
    const packed_bytes = try gzipped(gpa, "the quick brown fox jumps over the lazy dog, twice: " ** 10);
    defer gpa.free(packed_bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Too short to be a member at all.
    try testing.expectError(error.BadEncodedBody, inflate(a, "", 1024));
    try testing.expectError(error.BadEncodedBody, inflate(a, packed_bytes[0..17], 1024));
    // Not gzip: the JSON somebody forgot to compress, under a header that
    // says they did.
    try testing.expectError(error.BadEncodedBody, inflate(a, "{\"name\":\"wati\",\"a\":1,\"b\":2}", 1024));

    // Truncated in the middle: the trailer is gone, so the announced length
    // is whatever bytes happen to be last, and the stream ends early.
    const cut = try gpa.dupe(u8, packed_bytes[0 .. packed_bytes.len - 12]);
    defer gpa.free(cut);
    try testing.expectError(error.BadEncodedBody, inflate(a, cut, 1 << 20));

    // A trailer that claims less than the stream holds: the writer runs out.
    const under = try gpa.dupe(u8, packed_bytes);
    defer gpa.free(under);
    std.mem.writeInt(u32, under[under.len - 4 ..][0..4], 7, .little);
    try testing.expectError(error.BadEncodedBody, inflate(a, under, 1 << 20));

    // A trailer that claims more: the stream ends short of it.
    const over = try gpa.dupe(u8, packed_bytes);
    defer gpa.free(over);
    std.mem.writeInt(u32, over[over.len - 4 ..][0..4], 100_000, .little);
    try testing.expectError(error.BadEncodedBody, inflate(a, over, 1 << 20));
}
