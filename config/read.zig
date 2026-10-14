//! One reading of a Config, and every reason it could not be filled.
//!
//! ```zig
//! const read = config.fromEnv(Config, environ);
//! const settings = read.value() orelse {
//!     try read.report(stderr);
//!     std.process.exit(2);
//! };
//! ```
//!
//! **Every bad setting is named at once, and that is the whole feature**
//! (ADR 039). A reader that stopped at the first one costs an operator a
//! restart per mistake: fix `DATABASE_URL`, run again, discover `PORT`, run
//! again. The shape is [ADR 034](../docs/adr/034-a-binding-hands-its-failures-to-the-handler.md)'s
//! — `value() orelse` and a list of failures — pointed at startup instead of
//! at a handler, and it is the same shape on purpose: a person who has read
//! one has read the other.
//!
//! **Nothing is allocated, here or anywhere below.** `T`'s field count is
//! settled while compiling, so a whole reading is one fixed array in the
//! value the caller already holds. The environment is read where it lies:
//! `getPosix` hands back a slice of the block the operating system gave the
//! process, so a Config of `[]const u8` fields points into memory that
//! outlives every use of it and no copy is made
//! ([ADR 017](../docs/adr/017-the-trade-budget-has-four-axes.md) — this
//! module spends nothing on any of the four axes, being over before the
//! socket opens).
//!
//! **Two settings are not scalars** (ADR 289). A `config.List(T, max)` is one
//! variable with commas in it, and a `?Group` is a struct of settings that
//! is switched on when any of its variables is set. Both flatten into the
//! same table of leaves, one outcome per variable, so a failure inside a
//! group is named the way every other is, by the variable.
//!
//! **It is not a validation language.** The reasons are the five
//! `convert.zig` can produce. Whether the port is one this machine may bind
//! is the program's own question.

const std = @import("std");
const convert = @import("convert.zig");
const source_mod = @import("source.zig");

pub const Reason = convert.Reason;

/// What became of one field. Filled while reading, sized while compiling.
pub const Outcome = struct {
    /// Null when the field was filled — from the environment, from its
    /// default, or with `null` because it is a `?T` nothing was set for.
    reason: ?Reason = null,
    /// The text that was set, converted or not. Empty when nothing was set
    /// under this name at all.
    given: []const u8 = "",
    /// For a bad entry of a list, its position from 1; for `too_many`, how
    /// many entries there were. Zero for everything else.
    entry: usize = 0,
};

/// One setting that could not be read.
pub const Failure = struct {
    /// The field, spelled the way the struct spells it.
    field: []const u8,
    /// The environment variable it was looked for under, prefix and all.
    name: []const u8,
    reason: Reason,
    /// The text that was set, or empty when nothing was.
    given: []const u8,
    /// What it would have taken, in the words the messages use — "text",
    /// "a whole number", "one of debug, info, warn".
    expected: []const u8,
    /// For a bad entry of a list, its position from 1; for `too_many`, how
    /// many entries there were. Zero for a setting that is not a list.
    entry: usize = 0,
    /// How many entries a list has room for. Zero for a setting that is not
    /// a list.
    capacity: usize = 0,
    /// The prefix every variable of the group this one belongs to starts
    /// with (`SMTP_`), or empty when it is not in a group.
    group: []const u8 = "",

    /// Write nilo's own sentence for this failure.
    ///
    /// Here rather than in the caller so that a program printing its own
    /// banner around the list does not have to reproduce the wording.
    pub fn say(self: Failure, w: *std.Io.Writer) !void {
        switch (self.reason) {
            .missing => if (self.group.len == 0)
                try w.print("{s} is not set", .{self.name})
            else
                try w.print("{s} is not set, and other {s}* settings are", .{ self.name, self.group }),
            .too_many => try w.print(
                "{s} has room for {d} entries, not {d}",
                .{ self.name, self.capacity, self.entry },
            ),
            // One shape for the other three, because they differ in what
            // was expected and in nothing else — which is exactly what
            // `expected` holds. An entry of a list says where it is.
            else => if (self.entry == 0) try w.print(
                "{s} has to be {s}, not \"{s}\"",
                .{ self.name, self.expected, self.given },
            ) else try w.print(
                "{s} entry {d} has to be {s}, not \"{s}\"",
                .{ self.name, self.entry, self.expected, convert.nthEntry(self.given, self.entry) },
            ),
        }
    }
};

/// Everything about a Config that is settled while compiling: which
/// environment variable each setting is read from, and what it would have
/// taken. Built once per `(T, prefix)` rather than per reading.
///
/// One entry per *variable*: a group contributes one entry for each of its
/// fields, named `<prefix><GROUP>_<FIELD>`, in the order the struct declares
/// them (ADR 289).
pub fn Table(comptime T: type, comptime prefix: []const u8) type {
    checkPrefix(prefix);
    const info = @typeInfo(T).@"struct";

    return struct {
        pub const entries = blk: {
            @setEvalBranchQuota(quota(T));
            var t: [leafCount(T)]Entry = undefined;
            var at: usize = 0;
            for (info.field_names, info.field_types) |name, FT| {
                if (isGroup(FT)) {
                    const G = convert.unwrap(FT);
                    const group_prefix = envName(prefix, name) ++ "_";
                    for (@typeInfo(G).@"struct".field_names, @typeInfo(G).@"struct".field_types) |gname, GFT| {
                        t[at] = leaf(group_prefix, gname, GFT, name ++ "." ++ gname);
                        t[at].group = group_prefix;
                        at += 1;
                    }
                } else {
                    t[at] = leaf(prefix, name, FT, name);
                    at += 1;
                }
            }
            const frozen = t;
            break :blk frozen;
        };
    };
}

fn leaf(comptime prefix: []const u8, comptime name: []const u8, comptime FT: type, comptime path: []const u8) Entry {
    const P = convert.unwrap(FT);
    return .{
        .field = path,
        .name = envName(prefix, name),
        .expected = convert.expectedOf(FT),
        .capacity = if (convert.isList(P)) P.capacity else 0,
    };
}

pub const Entry = struct {
    /// The field, `durable.bucket` for one inside a group.
    field: []const u8,
    name: []const u8,
    expected: []const u8,
    capacity: usize = 0,
    group: []const u8 = "",
};

/// A `?Struct` field: a group of settings switched on when any of its
/// variables is set (ADR 289). A `List` is a struct too and is not one.
pub fn isGroup(comptime FT: type) bool {
    if (@typeInfo(FT) != .optional) return false;
    const C = @typeInfo(FT).optional.child;
    return @typeInfo(C) == .@"struct" and !convert.isList(C);
}

/// How many variables a Config reads: its fields, with each group counted
/// as the fields inside it.
pub fn leafCount(comptime T: type) usize {
    comptime {
        const info = @typeInfo(T).@"struct";
        @setEvalBranchQuota(1000 + 100 * info.field_names.len);
        var n: usize = 0;
        for (info.field_types) |FT| {
            n += if (isGroup(FT)) @typeInfo(convert.unwrap(FT)).@"struct".field_names.len else 1;
        }
        return n;
    }
}

/// The field of every variable, `durable.bucket` for one in a group, in the
/// order of the table.
fn paths(comptime T: type) [leafCount(T)][]const u8 {
    comptime {
        @setEvalBranchQuota(quota(T));
        var out: [leafCount(T)][]const u8 = undefined;
        var at: usize = 0;
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |name, FT| {
            if (isGroup(FT)) {
                for (@typeInfo(convert.unwrap(FT)).@"struct".field_names) |gname| {
                    out[at] = name ++ "." ++ gname;
                    at += 1;
                }
            } else {
                out[at] = name;
                at += 1;
            }
        }
        return out;
    }
}

/// The quota a comptime loop over a Config's fields and its groups' fields
/// needs: `convert.budget` of each set of names (ADR 126).
fn quota(comptime T: type) u32 {
    comptime {
        const info = @typeInfo(T).@"struct";
        @setEvalBranchQuota(1000 + 100 * info.field_names.len);
        var n: u32 = convert.budget(info.field_names);
        for (info.field_types) |FT| {
            if (isGroup(FT)) n += convert.budget(@typeInfo(convert.unwrap(FT)).@"struct".field_names);
        }
        return n;
    }
}

/// A Config filled as far as the environment allowed, and why each field
/// that is not filled is not.
///
/// One type per `T` rather than per `(T, prefix)`: the names a prefix
/// settles are comptime text either way, so the reading carries a pointer to
/// them instead of baking them into the type. That is what lets a caller
/// write `Read(Config)` without repeating the prefix they read it with.
pub fn Read(comptime T: type) type {
    // Here rather than in `fill`, because a return type is analysed before
    // the body that would have checked it — `fill(u32, …)` would otherwise
    // stop inside `@typeInfo` with a message about a union field, which is
    // exactly the kind of failure ADR 026 exists to stop being acceptable.
    checkConfig(T);
    const names = paths(T);

    return struct {
        const Self = @This();

        /// The struct the caller actually asked for.
        pub const Value = T;
        pub const Outcomes = [names.len]Outcome;

        _value: T,
        _outcomes: Outcomes,
        _entries: *const [names.len]Entry,

        pub fn from(filled: T, outcomes: Outcomes, entries: *const [names.len]Entry) Self {
            return .{ ._value = filled, ._outcomes = outcomes, ._entries = entries };
        }

        /// The Config, or null when any setting could not be read.
        ///
        /// Optional on purpose, and for the reason
        /// [ADR 034](../docs/adr/034-a-binding-hands-its-failures-to-the-handler.md)
        /// gives: a field that did not convert holds nothing worth reading,
        /// and there is deliberately no way to reach past this into a
        /// half-filled struct. A program that forgot to check would
        /// otherwise be serving on a port nobody set.
        pub fn value(self: Self) ?T {
            if (self.failed()) return null;
            return self._value;
        }

        pub fn failed(self: Self) bool {
            for (self._outcomes) |o| {
                if (o.reason != null) return true;
            }
            return false;
        }

        /// How many settings could not be read.
        pub fn failedCount(self: Self) usize {
            var n: usize = 0;
            for (self._outcomes) |o| {
                if (o.reason != null) n += 1;
            }
            return n;
        }

        /// The text that was set for one field, whether or not it
        /// converted. Empty when nothing was set under its name.
        ///
        /// The field name is checked while compiling, so a typo here is a
        /// Refusal rather than an empty string that looks like an answer.
        pub fn given(self: Self, comptime field: []const u8) []const u8 {
            return self._outcomes[comptime indexOf(field)].given;
        }

        /// The environment variable one field is read from, prefix and all.
        pub fn nameOf(self: Self, comptime field: []const u8) []const u8 {
            return self._entries[comptime indexOf(field)].name;
        }

        fn indexOf(comptime field: []const u8) usize {
            comptime {
                @setEvalBranchQuota(quota(T));
                for (names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, field)) return i;
                }
                @compileError("nilo: the Config `" ++ @typeName(T) ++
                    "` has no field `" ++ field ++ "`.");
            }
        }

        /// Walk the settings that could not be read, in the order the struct
        /// declares them.
        pub fn failures(self: *const Self) Failures {
            return .{ .read = self };
        }

        pub const Failures = struct {
            read: *const Self,
            at: usize = 0,

            pub fn next(self: *Failures) ?Failure {
                while (self.at < names.len) {
                    const i = self.at;
                    self.at += 1;
                    const reason = self.read._outcomes[i].reason orelse continue;
                    const entry = self.read._entries[i];
                    return .{
                        .field = entry.field,
                        .name = entry.name,
                        .reason = reason,
                        .given = self.read._outcomes[i].given,
                        .expected = entry.expected,
                        .entry = self.read._outcomes[i].entry,
                        .capacity = entry.capacity,
                        .group = entry.group,
                    };
                }
                return null;
            }
        };

        /// Write every failure, one per line, under a line saying how many
        /// there are. Writes nothing at all when there are none, so it is
        /// safe to call unconditionally.
        ///
        /// This is what a `main` prints before it exits, and the reason the
        /// count is on its own line is that the list is the part somebody
        /// scrolls back to: a run that fixed one of three mistakes should
        /// say three, then two, without the reader counting lines.
        pub fn report(self: Self, w: *std.Io.Writer) !void {
            const n = self.failedCount();
            if (n == 0) return;
            try w.print("{d} setting{s} could not be read from the environment:\n", .{
                n,
                if (n == 1) "" else "s",
            });
            var it = self.failures();
            while (it.next()) |f| {
                try w.writeAll("  ");
                try f.say(w);
                try w.writeAll("\n");
            }
        }
    };
}

/// Fill a `T` from anything that answers `get(name) ?[]const u8`.
///
/// The source is a comptime shape rather than an interface with a function
/// table, for the reason [ADR 038](../docs/adr/038-a-module-sits-where-the-loop-puts-it.md)
/// gives about a Scope: the check refuses an unsuitable type in a sentence
/// and generates the code a direct call generates.
pub fn fill(comptime T: type, comptime prefix: []const u8, source: anytype) Read(T) {
    source_mod.check(@TypeOf(source));
    const entries = &Table(T, prefix).entries;
    const info = @typeInfo(T).@"struct";

    var filled: T = undefined;
    var outcomes: Read(T).Outcomes = @splat(.{});

    // The unrolled loop below is analysed in the caller's evaluation, a field
    // at a time.
    comptime @setEvalBranchQuota(quota(T));
    comptime var at: usize = 0;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
        if (comptime isGroup(FT)) {
            const G = comptime convert.unwrap(FT);
            const g_info = @typeInfo(G).@"struct";
            const first = at;
            at += g_info.field_names.len;

            // On when any of its variables says something. A blank one does
            // not: `SMTP_HOST=` copied out of an example file is the usual
            // way to say "not here" (ADR 289).
            var on = false;
            inline for (0..g_info.field_names.len) |j| {
                if (source.get(entries[first + j].name)) |text| {
                    if (!convert.isBlank(text)) on = true;
                }
            }

            if (on) {
                var group: G = undefined;
                inline for (g_info.field_names, g_info.field_types, g_info.field_attrs, 0..) |gname, GFT, gattrs, j| {
                    // Inside an active group a blank variable is not set,
                    // the module's own rule for "not here" (ADR 289).
                    const found = source.get(entries[first + j].name);
                    const here: ?[]const u8 = if (found) |text| (if (convert.isBlank(text)) null else text) else null;
                    fillOne(GFT, gattrs, here, &@field(group, gname), &outcomes[first + j]);
                }
                @field(filled, name) = group;
            } else if (attrs.defaultValue(FT)) |default| {
                @field(filled, name) = default;
            } else {
                @field(filled, name) = null;
            }
        } else {
            fillOne(FT, attrs, source.get(entries[at].name), &@field(filled, name), &outcomes[at]);
            at += 1;
        }
    }

    return .from(filled, outcomes, entries);
}

/// One variable into one field.
fn fillOne(comptime FT: type, comptime attrs: anytype, found: ?[]const u8, dest: *FT, out: *Outcome) void {
    const P = comptime convert.unwrap(FT);
    if (found) |text| {
        // Kept before the conversion is tried, and kept whether or not it
        // works: what `report` quotes back is what was set, not what it
        // would have become.
        out.given = text;
        var value: P = undefined;
        const fault: ?convert.Fault = if (comptime convert.isList(P))
            convert.tryList(P, text, &value)
        else if (convert.tryConvert(P, text, &value)) |reason|
            .{ .reason = reason, .entry = 0 }
        else
            null;

        if (fault) |f| {
            out.reason = f.reason;
            out.entry = f.entry;
            // The default goes in anyway, the way `http/form.zig` does
            // it. `value()` refuses the whole struct either way, so this
            // is not a value anybody can read: it is one field fewer
            // left `undefined` in a struct that gets copied out by value.
            if (attrs.defaultValue(FT)) |default| dest.* = default;
        } else if (comptime convert.isList(P) and @typeInfo(FT) == .optional) {
            // An empty variable clears an optional list, its default
            // included (ADR 289).
            dest.* = if (value.len == 0) null else value;
        } else {
            dest.* = value;
        }
    } else if (attrs.defaultValue(FT)) |default| {
        // A default is checked before `?T` so that `?u8 = 5` answers 5
        // rather than null. Both mean "nothing was set"; only one of
        // them says what to do about it.
        dest.* = default;
    } else if (@typeInfo(FT) == .optional) {
        dest.* = null;
    } else {
        out.reason = .missing;
    }
}

/// `database_url` under the prefix `NILO_` is `NILO_DATABASE_URL`.
///
/// Upper-case and nothing else — no camelCase splitting, no `-` for `_`.
/// A rule with one step is a rule somebody can predict without reading this
/// file, and the field name is already the shape an environment variable
/// wants. What it cannot spell is a name that is not the field's own, and
/// that is a known gap rather than a decision (ADR 039).
fn envName(comptime prefix: []const u8, comptime field: []const u8) []const u8 {
    comptime {
        var upper: [field.len]u8 = undefined;
        for (field, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
        const frozen = upper;
        return prefix ++ &frozen;
    }
}

/// Refuse a Config that could never be read, while compiling.
fn checkConfig(comptime T: type) void {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: a Config is read into a struct, and " ++ @typeName(T) ++ " is not one.",
        );

        const info = @typeInfo(T).@"struct";
        @setEvalBranchQuota(convert.budget(info.field_names));
        if (info.field_names.len == 0) @compileError(
            "nilo: the Config `" ++ @typeName(T) ++
                "` has no fields, so it would read nothing.",
        );

        for (info.field_names, info.field_types) |name, FT| {
            if (isGroup(FT)) {
                checkGroup(T, name, FT);
            } else if (!convert.convertible(FT)) @compileError(
                "nilo: the field `" ++ name ++ ": " ++ @typeName(FT) ++
                    "` of the Config `" ++ @typeName(T) ++
                    "` is not something an environment variable can become.\n" ++
                    "  A setting is text, a number, a bool, an enum, a `config.List` of those, " ++
                    "or any of those wrapped in `?`.\n" ++
                    "  A group of settings is a `?` struct.",
            );
        }
        checkDistinct(T);
    }
}

/// Two settings that read one variable would each see the other's value,
/// and a plain `smtp_host` would switch the group `smtp` on. The prefix is
/// the same for both, so the names are compared without it (ADR 289).
fn checkDistinct(comptime T: type) void {
    comptime {
        const t = Table(T, "").entries;
        @setEvalBranchQuota(10000 + 200 * t.len * t.len);
        for (t, 0..) |a, i| {
            for (t[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name)) @compileError(
                    "nilo: the Config `" ++ @typeName(T) ++ "` reads `" ++ a.name ++
                        "` twice, from `" ++ a.field ++ "` and from `" ++ b.field ++ "`.",
                );
            }
        }
    }
}

/// A group is a struct of settings and nothing more: no fields would read
/// nothing, and a group inside a group has no variable name that anybody
/// could predict (ADR 289).
fn checkGroup(comptime T: type, comptime name: []const u8, comptime FT: type) void {
    comptime {
        const G = convert.unwrap(FT);
        const g = @typeInfo(G).@"struct";
        @setEvalBranchQuota(convert.budget(g.field_names));
        if (g.field_names.len == 0) @compileError(
            "nilo: the group `" ++ name ++ ": " ++ @typeName(FT) ++ "` of the Config `" ++
                @typeName(T) ++ "` has no fields, so it would read nothing.",
        );
        for (g.field_names, g.field_types) |gname, GFT| {
            if (isGroup(GFT)) @compileError(
                "nilo: the group `" ++ name ++ "` of the Config `" ++ @typeName(T) ++
                    "` holds a group `" ++ gname ++ "`, and a group does not nest.\n" ++
                    "  Put `" ++ gname ++ "` beside `" ++ name ++ "` in the Config instead.",
            );
            if (!convert.convertible(GFT)) @compileError(
                "nilo: the field `" ++ gname ++ ": " ++ @typeName(GFT) ++
                    "` of the group `" ++ name ++ "` of the Config `" ++ @typeName(T) ++
                    "` is not something an environment variable can become.",
            );
        }
    }
}

/// A prefix that no environment variable name could carry is a mistake at
/// the call rather than a lookup that silently answers nothing.
fn checkPrefix(comptime prefix: []const u8) void {
    comptime {
        for (prefix) |c| {
            if (c == '=' or c == 0) @compileError(
                "nilo: the Config prefix \"" ++ prefix ++ "\" has a `" ++ [_]u8{c} ++
                    "` in it, which no environment variable name may hold.",
            );
        }
    }
}

const testing = std.testing;

/// A source of fixed pairs — what the tests below read from, and what a
/// program that has parsed a file of its own hands over.
const Fixed = source_mod.Fixed;

const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

fn read(pairs: []const Fixed.Pair) Read(Settings) {
    return fill(Settings, "", Fixed{ .pairs = pairs });
}

test "a Config that is fully set is the struct that was asked for" {
    const r = read(&.{
        .{ "PORT", "9000" },
        .{ "DATABASE_URL", "postgres://localhost/app" },
        .{ "LOG_LEVEL", "warn" },
        .{ "WORKERS", "4" },
    });

    const settings = r.value().?;
    try testing.expectEqual(@as(u16, 9000), settings.port);
    try testing.expectEqualStrings("postgres://localhost/app", settings.database_url);
    try testing.expectEqual(.warn, settings.log_level);
    try testing.expectEqual(@as(?u8, 4), settings.workers);
}

test "a field name becomes the environment variable in upper case" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});
    try testing.expectEqualStrings("DATABASE_URL", r.nameOf("database_url"));
    try testing.expectEqualStrings("PORT", r.nameOf("port"));
}

test "a prefix goes in front of every name" {
    const r = fill(Settings, "NILO_", Fixed{ .pairs = &.{
        .{ "NILO_DATABASE_URL", "postgres://" },
    } });
    try testing.expectEqualStrings("NILO_DATABASE_URL", r.nameOf("database_url"));
    try testing.expect(!r.failed());
    // The unprefixed name is not read, which is the point of asking for one.
    const bare = fill(Settings, "NILO_", Fixed{ .pairs = &.{
        .{ "DATABASE_URL", "postgres://" },
    } });
    try testing.expect(bare.failed());
}

test "what is not set falls back to the default" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});
    const settings = r.value().?;
    try testing.expectEqual(@as(u16, 8080), settings.port);
    try testing.expectEqual(.info, settings.log_level);
    try testing.expectEqual(@as(?u8, null), settings.workers);
}

test "a setting with no default and no ? is missing when nothing is set" {
    const r = read(&.{.{ "PORT", "9000" }});
    try testing.expect(r.failed());
    try testing.expectEqual(@as(usize, 1), r.failedCount());
    try testing.expectEqual(@as(?Settings, null), r.value());

    var it = r.failures();
    const f = it.next().?;
    try testing.expectEqualStrings("database_url", f.field);
    try testing.expectEqualStrings("DATABASE_URL", f.name);
    try testing.expectEqual(Reason.missing, f.reason);
    try testing.expectEqualStrings("", f.given);
    try testing.expectEqual(@as(?Failure, null), it.next());
}

test "an optional with no default is null rather than missing" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});
    try testing.expect(!r.failed());
    try testing.expectEqual(@as(?u8, null), r.value().?.workers);
}

test "a default beats the ? when both could answer" {
    // `?u8 = 5` not being set means 5, not null: both say "nothing was
    // set", and only the default says what to do about it.
    const WithDefault = struct { workers: ?u8 = 5 };
    const r = fill(WithDefault, "", Fixed{ .pairs = &.{} });
    try testing.expectEqual(@as(?u8, 5), r.value().?.workers);
}

test "every bad setting is named at once, not just the first" {
    // The whole feature. Three mistakes, one run.
    const r = read(&.{
        .{ "PORT", "soon" },
        .{ "LOG_LEVEL", "verbose" },
    });

    try testing.expect(r.failed());
    try testing.expectEqual(@as(usize, 3), r.failedCount());

    var it = r.failures();
    const port = it.next().?;
    try testing.expectEqualStrings("PORT", port.name);
    try testing.expectEqual(Reason.not_a_number, port.reason);
    try testing.expectEqualStrings("soon", port.given);

    const url = it.next().?;
    try testing.expectEqualStrings("DATABASE_URL", url.name);
    try testing.expectEqual(Reason.missing, url.reason);

    const level = it.next().?;
    try testing.expectEqualStrings("LOG_LEVEL", level.name);
    try testing.expectEqual(Reason.not_a_choice, level.reason);
    try testing.expectEqualStrings("verbose", level.given);

    try testing.expectEqual(@as(?Failure, null), it.next());
}

test "failures are walked in the order the struct declares them" {
    const r = read(&.{ .{ "PORT", "soon" }, .{ "LOG_LEVEL", "verbose" } });
    var it = r.failures();
    try testing.expectEqualStrings("port", it.next().?.field);
    try testing.expectEqualStrings("database_url", it.next().?.field);
    try testing.expectEqualStrings("log_level", it.next().?.field);
}

test "the text that arrived is kept whether or not it converted" {
    const r = read(&.{
        .{ "PORT", "soon" },
        .{ "DATABASE_URL", "postgres://" },
    });
    try testing.expectEqualStrings("soon", r.given("port"));
    try testing.expectEqualStrings("postgres://", r.given("database_url"));
    // Nothing was set under this one at all.
    try testing.expectEqualStrings("", r.given("workers"));
}

test "the report names every setting and how many there are" {
    const r = read(&.{ .{ "PORT", "soon" }, .{ "LOG_LEVEL", "verbose" } });

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);

    try testing.expectEqualStrings(
        \\3 settings could not be read from the environment:
        \\  PORT has to be a whole number, not "soon"
        \\  DATABASE_URL is not set
        \\  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
        \\
    , buf[0..w.end]);
}

test "one bad setting is reported in the singular" {
    const r = read(&.{ .{ "DATABASE_URL", "postgres://" }, .{ "PORT", "soon" } });

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);

    try testing.expectEqualStrings(
        \\1 setting could not be read from the environment:
        \\  PORT has to be a whole number, not "soon"
        \\
    , buf[0..w.end]);
}

test "a reading with nothing wrong reports nothing at all" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);
    try testing.expectEqual(@as(usize, 0), w.end);
}

test "a value set to the empty string is set, and fails on its own terms" {
    // `DATABASE_URL=` in a shell sets it. Text takes it; a number does not,
    // and says so as a conversion rather than as `missing` — which is the
    // difference between "you forgot this" and "this is empty".
    const r = read(&.{ .{ "DATABASE_URL", "" }, .{ "PORT", "" } });

    var it = r.failures();
    const port = it.next().?;
    try testing.expectEqual(Reason.not_a_number, port.reason);
    // `DATABASE_URL` is not among them: empty text is still text.
    try testing.expectEqual(@as(?Failure, null), it.next());

    // And an empty value on its own reads clean.
    const only_text = read(&.{.{ "DATABASE_URL", "" }});
    try testing.expectEqualStrings("", only_text.value().?.database_url);
}

test "a message with braces in it survives being reported" {
    const r = read(&.{ .{ "DATABASE_URL", "postgres://" }, .{ "PORT", "{d}" } });

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);

    try testing.expectEqualStrings(
        \\1 setting could not be read from the environment:
        \\  PORT has to be a whole number, not "{d}"
        \\
    , buf[0..w.end]);
}

// Two programs, so the shape is not drawn from one (ADR 289). The first is
// photon's rules; the second is a mail-sending service that reads what a
// twelve-factor service reads.

const Photon = struct {
    port: u16 = 4318,
    promoted_attributes: List([]const u8, 8) = .of(&.{"service.name"}),
    retention_days: u32 = 30,
    durable: ?struct {
        endpoint: []const u8,
        bucket: []const u8,
        region: []const u8,
        access_key_id: ?[]const u8 = null,
    } = null,
    federation: ?struct {
        endpoint: []const u8,
        token: []const u8,
        mode: enum { summary, full } = .summary,
        signals: ?List(enum { traces, logs, metrics }, 3) = null,
    } = null,
};

const List = convert.List;

const Relay = struct {
    port: u16 = 8080,
    allowed_origins: List([]const u8, 4),
    kafka_brokers: List([]const u8, 3),
    kafka_ports: ?List(u16, 3) = null,
    smtp: ?struct {
        host: []const u8,
        port: u16,
        user: []const u8,
        password: []const u8,
        starttls: bool = true,
    } = null,
};

const relay_ok = [_]Fixed.Pair{
    .{ "ALLOWED_ORIGINS", "https://a.com, https://b.com" },
    .{ "KAFKA_BROKERS", "h1:9092,h2:9092" },
};

test "a list setting is one variable with commas in it" {
    const r = fill(Relay, "", Fixed{ .pairs = &relay_ok });
    const v = r.value().?;
    try testing.expectEqual(@as(usize, 2), v.allowed_origins.items().len);
    try testing.expectEqualStrings("https://b.com", v.allowed_origins.items()[1]);
    try testing.expectEqualStrings("h2:9092", v.kafka_brokers.items()[1]);
    try testing.expectEqual(@as(?List(u16, 3), null), v.kafka_ports);
    try testing.expectEqualStrings("ALLOWED_ORIGINS", r.nameOf("allowed_origins"));
}

test "a list with no variable and no default is missing, and one with a default is that default" {
    const none = fill(Relay, "", Fixed{ .pairs = &.{} });
    try testing.expectEqual(@as(usize, 2), none.failedCount());

    const p = fill(Photon, "", Fixed{ .pairs = &.{} });
    try testing.expectEqualStrings("service.name", p.value().?.promoted_attributes.items()[0]);

    const set = fill(Photon, "", Fixed{ .pairs = &.{.{ "PROMOTED_ATTRIBUTES", "a, b" }} });
    try testing.expectEqual(@as(usize, 2), set.value().?.promoted_attributes.items().len);
}

test "an empty variable is an empty list, and clears an optional one to null" {
    const empty = fill(Photon, "", Fixed{ .pairs = &.{.{ "PROMOTED_ATTRIBUTES", " , " }} });
    try testing.expectEqual(@as(usize, 0), empty.value().?.promoted_attributes.items().len);

    const fed = [_]Fixed.Pair{ .{ "FEDERATION_ENDPOINT", "https://hub" }, .{ "FEDERATION_TOKEN", "t" } };
    const some = fill(Photon, "", Fixed{ .pairs = &(fed ++ [_]Fixed.Pair{.{ "FEDERATION_SIGNALS", "traces,logs" }}) });
    try testing.expectEqual(@as(usize, 2), some.value().?.federation.?.signals.?.items().len);

    const cleared = fill(Photon, "", Fixed{ .pairs = &(fed ++ [_]Fixed.Pair{.{ "FEDERATION_SIGNALS", "" }}) });
    try testing.expect(cleared.value().?.federation.?.signals == null);
}

test "a bad entry is named by its position and too many by the capacity" {
    const r = fill(Relay, "", Fixed{ .pairs = &.{
        .{ "ALLOWED_ORIGINS", "a,b,c,d,e" },
        .{ "KAFKA_BROKERS", "h1" },
        .{ "KAFKA_PORTS", "9092,,soon" },
    } });
    try testing.expectEqual(@as(usize, 2), r.failedCount());

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);
    try testing.expectEqualStrings(
        \\2 settings could not be read from the environment:
        \\  ALLOWED_ORIGINS has room for 4 entries, not 5
        \\  KAFKA_PORTS entry 2 has to be a whole number, not "soon"
        \\
    , buf[0..w.end]);
}

test "a group is null while none of its variables is set" {
    const r = fill(Relay, "", Fixed{ .pairs = &relay_ok });
    try testing.expect(r.value().?.smtp == null);
    // A blank one is the usual way of saying "not here".
    const blank = fill(Relay, "", Fixed{ .pairs = &(relay_ok ++ [_]Fixed.Pair{.{ "SMTP_HOST", "  " }}) });
    try testing.expect(blank.value().?.smtp == null);
}

test "a group that is on needs its required fields, named in full" {
    const r = fill(Relay, "", Fixed{ .pairs = &(relay_ok ++ [_]Fixed.Pair{
        .{ "SMTP_HOST", "mail.example.com" },
        .{ "SMTP_USER", "mailer" },
    }) });
    try testing.expectEqual(@as(?Relay, null), r.value());
    try testing.expectEqual(@as(usize, 2), r.failedCount());

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);
    try testing.expectEqualStrings(
        \\2 settings could not be read from the environment:
        \\  SMTP_PORT is not set, and other SMTP_* settings are
        \\  SMTP_PASSWORD is not set, and other SMTP_* settings are
        \\
    , buf[0..w.end]);
    try testing.expectEqualStrings("SMTP_PORT", r.nameOf("smtp.port"));
}

test "a group that is on is read like a struct" {
    const r = fill(Relay, "", Fixed{ .pairs = &(relay_ok ++ [_]Fixed.Pair{
        .{ "SMTP_HOST", "mail.example.com" },
        .{ "SMTP_PORT", "587" },
        .{ "SMTP_USER", "mailer" },
        .{ "SMTP_PASSWORD", "hunter2" },
        .{ "SMTP_STARTTLS", "false" },
    }) });
    const smtp = r.value().?.smtp.?;
    try testing.expectEqual(@as(u16, 587), smtp.port);
    try testing.expectEqual(false, smtp.starttls);
    try testing.expectEqualStrings("mailer", smtp.user);
}

test "inside an active group a blank required variable is missing, not empty text" {
    const r = fill(Relay, "", Fixed{ .pairs = &(relay_ok ++ [_]Fixed.Pair{
        .{ "SMTP_HOST", "" },
        .{ "SMTP_PORT", "587" },
        .{ "SMTP_USER", "mailer" },
        .{ "SMTP_PASSWORD", "secret" },
    }) });
    try testing.expectEqual(@as(?Relay, null), r.value());
    try testing.expectEqual(@as(usize, 1), r.failedCount());
    var it = r.failures();
    try testing.expectEqual(Reason.missing, it.next().?.reason);
}

test "inside an active group a blank defaulted variable takes its default" {
    const r = fill(Relay, "", Fixed{ .pairs = &(relay_ok ++ [_]Fixed.Pair{
        .{ "SMTP_HOST", "mail.example.com" },
        .{ "SMTP_PORT", "587" },
        .{ "SMTP_USER", "mailer" },
        .{ "SMTP_PASSWORD", "secret" },
        .{ "SMTP_STARTTLS", "  " },
    }) });
    try testing.expectEqual(true, r.value().?.smtp.?.starttls);
}

test "inside an active group a blank optional variable is null" {
    const G = struct {
        mail: ?struct { host: []const u8, region: ?[]const u8 } = null,
    };
    const r = fill(G, "", Fixed{ .pairs = &.{
        .{ "MAIL_HOST", "mail.example.com" },
        .{ "MAIL_REGION", "" },
    } });
    try testing.expectEqual(@as(?[]const u8, null), r.value().?.mail.?.region);
}

test "a bad value inside a group is a failure like any other, beside the rest" {
    const r = fill(Relay, "", Fixed{ .pairs = &.{
        .{ "SMTP_HOST", "h" },
        .{ "SMTP_PORT", "soon" },
        .{ "SMTP_USER", "u" },
        .{ "SMTP_PASSWORD", "p" },
    } });
    // The two lists, and the port.
    try testing.expectEqual(@as(usize, 3), r.failedCount());
    try testing.expectEqualStrings("soon", r.given("smtp.port"));
}

test "a prefix goes in front of a group's variables too" {
    const r = fill(Relay, "APP_", Fixed{ .pairs = &.{
        .{ "APP_ALLOWED_ORIGINS", "a" },
        .{ "APP_KAFKA_BROKERS", "h" },
        .{ "APP_SMTP_HOST", "h" },
    } });
    try testing.expectEqual(@as(usize, 3), r.failedCount());
    try testing.expectEqualStrings("APP_SMTP_PORT", r.nameOf("smtp.port"));
}

test "a group's values come from the file and the environment together" {
    // photon's durable tier: the endpoint is set in the environment, the
    // bucket and region are what the file said, and the environment's own
    // value wins where both have one.
    const env = Fixed{ .pairs = &.{
        .{ "DURABLE_ENDPOINT", "https://s3.example.com" },
        .{ "DURABLE_REGION", "eu-west-1" },
    } };
    const file = Fixed{ .pairs = &.{
        .{ "DURABLE_BUCKET", "photon-prod" },
        .{ "DURABLE_REGION", "us-east-1" },
        .{ "DURABLE_ACCESS_KEY_ID", "key" },
    } };
    const r = fill(Photon, "", source_mod.layered(.{ env, file }));
    const d = r.value().?.durable.?;
    try testing.expectEqualStrings("https://s3.example.com", d.endpoint);
    try testing.expectEqualStrings("photon-prod", d.bucket);
    try testing.expectEqualStrings("eu-west-1", d.region);
    try testing.expectEqualStrings("key", d.access_key_id.?);

    // And a variable present in the file alone switches the group on.
    const alone = fill(Photon, "", source_mod.layered(.{ Fixed{ .pairs = &.{} }, file }));
    try testing.expect(alone.value() == null);
    try testing.expectEqual(@as(usize, 1), alone.failedCount());
}

test "a Config of two programs' rules reads from a .env" {
    const dotenv = @import("dotenv.zig");
    const r = fill(Relay, "", dotenv.Dotenv{ .text =
        \\ALLOWED_ORIGINS=https://a.com,https://b.com
        \\KAFKA_BROKERS="h1:9092, h2:9092"
        \\SMTP_HOST=mail
        \\SMTP_PORT=25
        \\SMTP_USER=u
        \\SMTP_PASSWORD=p
        \\
    });
    const v = r.value().?;
    try testing.expectEqual(@as(usize, 2), v.kafka_brokers.items().len);
    try testing.expectEqualStrings("h2:9092", v.kafka_brokers.items()[1]);
    try testing.expectEqual(@as(u16, 25), v.smtp.?.port);
}

test "every kind of failure is reported together" {
    // No allocator is handed in anywhere in this file, so there is nothing
    // to leak: this is one reading failing every way there is.
    const r = fill(Relay, "", Fixed{ .pairs = &.{
        .{ "PORT", "soon" },
        .{ "ALLOWED_ORIGINS", "a,b,c,d,e" },
        .{ "KAFKA_PORTS", "x" },
        .{ "SMTP_HOST", "h" },
    } });
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);
    try testing.expectEqualStrings(
        \\7 settings could not be read from the environment:
        \\  PORT has to be a whole number, not "soon"
        \\  ALLOWED_ORIGINS has room for 4 entries, not 5
        \\  KAFKA_BROKERS is not set
        \\  KAFKA_PORTS entry 1 has to be a whole number, not "x"
        \\  SMTP_PORT is not set, and other SMTP_* settings are
        \\  SMTP_USER is not set, and other SMTP_* settings are
        \\  SMTP_PASSWORD is not set, and other SMTP_* settings are
        \\
    , buf[0..w.end]);
}
