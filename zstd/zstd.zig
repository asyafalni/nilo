//! zstd as the caller's memory and nothing else (ADR 295): libzstd's
//! contexts placed in bytes the caller provides, sized by functions this file
//! gives, with no allocation and no libc anywhere inside.
//!
//! **The shape is the design.** Every user of zstd in nilo wants a context
//! somewhere different: the server a compressor per thread in a pool (ADR
//! 211), a request body a decoder in its arena, a chunked upload a streaming
//! compressor for the life of one connection, a static file a context for
//! the load. libzstd can do all of it on `ZSTD_initStatic*` contexts, which
//! never call `malloc` and error out (`ContextTooSmall`) if the memory was
//! not enough, so the module has one rule: **a context is `Workspace` bytes,
//! `contextSize` says how many, and the module allocates nothing for itself.**
//! The allocator `Decompressor.decode` takes is the caller's, for the one
//! output buffer they asked for, and the two pools map their contexts once
//! from the page allocator, which is the pool's whole point.
//!
//! | job | type | context |
//! |---|---|---|
//! | one whole body into a buffer | `Compressor` | `Compressor.contextSize` |
//! | a stream, flushable | `StreamCompressor` (a `std.Io.Writer`) | `StreamCompressor.contextSize` |
//! | one frame that announces its size | `Decompressor` | `Decompressor.contextSize` |
//! | a frame that does not, or a stream | `StreamDecoder` (a `std.Io.Reader`) | `StreamDecoder.contextSize` |
//! | one per executor thread, borrowed for a call | `CompressorPool`, `DecompressorPool` | one mapping each |
//!
//! **A frame is a claim, as a gzip trailer is** (`http/encoded.zig`):
//! `Decompressor.announced` reads the frame header and refuses a body over
//! the ceiling before anything is allocated or decoded, and `decode` then
//! refuses a stream whose bytes disagree with what it announced. The streaming
//! decoder counts what it produces against a ceiling instead, so a bomb stops
//! at the ceiling and not at the end of the frame.
//!
//! **The window is bounded.** RFC 9659 caps an HTTP zstd window at 8 MB
//! (`http_window_log`, 23), which is also the default of `window_log_max`:
//! a frame asking for more is refused with `WindowTooLarge` before its window
//! is sized, so a peer chooses the decoder's memory only up to this number.
//!
//! **Checksums.** A frame this module writes carries libzstd's content
//! checksum by default (the low 32 bits of XXH64 over the content, four
//! bytes), and libzstd verifies one whenever a frame has it, in the one-shot
//! and the streaming decoder alike: a flipped bit is `ChecksumMismatch`, not
//! a wrong byte. A frame without one is accepted, because browsers, curl and
//! the zstd CLI's defaults vary and refusing the absence would refuse peers;
//! `Frame.parse(...).checksum` says whether a frame has one, for a caller
//! (the `.zst` sibling of a static file) that requires it. Compare std's gzip
//! decoder, which reads the CRC and compares nothing.
//!
//! **Why libzstd and not `std.compress.zstd`.** The standard library has
//! a decoder and no encoder, and its decoder needs `window_len` plus 128 KB of
//! buffer in the destination, which for a frame at the RFC's 8 MB is 8.1 MB
//! whatever the body is; libzstd's one-shot decode needs no window at all
//! (the destination is the history) and its streaming decode sizes itself
//! from the frame header. Speed and memory are measured in
//! `bench/result/zstd.md`.
//!
//! **Without `-Dzstd` this file does not compile**, with a message that names
//! the line to write: the library is C, fetched only behind a flag (ADR 066).
//! `zig build test-zstd` is the whole suite; `zig test zstd/zstd.zig` alone
//! has no libzstd to link.

const std = @import("std");
const build_options = @import("zstd_build");

comptime {
    if (!build_options.linked) @compileError(
        "nilo: `nilo_zstd` needs libzstd, which is fetched and built only when asked for.\n" ++
            "  In your build.zig: b.dependency(\"nilo\", .{ .target = target, .optimize = optimize, .zstd = true }),\n" ++
            "  or `nilo.app(b, .{ ..., .zstd = true })`. In this repository: -Dzstd (ADR 295).",
    );
}

// ------------------------------------------------------------------ libzstd

const Cctx = opaque {};
const Dctx = opaque {};

const CParams = extern struct {
    window_log: c_uint,
    chain_log: c_uint,
    hash_log: c_uint,
    search_log: c_uint,
    min_match: c_uint,
    target_length: c_uint,
    strategy: c_int,
};

const InBuffer = extern struct { src: ?[*]const u8, size: usize, pos: usize };
const OutBuffer = extern struct { dst: ?[*]u8, size: usize, pos: usize };

const FrameHeader = extern struct {
    frame_content_size: c_ulonglong,
    window_size: c_ulonglong,
    block_size_max: c_uint,
    frame_type: c_int,
    header_size: c_uint,
    dict_id: c_uint,
    checksum_flag: c_uint,
    _reserved1: c_uint,
    _reserved2: c_uint,
};

extern fn ZSTD_versionNumber() c_uint;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getErrorCode(code: usize) c_int;
extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;
extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_getCParams(level: c_int, estimated_src_size: c_ulonglong, dict_size: usize) CParams;
extern fn ZSTD_adjustCParams(c_params: CParams, src_size: c_ulonglong, dict_size: usize) CParams;
extern fn ZSTD_estimateCCtxSize_usingCParams(c_params: CParams) usize;
extern fn ZSTD_estimateCStreamSize_usingCParams(c_params: CParams) usize;
extern fn ZSTD_estimateDCtxSize() usize;
extern fn ZSTD_estimateDStreamSize(max_window_size: usize) usize;
extern fn ZSTD_initStaticCCtx(workspace: *anyopaque, size: usize) ?*Cctx;
extern fn ZSTD_initStaticDCtx(workspace: *anyopaque, size: usize) ?*Dctx;
extern fn ZSTD_CCtx_reset(cctx: *Cctx, reset: c_int) usize;
extern fn ZSTD_CCtx_setParameter(cctx: *Cctx, param: c_int, value: c_int) usize;
extern fn ZSTD_CCtx_setCParams(cctx: *Cctx, c_params: CParams) usize;
extern fn ZSTD_CCtx_setPledgedSrcSize(cctx: *Cctx, size: c_ulonglong) usize;
extern fn ZSTD_compress2(cctx: *Cctx, dst: [*]u8, dst_cap: usize, src: [*]const u8, src_size: usize) usize;
extern fn ZSTD_compressStream2(cctx: *Cctx, out: *OutBuffer, in: *InBuffer, end_op: c_int) usize;
extern fn ZSTD_DCtx_setParameter(dctx: *Dctx, param: c_int, value: c_int) usize;
extern fn ZSTD_DCtx_reset(dctx: *Dctx, reset: c_int) usize;
extern fn ZSTD_decompressDCtx(dctx: *Dctx, dst: [*]u8, dst_cap: usize, src: [*]const u8, src_size: usize) usize;
extern fn ZSTD_decompressStream(dctx: *Dctx, out: *OutBuffer, in: *InBuffer) usize;
extern fn ZSTD_decompressBound(src: [*]const u8, src_size: usize) c_ulonglong;
extern fn ZSTD_getFrameHeader(header: *FrameHeader, src: [*]const u8, src_size: usize) usize;

const p_compression_level = 100;
const p_checksum_flag = 201;
const p_window_log = 101;
const p_d_window_log_max = 100;
const end_continue = 0;
const end_flush = 1;
const end_end = 2;
const reset_session_only = 1;
const reset_parameters = 2;
const p_content_size_flag = 200;
const content_size_unknown: u64 = std.math.maxInt(u64);

// -------------------------------------------------------------------- errors

pub const Error = error{
    /// The bytes are not a zstd frame: the magic is wrong. A body somebody
    /// forgot to compress, under a header that says they did.
    NotZstd,
    /// A frame this build cannot read: a version, a frame parameter or a
    /// skippable frame where a body was expected.
    Unsupported,
    /// The frame asks for a window over `window_log_max` (RFC 9659 allows
    /// 8 MB). Nothing was sized or decoded.
    WindowTooLarge,
    /// The bytes are a zstd frame that does not decode, or whose header
    /// claims more than any frame of this length could hold.
    Corrupt,
    /// The frame ends before it is complete.
    Truncated,
    /// The content checksum the frame carries is not the checksum of the
    /// bytes that came out.
    ChecksumMismatch,
    /// The output did not fit in `dst`. For a compressor this is the answer
    /// "no smaller than you allowed", not a failure.
    NoRoom,
    /// The decoded body is over the ceiling the caller gave, by the frame's
    /// own account (`announced`) or by the bytes counted (`StreamDecoder`).
    BodyTooLarge,
    /// The frame does not say how large it decodes to, so the one-shot
    /// decoder cannot be sized: use `StreamDecoder`.
    SizeNotAnnounced,
    /// The source is larger than the `max_src` the compressor was sized for.
    SourceTooLarge,
    /// The memory handed over is smaller than `contextSize` said, or not
    /// aligned to `workspace_alignment`.
    ContextTooSmall,
    /// The source reader failed (a streaming decoder) or libzstd refused for
    /// a reason with no name here: `detail` has libzstd's own words.
    Failed,
};

fn fromCode(code: usize) Error {
    return switch (ZSTD_getErrorCode(code)) {
        10 => error.NotZstd,
        12, 14 => error.Unsupported,
        16 => error.WindowTooLarge,
        20, 24, 30, 32 => error.Corrupt,
        22 => error.ChecksumMismatch,
        64, 66 => error.ContextTooSmall,
        70 => error.NoRoom,
        72 => error.Truncated,
        else => error.Failed,
    };
}

fn check(code: usize) Error!usize {
    if (ZSTD_isError(code) != 0) return fromCode(code);
    return code;
}

/// libzstd's name for the last failure of a context, for a log line or a
/// 400's message. `detail` of every type here.
pub fn describe(code: usize) [:0]const u8 {
    return std.mem.span(ZSTD_getErrorName(code));
}

/// libzstd's version as `major * 10000 + minor * 100 + patch`.
pub fn version() u32 {
    return ZSTD_versionNumber();
}

// ----------------------------------------------------------------- constants

/// The alignment of a context's memory: libzstd wants 8, and the contexts
/// are sized for it (their tables are aligned inside, by the library).
pub const workspace_alignment: std.mem.Alignment = .@"8";
/// Memory for one context.
pub const Workspace = []align(8) u8;

/// `log2` of the window RFC 9659 requires a decoder to accept, and caps the
/// encoder at: 8 MB.
pub const http_window_log = 23;

/// The largest frame header: what `Frame.parse` and `StreamDecoder.sizeFrom`
/// need to have seen.
pub const frame_header_max = 18;

/// A frame's worst expansion: a block is four bytes (a three-byte header and
/// one byte) and holds up to 128 KB of one repeated byte. No frame decodes to
/// more than this many times its length, so a header claiming more is a lie.
pub const ratio_max = 32768;

/// The bytes any compressor of this module may write for `n` of input:
/// what a destination needs to never be `NoRoom`.
pub fn compressBound(n: usize) usize {
    return ZSTD_compressBound(n);
}

pub const level_min = -131072;
pub const level_max = 22;

// --------------------------------------------------------------------- frame

/// What the first bytes of a frame say, read without a context.
pub const Frame = struct {
    /// The decoded length, when the encoder wrote it. Every frame nilo
    /// writes through `Compressor` does.
    content_size: ?u64,
    /// The largest distance a match reaches back: what a streaming decoder
    /// must hold. For a frame that is one segment it is the content size.
    window_size: u64,
    /// Whether the frame ends in a content checksum.
    checksum: bool,
    /// The bytes of the header, so the first block starts there.
    header_len: usize,

    /// The header of the frame at the start of `bytes`: `Truncated` if fewer
    /// than the header needs (read up to `frame_header_max` and ask again),
    /// `NotZstd` if the magic is wrong, `Unsupported` for a skippable frame.
    pub fn parse(bytes: []const u8) Error!Frame {
        var h: FrameHeader = undefined;
        const r = ZSTD_getFrameHeader(&h, bytes.ptr, bytes.len);
        if (ZSTD_isError(r) != 0) return fromCode(r);
        if (r > 0) return error.Truncated;
        // 0 is ZSTD_frame, 1 is ZSTD_skippableFrame.
        if (h.frame_type != 0) return error.Unsupported;
        return .{
            .content_size = if (h.frame_content_size == content_size_unknown) null else h.frame_content_size,
            .window_size = h.window_size,
            .checksum = h.checksum_flag != 0,
            .header_len = h.header_size,
        };
    }

    /// Whether `frame` is the compression of `plain`, as far as its header
    /// and trailer say, **without decoding it**: it announces `plain.len`, it
    /// carries a content checksum, and that checksum is the one `plain` has.
    /// This is a `.gz` sibling's check (ADR 273), where the CRC-32 and the
    /// length are compared to the plain file's: a stale or foreign sibling
    /// fails it, and a frame whose blocks are damaged under an intact trailer
    /// does not, exactly as a gzip member does not. The checksum is the low 32
    /// bits of XXH64 over the content (RFC 8878 section 3.1.1), so `plain`
    /// is hashed once at about memory speed. `frame` must be one frame, as a
    /// sibling file is.
    pub fn matches(frame: []const u8, plain: []const u8) bool {
        const f = parse(frame) catch return false;
        if (!f.checksum or f.content_size != plain.len) return false;
        if (frame.len < f.header_len + 4) return false;
        const trailer = std.mem.readInt(u32, frame[frame.len - 4 ..][0..4], .little);
        return trailer == contentChecksum(plain);
    }
};

/// The checksum a frame carries for `content`: the low 32 bits of XXH64 with
/// seed 0.
pub fn contentChecksum(content: []const u8) u32 {
    return @truncate(std.hash.XxHash64.hash(0, content));
}

// ---------------------------------------------------------------- compressor

/// What a compressor writes, and how hard it tries.
pub const EncodeOptions = struct {
    /// 1 is fastest, 22 smallest; 3 is libzstd's default. Negative levels
    /// are faster than 1 and larger. Memory and time both grow with it
    /// (`bench/result/zstd.md`).
    level: i32 = 3,
    /// Write the content checksum (four bytes, about 1% of the time).
    checksum: bool = true,
    /// The largest match distance a frame may use, as a power of two, never
    /// above the level's own. Levels 20 to 22 want 32 to 128 MB windows,
    /// which RFC 9659 forbids on the wire, so the default holds every level to
    /// the 8 MB a decoder must accept. For a stream the window is most of the
    /// memory it holds: a chunked upload that does not need a long history
    /// asks for 17 or 18 (bench/result/zstd.md).
    window_log: u5 = http_window_log,
    /// Streaming only: how many bytes the stream will carry, if known. It
    /// goes in the frame header, which lets the peer decode in one shot.
    content_size: ?u64 = null,
};

/// A static context starts with every parameter zero, which is not libzstd's
/// default: the content size flag is off, so a frame would not say how large it
/// decodes to. `ZSTD_createCCtx` resets to the defaults and `ZSTD_initStaticCCtx`
/// does not.
fn initCctx(memory: Workspace) Error!*Cctx {
    const cctx = ZSTD_initStaticCCtx(memory.ptr, memory.len) orelse return error.ContextTooSmall;
    _ = try check(ZSTD_CCtx_reset(cctx, reset_parameters));
    _ = try check(ZSTD_CCtx_setParameter(cctx, p_content_size_flag, 1));
    return cctx;
}

/// The level's parameters for a body of about `hint` bytes (0 for unknown),
/// with the window held to `window_log`.
fn cparamsFor(level: i32, hint: u64, window_log: u5) CParams {
    var cp = ZSTD_getCParams(level, hint, 0);
    cp.window_log = @min(cp.window_log, window_log);
    return ZSTD_adjustCParams(cp, hint, 0);
}

/// **Whole bodies into a caller's buffer**: the shape `app.compress` has
/// and a `.zst` file at load has. One context serves any number of bodies,
/// one at a time, each up to `max_src` bytes; a body smaller than that is
/// compressed with parameters tuned for its own size and needs no more
/// memory (`compress` checks, and falls back to the context's own).
pub const Compressor = struct {
    cctx: *Cctx,
    level: i32,
    checksum: bool,
    max_src: usize,
    window_log: u5,
    workspace_len: usize,
    base: CParams,
    /// libzstd's code for the last failure, for `describe`.
    detail: usize = 0,

    /// Bytes of context for bodies up to `max_src` at `options.level`, with
    /// `workspace_alignment`. The window is bounded by `max_src` (libzstd
    /// shrinks `windowLog` to fit the input), so a small body does not size
    /// a large context.
    pub fn contextSize(options: EncodeOptions, max_src: usize) usize {
        return ZSTD_estimateCCtxSize_usingCParams(cparamsFor(options.level, @max(max_src, 1), options.window_log));
    }

    pub fn init(memory: Workspace, options: EncodeOptions, max_src: usize) Error!Compressor {
        const cctx = try initCctx(memory);
        const base = cparamsFor(options.level, @max(max_src, 1), options.window_log);
        if (memory.len < ZSTD_estimateCCtxSize_usingCParams(base)) return error.ContextTooSmall;
        _ = try check(ZSTD_CCtx_setParameter(cctx, p_checksum_flag, @intFromBool(options.checksum)));
        return .{
            .cctx = cctx,
            .level = options.level,
            .checksum = options.checksum,
            .max_src = max_src,
            .window_log = options.window_log,
            .workspace_len = memory.len,
            .base = base,
        };
    }

    /// `src` as one frame in `dst`, returned as the slice written. `NoRoom`
    /// if the frame does not fit (a caller that wants "smaller than the body"
    /// passes a `dst` of that size and sends the body as it is on `NoRoom`),
    /// `SourceTooLarge` over `max_src`. The frame header carries the content
    /// size, so a peer can use `Decompressor`.
    pub fn compress(c: *Compressor, dst: []u8, src: []const u8) Error![]u8 {
        if (src.len > c.max_src) return error.SourceTooLarge;
        var cp = cparamsFor(c.level, @max(src.len, 1), c.window_log);
        // The parameters tuned for this body's size are not always smaller
        // than the context's: a level's table changes strategy by size, and a
        // strategy has its own tables. Use them only when they fit.
        if (ZSTD_estimateCCtxSize_usingCParams(cp) > c.workspace_len) cp = c.base;
        // A failed body (`NoRoom`) leaves the session open, and parameters
        // cannot be set in one.
        _ = try check(ZSTD_CCtx_reset(c.cctx, reset_session_only));
        _ = try check(ZSTD_CCtx_setCParams(c.cctx, cp));
        const n = ZSTD_compress2(c.cctx, dst.ptr, dst.len, src.ptr, src.len);
        if (ZSTD_isError(n) != 0) {
            c.detail = n;
            return fromCode(n);
        }
        return dst[0..n];
    }
};

/// **A stream with a flush**: a `std.Io.Writer` whose bytes go to `sink` as
/// one zstd frame. `flush` makes every byte written so far decodable by the
/// peer without ending the frame (`ZSTD_e_flush`), which is what a chunked
/// upload whose every line must arrive on time needs; `finish` ends the frame.
/// The frame's window is `EncodeOptions.window_log`, so a stream's memory is chosen
/// by the caller and not by how long it runs.
pub const StreamCompressor = struct {
    /// Write the stream's plaintext here.
    writer: std.Io.Writer,
    sink: *std.Io.Writer,
    cctx: *Cctx,
    /// Set when `writer` returned `WriteFailed` because libzstd refused (and
    /// not because `sink` failed).
    err: ?Error = null,
    detail: usize = 0,
    ended: bool = false,

    /// Bytes of context: the window, a block of input and a block of output
    /// (libzstd buffers a stream; it cannot see the caller's buffers stay).
    pub fn contextSize(options: EncodeOptions) usize {
        return ZSTD_estimateCStreamSize_usingCParams(streamParams(options));
    }

    /// `buffer` is the writer's own, and any size including none; a few KB
    /// saves libzstd a call per small write.
    pub fn init(memory: Workspace, sink: *std.Io.Writer, buffer: []u8, options: EncodeOptions) Error!StreamCompressor {
        const cctx = try initCctx(memory);
        const cp = streamParams(options);
        if (memory.len < ZSTD_estimateCStreamSize_usingCParams(cp)) return error.ContextTooSmall;
        _ = try check(ZSTD_CCtx_setCParams(cctx, cp));
        _ = try check(ZSTD_CCtx_setParameter(cctx, p_checksum_flag, @intFromBool(options.checksum)));
        if (options.content_size) |n| _ = try check(ZSTD_CCtx_setPledgedSrcSize(cctx, n));
        return .{
            .writer = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain, .flush = flush },
            },
            .sink = sink,
            .cctx = cctx,
        };
    }

    /// The parameters a stream runs on and is sized by: the level's, with the
    /// window cut to `window_log` and the tables cut to fit it.
    fn streamParams(options: EncodeOptions) CParams {
        return cparamsFor(options.level, 0, options.window_log);
    }

    /// Every byte written so far reaches `sink` as part of blocks the peer can
    /// decode, and `sink` is flushed.
    pub fn flushAll(c: *StreamCompressor) std.Io.Writer.Error!void {
        return c.writer.flush();
    }

    /// End the frame (its checksum included) and flush `sink`. After this the
    /// stream takes no more bytes.
    pub fn finish(c: *StreamCompressor) std.Io.Writer.Error!void {
        try c.writer.flush();
        try c.run(&.{}, end_end);
        c.ended = true;
        try c.sink.flush();
    }

    fn run(c: *StreamCompressor, bytes: []const u8, op: c_int) std.Io.Writer.Error!void {
        if (c.ended) return error.WriteFailed;
        var in: InBuffer = .{ .src = bytes.ptr, .size = bytes.len, .pos = 0 };
        while (true) {
            const room = try c.sink.writableSliceGreedy(1);
            var out: OutBuffer = .{ .dst = room.ptr, .size = room.len, .pos = 0 };
            const left = ZSTD_compressStream2(c.cctx, &out, &in, op);
            if (ZSTD_isError(left) != 0) {
                c.err = fromCode(left);
                c.detail = left;
                return error.WriteFailed;
            }
            c.sink.advance(out.pos);
            // For `continue` the input is consumed when `pos == size`; for
            // `flush` and `end`, zero left to flush means done.
            if (op == end_continue) {
                if (in.pos == in.size) return;
            } else if (left == 0 and in.pos == in.size) return;
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const c: *StreamCompressor = @fieldParentPtr("writer", w);
        if (w.end > 0) {
            const pending = w.buffer[0..w.end];
            w.end = 0;
            try c.run(pending, end_continue);
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try c.run(d, end_continue);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try c.run(last, end_continue);
        return n + last.len * splat;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const c: *StreamCompressor = @fieldParentPtr("writer", w);
        const pending = w.buffer[0..w.end];
        w.end = 0;
        try c.run(pending, end_continue);
        try c.run(&.{}, end_flush);
        try c.sink.flush();
    }
};

// --------------------------------------------------------------------- pools

/// One mapping for `n` contexts of `per` bytes each, rounded up to a page,
/// kept off transparent huge pages (ADR 248's finding, which holds for any
/// context a pool makes). The advice has to come before the first write, so
/// it is given before any context is built; Linux only, and a refusal is
/// ignored, because a kernel that refuses it has none to give.
const Mapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    stride: usize,

    fn init(n: usize, per: usize) error{OutOfMemory}!Mapping {
        const stride = std.mem.alignForward(usize, per, std.heap.page_size_min);
        const bytes = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), @max(stride * n, 1));
        if (@import("builtin").os.tag == .linux) {
            std.posix.madvise(bytes.ptr, bytes.len, std.posix.MADV.NOHUGEPAGE) catch {};
        }
        return .{ .bytes = bytes, .stride = stride };
    }

    fn at(m: Mapping, i: usize, per: usize) Workspace {
        return @alignCast(m.bytes[i * m.stride ..][0..per]);
    }

    fn deinit(m: Mapping) void {
        std.heap.page_allocator.free(m.bytes);
    }
};

/// A free flag on a cache line of its own, so a borrow and a give-back write a
/// line nobody else is writing (ADR 211).
const Flag = struct {
    taken: std.atomic.Value(bool) align(64) = .init(false),
};

fn borrowFrom(flags: []Flag, start: usize) ?usize {
    if (flags.len == 0) return null;
    var i = start % flags.len;
    for (0..flags.len) |_| {
        if (flags[i].taken.cmpxchgStrong(false, true, .acquire, .monotonic) == null) return i;
        i = (i + 1) % flags.len;
    }
    return null;
}

/// **Compressors for a server: one per executor thread, borrowed for one
/// call** (ADR 211, ADR 295). The shape ADR 211 settled on for gzip, built
/// once for every user of this module: all the contexts in one mapping, a
/// free flag each, and a borrow that is one `cmpxchg` and never waits.
/// `borrow(start)` scans from `start % n`, so a thread that passes its own
/// index finds its own context free every time and its tables stay in its
/// core's caches. An empty pool answers `null`, and the caller sends the body
/// as it is.
///
/// **The borrow must span no wait.** A compressor borrowed across a point
/// where the fiber can park is held by a sleeper, and a pool of one per thread
/// is then empty; `compress` parks nowhere, so the rule holds for a borrow
/// that is `borrow`, `compress`, `give` and nothing between.
///
/// What it keeps resident is what bodies have touched, not what it mapped:
/// a context is `contextSize` bytes and a 4 KB body writes 90 KB of it
/// (`bench/result/zstd.md`).
pub const CompressorPool = struct {
    mapping: Mapping,
    flags: []Flag,
    items: []Compressor,

    /// `n` compressors for bodies up to `max_src` at `options`.
    pub fn init(gpa: std.mem.Allocator, n: usize, options: EncodeOptions, max_src: usize) (Error || error{OutOfMemory})!CompressorPool {
        const per = Compressor.contextSize(options, max_src);
        const mapping = try Mapping.init(n, per);
        errdefer mapping.deinit();
        const flags = try gpa.alloc(Flag, n);
        errdefer gpa.free(flags);
        @memset(flags, .{});
        const items = try gpa.alloc(Compressor, n);
        errdefer gpa.free(items);
        for (items, 0..) |*item, i| item.* = try .init(mapping.at(i, per), options, max_src);
        return .{ .mapping = mapping, .flags = flags, .items = items };
    }

    pub fn deinit(p: *CompressorPool, gpa: std.mem.Allocator) void {
        gpa.free(p.items);
        gpa.free(p.flags);
        p.mapping.deinit();
        p.* = undefined;
    }

    /// A free compressor, scanning from slot `start % n`; `null` if all are
    /// out. Give it back with `give`.
    pub fn borrow(p: *CompressorPool, start: usize) ?*Compressor {
        const i = borrowFrom(p.flags, start) orelse return null;
        return &p.items[i];
    }

    pub fn give(p: *CompressorPool, c: *Compressor) void {
        const i = (@intFromPtr(c) - @intFromPtr(p.items.ptr)) / @sizeOf(Compressor);
        p.flags[i].taken.store(false, .release);
    }
};

/// The same for decompressors: one-shot contexts of `Decompressor.contextSize`
/// bytes each, which hold no window (ADR 295). A request body whose frame
/// announces its size is decoded on a borrowed one into one arena allocation
/// of exactly that size.
pub const DecompressorPool = struct {
    mapping: Mapping,
    flags: []Flag,
    items: []Decompressor,

    pub fn init(gpa: std.mem.Allocator, n: usize, options: DecodeOptions) (Error || error{OutOfMemory})!DecompressorPool {
        const per = Decompressor.contextSize();
        const mapping = try Mapping.init(n, per);
        errdefer mapping.deinit();
        const flags = try gpa.alloc(Flag, n);
        errdefer gpa.free(flags);
        @memset(flags, .{});
        const items = try gpa.alloc(Decompressor, n);
        errdefer gpa.free(items);
        for (items, 0..) |*item, i| item.* = try .init(mapping.at(i, per), options);
        return .{ .mapping = mapping, .flags = flags, .items = items };
    }

    pub fn deinit(p: *DecompressorPool, gpa: std.mem.Allocator) void {
        gpa.free(p.items);
        gpa.free(p.flags);
        p.mapping.deinit();
        p.* = undefined;
    }

    pub fn borrow(p: *DecompressorPool, start: usize) ?*Decompressor {
        const i = borrowFrom(p.flags, start) orelse return null;
        return &p.items[i];
    }

    pub fn give(p: *DecompressorPool, d: *Decompressor) void {
        const i = (@intFromPtr(d) - @intFromPtr(p.items.ptr)) / @sizeOf(Decompressor);
        p.flags[i].taken.store(false, .release);
    }
};

// -------------------------------------------------------------- decompressor

/// What a decoder refuses and how much it may hold.
pub const DecodeOptions = struct {
    /// The largest window a frame may ask for, as a power of two. 23 is the
    /// 8 MB RFC 9659 requires every HTTP decoder to accept and forbids an
    /// encoder to exceed.
    window_log_max: u5 = http_window_log,
};

/// **One frame that says how large it is, decoded in one call** into a buffer
/// of that size. The context is the same size whatever the frame is (libzstd's
/// entropy tables), and holds no window: the destination is the history.
pub const Decompressor = struct {
    dctx: *Dctx,
    window_log_max: u5,
    detail: usize = 0,

    pub fn contextSize() usize {
        return ZSTD_estimateDCtxSize();
    }

    pub fn init(memory: Workspace, options: DecodeOptions) Error!Decompressor {
        const dctx = ZSTD_initStaticDCtx(memory.ptr, memory.len) orelse return error.ContextTooSmall;
        _ = try check(ZSTD_DCtx_setParameter(dctx, p_d_window_log_max, options.window_log_max));
        return .{ .dctx = dctx, .window_log_max = options.window_log_max };
    }

    /// What the frame at the start of `src` says it will decode to, checked as
    /// far as it can be before anything is allocated or decoded: the magic, a
    /// window within `window_log_max`, a size no frame of this length could
    /// reach, and `limit`.
    ///
    /// **It is a claim and not a measure**: `decompress` refuses a stream whose
    /// bytes disagree. Order is the point: a body that is not zstd is `NotZstd`
    /// and not "too large", and a lie about the size is `Corrupt` and not a
    /// 413 about a size nobody sent.
    pub fn announced(src: []const u8, window_log_max: u5, limit: usize) Error!usize {
        const f = try Frame.parse(src);
        const size = f.content_size orelse return error.SizeNotAnnounced;
        if (f.window_size > (@as(u64, 1) << window_log_max)) return error.WindowTooLarge;
        if (size / ratio_max > src.len) return error.Corrupt;
        if (size > limit) return error.BodyTooLarge;
        return @intCast(size);
    }

    /// `src` decoded into `dst`, as the slice written. `dst` is the frame's
    /// whole content (`announced` bytes); more than one frame, a frame that
    /// decodes to a different length than `dst` holds, or a frame that fails
    /// its checksum, is an error.
    pub fn decompress(d: *Decompressor, dst: []u8, src: []const u8) Error![]u8 {
        const n = ZSTD_decompressDCtx(d.dctx, dst.ptr, dst.len, src.ptr, src.len);
        if (ZSTD_isError(n) != 0) {
            d.detail = n;
            return fromCode(n);
        }
        return dst[0..n];
    }

    /// `src` decoded into one `allocator.alloc`, at most `limit` bytes:
    /// `http/encoded.zig`'s `inflate`, for zstd. Allocate from an arena: a
    /// frame that fails partway leaves what was allocated.
    ///
    /// **A frame that announces its size gets an allocation of exactly that**
    /// (checked against `limit` first, as `announced` does). **One that does
    /// not** (a stream's encoder cannot know) gets the most libzstd can prove
    /// it holds from its block headers (`ZSTD_decompressBound`: at most 128 KB
    /// a block, so a few hundred KB over the truth at worst), or `limit` plus
    /// one byte if that is less, and the allocation is shrunk to the part used. It
    /// needs no window and no second context: the one-shot decoder reads its
    /// history out of the destination, so a frame cannot make this call hold
    /// more than `limit`.
    pub fn decode(d: *Decompressor, allocator: std.mem.Allocator, src: []const u8, limit: usize) (Error || error{OutOfMemory})![]u8 {
        const f = try Frame.parse(src);
        if (f.window_size > (@as(u64, 1) << d.window_log_max)) return error.WindowTooLarge;
        if (f.content_size) |size| {
            if (size / ratio_max > src.len) return error.Corrupt;
            if (size > limit) return error.BodyTooLarge;
            const out = try allocator.alloc(u8, @intCast(size));
            errdefer allocator.free(out);
            const got = try d.decompress(out, src);
            if (got.len != size) return error.Corrupt;
            return out;
        }
        const bound = ZSTD_decompressBound(src.ptr, src.len);
        if (bound == content_size_unknown - 1) return error.Corrupt;
        const room: usize = @intCast(@min(bound, @as(u64, limit) +| 1));
        const out = try allocator.alloc(u8, room);
        errdefer allocator.free(out);
        const got = d.decompress(out, src) catch |e| switch (e) {
            // The frame decodes to more than the room it was given: the room
            // is `limit + 1` unless the bound was lower, and a frame over its
            // own bound is a lie.
            error.NoRoom => return if (room == @as(u64, limit) +| 1) error.BodyTooLarge else error.Corrupt,
            else => return e,
        };
        if (got.len > limit) return error.BodyTooLarge;
        // The part used, handed back to the allocator: against an arena that
        // is the allocation made last, so it shrinks in place.
        return allocator.realloc(out, got.len);
    }
};

/// **A frame of any size, or a stream, as a `std.Io.Reader`**: it reads
/// `source` as it is asked, and counts what it decodes against `max_decoded`,
/// so a bomb stops at the ceiling and not at the end of the frame. The context
/// holds the frame's window, so it is sized from the frame's own header:
/// `sizeFrom` for what this frame needs, `contextSize` for the most any frame
/// within `window_log_max` could.
///
/// Errors surface as `error.ReadFailed` from the reader, as std's decoders do,
/// and `err` has which.
pub const StreamDecoder = struct {
    reader: std.Io.Reader,
    source: *std.Io.Reader,
    dctx: *Dctx,
    max_decoded: u64,
    decoded: u64 = 0,
    /// A frame has started and not ended.
    inside: bool = false,
    err: ?Error = null,
    detail: usize = 0,

    pub const Options = struct {
        window_log_max: u5 = http_window_log,
        /// The most the stream may decode to, in all.
        max_decoded: u64 = std.math.maxInt(u64),
    };

    /// Bytes of context for the largest frame `window_log_max` allows.
    pub fn contextSize(options: DecodeOptions) usize {
        return ZSTD_estimateDStreamSize(@as(usize, 1) << options.window_log_max);
    }

    /// Bytes of context for the frame whose first bytes are `header` (at
    /// least `Frame.parse` can read, up to `frame_header_max`). `WindowTooLarge`
    /// if it asks for more than `window_log_max`: the peer does not choose a
    /// decoder's memory beyond that.
    pub fn sizeFrom(header: []const u8, options: DecodeOptions) Error!usize {
        const f = try Frame.parse(header);
        if (f.window_size > (@as(u64, 1) << options.window_log_max)) return error.WindowTooLarge;
        // A frame that announces less than its window never fills it.
        const held = if (f.content_size) |n| @min(n, f.window_size) else f.window_size;
        return ZSTD_estimateDStreamSize(@intCast(@max(held, 1)));
    }

    /// `sizeFrom`, for the frame at the front of `source`: peeks up to
    /// `frame_header_max` bytes without consuming them. The reader's buffer
    /// must hold that many.
    pub fn sizeFromSource(source: *std.Io.Reader, options: DecodeOptions) Error!usize {
        var want: usize = 1;
        while (true) {
            const have = source.peek(want) catch |e| switch (e) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.Failed,
            };
            const head = have[0..@min(have.len, frame_header_max)];
            return sizeFrom(head, options) catch |e| switch (e) {
                error.Truncated => {
                    if (want >= frame_header_max) return e;
                    want = @min(frame_header_max, want + 4);
                    continue;
                },
                else => return e,
            };
        }
    }

    /// `buffer` is the reader's own; it may be empty if only `stream*`
    /// functions are used.
    pub fn init(memory: Workspace, source: *std.Io.Reader, buffer: []u8, options: StreamDecoder.Options) Error!StreamDecoder {
        const dctx = ZSTD_initStaticDCtx(memory.ptr, memory.len) orelse return error.ContextTooSmall;
        _ = try check(ZSTD_DCtx_setParameter(dctx, p_d_window_log_max, options.window_log_max));
        return .{
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .source = source,
            .dctx = dctx,
            .max_decoded = options.max_decoded,
        };
    }

    /// Ready for another frame after an error or at the end of one, in the
    /// same memory.
    pub fn reset(d: *StreamDecoder) void {
        _ = ZSTD_DCtx_reset(d.dctx, reset_session_only);
        d.inside = false;
        d.err = null;
        d.decoded = 0;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const d: *StreamDecoder = @fieldParentPtr("reader", r);
        if (d.err != null) return error.ReadFailed;
        const input = d.source.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => {
                if (d.inside) {
                    d.err = error.Truncated;
                    return error.ReadFailed;
                }
                return error.EndOfStream;
            },
            error.ReadFailed => {
                d.err = error.Failed;
                return error.ReadFailed;
            },
        };
        const room = try w.writableSliceGreedy(1);
        // One byte past the ceiling, so that reaching it is seen and a stream
        // of exactly the ceiling is not refused.
        const allowed = d.max_decoded - d.decoded;
        const cap = @min(@min(room.len, limit.minInt(room.len)), allowed +| 1);
        var in: InBuffer = .{ .src = input.ptr, .size = input.len, .pos = 0 };
        var out: OutBuffer = .{ .dst = room.ptr, .size = cap, .pos = 0 };
        const left = ZSTD_decompressStream(d.dctx, &out, &in);
        if (ZSTD_isError(left) != 0) {
            d.err = fromCode(left);
            d.detail = left;
            return error.ReadFailed;
        }
        d.source.toss(in.pos);
        d.decoded += out.pos;
        if (d.decoded > d.max_decoded) {
            d.err = error.BodyTooLarge;
            return error.ReadFailed;
        }
        w.advance(out.pos);
        d.inside = left != 0;
        return out.pos;
    }
};

// --------------------------------------------------------------------- tests

const testing = std.testing;

/// A body that looks like what the framework sends: JSON with repeated keys
/// and values that vary, `n` bytes.
fn body(gpa: std.mem.Allocator, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, n);
    var prng: std.Random.DefaultPrng = .init(n);
    const rand = prng.random();
    var i: usize = 0;
    while (i < n) {
        const line = std.fmt.bufPrint(out[i..], "{{\"id\":{d},\"name\":\"user-{d}\",\"tags\":[\"a\",\"b\",\"c\"],\"score\":{d}.{d}}},\n", .{
            rand.uintLessThan(u32, 100_000),
            rand.uintLessThan(u32, 1000),
            rand.uintLessThan(u32, 100),
            rand.uintLessThan(u32, 100),
        }) catch {
            @memset(out[i..], ' ');
            break;
        };
        i += line.len;
    }
    return out;
}

fn workspace(gpa: std.mem.Allocator, n: usize) !Workspace {
    return gpa.alignedAlloc(u8, workspace_alignment, n);
}

test "a body compressed at several levels and sizes comes back as the bytes that went in" {
    const gpa = testing.allocator;
    for ([_]i32{ -5, 1, 3, 6, 12, 19 }) |level| {
        for ([_]usize{ 0, 1, 100, 4 << 10, 64 << 10, 1 << 20 }) |size| {
            const src = try body(gpa, size);
            defer gpa.free(src);
            const mem = try workspace(gpa, Compressor.contextSize(.{ .level = level }, size));
            defer gpa.free(mem);
            var c: Compressor = try .init(mem, .{ .level = level }, size);
            const dst = try gpa.alloc(u8, compressBound(size));
            defer gpa.free(dst);
            const frame = try c.compress(dst, src);

            const dmem = try workspace(gpa, Decompressor.contextSize());
            defer gpa.free(dmem);
            var d: Decompressor = try .init(dmem, .{});
            const back = try d.decode(gpa, frame, size);
            defer gpa.free(back);
            try testing.expectEqualSlices(u8, src, back);
        }
    }
}

test "a context sized by the module's estimate is never asked for more, at any level or size" {
    const gpa = testing.allocator;
    // The context is sized for `max`, and every body up to `max` is compressed
    // in it: the tuned parameters of a smaller body may pick a strategy with
    // larger tables, and the module must not ask for the memory.
    for ([_]i32{ -3, 1, 3, 5, 9, 12, 15, 19, 22 }) |level| {
        const max: usize = 300 << 10;
        const mem = try workspace(gpa, Compressor.contextSize(.{ .level = level }, max));
        defer gpa.free(mem);
        var c: Compressor = try .init(mem, .{ .level = level }, max);
        const src = try body(gpa, max);
        defer gpa.free(src);
        const dst = try gpa.alloc(u8, compressBound(max));
        defer gpa.free(dst);
        for ([_]usize{ 0, 1, 50, 1000, 10_000, 16 << 10, 17 << 10, 100 << 10, 129 << 10, 256 << 10, 257 << 10, max }) |size| {
            _ = try c.compress(dst, src[0..size]);
        }
    }
}

test "a context of exactly the estimate works wherever in memory it starts" {
    const gpa = testing.allocator;
    const need = Compressor.contextSize(.{ .level = 6 }, 64 << 10);
    const raw = try gpa.alignedAlloc(u8, .@"64", need + 64);
    defer gpa.free(raw);
    const src = try body(gpa, 64 << 10);
    defer gpa.free(src);
    const dst = try gpa.alloc(u8, compressBound(src.len));
    defer gpa.free(dst);
    var off: usize = 0;
    while (off < 64) : (off += 8) {
        const mem: Workspace = @alignCast(raw[off..][0..need]);
        var c: Compressor = try .init(mem, .{ .level = 6 }, src.len);
        _ = try c.compress(dst, src);
    }
}

test "a context smaller than the estimate is refused rather than overrun" {
    const gpa = testing.allocator;
    const need = Compressor.contextSize(.{}, 64 << 10);
    const mem = try workspace(gpa, need - 8);
    defer gpa.free(mem);
    try testing.expectError(error.ContextTooSmall, Compressor.init(mem, .{}, 64 << 10));
}

test "a body over the size the context was made for is refused" {
    const gpa = testing.allocator;
    const mem = try workspace(gpa, Compressor.contextSize(.{}, 1000));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, 1000);
    var dst: [4096]u8 = undefined;
    try testing.expectError(error.SourceTooLarge, c.compress(&dst, &@as([1001]u8, @splat('x'))));
}

test "a destination too small for the frame says so, and the context is good for the next body" {
    const gpa = testing.allocator;
    const src = try body(gpa, 8 << 10);
    defer gpa.free(src);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, src.len);
    var small: [64]u8 = undefined;
    try testing.expectError(error.NoRoom, c.compress(&small, src));
    const dst = try gpa.alloc(u8, compressBound(src.len));
    defer gpa.free(dst);
    try testing.expect((try c.compress(dst, src)).len < src.len / 2);
}

test "the frame carries its content size and a checksum, and says so" {
    const gpa = testing.allocator;
    const src = try body(gpa, 5000);
    defer gpa.free(src);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    const dst = try gpa.alloc(u8, compressBound(src.len));
    defer gpa.free(dst);

    var c: Compressor = try .init(mem, .{}, src.len);
    const f = try Frame.parse(try c.compress(dst, src));
    try testing.expectEqual(@as(?u64, 5000), f.content_size);
    try testing.expect(f.checksum);
    try testing.expect(f.window_size <= 8192);

    var plain: Compressor = try .init(mem, .{ .checksum = false }, src.len);
    try testing.expect(!(try Frame.parse(try plain.compress(dst, src))).checksum);
}

test "a frame without a checksum is accepted, and one with a flipped bit is a mismatch" {
    const gpa = testing.allocator;
    const src = try body(gpa, 20_000);
    defer gpa.free(src);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    const dst = try gpa.alloc(u8, compressBound(src.len));
    defer gpa.free(dst);
    const dmem = try workspace(gpa, Decompressor.contextSize());
    defer gpa.free(dmem);
    var d: Decompressor = try .init(dmem, .{});

    var plain: Compressor = try .init(mem, .{ .checksum = false }, src.len);
    const back = try d.decode(gpa, try plain.compress(dst, src), src.len);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, src, back);

    var c: Compressor = try .init(mem, .{}, src.len);
    const frame = try c.compress(dst, src);
    // The checksum's last byte, changed: the blocks still decode to the
    // announced length, and only the checksum can tell.
    frame[frame.len - 1] ^= 0x01;
    try testing.expectError(error.ChecksumMismatch, d.decode(gpa, frame, src.len));
}

test "the ceiling is checked against the announced length before a byte is decoded" {
    const gpa = testing.allocator;
    const src = &@as([5000]u8, @splat('x'));
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, src.len);
    var dst: [256]u8 = undefined;
    const frame = try c.compress(&dst, src);

    try testing.expectEqual(@as(usize, 5000), try Decompressor.announced(frame, 23, 5000));
    try testing.expectError(error.BodyTooLarge, Decompressor.announced(frame, 23, 4999));
    // A counting allocator proves nothing was asked for.
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const dmem = try workspace(gpa, Decompressor.contextSize());
    defer gpa.free(dmem);
    var d: Decompressor = try .init(dmem, .{});
    try testing.expectError(error.BodyTooLarge, d.decode(failing.allocator(), frame, 4999));
}

test "a header that claims more than any frame of its length could hold is corrupt, not too large" {
    // magic, a frame header descriptor with a 8-byte content size (0xc0:
    // single segment off, size flag 3), then 2^60 as the size.
    var bad: [17]u8 = .{ 0x28, 0xb5, 0x2f, 0xfd, 0xc0, 0x00 } ++ @as([11]u8, @splat(0));
    std.mem.writeInt(u64, bad[6..14], 1 << 60, .little);
    try testing.expectError(error.Corrupt, Decompressor.announced(&bad, 31, 1 << 20));
}

test "bytes that are not a frame are NotZstd, and a frame cut short is Truncated" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotZstd, Decompressor.announced("{\"name\":\"wati\",\"a\":1,\"b\":2}", 23, 1024));
    try testing.expectError(error.Truncated, Decompressor.announced("", 23, 1024));
    try testing.expectError(error.Truncated, Decompressor.announced("\x28\xb5\x2f", 23, 1024));

    const src = try body(gpa, 10_000);
    defer gpa.free(src);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, src.len);
    const dst = try gpa.alloc(u8, compressBound(src.len));
    defer gpa.free(dst);
    const frame = try c.compress(dst, src);
    const dmem = try workspace(gpa, Decompressor.contextSize());
    defer gpa.free(dmem);
    var d: Decompressor = try .init(dmem, .{});
    try testing.expectError(error.Truncated, d.decode(gpa, frame[0 .. frame.len - 7], src.len));
    try testing.expectError(error.Truncated, d.decode(gpa, frame[0 .. frame.len / 2], src.len));
}

test "a corrupted block is refused or harmless, and never a different body" {
    const gpa = testing.allocator;
    const src = try body(gpa, 10_000);
    defer gpa.free(src);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, src.len);
    const dst = try gpa.alloc(u8, compressBound(src.len));
    defer gpa.free(dst);
    const frame = try c.compress(dst, src);
    const dmem = try workspace(gpa, Decompressor.contextSize());
    defer gpa.free(dmem);
    var d: Decompressor = try .init(dmem, .{});
    var at: usize = 12;
    while (at < frame.len) : (at += 97) {
        frame[at] ^= 0x10;
        // Either refused, or the flip landed on a bit nobody reads (padding)
        // and the body is the one that was sent: never a different body.
        if (d.decode(gpa, frame, src.len)) |back| {
            defer gpa.free(back);
            try testing.expectEqualSlices(u8, src, back);
        } else |_| {}
        frame[at] ^= 0x10;
    }
}

test "a frame whose window is over the cap is refused before anything is sized" {
    const gpa = testing.allocator;
    // 1 MB of a pattern with no repeats close by, at a 4 MB window.
    const src = try body(gpa, 600 << 10);
    defer gpa.free(src);
    const o: EncodeOptions = .{ .level = 9, .window_log = 22 };
    const smem = try workspace(gpa, StreamCompressor.contextSize(o));
    defer gpa.free(smem);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: StreamCompressor = try .init(smem, &out.writer, &.{}, o);
    try s.writer.writeAll(src);
    try s.finish();
    const frame = out.written();

    try testing.expectEqual(@as(u64, 1 << 22), (try Frame.parse(frame)).window_size);
    try testing.expectError(error.WindowTooLarge, StreamDecoder.sizeFrom(frame, .{ .window_log_max = 21 }));
    try testing.expect(try StreamDecoder.sizeFrom(frame, .{ .window_log_max = 22 }) > 4 << 20);
}

test "a stream round trips through the writer and the reader, in small writes" {
    const gpa = testing.allocator;
    const src = try body(gpa, 300 << 10);
    defer gpa.free(src);
    const o: EncodeOptions = .{ .level = 3 };
    const smem = try workspace(gpa, StreamCompressor.contextSize(o));
    defer gpa.free(smem);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: [1024]u8 = undefined;
    var s: StreamCompressor = try .init(smem, &out.writer, &buf, o);
    var at: usize = 0;
    while (at < src.len) : (at += 777) try s.writer.writeAll(src[at..@min(at + 777, src.len)]);
    try s.finish();
    const frame = out.written();
    try testing.expect(frame.len < src.len / 3);

    var in: std.Io.Reader = .fixed(frame);
    const dmem = try workspace(gpa, try StreamDecoder.sizeFromSource(&in, .{}));
    defer gpa.free(dmem);
    var d: StreamDecoder = try .init(dmem, &in, &.{}, .{});
    var back: std.Io.Writer.Allocating = .init(gpa);
    defer back.deinit();
    _ = try d.reader.streamRemaining(&back.writer);
    try testing.expectEqualSlices(u8, src, back.written());
}

test "flush makes the bytes so far decodable before the frame ends" {
    const gpa = testing.allocator;
    const o: EncodeOptions = .{};
    const smem = try workspace(gpa, StreamCompressor.contextSize(o));
    defer gpa.free(smem);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: StreamCompressor = try .init(smem, &out.writer, &.{}, o);

    try s.writer.writeAll("{\"line\":1}\n");
    // Nothing has reached the sink: a compressor holds a block back.
    const before = out.written().len;
    try s.writer.flush();
    const after = out.written().len;
    try testing.expect(after > before);

    // Those bytes, and no more, decode to the first line: the frame is not
    // over, and the reader says so by running out of input mid-frame.
    var in: std.Io.Reader = .fixed(out.written());
    const dmem = try workspace(gpa, StreamDecoder.contextSize(.{}));
    defer gpa.free(dmem);
    var d: StreamDecoder = try .init(dmem, &in, &.{}, .{});
    var got: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&got);
    var n: usize = 0;
    while (n < 11) n += try d.reader.stream(&w, .unlimited);
    try testing.expectEqualStrings("{\"line\":1}\n", w.buffered());
    try testing.expectError(error.ReadFailed, d.reader.stream(&w, .unlimited));
    try testing.expectEqual(@as(?Error, error.Truncated), d.err);

    try s.writer.writeAll("{\"line\":2}\n");
    try s.finish();
}

test "a bomb through the streaming reader stops at the ceiling" {
    const gpa = testing.allocator;
    // 64 MB of zeros is a few KB, and a frame that does not announce its size
    // (a stream) is the one a one-shot decoder cannot bound.
    const o: EncodeOptions = .{ .level = 1 };
    const smem = try workspace(gpa, StreamCompressor.contextSize(o));
    defer gpa.free(smem);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: StreamCompressor = try .init(smem, &out.writer, &.{}, o);
    const zeros: [1 << 16]u8 = @splat(0);
    for (0..1024) |_| try s.writer.writeAll(&zeros);
    try s.finish();
    const frame = out.written();
    try testing.expect(frame.len < 16 << 10);
    try testing.expectEqual(@as(?u64, null), (try Frame.parse(frame)).content_size);
    try testing.expectError(error.SizeNotAnnounced, Decompressor.announced(frame, 23, 1 << 30));

    var in: std.Io.Reader = .fixed(frame);
    const dmem = try workspace(gpa, try StreamDecoder.sizeFromSource(&in, .{}));
    defer gpa.free(dmem);
    var d: StreamDecoder = try .init(dmem, &in, &.{}, .{ .max_decoded = 1 << 20 });
    var sink_buf: [4096]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&sink_buf);
    try testing.expectError(error.ReadFailed, d.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(@as(?Error, error.BodyTooLarge), d.err);
    // Not a byte past the ceiling was handed on.
    try testing.expect(sink.count <= 1 << 20);

    // And the same frame under a ceiling it fits is decoded whole.
    in = .fixed(frame);
    d = try .init(dmem, &in, &.{}, .{ .max_decoded = 64 << 20 });
    var all: std.Io.Writer.Discarding = .init(&sink_buf);
    _ = try d.reader.streamRemaining(&all.writer);
    try all.writer.flush();
    try testing.expectEqual(@as(u64, 64 << 20), all.count);
}

test "a stream decoder stops at a frame cut short, and at bytes after the frame that are not one" {
    const gpa = testing.allocator;
    const src = try body(gpa, 50_000);
    defer gpa.free(src);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, src.len);
    const dst = try gpa.alloc(u8, compressBound(src.len) + 8);
    defer gpa.free(dst);
    const frame = try c.compress(dst, src);
    const dmem = try workspace(gpa, StreamDecoder.contextSize(.{}));
    defer gpa.free(dmem);

    var cut: std.Io.Reader = .fixed(frame[0 .. frame.len - 9]);
    var d: StreamDecoder = try .init(dmem, &cut, &.{}, .{});
    var sink_buf: [4096]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&sink_buf);
    try testing.expectError(error.ReadFailed, d.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(@as(?Error, error.Truncated), d.err);

    @memcpy(dst[frame.len..][0..4], "tail");
    var trailing: std.Io.Reader = .fixed(dst[0 .. frame.len + 4]);
    d = try .init(dmem, &trailing, &.{}, .{});
    try testing.expectError(error.ReadFailed, d.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(@as(?Error, error.NotZstd), d.err);
}

test "a stream decoder sized from the frame header holds exactly that frame, and no more" {
    const gpa = testing.allocator;
    const src = try body(gpa, 5000);
    defer gpa.free(src);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, src.len));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, src.len);
    const dst = try gpa.alloc(u8, compressBound(src.len));
    defer gpa.free(dst);
    const frame = try c.compress(dst, src);

    var in: std.Io.Reader = .fixed(frame);
    const need = try StreamDecoder.sizeFromSource(&in, .{});
    // A 5 KB body needs a 5 KB window, not 8 MB.
    try testing.expect(need < 400 << 10);
    const dmem = try workspace(gpa, need);
    defer gpa.free(dmem);
    var d: StreamDecoder = try .init(dmem, &in, &.{}, .{});
    var back: std.Io.Writer.Allocating = .init(gpa);
    defer back.deinit();
    _ = try d.reader.streamRemaining(&back.writer);
    try testing.expectEqualSlices(u8, src, back.written());

    // The same memory against a frame that needs a bigger window: refused,
    // not overrun.
    const o: EncodeOptions = .{ .level = 9, .window_log = 20 };
    const big = try body(gpa, 2 << 20);
    defer gpa.free(big);
    const smem = try workspace(gpa, StreamCompressor.contextSize(o));
    defer gpa.free(smem);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: StreamCompressor = try .init(smem, &out.writer, &.{}, o);
    try s.writer.writeAll(big);
    try s.finish();
    var in2: std.Io.Reader = .fixed(out.written());
    d = try .init(dmem, &in2, &.{}, .{});
    var sink_buf: [4096]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&sink_buf);
    try testing.expectError(error.ReadFailed, d.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(@as(?Error, error.ContextTooSmall), d.err);
}

test "an empty body compresses to a frame and decodes to nothing" {
    const gpa = testing.allocator;
    const mem = try workspace(gpa, Compressor.contextSize(.{}, 0));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, 0);
    var dst: [64]u8 = undefined;
    const frame = try c.compress(&dst, "");
    const dmem = try workspace(gpa, Decompressor.contextSize());
    defer gpa.free(dmem);
    var d: Decompressor = try .init(dmem, .{});
    const back = try d.decode(gpa, frame, 0);
    defer gpa.free(back);
    try testing.expectEqual(@as(usize, 0), back.len);
}

test "a frame that does not announce its size is decoded in one call, within the ceiling" {
    const gpa = testing.allocator;
    const src = try body(gpa, 300 << 10);
    defer gpa.free(src);
    const o: EncodeOptions = .{ .level = 3 };
    const smem = try workspace(gpa, StreamCompressor.contextSize(o));
    defer gpa.free(smem);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: StreamCompressor = try .init(smem, &out.writer, &.{}, o);
    try s.writer.writeAll(src);
    try s.finish();
    const frame = out.written();
    try testing.expectEqual(@as(?u64, null), (try Frame.parse(frame)).content_size);

    const dmem = try workspace(gpa, Decompressor.contextSize());
    defer gpa.free(dmem);
    var d: Decompressor = try .init(dmem, .{});
    const back = try d.decode(gpa, frame, src.len);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, src, back);
    // One byte under the length: the first byte past the ceiling is seen.
    try testing.expectError(error.BodyTooLarge, d.decode(gpa, frame, src.len - 1));
}

test "a bomb that does not announce its size cannot make the one-shot decoder hold more than the ceiling" {
    const gpa = testing.allocator;
    const o: EncodeOptions = .{ .level = 1 };
    const smem = try workspace(gpa, StreamCompressor.contextSize(o));
    defer gpa.free(smem);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: StreamCompressor = try .init(smem, &out.writer, &.{}, o);
    const zeros: [1 << 16]u8 = @splat(0);
    for (0..256) |_| try s.writer.writeAll(&zeros);
    try s.finish();
    const frame = out.written();
    try testing.expect(frame.len < 8 << 10);

    const dmem = try workspace(gpa, Decompressor.contextSize());
    defer gpa.free(dmem);
    var d: Decompressor = try .init(dmem, .{});
    var counting = testing.FailingAllocator.init(gpa, .{});
    try testing.expectError(error.BodyTooLarge, d.decode(counting.allocator(), frame, 100_000));
    try testing.expect(counting.allocated_bytes <= 100_001);
}

test "a sibling file is the compression of a file when its header and checksum say so, without decoding it" {
    const gpa = testing.allocator;
    const plain = try body(gpa, 20_000);
    defer gpa.free(plain);
    const mem = try workspace(gpa, Compressor.contextSize(.{}, plain.len));
    defer gpa.free(mem);
    var c: Compressor = try .init(mem, .{}, plain.len);
    const dst = try gpa.alloc(u8, compressBound(plain.len));
    defer gpa.free(dst);
    const frame = try c.compress(dst, plain);
    try testing.expect(Frame.matches(frame, plain));
    // Another file of the same length, the file edited since, and the frame
    // cut: each is not that file's sibling.
    const other = try gpa.dupe(u8, plain);
    defer gpa.free(other);
    other[7] ^= 1;
    try testing.expect(!Frame.matches(frame, other));
    try testing.expect(!Frame.matches(frame, plain[0 .. plain.len - 1]));
    try testing.expect(!Frame.matches(frame[0 .. frame.len - 1], plain));
    // A frame written without a checksum has nothing to be compared by.
    var unchecked: Compressor = try .init(mem, .{ .checksum = false }, plain.len);
    try testing.expect(!Frame.matches(try unchecked.compress(dst, plain), plain));
    try testing.expect(!Frame.matches("", plain));
}

test "a pool lends each compressor once, scans from the caller's slot, and is empty when all are out" {
    const gpa = testing.allocator;
    var pool: CompressorPool = try .init(gpa, 3, .{ .level = 1 }, 8 << 10);
    defer pool.deinit(gpa);
    const a = pool.borrow(1).?;
    const b = pool.borrow(1).?;
    const c = pool.borrow(1).?;
    try testing.expect(a != b and b != c and a != c);
    try testing.expectEqual(@as(?*Compressor, null), pool.borrow(0));
    pool.give(b);
    try testing.expectEqual(b, pool.borrow(2).?);
    // A thread asking for its own slot finds it when it is free.
    pool.give(a);
    try testing.expectEqual(a, pool.borrow(0).?);
}

test "four threads borrowing from a pool of four produce what one thread does" {
    const gpa = testing.allocator;
    const src = try body(gpa, 6000);
    defer gpa.free(src);
    var pool: CompressorPool = try .init(gpa, 4, .{}, src.len);
    defer pool.deinit(gpa);
    var dpool: DecompressorPool = try .init(gpa, 4, .{});
    defer dpool.deinit(gpa);

    const Worker = struct {
        fn run(p: *CompressorPool, dp: *DecompressorPool, plain: []const u8, id: usize, failed: *std.atomic.Value(bool)) void {
            var dst: [8192]u8 = undefined;
            for (0..200) |_| {
                const c = p.borrow(id) orelse {
                    failed.store(true, .monotonic);
                    return;
                };
                const frame = c.compress(&dst, plain) catch {
                    failed.store(true, .monotonic);
                    p.give(c);
                    return;
                };
                const d = dp.borrow(id) orelse {
                    failed.store(true, .monotonic);
                    p.give(c);
                    return;
                };
                var back: [6000]u8 = undefined;
                const got = d.decompress(&back, frame) catch &.{};
                if (!std.mem.eql(u8, got, plain)) failed.store(true, .monotonic);
                dp.give(d);
                p.give(c);
            }
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try .spawn(.{}, Worker.run, .{ &pool, &dpool, src[0..6000], i, &failed });
    for (threads) |t| t.join();
    try testing.expect(!failed.load(.monotonic));
}

test "libzstd is the release this module was written against" {
    try testing.expect(version() >= 10507);
}
