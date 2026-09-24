//! What does one more stream cost, if a stream is a fiber of its own?
//!
//! HTTP/2 puts many requests on one connection, and nilo serves a request on
//! a fiber. So the question ADR 0297 has to answer before it can say what a
//! gRPC connection costs is what zio charges for a fiber that is parked in the
//! middle of a handler: spawn them, let each touch K bytes of stack and wait
//! on an Event, and read VmRSS before and after.
//!
//! **One cold process per K.** zio keeps a finished fiber's stack in its pool
//! with the pages still resident, so a second round in the same process
//! reuses them and reads zero. The first version of this did exactly that.
//!
//! Average over 5,000, marginal from 5,000 to 20,000, and average over
//! 20,000: when marginal meets average the figure is a cost, not a transient.
//! VmRSS is read through raw syscalls into a stack buffer, so the reading
//! allocates nothing it would then count.
//!
//! Usage: `zig build -Doptimize=ReleaseFast && K=4096 ./zig-out/bin/fiber-spike`
//! for K in 0, 1024, 2048, 4096, 8192, 16384.
const std = @import("std");
const zio = @import("zio");

var started: std.atomic.Value(usize) = .init(0);

noinline fn touch(comptime k: usize) void {
    if (k == 0) return;
    var buf: [k]u8 = undefined;
    @memset(&buf, 0xaa);
    std.mem.doNotOptimizeAway(&buf);
}

fn Stream(comptime k: usize) type {
    return struct {
        fn run(ev: *zio.Event) void {
            touch(k);
            _ = started.fetchAdd(1, .monotonic);
            ev.wait() catch {};
        }
    };
}

fn rss() !usize {
    var buf: [4096]u8 = undefined;
    const linux = std.os.linux;
    const fd: i32 = @intCast(linux.open("/proc/self/status", .{}, 0));
    defer _ = linux.close(fd);
    const n = linux.read(fd, &buf, buf.len);
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| if (std.mem.startsWith(u8, line, "VmRSS:")) {
        const v = std.mem.trim(u8, line[6..], " \tkB");
        return (try std.fmt.parseInt(usize, v, 10)) * 1024;
    };
    return error.NoRss;
}

fn cold(comptime k: usize) !void {
    var ev: zio.Event = .init;
    var g: zio.Group = .init;
    defer g.cancel();
    const n1 = 5000;
    const n2 = 20000;
    const before = try rss();
    for (0..n1) |_| try g.spawn(Stream(k).run, .{&ev});
    while (started.load(.monotonic) < n1) try zio.yield();
    const mid = try rss();
    for (n1..n2) |_| try g.spawn(Stream(k).run, .{&ev});
    while (started.load(.monotonic) < n2) try zio.yield();
    const after = try rss();
    const f = struct {
        fn per(a: usize, b: usize, n: usize) f64 {
            return @as(f64, @floatFromInt(b - a)) / @as(f64, @floatFromInt(n));
        }
    }.per;
    std.debug.print("K={d:>5}  average over {d}: {d:>7.0}  marginal to {d}: {d:>7.0}  average over {d}: {d:>7.0} bytes/fiber\n", .{ k, n1, f(before, mid, n1), n2, f(mid, after, n2 - n1), n2, f(before, after, n2) });
    ev.set();
    try g.wait();
}

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(1), .enable_task_migration = false });
    defer rt.deinit();
    const which = init.environ_map.get("K") orelse "0";
    if (std.mem.eql(u8, which, "0")) try cold(0);
    if (std.mem.eql(u8, which, "1024")) try cold(1024);
    if (std.mem.eql(u8, which, "2048")) try cold(2048);
    if (std.mem.eql(u8, which, "4096")) try cold(4096);
    if (std.mem.eql(u8, which, "8192")) try cold(8192);
    if (std.mem.eql(u8, which, "16384")) try cold(16384);
}
