//! Turning one environment value into the type a Config asked for.
//!
//! The App has a converter of its own (`http/convert.zig`) and this is
//! deliberately not it. [ADR 038](../docs/adr/038-a-module-sits-where-the-loop-puts-it.md)
//! named that file "the interesting refusal" and left the question open for
//! whoever turned up as its second caller — and the answer this module gives
//! is that it is *not* that caller (ADR 039). Sharing it would mean naming
//! `nilo_core` for `Str`, and a tool module that cannot run under a plain
//! `zig test` is in the wrong layer. What is here is the same five reasons
//! against `[]const u8` instead, in forty lines.
//!
//! The wording is allowed to be its own, and that is not the oversight it
//! looks like. `http/convert.zig` keeps one copy of its sentences because a
//! handler shows a field's failure *next to* a 400 from the endpoint beside
//! it, and two spellings of one mistake is what somebody files a bug about.
//! Config is never next to anything: it is written to stderr once, before
//! the socket opens, by a process that is about to exit.

const std = @import("std");

/// Why one environment value could not become the type that was asked for.
///
/// Five, and it stays five. nilo's job stops at "this did not convert to a
/// `u16`"; whether the port is one this machine may bind is the program's
/// own question, and a reason set that grew to answer it would be a
/// validation language wearing a smaller name.
pub const Reason = enum {
    /// Nothing was set under this name, and the field has no default and is
    /// not a `?T`.
    missing,
    /// An int or a float that `std.fmt` would not read.
    not_a_number,
    not_true_or_false,
    not_a_choice,
    /// A `List` setting named more entries than the list has room for.
    /// Five, and it stays five: the capacity is part of the type the field
    /// asked for, the way the width of a `u16` is part of what a number has
    /// to fit, so this is still "did not convert" and not a rule about the
    /// value (ADR 289).
    too_many,
};

/// Whether an environment value can become a `T` at all: text, a number, a
/// `bool`, an enum or a `List`, or any of those wrapped in `?`.
///
/// Asked while compiling, by whoever is about to promise a field can be
/// filled from the environment. A field this answers false for is a Refusal
/// rather than a failure at startup. A group (`?Struct`) is not answered
/// here: it is a field of the Config, not a value of one variable (ADR 289).
pub fn convertible(comptime T: type) bool {
    const Inner = unwrap(T);
    return isScalar(Inner) or isList(Inner);
}

/// Text, a number, a `bool` or an enum: what one variable, or one entry of a
/// list, can be.
pub fn isScalar(comptime T: type) bool {
    if (T == []const u8) return true;
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

/// One setting that is several values, read from one variable with commas
/// between them (ADR 289).
///
/// ```zig
/// const Settings = struct {
///     allowed_origins: config.List([]const u8, 8),
///     broker_ports: config.List(u16, 4) = .of(&.{9092}),
/// };
/// // ALLOWED_ORIGINS=https://a.com, https://b.com  ->  .items() is two entries
/// ```
///
/// **The capacity is part of the type, and that is how it stays allocation
/// free.** `max` entries live in the struct itself, beside a length, so a
/// whole reading is still one value the caller already holds. More entries
/// than that is a failure naming the variable and the capacity, never a list
/// quietly missing its last entry (the rule `cors.Origins.setSplit` already
/// keeps).
///
/// Entries are trimmed of spaces, tabs and line ends, and an empty one is
/// skipped, so `a,,b,` is two. Text entries point into the source text, the
/// lifetime a `[]const u8` field already has. Each entry is read by the rule
/// of its own type, so a bad one is named by its position.
///
/// `items` takes a pointer, because the slice it returns points into the
/// struct: read it from the Config you keep, never from a copy that goes out
/// of scope.
pub fn List(comptime T: type, comptime max: usize) type {
    comptime {
        if (max == 0) @compileError(
            "nilo: `config.List(" ++ @typeName(T) ++ ", 0)` has room for no entries, " ++
                "so it could never hold what it was read from.",
        );
        if (!isScalar(T)) @compileError(
            "nilo: `config.List(" ++ @typeName(T) ++ ", " ++ std.fmt.comptimePrint("{d}", .{max}) ++
                ")` holds " ++ @typeName(T) ++ ", which is not something one entry of a variable can become.\n" ++
                "  An entry is text, a number, a bool or an enum.",
        );
    }
    return struct {
        const Self = @This();

        pub const Item = T;
        pub const capacity = max;

        buf: [max]T = undefined,
        len: usize = 0,

        /// The entries that were read, in order.
        pub fn items(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        /// A list written out where it is declared, for a default:
        /// `.of(&.{ "a", "b" })`. More entries than the capacity is a
        /// compile error.
        pub fn of(comptime entries: []const T) Self {
            comptime {
                if (entries.len > max) @compileError(
                    "nilo: a default of " ++ std.fmt.comptimePrint("{d}", .{entries.len}) ++
                        " entries does not fit a `config.List` with room for " ++
                        std.fmt.comptimePrint("{d}", .{max}) ++ ".",
                );
                var out: Self = .{};
                for (entries, 0..) |e, i| out.buf[i] = e;
                out.len = entries.len;
                return out;
            }
        }
    };
}

/// Whether `T` is a `List(Item, capacity)`.
pub fn isList(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "Item") or !@hasDecl(T, "capacity")) return false;
    return T == List(T.Item, T.capacity);
}

/// What went wrong with a `List`, and where.
pub const Fault = struct {
    reason: Reason,
    /// For a bad entry, its position, counting from 1 and counting only
    /// entries that are not empty. For `too_many`, how many there were.
    entry: usize,
};

/// Split `text` into `out`: null when it worked, the fault when it did not.
/// A bad entry wins over too many, being the more specific of the two.
pub fn tryList(comptime L: type, text: []const u8, out: *L) ?Fault {
    var n: usize = 0;
    var bad: ?Fault = null;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, entry_trim);
        if (entry.len == 0) continue;
        n += 1;
        if (n > L.capacity or bad != null) continue;
        var item: L.Item = undefined;
        if (tryConvert(L.Item, entry, &item)) |reason| {
            bad = .{ .reason = reason, .entry = n };
        } else {
            out.buf[n - 1] = item;
        }
    }
    if (bad) |b| return b;
    if (n > L.capacity) return .{ .reason = .too_many, .entry = n };
    out.len = n;
    return null;
}

/// The nth entry (from 1) of a list's text, as `tryList` saw it.
pub fn nthEntry(text: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, entry_trim);
        if (entry.len == 0) continue;
        i += 1;
        if (i == n) return entry;
    }
    return "";
}

const entry_trim = " \t\r\n";

/// Whether a value says anything: a variable set to nothing but spaces is
/// set, and still switches no group on (ADR 289).
pub fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, entry_trim).len == 0;
}

/// Turn one environment value into the type the Config asked for: null when
/// it worked and `out` holds the value, a Reason when it did not.
///
/// The reason comes back through the return value and the value through a
/// pointer rather than the other way round, because that is what makes a
/// struct's worth of outcomes one `[N]?Reason` array. A union carrying each
/// field's own type would need a different shape per field, which is exactly
/// what a Read cannot hold.
pub fn tryConvert(comptime P: type, text: []const u8, out: *P) ?Reason {
    if (P == []const u8) {
        out.* = text;
        return null;
    }

    switch (@typeInfo(P)) {
        .int => out.* = std.fmt.parseInt(P, text, 10) catch return .not_a_number,
        .float => out.* = std.fmt.parseFloat(P, text) catch return .not_a_number,
        .bool => out.* = boolFrom(text) orelse return .not_true_or_false,
        .@"enum" => out.* = std.meta.stringToEnum(P, text) orelse return .not_a_choice,
        else => comptime unreachable,
    }
    return null;
}

/// What a `P` would have taken, in the words the messages use.
///
/// Built once while compiling and stored in the table `Read` carries, so
/// that reporting a failure reads a string rather than walking the type
/// again. It is also the whole of what the message needs beyond the name and
/// the text that arrived, which is why there is no per-type function pointer
/// here the way there is in `http/bound.zig`.
pub fn expectedOf(comptime T: type) []const u8 {
    const P = comptime unwrap(T);
    if (comptime isList(P)) return expectedOf(P.Item);
    if (P == []const u8) return "text";
    return switch (@typeInfo(P)) {
        .int => "a whole number",
        .float => "a number",
        .bool => "true or false",
        .@"enum" => "one of " ++ enumChoices(P),
        else => comptime unreachable,
    };
}

/// The type inside a `?T`, or `T` itself.
pub fn unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn boolFrom(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

/// How many backwards branches a comptime loop over a type's fields may take,
/// sized off the input: a fixed number per field, one per byte of every name
/// (a byte at a time is how names get upper-cased, compared and joined), and a
/// floor. `names` is a struct's or an enum's `field_names`.
///
/// Called by every comptime loop in this module that walks user fields or
/// their names, because a quota raised in a callee raises the caller's whole
/// evaluation and the default 1000 ran out at about 330 characters of field
/// names (ADR 126). The factors are deliberately generous: the cost of too
/// many is nothing, and the cost of too few is a message from inside nilo.
pub fn budget(comptime names: []const [:0]const u8) u32 {
    comptime {
        // Adding the sizes up is itself a loop over the fields.
        @setEvalBranchQuota(1000 + 2 * names.len);
        var n: u32 = 2000;
        for (names) |name| n += 100 + 20 * @as(u32, @intCast(name.len));
        return n;
    }
}

/// The names an enum's values answer to, for the message that says what was
/// expected. Built once at compile time.
pub fn enumChoices(comptime E: type) []const u8 {
    comptime {
        const names = @typeInfo(E).@"enum".field_names;
        @setEvalBranchQuota(budget(names));
        var out: []const u8 = "";
        for (names, 0..) |name, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ name;
        }
        return out;
    }
}

const testing = std.testing;

test "the types an environment value can become" {
    try testing.expect(convertible([]const u8));
    try testing.expect(convertible(u16));
    try testing.expect(convertible(f64));
    try testing.expect(convertible(bool));
    try testing.expect(convertible(enum { a, b }));
    try testing.expect(convertible(?u16));
    try testing.expect(convertible(?[]const u8));

    try testing.expect(!convertible([]const []const u8));
    try testing.expect(!convertible(struct { a: u32 }));
    try testing.expect(!convertible([4]u8));
}

test "text that fits becomes the value" {
    var port: u16 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(u16, "8080", &port));
    try testing.expectEqual(@as(u16, 8080), port);

    var ratio: f64 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(f64, "1.5", &ratio));
    try testing.expectEqual(@as(f64, 1.5), ratio);

    var on: bool = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(bool, "true", &on));
    try testing.expectEqual(true, on);

    var url: []const u8 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert([]const u8, "postgres://", &url));
    try testing.expectEqualStrings("postgres://", url);

    const Level = enum { debug, info, warn };
    var level: Level = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(Level, "warn", &level));
    try testing.expectEqual(Level.warn, level);
}

test "text that does not fit says why, and leaves failing to the caller" {
    var port: u16 = undefined;
    try testing.expectEqual(Reason.not_a_number, tryConvert(u16, "soon", &port).?);
    // In range for the text and out of range for the type is the same
    // answer: `std.fmt` would not read it into a `u16`.
    try testing.expectEqual(Reason.not_a_number, tryConvert(u16, "70000", &port).?);

    var on: bool = undefined;
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, "yes", &on).?);
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, "1", &on).?);

    const Level = enum { debug, info, warn };
    var level: Level = undefined;
    try testing.expectEqual(Reason.not_a_choice, tryConvert(Level, "verbose", &level).?);

    // Text is text, so there is nothing that can fail — including the empty
    // string, which is what `PORT=` in a shell actually sets.
    var url: []const u8 = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert([]const u8, "", &url));
    try testing.expectEqualStrings("", url);
}

test "an empty value is not a missing one" {
    // `DATABASE_URL=` is set. Only a name nothing was set under is missing,
    // and that answer is `Read`'s to give rather than this file's — which is
    // why `.missing` is in the Reason set and never returned here.
    var port: u16 = undefined;
    try testing.expectEqual(Reason.not_a_number, tryConvert(u16, "", &port).?);
}

test "what a field would have taken is settled while compiling" {
    try testing.expectEqualStrings("text", comptime expectedOf([]const u8));
    try testing.expectEqualStrings("a whole number", comptime expectedOf(u16));
    try testing.expectEqualStrings("a number", comptime expectedOf(f64));
    try testing.expectEqualStrings("true or false", comptime expectedOf(bool));
    try testing.expectEqualStrings(
        "one of debug, info, warn",
        comptime expectedOf(enum { debug, info, warn }),
    );

    // An optional is worded as the thing inside it: `?u16` not being set is
    // not a failure at all, so the only sentence it can need is the one
    // about text that would not convert.
    try testing.expectEqualStrings("a whole number", comptime expectedOf(?u16));
}

test "the choices an enum offers are listed in order" {
    try testing.expectEqualStrings("red, green, blue", comptime enumChoices(enum { red, green, blue }));
}

const ManyValues = blk: {
    @setEvalBranchQuota(1_000_000);
    var names: [1200][:0]const u8 = undefined;
    var values: [1200]u16 = undefined;
    for (&names, &values, 0..) |*n, *v, i| {
        n.* = std.fmt.comptimePrint("a_value_{d}", .{i});
        v.* = i;
    }
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

test "an enum of 1200 values lists them all without a quota of the caller's" {
    const text = comptime enumChoices(ManyValues);
    try testing.expect(std.mem.startsWith(u8, text, "a_value_0, "));
    try testing.expect(std.mem.endsWith(u8, text, "a_value_1199"));
}

test "a list is its entries, trimmed, with the empty ones skipped" {
    const L = List([]const u8, 4);
    var l: L = .{};
    try testing.expectEqual(@as(?Fault, null), tryList(L, " a , b,, c ,", &l));
    try testing.expectEqual(@as(usize, 3), l.items().len);
    try testing.expectEqualStrings("a", l.items()[0]);
    try testing.expectEqualStrings("c", l.items()[2]);

    var none: L = .{};
    try testing.expectEqual(@as(?Fault, null), tryList(L, " , ,", &none));
    try testing.expectEqual(@as(usize, 0), none.items().len);
}

test "each entry is read by the rule of its own type and named by its position" {
    const L = List(u16, 4);
    var l: L = .{};
    try testing.expectEqual(@as(?Fault, null), tryList(L, "9092,9093", &l));
    try testing.expectEqualSlices(u16, &.{ 9092, 9093 }, l.items());

    const bad = tryList(L, "9092,,soon,70000", &l).?;
    try testing.expectEqual(Reason.not_a_number, bad.reason);
    try testing.expectEqual(@as(usize, 2), bad.entry);
    try testing.expectEqualStrings("soon", nthEntry("9092,,soon,70000", bad.entry));

    const Level = enum { debug, info };
    var levels: List(Level, 2) = .{};
    try testing.expectEqual(Reason.not_a_choice, tryList(@TypeOf(levels), "debug,loud", &levels).?.reason);
}

test "more entries than the capacity is too many, with how many there were" {
    const L = List([]const u8, 2);
    var l: L = .{};
    const f = tryList(L, "a,b,c,d", &l).?;
    try testing.expectEqual(Reason.too_many, f.reason);
    try testing.expectEqual(@as(usize, 4), f.entry);
    // Exactly full is fine.
    try testing.expectEqual(@as(?Fault, null), tryList(L, "a,b", &l));
}

test "a list default is written as a list literal" {
    const L = List([]const u8, 3);
    const d = comptime L.of(&.{ "x", "y" });
    try testing.expectEqual(@as(usize, 2), d.items().len);
    try testing.expectEqualStrings("y", d.items()[1]);
}

test "what is a list is known" {
    try testing.expect(isList(List(u8, 2)));
    try testing.expect(!isList(struct { a: u8 }));
    try testing.expect(!isList(u8));
    try testing.expect(convertible(List(bool, 2)));
    try testing.expect(convertible(?List(bool, 2)));
    try testing.expectEqualStrings("a whole number", comptime expectedOf(List(u8, 2)));
}
