//! What validating a string as UTF-8 costs, `std.unicode.utf8ValidateSlice`
//! against `http/utf8.zig` (ADR 096). This is the table in `bench/result/http.md`
//! under "What validating a string as UTF-8 costs", with the new validator
//! beside the old one on every row.
//!
//! ```
//! taskset -c 0 zig build bench-utf8 -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
//! ```
//!
//! Best of 25 rounds of 200,000 calls, the two interleaved round by round, so
//! a neighbour on a shared box lands on both. The input is read through a
//! pointer the optimizer cannot see through, and the answer is consumed, so
//! the call is neither hoisted nor dropped. Run it again afterwards: one run on
//! a box with anything else on it is the figure that was 3 to 4 times too high
//! the first time this table was taken.

const std = @import("std");
const utf8 = @import("utf8");

const per_round = 200_000;
const rounds = 25;

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Row = struct { name: []const u8, text: []const u8 };

fn timeOne(comptime which: enum { old, new }, text: []const u8) f64 {
    var sink: usize = 0;
    const start = nowNs();
    for (0..per_round) |_| {
        var t = text;
        std.mem.doNotOptimizeAway(&t);
        const ok = switch (which) {
            .old => std.unicode.utf8ValidateSlice(t),
            .new => utf8.valid(t),
        };
        sink +%= @intFromBool(ok);
    }
    const took = nowNs() - start;
    std.mem.doNotOptimizeAway(sink);
    return @as(f64, @floatFromInt(took)) / per_round;
}

pub fn main() !void {
    var payload: [365]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = "abcdefghij klmnop"[i % 17];
    var short: [9]u8 = "plain txt".*;
    var one_kb: [1024]u8 = undefined;
    var halfway: [1024]u8 = undefined;
    var front: [1024]u8 = undefined;
    var all_e: [1024]u8 = undefined;
    @memset(&one_kb, 'a');
    halfway = one_kb;
    front = one_kb;
    @memcpy(halfway[512..][0..2], "\xC3\xA9");
    @memcpy(front[8..][0..2], "\xC3\xA9");
    for (0..512) |k| @memcpy(all_e[2 * k ..][0..2], "\xC3\xA9");
    var all_ja: [1023]u8 = undefined;
    for (0..341) |k| @memcpy(all_ja[3 * k ..][0..3], "\xE3\x81\x82");

    const table = [_]Row{
        .{ .name = "the primary metric's payload, all ASCII", .text = &payload },
        .{ .name = "a short field value", .text = &short },
        .{ .name = "1 KB with one e-acute halfway through", .text = &halfway },
        .{ .name = "1 KB with one e-acute near the front", .text = &front },
        .{ .name = "1 KB of nothing but e-acute", .text = &all_e },
        .{ .name = "1 KB of nothing but hiragana (3-byte)", .text = &all_ja },
    };

    std.debug.print("{s:<44} {s:>6} {s:>10} {s:>10}\n", .{ "input", "bytes", "std ns", "new ns" });
    for (table) |row| {
        var best_old: f64 = std.math.inf(f64);
        var best_new: f64 = std.math.inf(f64);
        for (0..rounds) |_| {
            best_old = @min(best_old, timeOne(.old, row.text));
            best_new = @min(best_new, timeOne(.new, row.text));
        }
        std.debug.print("{s:<44} {d:>6} {d:>10.1} {d:>10.1}\n", .{ row.name, row.text.len, best_old, best_new });
    }
}
