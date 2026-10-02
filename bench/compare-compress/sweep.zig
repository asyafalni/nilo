//! Per-body cost of compressing a whole in-memory JSON body, for nilo's
//! response compression (ADR 211). Every codec gets the body as one slice
//! and writes into one buffer allocated from a request-style arena that is
//! reset after every body, the way `Pool.gzip` does.
//!
//! The std.flate path is nilo's `Pool.gzip` copied: one long-lived
//! `Compress` + window, re-armed with the same `reset` as http/compress.zig.
//!
//! Runs are interleaved: the outer loop is the repetition, so every codec on
//! every body is measured once before any is measured twice, and a burst of
//! load from another process lands on all of them rather than on one.
//!
//! Output: one CSV line per (rep, body, codec): rep,body,in,codec,out,cpu_us,wall_us

const std = @import("std");
const flate = std.compress.flate;

// ---------------------------------------------------------------- C APIs

const LdfOptions = extern struct {
    sizeof_options: usize,
    malloc_func: ?*const fn (usize) callconv(.c) ?*anyopaque,
    free_func: ?*const fn (?*anyopaque) callconv(.c) void,
};
extern fn libdeflate_alloc_compressor_ex(level: c_int, opts: *const LdfOptions) ?*anyopaque;
extern fn libdeflate_gzip_compress(c: *anyopaque, in: [*]const u8, n: usize, out: [*]u8, avail: usize) usize;
extern fn libdeflate_gzip_compress_bound(c: ?*anyopaque, n: usize) usize;
extern fn libdeflate_alloc_decompressor() ?*anyopaque;
extern fn libdeflate_gzip_decompress(d: *anyopaque, in: [*]const u8, n: usize, out: [*]u8, avail: usize, actual: ?*usize) c_int;

extern fn ZSTD_createCCtx() ?*anyopaque;
extern fn ZSTD_freeCCtx(c: ?*anyopaque) usize;
extern fn ZSTD_compressCCtx(c: *anyopaque, dst: [*]u8, cap: usize, src: [*]const u8, n: usize, level: c_int) usize;
extern fn ZSTD_compressBound(n: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_sizeof_CCtx(c: *anyopaque) usize;
extern fn ZSTD_estimateCCtxSize(level: c_int) usize;
extern fn ZSTD_decompress(dst: [*]u8, cap: usize, src: [*]const u8, n: usize) usize;

const BrAlloc = *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque;
const BrFree = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
extern fn BrotliEncoderCompress(quality: c_int, lgwin: c_int, mode: c_int, in_size: usize, in: [*]const u8, out_size: *usize, out: [*]u8) c_int;
extern fn BrotliEncoderMaxCompressedSize(n: usize) usize;
extern fn BrotliEncoderCreateInstance(a: ?BrAlloc, f: ?BrFree, o: ?*anyopaque) ?*anyopaque;
extern fn BrotliEncoderSetParameter(s: *anyopaque, p: c_int, v: u32) c_int;
extern fn BrotliEncoderCompressStream(s: *anyopaque, op: c_int, avail_in: *usize, next_in: *[*]const u8, avail_out: *usize, next_out: *[*]u8, total_out: ?*usize) c_int;
extern fn BrotliEncoderIsFinished(s: *anyopaque) c_int;
extern fn BrotliEncoderDestroyInstance(s: *anyopaque) void;
extern fn BrotliDecoderDecompress(n: usize, in: [*]const u8, out_n: *usize, out: [*]u8) c_int;

extern fn malloc(n: usize) ?*anyopaque;
extern fn free(p: ?*anyopaque) void;

// ---------------------------------------------------------------- bodies

const Body = struct { name: []const u8, bytes: []const u8 };
const bodies = [_]Body{
    .{ .name = "bench-25", .bytes = @embedFile("bodies/bench-25.json") },
    .{ .name = "bench-40", .bytes = @embedFile("bodies/bench-40.json") },
    .{ .name = "bench-50", .bytes = @embedFile("bodies/bench-50.json") },
    .{ .name = "arena-25", .bytes = @embedFile("bodies/arena-25.json") },
    .{ .name = "arena-40", .bytes = @embedFile("bodies/arena-40.json") },
    .{ .name = "arena-50", .bytes = @embedFile("bodies/arena-50.json") },
};

// ---------------------------------------------------------------- std.flate, as nilo does it

const Slot = struct {
    state: flate.Compress,
    window: [flate.max_window_len]u8,
    vtable: *const std.Io.Writer.VTable,
};

/// http/compress.zig's `reset`, verbatim.
fn reset(slot: *Slot, output: *std.Io.Writer, opts: flate.Compress.Options) std.Io.Writer.Error!void {
    const c = &slot.state;
    try output.writeAll(flate.Container.gzip.header());
    c.writer = .{ .buffer = &slot.window, .vtable = slot.vtable, .end = 0 };
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

fn newSlot(gpa: std.mem.Allocator, opts: flate.Compress.Options) !*Slot {
    const slot = try gpa.create(Slot);
    var scratch: [16]u8 = undefined;
    var discard: std.Io.Writer = .fixed(&scratch);
    slot.state = try flate.Compress.init(&discard, &slot.window, .gzip, opts);
    slot.vtable = slot.state.writer.vtable;
    return slot;
}

// ---------------------------------------------------------------- codecs

const Kind = enum { std_flate, std_reset_only, libdeflate, zstd, brotli };
const Codec = struct {
    name: []const u8,
    kind: Kind,
    level: c_int,
    /// Skip bodies larger than this (the slowest levels on the 4 MB body).
    max_in: usize = std.math.maxInt(usize),
    slot: ?*Slot = null,
    flate_opts: flate.Compress.Options = .default,
    ldf: ?*anyopaque = null,
    cctx: ?*anyopaque = null,
};

var codecs = [_]Codec{
    .{ .name = "std-reset-only", .kind = .std_reset_only, .level = 6 },
    .{ .name = "std-flate-1", .kind = .std_flate, .level = 1, .flate_opts = .level_1 },
    .{ .name = "std-flate-2", .kind = .std_flate, .level = 2, .flate_opts = .level_2 },
    .{ .name = "std-flate-3", .kind = .std_flate, .level = 3, .flate_opts = .level_3 },
    .{ .name = "std-flate-4", .kind = .std_flate, .level = 4, .flate_opts = .level_4 },
    .{ .name = "std-flate-5", .kind = .std_flate, .level = 5, .flate_opts = .level_5 },
    .{ .name = "std-flate-6", .kind = .std_flate, .level = 6, .flate_opts = .level_6 },
    .{ .name = "std-flate-7", .kind = .std_flate, .level = 7, .flate_opts = .level_7 },
    .{ .name = "std-flate-8", .kind = .std_flate, .level = 8, .flate_opts = .level_8 },
    .{ .name = "std-flate-9", .kind = .std_flate, .level = 9, .flate_opts = .level_9 },
    .{ .name = "libdeflate-1", .kind = .libdeflate, .level = 1 },
    .{ .name = "libdeflate-2", .kind = .libdeflate, .level = 2 },
    .{ .name = "libdeflate-3", .kind = .libdeflate, .level = 3 },
    .{ .name = "libdeflate-4", .kind = .libdeflate, .level = 4 },
    .{ .name = "libdeflate-5", .kind = .libdeflate, .level = 5 },
    .{ .name = "libdeflate-6", .kind = .libdeflate, .level = 6 },
    .{ .name = "libdeflate-7", .kind = .libdeflate, .level = 7 },
    .{ .name = "libdeflate-8", .kind = .libdeflate, .level = 8 },
    .{ .name = "libdeflate-9", .kind = .libdeflate, .level = 9 },
    .{ .name = "libdeflate-10", .kind = .libdeflate, .level = 10 },
    .{ .name = "libdeflate-11", .kind = .libdeflate, .level = 11 },
    .{ .name = "libdeflate-12", .kind = .libdeflate, .level = 12 },
    .{ .name = "brotli-0", .kind = .brotli, .level = 0 },
    .{ .name = "brotli-1", .kind = .brotli, .level = 1 },
    .{ .name = "brotli-2", .kind = .brotli, .level = 2 },
    .{ .name = "brotli-3", .kind = .brotli, .level = 3 },
    .{ .name = "brotli-4", .kind = .brotli, .level = 4 },
    .{ .name = "brotli-5", .kind = .brotli, .level = 5 },
    .{ .name = "brotli-6", .kind = .brotli, .level = 6 },
    .{ .name = "brotli-7", .kind = .brotli, .level = 7 },
    .{ .name = "brotli-8", .kind = .brotli, .level = 8 },
    .{ .name = "brotli-9", .kind = .brotli, .level = 9 },
    .{ .name = "zstd-1", .kind = .zstd, .level = 1 },
    .{ .name = "zstd-2", .kind = .zstd, .level = 2 },
    .{ .name = "zstd-3", .kind = .zstd, .level = 3 },
    .{ .name = "zstd-4", .kind = .zstd, .level = 4 },
    .{ .name = "zstd-5", .kind = .zstd, .level = 5 },
    .{ .name = "zstd-6", .kind = .zstd, .level = 6 },
};

/// Compress `body` once into `arena`; returns the compressed length.
fn once(c: *Codec, arena: std.mem.Allocator, body: []const u8) !usize {
    switch (c.kind) {
        .std_reset_only => {
            var out = try std.Io.Writer.Allocating.initCapacity(arena, body.len / 2 + 64);
            try reset(c.slot.?, &out.writer, c.flate_opts);
            return out.written().len;
        },
        .std_flate => {
            var out = try std.Io.Writer.Allocating.initCapacity(arena, body.len / 2 + 64);
            try reset(c.slot.?, &out.writer, c.flate_opts);
            try c.slot.?.state.writer.writeAll(body);
            try c.slot.?.state.finish();
            return out.written().len;
        },
        .libdeflate => {
            const cap = libdeflate_gzip_compress_bound(c.ldf, body.len);
            const out = try arena.alloc(u8, cap);
            const n = libdeflate_gzip_compress(c.ldf.?, body.ptr, body.len, out.ptr, cap);
            if (n == 0) return error.LibdeflateFailed;
            return n;
        },
        .zstd => {
            const cap = ZSTD_compressBound(body.len);
            const out = try arena.alloc(u8, cap);
            const n = ZSTD_compressCCtx(c.cctx.?, out.ptr, cap, body.ptr, body.len, c.level);
            if (ZSTD_isError(n) != 0) return error.ZstdFailed;
            return n;
        },
        .brotli => {
            var n = BrotliEncoderMaxCompressedSize(body.len);
            const out = try arena.alloc(u8, n);
            // lgwin 22 (BROTLI_DEFAULT_WINDOW), mode 0 (GENERIC)
            if (BrotliEncoderCompress(c.level, 22, 0, body.len, body.ptr, &n, out.ptr) == 0) return error.BrotliFailed;
            return n;
        },
    }
}

/// Compress once more and decode with the reference decoder, to prove the
/// timed output is the body.
fn verify(c: *Codec, gpa: std.mem.Allocator, body: []const u8) !void {
    if (c.kind == .std_reset_only) return;
    var a = std.heap.ArenaAllocator.init(gpa);
    defer a.deinit();
    const arena = a.allocator();
    const enc: []const u8 = switch (c.kind) {
        .std_flate => blk: {
            var out = try std.Io.Writer.Allocating.initCapacity(arena, body.len / 2 + 64);
            try reset(c.slot.?, &out.writer, c.flate_opts);
            try c.slot.?.state.writer.writeAll(body);
            try c.slot.?.state.finish();
            break :blk out.written();
        },
        .libdeflate => blk: {
            const cap = libdeflate_gzip_compress_bound(c.ldf, body.len);
            const out = try arena.alloc(u8, cap);
            break :blk out[0..libdeflate_gzip_compress(c.ldf.?, body.ptr, body.len, out.ptr, cap)];
        },
        .zstd => blk: {
            const cap = ZSTD_compressBound(body.len);
            const out = try arena.alloc(u8, cap);
            break :blk out[0..ZSTD_compressCCtx(c.cctx.?, out.ptr, cap, body.ptr, body.len, c.level)];
        },
        .brotli => blk: {
            var n = BrotliEncoderMaxCompressedSize(body.len);
            const out = try arena.alloc(u8, n);
            _ = BrotliEncoderCompress(c.level, 22, 0, body.len, body.ptr, &n, out.ptr);
            break :blk out[0..n];
        },
        .std_reset_only => unreachable,
    };
    const dec = try arena.alloc(u8, body.len + 16);
    var got: usize = 0;
    switch (c.kind) {
        .std_flate, .libdeflate => {
            const d = libdeflate_alloc_decompressor().?;
            if (libdeflate_gzip_decompress(d, enc.ptr, enc.len, dec.ptr, dec.len, &got) != 0) return error.BadGzip;
        },
        .zstd => {
            got = ZSTD_decompress(dec.ptr, dec.len, enc.ptr, enc.len);
            if (ZSTD_isError(got) != 0) return error.BadZstd;
        },
        .brotli => {
            got = dec.len;
            if (BrotliDecoderDecompress(enc.len, enc.ptr, &got, dec.ptr) != 1) return error.BadBrotli;
        },
        .std_reset_only => unreachable,
    }
    if (!std.mem.eql(u8, dec[0..got], body)) return error.RoundTripMismatch;
}

// ---------------------------------------------------------------- memory accounting

/// libdeflate: one allocation, the compressor struct. Record its size.
var ldf_last_alloc: usize = 0;
fn ldfMalloc(n: usize) callconv(.c) ?*anyopaque {
    ldf_last_alloc = n;
    return malloc(n);
}
fn ldfFree(p: ?*anyopaque) callconv(.c) void {
    free(p);
}

/// brotli: peak bytes live inside one encoder instance for one body.
var br_live: usize = 0;
var br_peak: usize = 0;
fn brAlloc(_: ?*anyopaque, n: usize) callconv(.c) ?*anyopaque {
    const raw: [*]u8 = @ptrCast(malloc(n + 16) orelse return null);
    @as(*usize, @ptrCast(@alignCast(raw))).* = n;
    br_live += n;
    br_peak = @max(br_peak, br_live);
    return raw + 16;
}
fn brFree(_: ?*anyopaque, p: ?*anyopaque) callconv(.c) void {
    const q: [*]u8 = @ptrCast(p orelse return);
    const raw = q - 16;
    br_live -= @as(*usize, @ptrCast(@alignCast(raw))).*;
    free(raw);
}
fn brotliPeak(level: c_int, body: []const u8, out: []u8) usize {
    br_live = 0;
    br_peak = 0;
    const s = BrotliEncoderCreateInstance(brAlloc, brFree, null).?;
    _ = BrotliEncoderSetParameter(s, 1, @intCast(level)); // QUALITY
    _ = BrotliEncoderSetParameter(s, 2, 22); // LGWIN
    _ = BrotliEncoderSetParameter(s, 5, @intCast(@min(body.len, 1 << 30))); // SIZE_HINT
    var avail_in = body.len;
    var next_in: [*]const u8 = body.ptr;
    var avail_out = out.len;
    var next_out: [*]u8 = out.ptr;
    while (BrotliEncoderIsFinished(s) == 0) {
        if (BrotliEncoderCompressStream(s, 2, &avail_in, &next_in, &avail_out, &next_out, null) == 0) break;
    }
    BrotliEncoderDestroyInstance(s);
    return br_peak;
}

// ---------------------------------------------------------------- timing

fn nanos() u64 {
    return clockNanos(.MONOTONIC);
}

/// This thread's CPU time: what the codec cost, minus the time another
/// process held the core (the box is shared and had a load of 5 on 2 cores).
fn cpuNanos() u64 {
    return clockNanos(.THREAD_CPUTIME_ID);
}

fn clockNanos(id: std.posix.clockid_t) u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(id, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    const print = std.debug.print;
    const reps: usize = 7;
    // sweep: every level on the arena-sized bodies
    const target_ns: u64 = 60 * std.time.ns_per_ms;

    for (&codecs) |*c| switch (c.kind) {
        .std_flate, .std_reset_only => c.slot = try newSlot(gpa, c.flate_opts),
        .libdeflate => {
            const o: LdfOptions = .{ .sizeof_options = @sizeOf(LdfOptions), .malloc_func = ldfMalloc, .free_func = ldfFree };
            c.ldf = libdeflate_alloc_compressor_ex(c.level, &o).?;
            print("# mem libdeflate-{d} compressor bytes={d}\n", .{ c.level, ldf_last_alloc });
        },
        .zstd => {
            c.cctx = ZSTD_createCCtx().?;
            print("# mem zstd-{d} estimateCCtxSize(worst case)={d}\n", .{ c.level, ZSTD_estimateCCtxSize(c.level) });
        },
        .brotli => {},
    };
    print("# mem std.flate Slot (Compress + window) bytes={d}\n", .{@sizeOf(Slot)});

    // Round trips, and per-body memory for the codecs whose state depends on the input.
    for (bodies) |b| {
        for (&codecs) |*c| {
            if (b.bytes.len > c.max_in) continue;
            try verify(c, gpa, b.bytes);
        }
        for ([_]c_int{}) |lv| {
            if (lv == 19 and b.bytes.len > 70_000) continue;
            const cx = ZSTD_createCCtx().?;
            const out = try gpa.alloc(u8, ZSTD_compressBound(b.bytes.len));
            defer gpa.free(out);
            _ = ZSTD_compressCCtx(cx, out.ptr, out.len, b.bytes.ptr, b.bytes.len, lv);
            print("# mem zstd-{d} {s} sizeof_CCtx after one body={d}\n", .{ lv, b.name, ZSTD_sizeof_CCtx(cx) });
            _ = ZSTD_freeCCtx(cx);
        }
        for ([_]c_int{}) |lv| {
            if (lv == 11 and b.bytes.len > 70_000) continue;
            const out = try gpa.alloc(u8, BrotliEncoderMaxCompressedSize(b.bytes.len) + 1024);
            defer gpa.free(out);
            print("# mem brotli-{d} {s} peak instance bytes={d}\n", .{ lv, b.name, brotliPeak(lv, b.bytes, out) });
        }
    }
    print("# all round trips verified\n", .{});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    print("rep,body,in,codec,out,cpu_us,wall_us\n", .{});
    for (0..reps) |rep| {
        for (bodies) |b| {
            for (&codecs) |*c| {
                if (b.bytes.len > c.max_in) continue;
                // Warm, and estimate how many rounds fill target_ns.
                var out_len: usize = 0;
                const w0 = nanos();
                var warm: usize = 0;
                while (warm < 3 or (warm < 50 and nanos() - w0 < 20 * std.time.ns_per_ms)) : (warm += 1) {
                    out_len = try once(c, arena, b.bytes);
                    _ = arena_state.reset(.retain_capacity);
                }
                const per = @max(1, (nanos() - w0) / warm);
                const rounds: usize = @intCast(std.math.clamp(target_ns / per, 3, 200_000));
                const t0 = nanos();
                const c0 = cpuNanos();
                for (0..rounds) |_| {
                    _ = try once(c, arena, b.bytes);
                    _ = arena_state.reset(.retain_capacity);
                }
                const cpu_us = @as(f64, @floatFromInt(cpuNanos() - c0)) / @as(f64, @floatFromInt(rounds)) / 1000.0;
                const wall_us = @as(f64, @floatFromInt(nanos() - t0)) / @as(f64, @floatFromInt(rounds)) / 1000.0;
                print("{d},{s},{d},{s},{d},{d:.2},{d:.2}\n", .{ rep, b.name, b.bytes.len, c.name, out_len, cpu_us, wall_us });
            }
        }
    }
}
