//! A request body under a content coding (ADR 293, ADR 295).
//!
//! ```zig
//! const res = try client.postJson(c, url, report, .{ .encoding = fetch.gzip });
//! const res = try client.postJson(c, url, report, .{ .encoding = fetch.zstd });
//! ```
//!
//! **A `Coding` is a value the caller names, and naming it is what links the
//! compressor.** `fetch.gzip` is a constant whose vtable points at the
//! functions below; a program that never writes `fetch.gzip` never analyses
//! them, so `std.compress.flate`'s compressor is not in its binary. The other
//! shape, a runtime `Call.encoding` enum switched on inside `send`, would
//! link it into every program that dials out, which is the complaint ADR 017
//! made of a setting that costs a branch whether or not anybody chose it.
//! A second coding is a second constant with a vtable of its own, and zstd is
//! that second (ADR 295); nothing in `fetch.zig` knows the name `gzip` or
//! `zstd` apart from this file, and a program that names `fetch.zstd` and not
//! `fetch.gzip` links libzstd and no flate.
//!
//! **Where the compressor lives is the other half of the design.** A deflate
//! compressor is `~288 KB` and `Compress.init` builds a 96 KB temporary on the
//! stack (ADR 211); a fiber keeps its stack at its high-water mark (ADR 062),
//! and a call made from a handler runs on that fiber. So the compressor is on
//! the heap, started in place by `core.deflate` (40 bytes of stack), and
//! **kept on the `Client` between calls** in a `Stash` of one: the first
//! compressed call allocates it, every later one takes it back and resets it,
//! and a call that finds it taken (two compressed calls at once) allocates a
//! spare that is freed when that call ends. A client that never compresses
//! holds a null pointer.

const std = @import("std");
const core = @import("nilo_core");
const z = @import("nilo_zstd");

/// How hard to look for a match, in words every coding has: `.fastest` is the
/// least CPU, `.default` the one a coding recommends, `.best` the smallest
/// output at a cost that is the caller's to have chosen (an agent on a busy
/// host chooses `.fastest`). A coding maps them to its own scale: gzip to
/// zlib's levels 1, 6 and 9, zstd to 1, 3 and 6. `.exact` is the codec's
/// own number, for the caller who has measured: zstd takes 1 to 22 (and
/// negative levels, faster and larger), gzip clamps it to those three. The
/// memory of zstd's compressor grows with the level (`.best` at a megabyte
/// is 3.7 MB, level 12 is 13 MB, level 19 is 18 MB, and a chunked upload
/// above level 6 holds 7 to 86 MB), which is why `.best` is 6 and the number
/// above it is `exact` (ADR 295).
pub const Level = union(enum) {
    fastest,
    default,
    best,
    exact: i32,
};

/// A content coding a request body can be sent under.
pub const Coding = struct {
    /// The token in `Content-Encoding`, and the one a 415 is checked for in
    /// `Accept-Encoding`.
    name: []const u8,
    /// How hard to look for a match. A client's CPU is the cost here, on a
    /// host that runs other people's work, so `.default` is zlib's level 6
    /// and `.fastest` is level 1.
    level: Level = .default,
    /// A body shorter than this goes out as it is: a hundred bytes get
    /// longer under gzip, and the round trip is the cost of a small post.
    min_bytes: usize = 1024,
    vtable: *const VTable,

    /// What a coding does. Four functions, so that the call in `fetch.zig`
    /// names no codec.
    pub const VTable = struct {
        /// The whole of `plain` under the coding, in `arena`, or null when
        /// the result is not smaller.
        squeeze: *const fn (stash: *Stash, gpa: std.mem.Allocator, arena: std.mem.Allocator, plain: []const u8, level: Level) error{OutOfMemory}!?[]const u8,
        /// A compressor started onto `sink`, to be written to and finished.
        open: *const fn (stash: *Stash, gpa: std.mem.Allocator, level: Level, sink: *std.Io.Writer) error{OutOfMemory}!*Spare,
        /// Where the plain bytes go. A `flush` on it is a sync flush: what
        /// was written reaches the sink as whole blocks.
        writer: *const fn (spare: *Spare) *std.Io.Writer,
        /// The last block and the trailer.
        finish: *const fn (spare: *Spare) std.Io.Writer.Error!void,
    };

    /// The same coding at another level or threshold.
    pub fn with(self: Coding, options: struct { level: ?Level = null, min_bytes: ?usize = null }) Coding {
        var c = self;
        if (options.level) |l| c.level = l;
        if (options.min_bytes) |m| c.min_bytes = m;
        return c;
    }
};

/// A compressor that outlives a call. The header every coding's spare starts
/// with, so that the client can hold one without knowing which.
pub const Spare = struct {
    owner: *const Coding.VTable,
    destroy: *const fn (spare: *Spare, gpa: std.mem.Allocator) void,
    /// The bytes it holds, so that `Stash.give` can decline to keep one a
    /// client would carry for ever: a context grows with the level and the
    /// body, and a call at level 19 must not leave tens of megabytes behind
    /// (`stash_keep_max`).
    held: usize,
};

/// The largest compressor a `Client` keeps between calls: 4 MiB. Gzip's is
/// 288 KB; zstd's is 73 KB to 4 MiB at the levels `.fastest` to `.best` and
/// the bodies up to a megabyte, and more at the levels above, which a caller
/// asks for by number and pays for in one call (ADR 295).
pub const stash_keep_max = 4 << 20;

/// The one compressor a `Client` keeps between calls. A swap on a pointer:
/// no lock, and no waiting when it is taken.
pub const Stash = struct {
    slot: std.atomic.Value(?*Spare) = .init(null),

    /// The kept compressor if it is this coding's, else null. One of
    /// another coding is freed, because it is not coming back.
    pub fn take(self: *Stash, owner: *const Coding.VTable, gpa: std.mem.Allocator) ?*Spare {
        const got = self.slot.swap(null, .acquire) orelse return null;
        if (got.owner == owner) return got;
        got.destroy(got, gpa);
        return null;
    }

    /// Keep `spare` for the next call, or free it when one is kept already or
    /// when it holds more than `stash_keep_max`.
    pub fn give(self: *Stash, spare: *Spare, gpa: std.mem.Allocator) void {
        if (spare.held > stash_keep_max) return spare.destroy(spare, gpa);
        if (self.slot.cmpxchgStrong(null, spare, .release, .monotonic) != null) spare.destroy(spare, gpa);
    }

    pub fn deinit(self: *Stash, gpa: std.mem.Allocator) void {
        if (self.slot.swap(null, .acquire)) |spare| spare.destroy(spare, gpa);
    }
};

/// Whether `accept_encoding`, the value a 415 answered with, lists `name`
/// with a quality above zero. A server that reads gzip and says so is
/// refusing for another reason, and the body is not sent again (ADR 293).
pub fn lists(accept_encoding: ?[]const u8, name: []const u8) bool {
    const value = accept_encoding orelse return false;
    var parts = std.mem.tokenizeScalar(u8, value, ',');
    while (parts.next()) |part| {
        var fields = std.mem.tokenizeScalar(u8, part, ';');
        const token = std.mem.trim(u8, fields.next() orelse continue, " \t");
        if (!std.ascii.eqlIgnoreCase(token, name)) continue;
        while (fields.next()) |param| {
            const p = std.mem.trim(u8, param, " \t");
            if (p.len > 2 and (p[0] == 'q' or p[0] == 'Q') and p[1] == '=') {
                const q = std.fmt.parseFloat(f32, p[2..]) catch return true;
                return q > 0;
            }
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- gzip

/// gzip, from the standard library's deflate. The level is `Coding.level`.
pub const gzip: Coding = .{ .name = "gzip", .vtable = &gzip_vtable };

const gzip_vtable: Coding.VTable = .{
    .squeeze = gzipSqueeze,
    .open = gzipOpen,
    .writer = gzipWriter,
    .finish = gzipFinish,
};

const GzipSpare = struct {
    spare: Spare,
    z: core.deflate.Gzip,

    fn destroySpare(spare: *Spare, gpa: std.mem.Allocator) void {
        const self: *GzipSpare = @fieldParentPtr("spare", spare);
        gpa.destroy(self);
    }
};

fn gzipLevel(level: Level) core.deflate.Level {
    return switch (level) {
        .fastest => .fastest,
        .default => .default,
        .best => .best,
        .exact => |n| if (n <= 1) .fastest else if (n >= 9) .best else .default,
    };
}

fn gzipAcquire(stash: *Stash, gpa: std.mem.Allocator) error{OutOfMemory}!*GzipSpare {
    if (stash.take(&gzip_vtable, gpa)) |kept| return @fieldParentPtr("spare", kept);
    const fresh = try gpa.create(GzipSpare);
    // Never `Compress.init`, and never a copy of a started one: `reset`
    // writes every field the compressor reads (core/deflate.zig).
    fresh.* = .{ .spare = .{ .owner = &gzip_vtable, .destroy = GzipSpare.destroySpare, .held = @sizeOf(GzipSpare) }, .z = undefined };
    return fresh;
}

fn gzipSqueeze(stash: *Stash, gpa: std.mem.Allocator, arena: std.mem.Allocator, plain: []const u8, level: Level) error{OutOfMemory}!?[]const u8 {
    const g = try gzipAcquire(stash, gpa);
    defer stash.give(&g.spare, gpa);
    // Half the input plus a little is where text lands, so the output is
    // usually one arena allocation that is never grown.
    var out = try std.Io.Writer.Allocating.initCapacity(arena, plain.len / 2 + 64);
    g.z.reset(&out.writer, gzipLevel(level)) catch return error.OutOfMemory;
    g.z.writer().writeAll(plain) catch return error.OutOfMemory;
    g.z.finish() catch return error.OutOfMemory;
    const squeezed = out.written();
    if (squeezed.len >= plain.len) return null;
    return squeezed;
}

fn gzipOpen(stash: *Stash, gpa: std.mem.Allocator, level: Level, sink: *std.Io.Writer) error{OutOfMemory}!*Spare {
    const g = try gzipAcquire(stash, gpa);
    errdefer stash.give(&g.spare, gpa);
    g.z.reset(sink, gzipLevel(level)) catch return error.OutOfMemory;
    return &g.spare;
}

fn gzipWriter(spare: *Spare) *std.Io.Writer {
    const g: *GzipSpare = @fieldParentPtr("spare", spare);
    return g.z.writer();
}

fn gzipFinish(spare: *Spare) std.Io.Writer.Error!void {
    const g: *GzipSpare = @fieldParentPtr("spare", spare);
    return g.z.finish();
}

// ---------------------------------------------------------------- zstd

/// zstd, from libzstd through `nilo_zstd` (ADR 295). **Naming it is what
/// links the library**: this constant's vtable is the only reference to
/// `nilo_zstd` in the module outside `-Dfetch_zstd`'s reading side, so a
/// program that never writes `fetch.zstd` never analyses it. The build must
/// have been given `.zstd = true`; without it importing `nilo_zstd` is a
/// compile error that names the line to write.
pub const zstd: Coding = .{ .name = "zstd", .vtable = &zstd_vtable };

const zstd_vtable: Coding.VTable = .{
    .squeeze = zstdSqueeze,
    .open = zstdOpen,
    .writer = zstdWriter,
    .finish = zstdFinish,
};

/// The window of a chunked upload, as a power of two: 256 KB. A stream's
/// memory is mostly its window (`bench/result/zstd.md`), the lines of an
/// upload repeat within a few kilobytes, and the peer's decoder holds what
/// this one declares.
const zstd_upload_window_log = 18;

const ZstdSpare = struct {
    spare: Spare,
    /// The context's memory, as large as the biggest need so far.
    mem: z.Workspace,
    /// The writer's own buffer for an upload: a few KB saves libzstd a call
    /// per small write.
    buffer: [4096]u8,
    stream: z.StreamCompressor,

    fn destroySpare(spare: *Spare, gpa: std.mem.Allocator) void {
        const self: *ZstdSpare = @fieldParentPtr("spare", spare);
        gpa.free(self.mem);
        gpa.destroy(self);
    }

    /// Make sure `mem` holds `need` bytes: the first call allocates, a larger
    /// one later replaces. Grown to a power of two so a client posting bodies
    /// of slowly growing size allocates a handful of times, not every call.
    fn room(self: *ZstdSpare, gpa: std.mem.Allocator, need: usize) error{OutOfMemory}!void {
        if (self.mem.len >= need) return;
        const size = if (need > stash_keep_max) need else std.math.ceilPowerOfTwo(usize, @max(need, 128 << 10)) catch need;
        const grown = try gpa.alignedAlloc(u8, z.workspace_alignment, size);
        gpa.free(self.mem);
        self.mem = grown;
        self.spare.held = size;
    }
};

fn zstdAcquire(stash: *Stash, gpa: std.mem.Allocator) error{OutOfMemory}!*ZstdSpare {
    if (stash.take(&zstd_vtable, gpa)) |kept| return @fieldParentPtr("spare", kept);
    const fresh = try gpa.create(ZstdSpare);
    fresh.spare = .{ .owner = &zstd_vtable, .destroy = ZstdSpare.destroySpare, .held = @sizeOf(ZstdSpare) };
    fresh.mem = &.{};
    return fresh;
}

fn zstdLevel(level: Level) i32 {
    return switch (level) {
        .fastest => 1,
        .default => 3,
        .best => 6,
        .exact => |n| std.math.clamp(n, z.level_min, z.level_max),
    };
}

fn zstdSqueeze(stash: *Stash, gpa: std.mem.Allocator, arena: std.mem.Allocator, plain: []const u8, level: Level) error{OutOfMemory}!?[]const u8 {
    const options: z.EncodeOptions = .{ .level = zstdLevel(level) };
    const need = z.Compressor.contextSize(options, plain.len);
    // Given back to the stash, which keeps it unless it grew past
    // `stash_keep_max` (a body that needs more is compressed on a context
    // made for it, and nothing of it stays behind).
    const spare = try zstdAcquire(stash, gpa);
    defer stash.give(&spare.spare, gpa);
    try spare.room(gpa, need);
    var compressor = z.Compressor.init(spare.mem[0..need], options, plain.len) catch return error.OutOfMemory;
    // The room of the body itself: a result that does not fit is a body that
    // does not shrink, which goes out as it is. The arena gives back what the
    // frame did not use, so a body that shrank to a tenth costs a tenth.
    const dst = try arena.alloc(u8, plain.len -| 1);
    const frame = compressor.compress(dst, plain) catch |err| switch (err) {
        error.NoRoom => return null,
        else => return error.OutOfMemory,
    };
    _ = arena.resize(dst, frame.len);
    return frame;
}

fn zstdOpen(stash: *Stash, gpa: std.mem.Allocator, level: Level, sink: *std.Io.Writer) error{OutOfMemory}!*Spare {
    const spare = try zstdAcquire(stash, gpa);
    errdefer stash.give(&spare.spare, gpa);
    const options: z.EncodeOptions = .{ .level = zstdLevel(level), .window_log = zstd_upload_window_log };
    try spare.room(gpa, z.StreamCompressor.contextSize(options));
    spare.stream = z.StreamCompressor.init(spare.mem, sink, &spare.buffer, options) catch return error.OutOfMemory;
    return &spare.spare;
}

fn zstdWriter(spare: *Spare) *std.Io.Writer {
    const self: *ZstdSpare = @fieldParentPtr("spare", spare);
    return &self.stream.writer;
}

fn zstdFinish(spare: *Spare) std.Io.Writer.Error!void {
    const self: *ZstdSpare = @fieldParentPtr("spare", spare);
    return self.stream.finish();
}

fn inflated(gpa: std.mem.Allocator, gzipped: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gzipped);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    return d.reader.allocRemaining(gpa, .unlimited);
}

test "a body gzipped on a kept compressor inflates to itself, call after call" {
    const gpa = std.testing.allocator;
    var stash: Stash = .{};
    defer stash.deinit(gpa);
    var made: std.Io.Writer.Allocating = .init(gpa);
    defer made.deinit();
    for (0..100) |i| try made.writer.print("{{\"line\":{d},\"text\":\"hello hello hello\"}}\n", .{i});
    const plain = made.written();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var first: ?[]const u8 = null;
    for (0..3) |_| {
        const small = (try gzip.vtable.squeeze(&stash, gpa, arena, plain, .default)).?;
        try std.testing.expect(small.len < plain.len / 4);
        if (first) |f| try std.testing.expectEqualSlices(u8, f, small) else first = small;
        const back = try inflated(gpa, small);
        defer gpa.free(back);
        try std.testing.expectEqualStrings(plain, back);
    }
    // One compressor was made and kept, not three.
    try std.testing.expect(stash.slot.load(.monotonic) != null);
}

test "a body that does not shrink is not squeezed" {
    const gpa = std.testing.allocator;
    var stash: Stash = .{};
    defer stash.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var noise: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&noise);
    try std.testing.expect((try gzip.vtable.squeeze(&stash, gpa, arena_state.allocator(), &noise, .default)) == null);
}

test "an Accept-Encoding that lists the coding is read, q=0 and silence are not" {
    try std.testing.expect(lists("gzip", "gzip"));
    try std.testing.expect(lists("br, GZIP;q=0.5", "gzip"));
    try std.testing.expect(!lists("identity", "gzip"));
    try std.testing.expect(!lists("gzip;q=0, identity", "gzip"));
    try std.testing.expect(!lists(null, "gzip"));
}

/// What the compressing path may use of a stack. Measured when this was
/// written: the path runs in 12 KB in ReleaseSafe and fails in Debug, which
/// has the largest frames, at 12 KB and passes at this size; the standard
/// library's own `init` needs 99,048 bytes before it writes a byte, so it
/// aborts on a stack of this size (ADR 062, ADR 293).
const small_stack = 48 << 10;

test "compressing a body runs on a stack too small for the compressor's own init" {
    const gpa = std.testing.allocator;
    var made: std.Io.Writer.Allocating = .init(gpa);
    defer made.deinit();
    for (0..100) |i| try made.writer.print("{{\"line\":{d},\"text\":\"hello hello hello\"}}\n", .{i});
    const plain = made.written();

    var stash: Stash = .{};
    defer stash.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const Run = struct {
        stash: *Stash,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        plain: []const u8,
        out: ?[]const u8 = null,

        fn go(self: *@This()) void {
            // Twice: the first allocates the compressor, the second reuses it.
            for (0..2) |_| {
                self.out = gzip.vtable.squeeze(self.stash, self.gpa, self.arena, self.plain, .best) catch null;
            }
        }
    };
    var run: Run = .{ .stash = &stash, .gpa = gpa, .arena = arena_state.allocator(), .plain = plain };
    const thread = try std.Thread.spawn(.{ .stack_size = small_stack }, Run.go, .{&run});
    thread.join();
    const small = run.out orelse return error.NotSqueezed;
    const back = try inflated(gpa, small);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(plain, back);
}

fn jsonBody(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var made: std.Io.Writer.Allocating = .init(gpa);
    errdefer made.deinit();
    var i: usize = 0;
    while (made.written().len < n) : (i += 1) {
        try made.writer.print("{{\"line\":{d},\"text\":\"hello {d} hello hello\"}}\n", .{ i, i % 13 });
    }
    return made.toOwnedSlice();
}

test "a body zstd'd on a kept compressor decodes to itself, call after call, at every named level" {
    const gpa = std.testing.allocator;
    var stash: Stash = .{};
    defer stash.deinit(gpa);
    const plain = try jsonBody(gpa, 6000);
    defer gpa.free(plain);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]Level{ .fastest, .default, .best, .{ .exact = 12 }, .{ .exact = -3 }, .default }) |level| {
        const small = (try zstd.vtable.squeeze(&stash, gpa, arena, plain, level)).?;
        try std.testing.expect(small.len < plain.len / 4);
        const back = try @import("testing.zig").inflateZstd(gpa, small);
        defer gpa.free(back);
        try std.testing.expectEqualStrings(plain, back);
    }
    // One compressor was made and kept, not six.
    try std.testing.expect(stash.slot.load(.monotonic) != null);
}

test "a body that does not shrink is not squeezed by zstd either" {
    const gpa = std.testing.allocator;
    var stash: Stash = .{};
    defer stash.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var noise: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&noise);
    try std.testing.expect((try zstd.vtable.squeeze(&stash, gpa, arena_state.allocator(), &noise, .default)) == null);
}

test "a compressor that grew past what a client keeps is freed with the call" {
    const gpa = std.testing.allocator;
    var stash: Stash = .{};
    defer stash.deinit(gpa);
    const plain = try jsonBody(gpa, 300 << 10);
    defer gpa.free(plain);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // Level 12 on 300 KB needs more than `stash_keep_max`.
    try std.testing.expect(z.Compressor.contextSize(.{ .level = 12 }, plain.len) > stash_keep_max);
    const small = (try zstd.vtable.squeeze(&stash, gpa, arena_state.allocator(), plain, .{ .exact = 12 })).?;
    const back = try @import("testing.zig").inflateZstd(gpa, small);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(plain, back);
    try std.testing.expect(stash.slot.load(.monotonic) == null);

    // And a level that fits is kept.
    _ = (try zstd.vtable.squeeze(&stash, gpa, arena_state.allocator(), plain, .default)).?;
    try std.testing.expect(stash.slot.load(.monotonic) != null);
}

test "compressing with zstd runs on a stack too small for a compressor context" {
    const gpa = std.testing.allocator;
    const plain = try jsonBody(gpa, 6000);
    defer gpa.free(plain);
    var stash: Stash = .{};
    defer stash.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const Run = struct {
        stash: *Stash,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        plain: []const u8,
        out: ?[]const u8 = null,

        fn go(self: *@This()) void {
            for (0..2) |_| {
                self.out = zstd.vtable.squeeze(self.stash, self.gpa, self.arena, self.plain, .default) catch null;
            }
        }
    };
    var run: Run = .{ .stash = &stash, .gpa = gpa, .arena = arena_state.allocator(), .plain = plain };
    // 48 KB, where gzip's own `init` aborts: the context is on the heap and
    // the call is a few kilobytes of frames (ADR 062, ADR 295).
    const thread = try std.Thread.spawn(.{ .stack_size = small_stack }, Run.go, .{&run});
    thread.join();
    const small = run.out orelse return error.NotSqueezed;
    const back = try @import("testing.zig").inflateZstd(gpa, small);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(plain, back);
}
