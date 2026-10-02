//! libdeflate, the gzip a build gets by asking for it with `.libdeflate =
//! true` (ADR 248). Reached only from `compress.zig`, and only when the
//! build linked the library: nothing here is analysed otherwise, so the
//! symbols this file exports exist only in a program that has the C beside
//! them.
//!
//! **Why libdeflate and not the standard library's deflate.** On a quiet
//! Zen 5 it takes a quarter of `std.flate`'s time at level 6 on 4 to 8 KB
//! of JSON and a third of it on a megabyte, and its output is 2% to 24%
//! smaller (`bench/result/http.md`). Its compressor is one allocation that
//! keeps no state from one body to the next, so the in-place `reset` that
//! `compress.zig` needs for the standard library has no counterpart here,
//! and one call writes 3.1 KB of stack where `std.flate` writes 7.4 KB.
//!
//! **What this file replaces is `lib/utils.c`, and it has to.** nilo's
//! plain build links no libc, so the library is compiled `FREESTANDING`,
//! and under that macro `utils.c` defines `memcpy`, `memset`, `memmove`
//! and `memcmp` as weak byte loops. Linked in, its 288-byte `memcpy` won
//! over compiler_rt's for every caller in the program, Zig's own included.
//! So `build.zig` leaves `utils.c` out and the four things the compressor
//! needs from it are below: the two default allocator pointers, null
//! because nilo always hands its own, and the aligned allocation pair,
//! which is the same arithmetic as the C.
//!
//! **Where a compressor lives is nilo's to say.** `libdeflate_options`
//! carries a `malloc_func` with no context argument, so the address goes in
//! through a thread-local that `placeAt` sets for the length of one
//! allocation. The compressor is never freed through libdeflate: its memory
//! belongs to whoever placed it, and `libdeflate_free_compressor` is not
//! called anywhere.

const std = @import("std");

pub const Compressor = opaque {};

const MallocFn = *const fn (usize) callconv(.c) ?*anyopaque;
const FreeFn = *const fn (?*anyopaque) callconv(.c) void;

const Options = extern struct {
    sizeof_options: usize = @sizeOf(Options),
    malloc_func: ?MallocFn,
    free_func: ?FreeFn,
};

extern fn libdeflate_alloc_compressor_ex(level: c_int, options: *const Options) ?*Compressor;
extern fn libdeflate_gzip_compress(c: *Compressor, in: [*]const u8, in_len: usize, out: [*]u8, out_avail: usize) usize;

// ---------------------------------------------------------------- utils.c

export var libdeflate_default_malloc_func: ?MallocFn = null;
export var libdeflate_default_free_func: ?FreeFn = null;

/// `utils.c`'s, line for line: room for the original pointer and the
/// alignment, and the original pointer kept just below what is returned.
export fn libdeflate_aligned_malloc(malloc_func: ?MallocFn, alignment: usize, size: usize) ?*anyopaque {
    const m = malloc_func orelse return null;
    const raw = m(@sizeOf(usize) + alignment - 1 + size) orelse return null;
    const at = std.mem.alignForward(usize, @intFromPtr(raw) + @sizeOf(usize), alignment);
    @as(*usize, @ptrFromInt(at - @sizeOf(usize))).* = @intFromPtr(raw);
    return @ptrFromInt(at);
}

export fn libdeflate_aligned_free(free_func: ?FreeFn, ptr: ?*anyopaque) void {
    const f = free_func orelse return;
    const p = ptr orelse return;
    f(@ptrFromInt(@as(*const usize, @ptrFromInt(@intFromPtr(p) - @sizeOf(usize))).*));
}

// ---------------------------------------------------------------- placement

/// Where the allocation `placeAt` is making goes, and what libdeflate asked
/// for. Thread-local because the callback has no other way in, and set only
/// for the length of one call.
threadlocal var placing: ?[]u8 = null;
threadlocal var asked: usize = 0;

fn place(n: usize) callconv(.c) ?*anyopaque {
    asked = n;
    const into = placing orelse return null;
    placing = null;
    if (n > into.len) return null;
    return into.ptr;
}

fn keep(_: ?*anyopaque) callconv(.c) void {}

/// The bytes one compressor at `level` takes, alignment slack included:
/// what `placeAt` has to be given. Asked by making the allocation with
/// nowhere to put it, which libdeflate answers with null and no side effect.
pub fn footprint(level: c_int) usize {
    placing = null;
    asked = 0;
    const options: Options = .{ .malloc_func = place, .free_func = keep };
    std.debug.assert(libdeflate_alloc_compressor_ex(level, &options) == null);
    return asked;
}

/// A compressor at `level` built inside `memory`, which has to be at least
/// `footprint(level)` long and outlive it. Null when it is not.
pub fn placeAt(level: c_int, memory: []u8) ?*Compressor {
    placing = memory;
    defer placing = null;
    const options: Options = .{ .malloc_func = place, .free_func = keep };
    return libdeflate_alloc_compressor_ex(level, &options);
}

// ---------------------------------------------------------------- gzip

/// `body` gzipped into memory from `allocator`, or null when the result is
/// not smaller than `body`. The rule is the standard library's in
/// `compress.zig`, so the two builds send gzip for exactly the same bodies.
///
/// **Half the input plus a little is tried first**, because that is where
/// text lands and it is the buffer the standard library's path reserves:
/// one allocation of the same size in either build. libdeflate writes into
/// a fixed buffer and answers 0 when the result does not fit, so a body
/// that compresses worse than half is tried once more with room for
/// anything shorter than itself, in the same allocation grown in place when
/// it was the allocator's last. Twice the CPU on that body, which on text
/// is the rare case: no body measured for ADR 248 came out above 37%.
///
/// The allocation is handed back whole beside what was written, and not
/// shrunk: a request's arena is reset after the answer, so a resize there
/// is a call that buys nothing, and `test "a compressed answer costs one
/// allocation"` holds the request path to none. A caller that keeps the
/// result for good shrinks it itself.
pub fn gzip(c: *Compressor, allocator: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?Squeezed {
    if (body.len < 2) return null;
    const most = body.len - 1;
    const first_len = @min(most, body.len / 2 + 64);
    const first = try allocator.alloc(u8, first_len);
    const n = libdeflate_gzip_compress(c, body.ptr, body.len, first.ptr, first.len);
    if (n != 0) return .{ .allocation = first, .len = n };
    if (first_len == most) {
        allocator.free(first);
        return null;
    }
    const room = if (allocator.resize(first, most)) first.ptr[0..most] else blk: {
        allocator.free(first);
        break :blk try allocator.alloc(u8, most);
    };
    const m = libdeflate_gzip_compress(c, body.ptr, body.len, room.ptr, room.len);
    if (m == 0) {
        allocator.free(room);
        return null;
    }
    return .{ .allocation = room, .len = m };
}

/// What `gzip` wrote, and the allocation it wrote it into.
pub const Squeezed = struct {
    allocation: []u8,
    len: usize,

    pub fn bytes(self: Squeezed) []u8 {
        return self.allocation[0..self.len];
    }
};
