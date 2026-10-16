//! A gzip compressor started in place, so no stack ever holds its 96 KB
//! temporary (ADR 293, ADR 211, ADR 062).
//!
//! `std.compress.flate.Compress.init` builds its token buffer as a temporary
//! on the caller's stack before copying it into the result: measured from the
//! assembly, **99,048 bytes of stack** for one call. A fiber keeps its stack
//! at the high-water mark it ever reached, for the life of its connection
//! (ADR 062), so a handler, or a client call made from one, that initialises
//! a compressor on its own stack pays that for every connection it ever
//! serves. `Compress` itself is `~224 KB`, so it lives on the heap or in a
//! pool in any case; the question is only how it gets started.
//!
//! `reset` is what `init` does, field by field, into memory that is already
//! there: about 40 bytes of stack. The one thing `init` has that a field copy
//! cannot is the writer's vtable, whose functions are private to
//! `Compress.zig`. It is read here from a compressor built **at compile
//! time**, where the 96 KB is the compiler's and not a stack's, so no
//! compressor is ever initialised at run time by `Compress.init`, and the
//! caller needs no one early call on a big stack to learn it.
//!
//! This file is in core because two layers need it (ADR 057): the server
//! gzips an answer on a pooled compressor (`http/compress.zig`) and the
//! client gzips a request body on a spare (`fetch/encode.zig`), and a Fitting
//! cannot import `nilo_http`. It depends on the fields `Compress` has in the
//! Zig this toolkit is pinned to, and `test "a compressor reset in place
//! produces what a fresh one does"` holds it there byte for byte.

const std = @import("std");
const flate = std.compress.flate;

/// How hard to look for a match. `.default` is zlib's level 6.
pub const Level = enum {
    fastest,
    default,
    best,

    pub fn flateOptions(self: Level) flate.Compress.Options {
        return switch (self) {
            .fastest => .fastest,
            .default => .default,
            .best => .best,
        };
    }
};

/// The writer vtable `Compress.init` gives, taken from a compressor built at
/// compile time. The compile-time compressor is thrown away; only the
/// pointer to the (constant) vtable survives into the program.
const vtable: *const std.Io.Writer.VTable = blk: {
    @setEvalBranchQuota(10_000_000);
    var scratch: [32]u8 = undefined;
    var out: std.Io.Writer = .fixed(&scratch);
    var window: [flate.max_window_len]u8 = undefined;
    const c = flate.Compress.init(&out, &window, .gzip, .default) catch unreachable;
    break :blk c.writer.vtable;
};

/// A gzip compressor and its window, for the heap. 224 KB and a 64 KB
/// window: never a local variable.
pub const Gzip = struct {
    state: flate.Compress,
    window: [flate.max_window_len]u8,

    /// The compressor writing to `output`, whose gzip header is written
    /// now. `output` is one the compressor may write at least eight bytes
    /// into at a time (an `Allocating` grows to it, a fixed writer needs the
    /// room). The compressor
    /// is good for one body: `finish` ends it, and `reset` begins another.
    pub fn reset(self: *Gzip, output: *std.Io.Writer, level: Level) std.Io.Writer.Error!void {
        return resetIn(&self.state, &self.window, output, level.flateOptions());
    }

    /// The writer to put the body into. `flush` on it is a sync flush: the
    /// bytes written so far reach `output` as whole blocks, ending on a byte
    /// boundary, so a reader of the stream can decode up to there.
    pub fn writer(self: *Gzip) *std.Io.Writer {
        return &self.state.writer;
    }

    /// Ends the body: the last block and the gzip trailer go to `output`.
    pub fn finish(self: *Gzip) std.Io.Writer.Error!void {
        return self.state.finish();
    }
};

/// What `flate.Compress.init` does, into a compressor that is already there,
/// with the gzip container. `chain` is left as it is, as `init` leaves it
/// undefined.
pub fn resetIn(c: *flate.Compress, window: *[flate.max_window_len]u8, output: *std.Io.Writer, opts: flate.Compress.Options) std.Io.Writer.Error!void {
    try output.writeAll(flate.Container.gzip.header());
    c.writer = .{ .buffer = window, .vtable = vtable, .end = 0 };
    c.history_len = 0;
    c.history_end_unhashed = false;
    c.bit_writer.output = output;
    c.bit_writer.buffered = 0;
    c.bit_writer.buffered_n = 0;
    c.buffered_tokens.pos = 0;
    c.buffered_tokens.n = 0;
    @memset(&c.buffered_tokens.lit_freqs, 0);
    @memset(&c.buffered_tokens.dist_freqs, 0);
    @memset(&c.lookup.head, .{ .value = std.math.maxInt(u15), .is_null = true });
    c.lookup.chain_pos = std.math.maxInt(u15);
    c.container = .gzip;
    c.opts = opts;
    c.hasher = .init(.gzip);
}

test "a compressor reset in place produces what a fresh one does" {
    const gpa = std.testing.allocator;
    var made: std.Io.Writer.Allocating = .init(gpa);
    defer made.deinit();
    for (0..200) |_| try made.writer.writeAll("{\"id\":1,\"name\":\"Alpha Widget\"}");
    const body = made.written();

    var fresh_out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer fresh_out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var fresh = try flate.Compress.init(&fresh_out.writer, window, .gzip, .default);
    try fresh.writer.writeAll(body);
    try fresh.finish();

    const g = try gpa.create(Gzip);
    defer gpa.destroy(g);
    g.state = undefined;
    // Twice, the second time over a compressor that has finished once.
    for (0..2) |_| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try g.reset(&out.writer, .default);
        try g.writer().writeAll(body);
        try g.finish();
        try std.testing.expectEqualSlices(u8, fresh_out.written(), out.written());
    }
}

test "a sync flush ends on a byte boundary the reader can decode up to" {
    const gpa = std.testing.allocator;
    const g = try gpa.create(Gzip);
    defer gpa.destroy(g);
    g.state = undefined;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try g.reset(&out.writer, .fastest);
    try g.writer().writeAll("{\"a\":1}\n");
    try g.writer().flush();
    const cut = out.written().len;
    try g.writer().writeAll("{\"b\":2}\n");
    try g.finish();

    // The decoder looks ahead of what it returns, so what follows the cut
    // is an empty final block: the first line must come out of what was
    // flushed, which ends on a block boundary.
    const cutoff = try gpa.alloc(u8, cut + 5 + 64);
    defer gpa.free(cutoff);
    @memset(cutoff, 0);
    @memcpy(cutoff[0..cut], out.written()[0..cut]);
    @memcpy(cutoff[cut..][0..5], &[_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff });
    var in: std.Io.Reader = .fixed(cutoff);
    var win: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .gzip, &win);
    var line: [8]u8 = undefined;
    try d.reader.readSliceAll(&line);
    try std.testing.expectEqualStrings("{\"a\":1}\n", &line);
}
