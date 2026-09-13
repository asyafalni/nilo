//! A whole number inside a range, as a type
//! ([ADR 0206](../docs/adr/0206-a-whole-number-inside-a-range-is-a-type.md)).
//!
//! ```zig
//! const ListQuery = struct {
//!     limit: nilo.Within(1, 200) = .of(50),
//!     offset: u32 = 0,
//! };
//! ```
//!
//! `?limit=500` is a 400 — `?limit has to be a whole number from 1 to 200,
//! not "500"` — and the document says `minimum: 1, maximum: 200`, so a
//! client generated from it refuses the same value before sending it. Both
//! come from the type, which is the only place nilo reads a contract from.
//!
//! **A type rather than a marker, because a bound is not a validation.**
//! `convert.Reason`'s comment refuses a validation language on purpose:
//! whether an age is plausible is the application's question. But a `u8`
//! already refuses 300 and a `u32` already refuses `-1`, and nobody calls
//! either a validation — the type has a range and the text did not fit it.
//! This is that, with the range chosen rather than inherited from a width.
//! It is read everywhere a `u8` is read: a path param, a query value, a form
//! field, and a JSON body (ADR 0205), with one sentence for all four.
//!
//! **The value is read as `.value`**, which is the cost. The integer inside is
//! the narrowest that holds the range, so `Within(1, 200)` is a `u8` and
//! `Within(0, 100_000)` is a `u17`; handing it to a `LIMIT` is `q.limit.value`
//! rather than `q.limit`. Zig has no way to give a struct the arithmetic of
//! its one field, and a type that hid the wrapper would be one nilo could not
//! read a range off.
//!
//! `.of(50)` rather than `.{ .value = 50 }` for the default, because the
//! default is checked against the range while compiling — a default the
//! request could not have sent is the one value the bound would never catch.

const std = @import("std");
const convert = @import("convert.zig");
const mark = @import("jsonmark.zig");

/// A whole number from `min` to `max`, both inclusive.
pub fn Within(comptime min: comptime_int, comptime max: comptime_int) type {
    if (min > max) @compileError(std.fmt.comptimePrint(
        "nilo: `Within({d}, {d})` has its bounds the wrong way round: nothing is at least {d} and at most {d}.\n" ++
            "  The lower bound comes first: `Within({d}, {d})`.",
        .{ min, max, min, max, max, min },
    ));
    return struct {
        const Self = @This();

        /// The narrowest integer that holds the range.
        pub const Int = std.math.IntFittingRange(min, max);

        pub const lowest: Int = min;
        pub const highest: Int = max;

        /// What a nilo compile error calls this type (ADR 0122).
        pub const nilo_type_name = std.fmt.comptimePrint("nilo.Within({d}, {d})", .{ min, max });

        /// What a 400 asks for, in place of the type's name.
        pub const nilo_expects = std.fmt.comptimePrint("a whole number from {d} to {d}", .{ min, max });

        /// The bounds, for the document to say (`openapi.zig` reads it by
        /// name).
        pub const nilo_within = .{ .min = min, .max = max };

        /// A number on the wire, and said so, so that a response carrying
        /// one is written by nilo's own writer around it (ADR 0182).
        pub const nilo_openapi = .{ .type = "integer" };

        value: Int,

        /// A value known while compiling — the default a field falls back
        /// to — checked against the range here rather than never.
        pub fn of(comptime n: comptime_int) Self {
            if (n < min or n > max) @compileError(std.fmt.comptimePrint(
                "nilo: `Within({d}, {d}).of({d})` is outside its own range.\n" ++
                    "  A default is the one value a request never sends, so it is the one " ++
                    "the bound would never catch — which is why it is checked here.",
                .{ min, max, n },
            ));
            return .{ .value = n };
        }

        /// The digits, read the way a `u32` is read from request text —
        /// `+7` and `1_0` are not numbers here either — and refused outside
        /// the range with the same null a bad number gets (ADR 0142).
        pub fn nilo_parse(text: []const u8) ?Self {
            if (!convert.spelledAsNumber(text, min < 0, false)) return null;
            const n = std.fmt.parseInt(i128, text, 10) catch return null;
            if (n < min or n > max) return null;
            return .{ .value = @intCast(n) };
        }

        /// The third arrival, a JSON body: the same digits, as a number or
        /// as text (ADR 0205).
        pub const jsonParse = mark.parseFor(Self);

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.write(self.value);
        }
    };
}

// ---- tests ----

const testing = std.testing;

test "the range decides the integer, and a value inside it is the number" {
    const Page = Within(1, 200);
    try testing.expectEqual(u8, Page.Int);
    try testing.expectEqual(u17, Within(0, 100_000).Int);
    try testing.expectEqual(i4, Within(-5, 5).Int);

    try testing.expectEqual(@as(u8, 50), Page.nilo_parse("50").?.value);
    try testing.expectEqual(@as(u8, 1), Page.nilo_parse("1").?.value);
    try testing.expectEqual(@as(u8, 200), Page.nilo_parse("200").?.value);
    try testing.expectEqual(@as(u8, 50), Page.of(50).value);
}

test "outside the range is null, and so is anything that is not the digits" {
    const Page = Within(1, 200);
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("0"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("201"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("-1"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("+7"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("1_0"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("fifty"));
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse(""));
    // Far past any width, which `parseInt` would refuse on its own — the
    // answer is the same null rather than an error nilo has no word for.
    try testing.expectEqual(@as(?Page, null), Page.nilo_parse("99999999999999999999999999999999999999999"));

    // A signed range reads a minus sign, because the range has one.
    const Delta = Within(-5, 5);
    try testing.expectEqual(@as(i4, -3), Delta.nilo_parse("-3").?.value);
    try testing.expectEqual(@as(?Delta, null), Delta.nilo_parse("-6"));
}

test "what a 400 asks for names the range, and the type names itself" {
    try testing.expectEqualStrings("a whole number from 1 to 200", Within(1, 200).nilo_expects);
    try testing.expectEqualStrings("nilo.Within(1, 200)", Within(1, 200).nilo_type_name);
    try testing.expectEqual(@as(comptime_int, 1), Within(1, 200).nilo_within.min);
    try testing.expectEqual(@as(comptime_int, 200), Within(1, 200).nilo_within.max);
}

test "in a JSON body it is the number, in and out" {
    const Page = Within(1, 200);
    const Body = struct { limit: Page = .of(50) };

    const parsed = try std.json.parseFromSlice(Body, testing.allocator, "{\"limit\":20}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 20), parsed.value.limit.value);

    const absent = try std.json.parseFromSlice(Body, testing.allocator, "{}", .{});
    defer absent.deinit();
    try testing.expectEqual(@as(u8, 50), absent.value.limit.value);

    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Body, testing.allocator, "{\"limit\":500}", .{}));
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Body, testing.allocator, "{\"limit\":true}", .{}));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Body{ .limit = .of(7) }, .{}, &out.writer);
    try testing.expectEqualStrings("{\"limit\":7}", out.written());
}
