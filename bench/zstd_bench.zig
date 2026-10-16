//! What zstd costs next to gzip, on the bodies `bench-compress` times
//! (ADR 295, ADR 211, ADR 248).
//!
//! ```
//! zig build bench-zstd
//! zig build bench-zstd -Dlibdeflate
//! ```
//!
//! `-Dlibdeflate` swaps the gzip column from `std.flate` to libdeflate (the
//! pool's backend, ADR 248); the zstd columns are the same code in both, so
//! the two runs also show how far the machine moved between them.
//!
//! Seven tables, the timed ones in thread CPU time (`CLOCK_THREAD_CPUTIME_ID`, which leaves
//! out the time a busy machine makes a thread wait for a core), each timed
//! for a quarter of a second or five repetitions:
//!
//! 1. compressing: gzip through `Pool.gzip` at its three levels and zstd at
//!    levels 1, 3 and 6 through `Compressor`, on the bodies of
//!    `bench/compress_bench.zig`;
//! 2. what a compressor and a decompressor are, in bytes of the caller's
//!    memory, as the module's `contextSize` functions answer;
//! 3. decoding: libzstd's one-shot and streaming decoders, and the standard
//!    library's zstd decoder, which takes either the destination as its
//!    history or a window buffer of its own;
//! 4. what each decoder holds for a frame at the RFC 9659 cap;
//! 5. a stream: context bytes and output bytes by level and window, written
//!    in 1,000-byte pieces with and without a flush after each;
//! 6. the load-time levels a static file would be compressed at;
//! 7. how much of a pooled compressor's mapping a body makes resident
//!    (`mincore` over the slot, Linux).
//!
//! Always `ReleaseFast`, like `bench-compress`: a Debug codec is a different
//! program.

const std = @import("std");
const nilo = @import("nilo_http");
const zstd = @import("nilo_zstd");

const Item = struct {
    id: u32,
    name: []const u8,
    category: []const u8,
    price: u32,
    quantity: u32,
    active: bool,
    tags: []const []const u8,
    rating: struct { score: u32, count: u32 },
    total: u64,
};

const names = [_][]const u8{ "Alpha Widget", "Beta Gadget", "Gamma Gizmo", "Delta Device", "Epsilon Engine" };
const categories = [_][]const u8{ "electronics", "home", "garden", "toys", "office" };
const tag_sets = [_][]const []const u8{ &.{ "fast", "new" }, &.{"sale"}, &.{ "popular", "bulk", "eco" } };

fn body(arena: std.mem.Allocator, count: usize, m: u32) ![]const u8 {
    const items = try arena.alloc(Item, count);
    for (items, 0..) |*it, i| {
        const price: u32 = @intCast(100 + (i * 37) % 900);
        const quantity: u32 = @intCast(1 + (i * 7) % 40);
        it.* = .{
            .id = @intCast(i + 1),
            .name = names[i % names.len],
            .category = categories[i % categories.len],
            .price = price,
            .quantity = quantity,
            .active = i % 3 != 0,
            .tags = tag_sets[i % tag_sets.len],
            .rating = .{ .score = @intCast(10 + (i * 13) % 40), .count = @intCast((i * 53) % 500) },
            .total = @as(u64, price) * quantity * m,
        };
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .items = items, .count = count }, .{}, &out.writer);
    return out.written();
}

fn cpuNanos() u64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.THREAD_CPUTIME_ID, &ts))) {
        .SUCCESS => {},
        else => |e| std.debug.panic("clock: {s}", .{@tagName(e)}),
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Microseconds one call of `f` takes on this thread, the best of three
/// runs of enough calls for a quarter of a second.
fn micros(ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) f64 {
    f(ctx);
    var rounds: usize = 1;
    // Find a repetition count that takes about 80 ms.
    while (true) {
        const t0 = cpuNanos();
        for (0..rounds) |_| f(ctx);
        if (cpuNanos() - t0 > 80_000_000 or rounds >= 1 << 20) break;
        rounds *= 2;
    }
    var best: f64 = std.math.inf(f64);
    for (0..3) |_| {
        const t0 = cpuNanos();
        for (0..rounds) |_| f(ctx);
        const per = @as(f64, @floatFromInt(cpuNanos() - t0)) / @as(f64, @floatFromInt(rounds));
        best = @min(best, per);
    }
    return best / 1000.0;
}

const GzipJob = struct {
    pool: *nilo.compress.Pool,
    arena: *std.heap.ArenaAllocator,
    plain: []const u8,
    fn run(j: GzipJob) void {
        std.mem.doNotOptimizeAway(j.pool.gzip(j.arena.allocator(), j.plain));
        _ = j.arena.reset(.retain_capacity);
    }
};

const ZstdJob = struct {
    c: *zstd.Compressor,
    dst: []u8,
    plain: []const u8,
    fn run(j: ZstdJob) void {
        std.mem.doNotOptimizeAway((j.c.compress(j.dst, j.plain) catch unreachable).len);
    }
};

const OneShotJob = struct {
    d: *zstd.Decompressor,
    dst: []u8,
    frame: []const u8,
    fn run(j: OneShotJob) void {
        std.mem.doNotOptimizeAway((j.d.decompress(j.dst, j.frame) catch unreachable).len);
    }
};

const StreamJob = struct {
    mem: zstd.Workspace,
    frame: []const u8,
    out: []u8,
    fn run(j: StreamJob) void {
        var in: std.Io.Reader = .fixed(j.frame);
        var d = zstd.StreamDecoder.init(j.mem, &in, &.{}, .{}) catch unreachable;
        var w: std.Io.Writer = .fixed(j.out);
        std.mem.doNotOptimizeAway(d.reader.streamRemaining(&w) catch unreachable);
    }
};

const StdJob = struct {
    frame: []const u8,
    out: []u8,
    /// Empty: the destination is the history. Otherwise the decoder's own.
    window: []u8,
    fn run(j: StdJob) void {
        var in: std.Io.Reader = .fixed(j.frame);
        var d: std.compress.zstd.Decompress = .init(&in, j.window, .{});
        var w: std.Io.Writer = .fixed(j.out);
        std.mem.doNotOptimizeAway(d.reader.streamRemaining(&w) catch unreachable);
    }
};

const InflateJob = struct {
    gz: []const u8,
    out: []u8,
    fn run(j: InflateJob) void {
        var in: std.Io.Reader = .fixed(j.gz);
        var d: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
        var w: std.Io.Writer = .fixed(j.out);
        std.mem.doNotOptimizeAway(d.reader.streamRemaining(&w) catch unreachable);
    }
};

/// How many bytes of `bytes` are resident, by `mincore`.
fn residentBytes(bytes: []align(std.heap.page_size_min) u8) usize {
    const page = std.heap.page_size_min;
    var vec: [4096]u8 = undefined;
    const pages = bytes.len / page;
    var resident: usize = 0;
    var done: usize = 0;
    while (done < pages) {
        const n = @min(vec.len, pages - done);
        const rc = std.os.linux.mincore(bytes.ptr + done * page, n * page, &vec);
        if (std.os.linux.errno(rc) != .SUCCESS) return 0;
        for (vec[0..n]) |v| resident += (v & 1) * page;
        done += n;
    }
    return resident;
}

const Row = struct { label: []const u8, plain: []const u8 };

fn alignedMem(gpa: std.mem.Allocator, n: usize) !zstd.Workspace {
    return gpa.alignedAlloc(u8, zstd.workspace_alignment, n);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const print = std.debug.print;

    const counts = [_]usize{ 25, 40, 50, 250, 1_000, 6_000, 24_000 };
    // Bodies: the JSON ones, then any file named on the command line, which is
    // how a body with more literals in it than JSON has (prose, a binary) is
    // tried against the same columns.
    var rows: std.ArrayList(Row) = .empty;
    for (counts) |count| {
        const plain = try body(arena, count, 5);
        try rows.append(arena, .{ .label = try std.fmt.allocPrint(arena, "{d} items", .{count}), .plain = plain });
    }
    var args: std.process.Args.Iterator = .init(init.minimal.args);
    _ = args.skip();
    while (args.next()) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);
        try rows.append(arena, .{ .label = std.fs.path.basename(path), .plain = data });
    }

    print("compressing (us a body, thread CPU time)\n", .{});
    print("{s:>8} {s:>9} | {s:>16} {s:>16} | {s:>16} {s:>16} {s:>16}\n", .{ "items", "in B", "gzip fastest", "gzip default", "zstd 1", "zstd 3", "zstd 6" });
    for (rows.items) |row| {
        const plain = row.plain;
        var cells: [5][2]f64 = undefined;
        for ([_]nilo.compress.Level{ .fastest, .default }, 0..) |level, i| {
            var pool = try nilo.compress.Pool.init(gpa, 1, .{ .level = level });
            defer pool.deinit(gpa);
            var request_arena = std.heap.ArenaAllocator.init(gpa);
            defer request_arena.deinit();
            const out_len = pool.gzip(request_arena.allocator(), plain).?.len;
            _ = request_arena.reset(.retain_capacity);
            cells[i] = .{ @floatFromInt(out_len), micros(GzipJob{ .pool = &pool, .arena = &request_arena, .plain = plain }, GzipJob.run) };
        }
        for ([_]i32{ 1, 3, 6 }, 2..) |level, i| {
            const mem = try alignedMem(gpa, zstd.Compressor.contextSize(.{ .level = level }, plain.len));
            defer gpa.free(mem);
            var c = try zstd.Compressor.init(mem, .{ .level = level }, plain.len);
            const dst = try gpa.alloc(u8, zstd.compressBound(plain.len));
            defer gpa.free(dst);
            const out_len = (try c.compress(dst, plain)).len;
            cells[i] = .{ @floatFromInt(out_len), micros(ZstdJob{ .c = &c, .dst = dst, .plain = plain }, ZstdJob.run) };
        }
        print("{s:>8} {d:>9} |", .{ row.label, plain.len });
        for (cells, 0..) |cell, i| {
            if (i == 2) print(" |", .{});
            print(" {d:>7.0} B {d:>7.1}", .{ cell[0], cell[1] });
        }
        print("\n", .{});
    }

    print("\nwhat a context is (bytes of the caller's memory)\n", .{});
    print("{s:>22} {s:>12} {s:>12} {s:>12}\n", .{ "compressor", "4 KB", "64 KB", "1 MB" });
    for ([_]i32{ 1, 3, 6, 9 }) |level| {
        print("{s:>18} {d:>3} {d:>12} {d:>12} {d:>12}\n", .{
            "one-shot level",
            level,
            zstd.Compressor.contextSize(.{ .level = level }, 4 << 10),
            zstd.Compressor.contextSize(.{ .level = level }, 64 << 10),
            zstd.Compressor.contextSize(.{ .level = level }, 1 << 20),
        });
    }
    // The context `app.static` allocates for the length of one load-time copy
    // and frees (ADR 295): level 12, the default `max_file_bytes` of 8 MB at most.
    print("{s:>22} {s:>12} {s:>12} {s:>12}\n", .{ "load copy, level 12", "64 KB", "1 MB", "8 MB" });
    print("{s:>22} {d:>12} {d:>12} {d:>12}\n", .{
        "",
        zstd.Compressor.contextSize(.{ .level = 12 }, 64 << 10),
        zstd.Compressor.contextSize(.{ .level = 12 }, 1 << 20),
        zstd.Compressor.contextSize(.{ .level = 12 }, 8 << 20),
    });
    print("{s:>22} {d:>12} {d:>12} {d:>12}\n", .{
        "  window 2^20",
        zstd.Compressor.contextSize(.{ .level = 12, .window_log = 20 }, 64 << 10),
        zstd.Compressor.contextSize(.{ .level = 12, .window_log = 20 }, 1 << 20),
        zstd.Compressor.contextSize(.{ .level = 12, .window_log = 20 }, 8 << 20),
    });
    print("{s:>22} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{ "stream, level 3, window", "2^16", "2^17", "2^19", "2^21" });
    print("{s:>22} {d:>12} {d:>12} {d:>12} {d:>12}\n", .{
        "",
        zstd.StreamCompressor.contextSize(.{ .level = 3, .window_log = 16 }),
        zstd.StreamCompressor.contextSize(.{ .level = 3, .window_log = 17 }),
        zstd.StreamCompressor.contextSize(.{ .level = 3, .window_log = 19 }),
        zstd.StreamCompressor.contextSize(.{ .level = 3, .window_log = 21 }),
    });
    print("{s:>22} {d}\n", .{ "decompressor (one-shot)", zstd.Decompressor.contextSize() });
    print("{s:>22} {d}\n", .{ "std zstd at the cap", std.compress.zstd.default_window_len + std.compress.zstd.block_size_max });
    print("{s:>22} {d}\n", .{ "stream decoder at cap", zstd.StreamDecoder.contextSize(.{}) });

    print("\ndecoding (us a body, thread CPU time)\n", .{});
    print("{s:>8} {s:>9} | {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} | {s:>12} {s:>12}\n", .{ "items", "out B", "zstd 1shot", "zstd strm", "std zstd", "std+window", "inflate", "strm ctx B", "std zstd B" });
    for (rows.items) |row| {
        const plain = row.plain;
        const cmem = try alignedMem(gpa, zstd.Compressor.contextSize(.{ .level = 3 }, plain.len));
        defer gpa.free(cmem);
        var c = try zstd.Compressor.init(cmem, .{ .level = 3 }, plain.len);
        const frame_buf = try gpa.alloc(u8, zstd.compressBound(plain.len));
        defer gpa.free(frame_buf);
        const frame = try c.compress(frame_buf, plain);

        var pool = try nilo.compress.Pool.init(gpa, 1, .{ .level = .default });
        defer pool.deinit(gpa);
        var request_arena = std.heap.ArenaAllocator.init(gpa);
        defer request_arena.deinit();
        const gz = pool.gzip(request_arena.allocator(), plain).?;

        const out = try gpa.alloc(u8, plain.len + 1);
        defer gpa.free(out);
        const dmem = try alignedMem(gpa, zstd.Decompressor.contextSize());
        defer gpa.free(dmem);
        var d = try zstd.Decompressor.init(dmem, .{});
        const strm_bytes = try zstd.StreamDecoder.sizeFrom(frame, .{});
        const smem = try alignedMem(gpa, strm_bytes);
        defer gpa.free(smem);
        const window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer gpa.free(window);

        const a = micros(OneShotJob{ .d = &d, .dst = out, .frame = frame }, OneShotJob.run);
        const b = micros(StreamJob{ .mem = smem, .frame = frame, .out = out }, StreamJob.run);
        const e = micros(StdJob{ .frame = frame, .out = out, .window = &.{} }, StdJob.run);
        const f = micros(StdJob{ .frame = frame, .out = out, .window = window }, StdJob.run);
        const g = micros(InflateJob{ .gz = gz, .out = out }, InflateJob.run);
        print("{s:>8} {d:>9} | {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1} | {d:>12} {d:>12}\n", .{ row.label, plain.len, a, b, e, f, g, strm_bytes, window.len });
    }

    const stream_body = try body(arena, 1_000, 5);
    print("\na stream of {d} bytes in 1,000-byte writes: context bytes, then output bytes without and with a flush after every write\n", .{stream_body.len});
    print("{s:>7} {s:>7} {s:>12} {s:>12} {s:>12}\n", .{ "level", "window", "context B", "plain out B", "flushed out B" });
    for ([_]i32{ 1, 3 }) |level| {
        for ([_]u5{ 15, 17, 19, 21 }) |window| {
            const o: zstd.EncodeOptions = .{ .level = level, .window_log = window };
            const mem = try alignedMem(gpa, zstd.StreamCompressor.contextSize(o));
            defer gpa.free(mem);
            var sizes: [2]usize = undefined;
            for ([_]bool{ false, true }, 0..) |flush, i| {
                var out: std.Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                var sc = try zstd.StreamCompressor.init(mem, &out.writer, &.{}, o);
                var at: usize = 0;
                while (at < stream_body.len) : (at += 1000) {
                    try sc.writer.writeAll(stream_body[at..@min(at + 1000, stream_body.len)]);
                    if (flush) try sc.writer.flush();
                }
                try sc.finish();
                sizes[i] = out.written().len;
            }
            print("{d:>7} {d:>7} {d:>12} {d:>12} {d:>12}\n", .{ level, window, mem.len, sizes[0], sizes[1] });
        }
    }

    print("\nthe levels a file compressed once at load could use (one run each, ms)\n", .{});
    print("{s:>8} {s:>9} | {s:>22} {s:>22} {s:>22} {s:>22}\n", .{ "body", "in B", "level 3", "level 9", "level 12", "level 19" });
    for (rows.items) |row| {
        if (row.plain.len < 500_000 or row.plain.len > 2_000_000) continue;
        print("{s:>8} {d:>9} |", .{ row.label, row.plain.len });
        for ([_]i32{ 3, 9, 12, 19 }) |level| {
            const mem = try alignedMem(gpa, zstd.Compressor.contextSize(.{ .level = level }, row.plain.len));
            defer gpa.free(mem);
            var c = try zstd.Compressor.init(mem, .{ .level = level }, row.plain.len);
            const dst = try gpa.alloc(u8, zstd.compressBound(row.plain.len));
            defer gpa.free(dst);
            const t0 = cpuNanos();
            const n = (try c.compress(dst, row.plain)).len;
            const ms = @as(f64, @floatFromInt(cpuNanos() - t0)) / 1e6;
            print(" {d:>10} B {d:>8.1} ms", .{ n, ms });
        }
        print("\n", .{});
    }

    // What bounding the window to 2^20 costs a file at the load level (ADR
    // 295): `app.static` does, so the context stays 13 MB for a file of any size.
    print("\nlevel 12 at load, window 2^23 (the RFC's) against 2^20 (ms)\n", .{});
    for (rows.items) |row| {
        if (row.plain.len < 1_500_000) continue;
        print("{s:>8} {d:>9} |", .{ row.label, row.plain.len });
        for ([_]u5{ 23, 20 }) |window| {
            const o: zstd.EncodeOptions = .{ .level = 12, .window_log = window };
            const mem = try alignedMem(gpa, zstd.Compressor.contextSize(o, row.plain.len));
            defer gpa.free(mem);
            var c = try zstd.Compressor.init(mem, o, row.plain.len);
            const dst = try gpa.alloc(u8, zstd.compressBound(row.plain.len));
            defer gpa.free(dst);
            const t0 = cpuNanos();
            const n = (try c.compress(dst, row.plain)).len;
            const ms = @as(f64, @floatFromInt(cpuNanos() - t0)) / 1e6;
            print(" 2^{d}: {d:>10} B {d:>8.1} ms, context {d:>10} B |", .{ window, n, ms, mem.len });
        }
        print("\n", .{});
    }

    print("\nresident bytes of one pooled compressor (its mapping kept off huge pages) after one body, level 3, max 1 MB\n", .{});
    print("{s:>9} {s:>12} {s:>12}\n", .{ "body B", "mapped B", "resident B" });
    for ([_]usize{ 4 << 10, 16 << 10, 64 << 10, 256 << 10, 1 << 20 }) |size| {
        var pool = try zstd.CompressorPool.init(gpa, 1, .{ .level = 3 }, 1 << 20);
        defer pool.deinit(gpa);
        const plain = try body(arena, size / 160 + 1, 5);
        const input = plain[0..@min(plain.len, size)];
        const c = pool.borrow(0).?;
        const dst = try gpa.alloc(u8, zstd.compressBound(input.len));
        defer gpa.free(dst);
        _ = try c.compress(dst, input);
        pool.give(c);
        print("{d:>9} {d:>12} {d:>12}\n", .{ input.len, pool.mapping.bytes.len, residentBytes(pool.mapping.bytes) });
    }
}
