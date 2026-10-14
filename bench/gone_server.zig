//! What asking whether the client is there costs a request that asks
//! (ADR 287), against a control route that does the same loop around a read
//! of a field.
//!
//! - `/control/:n`: `n` times `c.overdue()` (a field read and a compare).
//! - `/peer/:n`: `n` times `c.presence()` (one `poll(2)` with `POLLRDHUP`).
//! - `/naps/:n` and `/naps-watched/:n`: `n` sleeps of 1 ms with `nilo.sleep` and with
//!   `c.sleepUnlessGone`, the mean nanoseconds a sleep took.
//! - `/plain`: answers and asks nothing, the route a program that never asks
//!   has: for instructions and allocations a request, which must not move.
//!
//! Each of the first two answers the nanoseconds a call took, measured inside
//! the handler around the loop, so the loop's own cost is the control's.
//! `bench/result/http.md` has the run. `PORT` comes from the environment.
//!
//! ```
//! zig build bench-gone-server -Dtarget=x86_64-linux-gnu
//! PORT=8802 taskset -c 2 ./zig-out/bin/nilo-bench-gone-server
//! ```

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn control(c: *nilo.Ctx, n: u32) !void {
    var sink: u32 = 0;
    const started = nowNs();
    for (0..n) |_| {
        if (c.overdue()) sink += 1;
        std.mem.doNotOptimizeAway(sink);
    }
    var buf: [32]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}\n", .{(nowNs() - started) * 1000 / n}) catch unreachable);
}

fn peer(c: *nilo.Ctx, n: u32) !void {
    var sink: u32 = 0;
    const started = nowNs();
    for (0..n) |_| {
        if (c.presence() != .here) sink += 1;
        std.mem.doNotOptimizeAway(sink);
    }
    var buf: [32]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}\n", .{(nowNs() - started) * 1000 / n}) catch unreachable);
}

/// `n` sleeps of one millisecond with `nilo.sleep`: the control for the next.
fn naps(c: *nilo.Ctx, n: u32) !void {
    const started = nowNs();
    for (0..n) |_| try nilo.sleep(1);
    var buf: [32]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}\n", .{(nowNs() - started) / n}) catch unreachable);
}

/// The same with `c.sleepUnlessGone`: the poll armed, the timer, the cancel.
fn napsWatched(c: *nilo.Ctx, n: u32) !void {
    const started = nowNs();
    for (0..n) |_| _ = try c.sleepUnlessGone(1);
    var buf: [32]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}\n", .{(nowNs() - started) / n}) catch unreachable);
}

fn plain(c: *nilo.Ctx) !void {
    try c.sendText(200, "ok\n");
}

pub fn main(init: std.process.Init) !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.get("/control/:n", control);
    try app.get("/peer/:n", peer);
    try app.get("/plain", plain);
    try app.get("/naps/:n", naps);
    try app.get("/naps-watched/:n", napsWatched);

    const port: u16 = if (init.minimal.environ.getPosix("PORT")) |text| std.fmt.parseInt(u16, text, 10) catch 8802 else 8802;
    try app.listen(.{ .port = port, .threads = 1 });
}
