//! What a streamed upload from a file costs through `nilo_fetch`: CPU and wall
//! for one PUT of a file of N MiB to the canned server in `fetch/testing.zig`
//! (loopback, so the numbers are the client's copying and syscalls, not a
//! network). `bench/result/fetch.md`, "A streamed body from a file reader".
//!
//! ```
//! zig build-exe -O ReleaseFast -target x86_64-linux-gnu \
//!     --dep nilo_fetch -Mroot=bench/fetch_upload.zig \
//!     --dep nilo_core -Mnilo_fetch=fetch/fetch.zig -Mnilo_core=core/core.zig \
//!     -femit-bin=zig-out/bin/nilo-bench-fetch-upload
//! MIB=64 RUNS=7 MODE=file ./zig-out/bin/nilo-bench-fetch-upload
//! ```
//!
//! `MODE=file` hands the call a `std.Io.File.Reader`, which before the framed
//! body writer was given a buffer was an assertion; `MODE=pump` is the
//! workaround that worked then (a reader that reads the file into its own
//! 64 KiB chunk and `writeAll`s it), kept so the two can be set side by side.
//! `MODE=fixed` sends the same bytes from memory, which is what the tests of
//! `putStream` did, as the floor. The canned server shares the process, so
//! its read side is in every figure and is the same in all three.

const std = @import("std");
const fetch = @import("nilo_fetch");

const Pump = struct {
    file: *std.Io.File.Reader,
    chunk: [64 << 10]u8 = undefined,
    reader: std.Io.Reader,

    fn init(file: *std.Io.File.Reader) Pump {
        return .{ .file = file, .reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Pump = @alignCast(@fieldParentPtr("reader", r));
        const want = limit.minInt(self.chunk.len);
        const n = try self.file.interface.readSliceShort(self.chunk[0..want]);
        if (n == 0) return error.EndOfStream;
        try w.writeAll(self.chunk[0..n]);
        return n;
    }
};

fn cpuSeconds() f64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.PROCESS_CPUTIME_ID, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

fn wallSeconds() f64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    const env = init.environ_map;
    const mib = std.fmt.parseInt(usize, env.get("MIB") orelse "64", 10) catch 64;
    const runs = std.fmt.parseInt(usize, env.get("RUNS") orelse "5", 10) catch 5;
    const mode = env.get("MODE") orelse "file";
    const stall = std.fmt.parseInt(u32, env.get("STALL_MS") orelse "0", 10) catch 0;
    const size = mib << 20;

    const path = "bench-upload.bin";
    {
        const data = try gpa.alloc(u8, size);
        defer gpa.free(data);
        for (data, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const in_memory = if (std.mem.eql(u8, mode, "fixed")) try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) else &[_]u8{};

    for (0..runs) |_| {
        var canned = try fetch.testing.Canned.open(io);
        defer canned.close();
        var served = try io.concurrent(fetch.testing.Canned.serveWithBody, .{&canned});
        defer served.cancel(io) catch {};

        var client: fetch.Client = .init(gpa, .{ .timeout_ms = 0, .stall_ms = stall });
        defer client.deinit();
        try client.nilo_start(io, .none);

        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var file_buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &file_buf);
        var pump: Pump = .init(&file_reader);
        var fixed = std.Io.Reader.fixed(in_memory);
        const source: *std.Io.Reader = if (std.mem.eql(u8, mode, "pump")) &pump.reader else if (std.mem.eql(u8, mode, "fixed")) &fixed else &file_reader.interface;

        var url_buf: [64]u8 = undefined;
        const cpu0 = cpuSeconds();
        const wall0 = wallSeconds();
        var ex: fetch.Exchange = .idle;
        defer ex.end();
        const head = try ex.begin(&client, .{
            .method = .PUT,
            .url = try canned.url(&url_buf),
            .body = .{ .stream = .{ .reader = source, .len = size } },
        });
        served.await(io) catch {};
        const cpu1 = cpuSeconds();
        const wall1 = wallSeconds();
        std.debug.print("{s} {d} MiB status_ok={} cpu={d:.3}s wall={d:.3}s\n", .{ mode, mib, head.ok(), cpu1 - cpu0, wall1 - wall0 });
    }
}
