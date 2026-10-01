//! What writing a float as JSON costs, the old way against the new
//! (ADR 096).
//!
//! ```
//! taskset -c 5 zig build bench-json-float -Doptimize=ReleaseFast
//! ```
//!
//! **old** is `std.json.Stringify.value` after an `isFinite` check, which is what
//! the generated writer did for every float; **new** is `jsonfloat.write`. Both
//! write into one fixed buffer that is rewound each time, so the number is the
//! formatter and the write, with no allocation on either side. The two are run
//! round by round, interleaved, over three sets of values: the short ones a
//! response is mostly made of (`0.0`, `1.0`, `12.5`), values that need all
//! seventeen digits (a ratio, a rate), and random bit patterns, which is the
//! worst case because most of them are 17 digits with a large exponent. Each
//! prints the minimum round and the spread, in ns a float.

const std = @import("std");
const jsonfloat = @import("jsonfloat");

const per_round = 4096;
const rounds = 41;

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn writeOld(w: *std.Io.Writer, v: f64) !void {
    if (!std.math.isFinite(v)) return w.writeAll("null");
    return std.json.Stringify.value(v, .{}, w);
}

fn writeNew(w: *std.Io.Writer, v: f64) !void {
    return jsonfloat.write(w, v);
}

fn round(comptime f: fn (*std.Io.Writer, f64) anyerror!void, values: []const f64) !u64 {
    var buf: [400]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const t0 = nowNs();
    for (values) |v| {
        w.end = 0;
        try f(&w, v);
        std.mem.doNotOptimizeAway(w.end);
    }
    return nowNs() - t0;
}

fn measure(name: []const u8, values: []const f64) !void {
    var old_min: u64 = std.math.maxInt(u64);
    var old_max: u64 = 0;
    var new_min: u64 = std.math.maxInt(u64);
    var new_max: u64 = 0;
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        const o = try round(writeOld, values);
        const n = try round(writeNew, values);
        old_min = @min(old_min, o);
        old_max = @max(old_max, o);
        new_min = @min(new_min, n);
        new_max = @max(new_max, n);
    }
    const k: f64 = @floatFromInt(values.len);
    std.debug.print("{s:<12} old {d:>6.1} ns ({d:>6.1} to {d:>6.1})   new {d:>6.1} ns ({d:>6.1} to {d:>6.1})\n", .{
        name,
        @as(f64, @floatFromInt(old_min)) / k,
        @as(f64, @floatFromInt(old_min)) / k,
        @as(f64, @floatFromInt(old_max)) / k,
        @as(f64, @floatFromInt(new_min)) / k,
        @as(f64, @floatFromInt(new_min)) / k,
        @as(f64, @floatFromInt(new_max)) / k,
    });
}

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(0x0f10a7);
    const rnd = prng.random();
    var short: [per_round]f64 = undefined;
    var ratio: [per_round]f64 = undefined;
    var bits: [per_round]f64 = undefined;
    const shorts = [_]f64{ 0.0, 1.0, 12.5, 100.0, 0.25, 3.0, 42.0, 0.5 };
    for (&short, 0..) |*v, i| v.* = shorts[i % shorts.len];
    for (&ratio) |*v| v.* = rnd.float(f64);
    for (&bits) |*v| {
        while (true) {
            v.* = @bitCast(rnd.int(u64));
            if (std.math.isFinite(v.*)) break;
        }
    }
    std.debug.print("ns a float, min of {d} rounds of {d}, interleaved (spread in brackets)\n", .{ rounds, per_round });
    try measure("short", &short);
    try measure("17 digits", &ratio);
    try measure("random bits", &bits);
}
