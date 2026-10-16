//! A request body under `Content-Encoding: zstd`, decoded into the arena
//! ([ADR 295](../docs/adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)),
//! the counterpart of `encoded.zig` for gzip.
//!
//! **It exists only in a build that asked for it**: `nilo_build.zstd` is true
//! when a dependent passed `.zstd = true`, and otherwise nothing here names
//! `nilo_zstd`, so no libzstd is fetched or linked and the parser keeps
//! calling zstd an encoding the server does not read (ADR 089). `enabled` is
//! the one constant the rest of `http/` asks.
//!
//! The shape is `encoded.inflate`'s, with a better contract underneath: a
//! frame announces its size in the header, so the ceiling is checked against
//! a number before anything is allocated, the allocation is exactly that size,
//! and a frame that lies is refused (libzstd's one-shot decoder needs no
//! window, the destination is the history). **The context is a pool slot**,
//! one 95,968-byte decoder a thread in one mapping (`DecompressorPool`),
//! borrowed for the length of one call that parks nowhere; it is not on the
//! fiber's stack and not in the arena. Only an App with no server under it
//! (a test driving a handler by hand, with no pool) takes one from the arena.
//!
//! **A frame that does not announce its size** (a streaming encoder cannot
//! know it, and the OpenTelemetry Collector's zstd is one) is decoded into at
//! most `limit + 1` bytes and shrunk to what it used, so a bomb of zeros
//! costs the ceiling and not its own size, and is a 413 (ADR 295). A checksum
//! the frame carries is verified; one it lacks is not required.

const std = @import("std");

const build = @import("nilo_build");
const encoded = @import("encoded.zig");
const bulkhead = @import("bulkhead.zig");

/// Whether this build reads a zstd request body.
pub const enabled = build.zstd;

pub const zstd = if (enabled) @import("nilo_zstd") else struct {};

/// The decoders, one per executor thread. `void` in a build that does not
/// read zstd, so the App and the Ctx carry nothing for it.
pub const Pool = if (enabled) zstd.DecompressorPool else void;

pub const Error = encoded.Error;

/// The window a request's frame may ask for: RFC 9659's 8 MB, and no more
/// (ADR 295).
pub const window_log_max = if (enabled) zstd.http_window_log else 0;

fn refusal(err: anyerror) Error {
    return switch (err) {
        error.BodyTooLarge => error.BodyTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        // Not zstd, corrupt, truncated, a checksum that disagrees, a window
        // over the cap, a size no frame of this length could hold: one answer.
        else => error.BadEncodedBody,
    };
}

/// What the frame at the front of `raw` says it decodes to, checked as far as
/// it can be before anything is allocated (the magic, the window, a size the
/// frame's length could hold, `limit`), or null when it announces nothing.
/// What a caller with a budget to keep (a gRPC connection's, ADR 220) asks
/// first, so that what it charges is what `decode` will allocate.
pub fn announcedSize(raw: []const u8, limit: usize) Error!?usize {
    if (comptime !enabled) unreachable;
    return zstd.Decompressor.announced(raw, window_log_max, limit) catch |err| switch (err) {
        error.SizeNotAnnounced => null,
        else => refusal(err),
    };
}

/// `raw`, decoded into `arena`, at most `limit` bytes.
///
/// `arena` is the request arena, on the terms `readSizedBody` states: a frame
/// that fails partway leaves what was allocated, which against an arena is
/// free. `pool` is the App's, or null where there is none. `noinline`, so a
/// request that reads no zstd carries none of its frame.
pub noinline fn decode(arena: std.mem.Allocator, pool: ?*Pool, raw: []const u8, limit: usize) Error![]const u8 {
    if (comptime !enabled) unreachable;
    // The thread's own slot first (the executor index is where the thread
    // that decoded last time left its tables warm). An empty pool, which a
    // server never has, falls through to the arena.
    const lent: ?*zstd.Decompressor = if (pool) |p| p.borrow(bulkhead.executorIndex() orelse 0) else null;
    defer if (lent) |d| pool.?.give(d);
    var own: zstd.Decompressor = undefined;
    const decoder: *zstd.Decompressor = lent orelse blk: {
        const memory = try arena.alignedAlloc(u8, zstd.workspace_alignment, zstd.Decompressor.contextSize());
        own = zstd.Decompressor.init(memory, .{ .window_log_max = window_log_max }) catch |err| return refusal(err);
        break :blk &own;
    };
    return decoder.decode(arena, raw, limit) catch |err| refusal(err);
}

// ---- tests ----

const testing = std.testing;

test "a build without the flag has no decoders and says so with one constant" {
    if (enabled) return error.SkipZigTest;
    try testing.expect(Pool == void);
}
