//! The `Date` every response carries, formatted once a second rather than
//! once a response ([ADR 0269](../docs/adr/0269-a-response-says-when-it-was-sent.md)).
//!
//! RFC 9110 §6.6.1: an origin server with a clock **must** send `Date` on
//! every 2xx, 3xx and 4xx response. A cache in front — a CDN, nginx's
//! `proxy_cache`, a browser — does its `Age` and `max-age` arithmetic from
//! it, and without one falls back to the time of receipt, which the RFC calls
//! "the recipient's best guess". nilo sent none for 268 ADRs, and every other
//! server in `bench/compare/` sends one.
//!
//! **Lazily, per thread, and not from a task.** actix keeps a formatted date
//! per worker and has a timer task refresh it every 500 ms — a task per
//! thread, and a date that can be half a second stale. Here the response path
//! reads the wall clock, compares the second against the one this thread's
//! copy was formatted for, and reformats only when it has moved. Reading the
//! clock is 15 ns from the vDSO (`core/clock.zig` has the measurement);
//! the compare is one integer; the reformat happens once a second per thread
//! and costs a few hundred nanoseconds when it does. Nothing is spawned,
//! nothing is shared between threads, and there is no atomic on the path.
//!
//! **A threadlocal is right here and wrong for the fiber slot**, and the
//! difference is worth stating because `engine/zio.zig` says a threadlocal
//! cannot hold per-request state: a fiber suspends mid-handler, another runs
//! on the thread, the first wakes up somewhere else. `now()` does not suspend.
//! Between reading the clock and returning the bytes it makes a clock read,
//! a compare and at most a format into the thread's buffer — nothing that
//! touches a socket, so no other fiber can run on this thread in between, and
//! the copy the caller gets back is its own. A fiber that moves threads
//! *after* the call holds a correct date from the thread it left.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("nilo_core");

/// `Sun, 06 Nov 1994 08:49:37 GMT` is twenty-nine bytes, always: RFC 9110
/// §5.6.7's IMF-fixdate has no field that varies in width.
pub const len = 29;
pub const Text = [len]u8;

/// The whole header line, `Date: ` to CRLF: 6 + 29 + 2.
pub const line_len = "Date: ".len + len + "\r\n".len;

const Cache = struct {
    /// The second `text` was formatted for, or -1 before the first call.
    second: i64 = -1,
    text: Text = undefined,
};

threadlocal var cache: Cache = .{};

/// Under `zig test`, the second to answer with instead of the clock's, so a
/// test can expect a literal head. Null reads the clock. Not referenced
/// outside a test build, so it costs a release build nothing.
pub threadlocal var pinned: ?i64 = null;

fn second() i64 {
    if (builtin.is_test) if (pinned) |s| return s;
    return @divFloor(core.nowMicros(), std.time.us_per_s);
}

/// The current HTTP-date, copied out of this thread's cache — twenty-nine
/// bytes by value, which is what makes the threadlocal safe to hand out.
pub fn now() Text {
    const s = second();
    if (cache.second != s) {
        format(&cache.text, s);
        cache.second = s;
    }
    return cache.text;
}

/// Write the `Date` line for right now.
pub fn writeLine(out: *std.Io.Writer) !void {
    const text = now();
    try out.writeAll("Date: ");
    try out.writeAll(&text);
    try out.writeAll("\r\n");
}

const day_names = "SunMonTueWedThuFriSat";
const month_names = "JanFebMarAprMayJunJulAugSepOctNovDec";

/// `unix_seconds` as an IMF-fixdate. By hand rather than through `std.fmt`:
/// every field has a fixed width and a fixed offset, so this is nine
/// two-digit writes and three memcpys, and nothing parses a format string.
/// A negative time is written as the epoch; a clock set before 1970 is a
/// broken clock, and the header has no way to say so.
pub fn format(out: *Text, unix_seconds: i64) void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix_seconds, 0)) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();

    // 1970-01-01 was a Thursday, and Sunday is 0 in `day_names`.
    const weekday: usize = @intCast((day.day + 4) % 7);
    const month: usize = month_day.month.numeric() - 1;

    @memcpy(out[0..3], day_names[weekday * 3 ..][0..3]);
    @memcpy(out[3..5], ", ");
    twoDigits(out[5..7], month_day.day_index + 1);
    out[7] = ' ';
    @memcpy(out[8..11], month_names[month * 3 ..][0..3]);
    out[11] = ' ';
    fourDigits(out[12..16], year_day.year);
    out[16] = ' ';
    twoDigits(out[17..19], time.getHoursIntoDay());
    out[19] = ':';
    twoDigits(out[20..22], time.getMinutesIntoHour());
    out[22] = ':';
    twoDigits(out[23..25], time.getSecondsIntoMinute());
    @memcpy(out[25..29], " GMT");
}

fn twoDigits(out: *[2]u8, n: anytype) void {
    const v: u8 = @intCast(n);
    out[0] = '0' + v / 10;
    out[1] = '0' + v % 10;
}

fn fourDigits(out: *[4]u8, n: u16) void {
    // A year past 9999 has no IMF-fixdate; the clock is wrong long before
    // then, and the modulo keeps the write inside the buffer.
    const v = n % 10000;
    out[0] = '0' + @as(u8, @intCast(v / 1000));
    out[1] = '0' + @as(u8, @intCast(v / 100 % 10));
    out[2] = '0' + @as(u8, @intCast(v / 10 % 10));
    out[3] = '0' + @as(u8, @intCast(v % 10));
}

const testing = std.testing;

test "the RFC's own example formats to the RFC's own bytes" {
    // RFC 9110 §5.6.7: Sun, 06 Nov 1994 08:49:37 GMT is 784111777.
    var text: Text = undefined;
    format(&text, 784111777);
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", &text);
}

test "the epoch is a Thursday, and a leap day and a year end format correctly" {
    var text: Text = undefined;
    format(&text, 0);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &text);
    // 2024-02-29 23:59:59 UTC
    format(&text, 1709251199);
    try testing.expectEqualStrings("Thu, 29 Feb 2024 23:59:59 GMT", &text);
    // 2023-12-31 23:59:59 UTC
    format(&text, 1704067199);
    try testing.expectEqualStrings("Sun, 31 Dec 2023 23:59:59 GMT", &text);
    // 2026-09-22 00:00:00 UTC, a Tuesday.
    format(&text, 1790035200);
    try testing.expectEqualStrings("Tue, 22 Sep 2026 00:00:00 GMT", &text);
}

test "a clock set before 1970 writes the epoch rather than reading out of bounds" {
    var text: Text = undefined;
    format(&text, -1);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &text);
}

test "the cache is reformatted only when the second moves" {
    defer pinned = null;
    pinned = 784111777;
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", &now());
    // Same second: the same bytes come back, from the cache.
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", &now());
    pinned = 784111778;
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:38 GMT", &now());
}

test "the line is Date, a colon, the text and a CRLF" {
    defer pinned = null;
    pinned = 0;
    var buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try writeLine(&out);
    try testing.expectEqualStrings("Date: Thu, 01 Jan 1970 00:00:00 GMT\r\n", out.buffered());
    try testing.expectEqual(line_len, out.buffered().len);
}

test "the clock is read when nothing is pinned" {
    pinned = null;
    const text = now();
    // Whatever the year is, the shape holds: a comma at 3, `GMT` at the end.
    try testing.expectEqual(',', text[3]);
    try testing.expectEqualStrings(" GMT", text[25..29]);
    // And the year is one this code was written to see.
    try testing.expect(text[12] == '2');
}
