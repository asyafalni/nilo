//! What a Row says about the **table** rather than about a query
//! ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! `row.zig` answers what a `SELECT` needs: the name, the key, the column
//! list. That is not enough to create anything. A table also has a unique
//! constraint, an index and a foreign key, and none of the three can be
//! derived from a struct.
//!
//! So the marker grows, and the bar every word in it has to pass is **the
//! compiler can check it**:
//!
//! ```zig
//! pub const nilo_table = .{
//!     .name = "users",
//!     .key = .id,
//!     .default = .{ .created_at = .now, .state = .draft, .seats = 1 },
//!     .unique = .{
//!         .{ .columns = .{.email}, .ignoring_case = true,
//!            .name = "users_one_account_per_address" },
//!     },
//!     .index = .{
//!         .{ .tenant_id, .created_at },
//!         .{ .columns = .{ .tenant_id, .{ .created_at = .desc } },
//!            .where = .{ .deleted_at = null } },
//!     },
//!     .references = .{ .org_id = .{ Org, .id, .cascade } },
//! };
//! ```
//!
//! `.unique` and `.index` are checked against the Row's own columns, and so is
//! a partial index's `.where` — it is the where walker's own grammar rather
//! than a string, so a column that is not one is a Refusal and a literal that
//! is not the column's type does not compile. `.default` takes `.now` on a
//! `sql.Timestamp` and a literal of the column's own type, and nothing wider:
//! `DEFAULT (lower(x))` is a step. A column the Row reads as a Zig enum
//! carries its words into `CHECK ("col" IN (…))` unless the enum names a
//! database type of its own, which is then the database's to grow. Every name
//! is checked at 63 bytes whatever the Dialect is, because Postgres cuts a
//! longer one down in a `NOTICE` nothing reads.
//!
//! `.references` is checked hardest, and it is the reason the words are worth
//! having at all: `Org` has to be a Row, `.id` has to be one of its columns,
//! **and `org_id`'s Zig type has to be the same as `Org.id`'s**. A foreign key
//! whose two sides do not line up is a bug that arrives at the first insert in
//! production, and here it does not compile. `.set_null` on a column that is
//! not optional is refused for the same reason.
//!
//! **A check constraint written by hand, a trigger, a collation, a generated
//! column and a view are all absent, and none of them is a gap here.** Each is
//! a text the database reads. A diff can own a *named* text — same name and
//! same hash, nothing to do; new hash, replace; name gone, drop — so `.check`
//! and `.trigger` are a second kind of word rather than a refusal, and the
//! list of object kinds whose replace is mechanical is what closes that kind.
//! That is its own decision and is not made here
//! ([ADR 0221](../docs/adr/0221-the-marker-has-two-kinds-of-word.md)). Until
//! it is, those go in a step as SQL, and the snapshot marks them as objects
//! nilo does not own so that a diff never tries to drop one.
//!
//! **Nothing in this file allocates, and none of it is reachable from a
//! request.** A `Desc` is a comptime value, so the whole description of a table
//! is in `.rodata` before the program runs, which is the same property
//! `statement.zig` has and for the same reason.

const std = @import("std");
const core = @import("nilo_core");
const row_mod = @import("row.zig");
const types_mod = @import("types.zig");

/// The longest identifier Postgres keeps, in bytes.
///
/// **Checked whatever the Dialect is**, and that is the decision rather than an
/// oversight: SQLite has no limit, and a schema that compiles for one database
/// and silently loses a constraint name on the other is the opposite of what one
/// type describing both is for. Sixty-three is the stricter of the two, so a
/// name that passes here works everywhere.
pub const max_identifier = 63;

/// What happens to a referencing row when the row it points at is deleted.
///
/// Four, and they are the four the standard has that mean something different.
/// `SET DEFAULT` is left out, and the reason moved when `.default` arrived
/// (ADR 0221): the marker can express the default now, and what it cannot
/// express is the part that matters, which is that the default has to be a row
/// that exists over there. A default naming a row nobody kept turns the delete
/// it was meant to survive into a foreign-key violation. Nobody has brought a
/// case, so it stays out.
pub const OnDelete = enum {
    /// No clause at all, which is the database's own default. Deleting a
    /// referenced row fails while anything points at it.
    no_action,
    cascade,
    restrict,
    /// Only on a column that is optional, and refused otherwise. The database
    /// would refuse it too, at the moment of the delete rather than at the
    /// moment somebody wrote it.
    set_null,

    pub fn clause(self: OnDelete) []const u8 {
        return switch (self) {
            .no_action => "",
            .cascade => " ON DELETE CASCADE",
            .restrict => " ON DELETE RESTRICT",
            .set_null => " ON DELETE SET NULL",
        };
    }
};

pub const Column = struct {
    name: []const u8,
    /// What this Dialect would write for the column, which is the first entry
    /// of `accepts` and therefore the type the startup check expects.
    sql_type: []const u8,
    nullable: bool = false,
    /// Whether `.key` names this column. True of several columns when the key
    /// spans several, which is what a join table and a multi-tenant table both
    /// are.
    key: bool = false,
    /// The database makes the value. True for an integer key of one column and
    /// nothing else — see `generatedKey`.
    generated: bool = false,
    /// What the database writes when an insert leaves this column out, as the
    /// Dialect spells it: `now()`, `'draft'`, `0`. Null when the marker said
    /// nothing, and then the database's own answer is null.
    ///
    /// **The rendered text rather than the value**, which is the arrangement
    /// `sql_type` already has one field up. A `Desc` is dialect-specific and
    /// the snapshot records which Dialect it was written against, so one
    /// string is both what the `CREATE` writes and what the diff compares —
    /// and two of those cannot fall out of step. The checking happens before
    /// the rendering: a literal that is not the column's own Zig type does not
    /// compile ([ADR 0221](../docs/adr/0221-the-marker-has-two-kinds-of-word.md)).
    default: ?[]const u8 = null,
    /// The words this column may hold, when the Row reads it as a Zig enum
    /// that has not said which database type it is. Empty for every other
    /// column.
    ///
    /// They become `CHECK ("col" IN (…))`, named `<table>_<col>_check`, and
    /// they are in the snapshot so that adding a word to the enum is a
    /// migration rather than an insert the database refuses.
    values: []const []const u8 = &.{},

    /// Whether two columns describe the same thing. The name is matched by the
    /// caller, so this is the part that decides whether an `ALTER` is needed.
    pub fn sameAs(self: Column, other: Column) bool {
        return std.mem.eql(u8, self.sql_type, other.sql_type) and
            self.nullable == other.nullable and
            self.key == other.key and
            self.generated == other.generated and
            sameOptionalText(self.default, other.default) and
            sameColumns(self.values, other.values);
    }
};

pub const Unique = struct {
    name: []const u8,
    columns: []const []const u8,
    /// Compared without regard to case, which the two databases reach by
    /// different mechanisms. That is the Dialect's business, not this file's.
    ignoring_case: bool = false,

    pub fn sameAs(self: Unique, other: Unique) bool {
        return self.ignoring_case == other.ignoring_case and
            sameColumns(self.columns, other.columns);
    }
};

/// Two column lists, in order. Order matters in an index: `(a, b)` and
/// `(b, a)` serve different queries, so they are two indexes rather than one
/// written twice.
pub fn sameColumns(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

pub const Index = struct {
    name: []const u8,
    columns: []const []const u8,
    /// Which of `columns` are read the other way up, by name.
    ///
    /// **A second list rather than a shape on the first**, so that a snapshot
    /// written before this field existed still parses: `std.zon` fills a
    /// missing field from its default, and an index with no `DESC` in it says
    /// nothing at all. By name rather than by position for the same reason a
    /// `.was` entry is by name — a list of `true, false, true` beside a list
    /// of columns is two things a reader has to line up.
    descending: []const []const u8 = &.{},
    /// The `WHERE` of a partial index, as the Dialect spells it, or empty for
    /// an index over the whole table.
    ///
    /// Rendered here rather than held as a shape, for the reason `Column.default`
    /// gives: the string the `CREATE INDEX` writes is the string the diff
    /// compares. What the caller wrote is checked before it is rendered — a
    /// column that is not one, or a literal that is not the column's type, does
    /// not compile.
    where: []const u8 = "",

    pub fn sameAs(self: Index, other: Index) bool {
        return sameColumns(self.columns, other.columns) and
            sameColumns(self.descending, other.descending) and
            std.mem.eql(u8, self.where, other.where);
    }
};

pub const Reference = struct {
    name: []const u8,
    /// The columns doing the pointing, in the order they were written — which
    /// is the order they line up with `targets`.
    ///
    /// **A list rather than a name, and it is not an edge case**: "an Epic has
    /// to be on the same board" is `(epic_id, department_id)` pointing at
    /// `work_epics (id, department_id)`, and a rule like that has nowhere else
    /// as cheap to live ([ADR 0222](../docs/adr/0222-a-foreign-key-is-columns-and-a-table-name.md)).
    columns: []const []const u8,
    /// The table pointed at, split the same way the Row's own name is, so that
    /// the create order is worked out by comparing two names rather than by
    /// parsing one.
    ///
    /// Written from the target Row when the marker named a type, and from the
    /// text when it named the table — the two spellings answer here the same
    /// way, which is what keeps everything downstream of this field the same.
    schema: ?[]const u8 = null,
    table: []const u8,
    /// The columns pointed at, one for each of `columns`.
    targets: []const []const u8,
    on_delete: OnDelete = .no_action,

    pub fn sameAs(self: Reference, other: Reference) bool {
        return sameColumns(self.columns, other.columns) and
            std.mem.eql(u8, self.table, other.table) and
            sameSchema(self.schema, other.schema) and
            sameColumns(self.targets, other.targets) and
            self.on_delete == other.on_delete;
    }
};

pub fn sameSchema(a: ?[]const u8, b: ?[]const u8) bool {
    return sameOptionalText(a, b);
}

/// Two pieces of text that may not be there. A schema, and a default.
pub fn sameOptionalText(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const Rename = struct {
    /// What the column used to be called, and what the database still has.
    from: []const u8,
    /// What the Row calls it now.
    to: []const u8,
};

/// One table, entirely. A comptime value, and every slice in it points into
/// the binary.
pub const Desc = struct {
    /// `@typeName` of the Row, for a message rather than for the SQL. Empty in
    /// a snapshot: renaming the Zig type would otherwise read as a schema
    /// change, and it is not one.
    row: []const u8 = "",
    schema: ?[]const u8 = null,
    table: []const u8,
    /// The columns that identify a row, in the order the marker wrote them —
    /// which is also the order they go into the `PRIMARY KEY`, and therefore
    /// the order of the index behind it.
    ///
    /// **A list rather than a name, and the snapshot says `.keys` because of
    /// it.** A file written by an older `generate` says `.key` and no longer
    /// parses; `db generate` rewrites it from the types, which is the same
    /// thing that fixes every other snapshot disagreement.
    keys: []const []const u8,
    columns: []const Column,
    /// The four below default to nothing so that a snapshot file carries only
    /// what a table actually has. `std.zon` omits a field equal to its default,
    /// which is what keeps the file readable and its diffs small.
    uniques: []const Unique = &.{},
    indexes: []const Index = &.{},
    references: []const Reference = &.{},
    /// Never written to a snapshot. A rename is how a schema got somewhere,
    /// not part of where it is.
    renames: []const Rename = &.{},
    /// Whether this program builds the table
    /// ([ADR 0162](../docs/adr/0162-a-table-this-program-reads-and-does-not-build.md)).
    /// Written to a snapshot, unlike the two above: a table this program
    /// starts or stops building is a change somebody should see in the file's
    /// diff, and `std.zon` omits a field equal to its default — so `false` is
    /// a line and `true` is silence.
    managed: bool = true,

    pub fn column(self: Desc, name: []const u8) ?Column {
        for (self.columns) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

/// The whole table `Row` describes, as `D` would write it.
///
/// Every Refusal this file has fires from here, so a Row that does not
/// describe a table stops at the first call rather than at the third.
pub fn descOf(comptime D: type, comptime Row: type) Desc {
    return comptime blk: {
        const owner = row_mod.ownerOf(Row);
        const qualified = row_mod.qualifiedOf(owner);
        const keys = row_mod.keysOf(owner);
        const decl = @field(owner, row_mod.marker);

        const desc: Desc = .{
            .row = @typeName(owner),
            .schema = qualified.schema,
            .table = qualified.table,
            .keys = keys,
            .columns = columnsOf(D, owner, qualified.table, keys, decl),
            .uniques = uniquesOf(owner, qualified.table, decl),
            .indexes = indexesOf(D, owner, qualified.table, decl),
            .references = referencesOf(owner, qualified.table, decl),
            .renames = renamesOf(owner, decl),
            .managed = row_mod.managedOf(owner),
        };
        assertNamesDistinct(owner, desc);
        break :blk desc;
    };
}

/// Two constraints on one table cannot share a name, and since `.index` took a
/// `.where` two of them can be written over the same columns — which is exactly
/// what a table with four partial indexes on one column looks like, and exactly
/// what the derived name cannot tell apart.
///
/// The second `CREATE` would fail at `migrate`, in the database's words, after
/// the first one had already run. Here it is a Refusal naming both.
fn assertNamesDistinct(comptime Row: type, comptime desc: Desc) void {
    comptime {
        const total = desc.uniques.len + desc.indexes.len + desc.references.len;
        @setEvalBranchQuota(10_000 + 500 * total * total);

        var seen: [total][]const u8 = undefined;
        var n: usize = 0;
        for (desc.uniques) |u| {
            claim(Row, &seen, &n, u.name, "`.unique`");
        }
        for (desc.indexes) |x| {
            claim(Row, &seen, &n, x.name, "`.index`");
        }
        for (desc.references) |r| {
            claim(Row, &seen, &n, r.name, "`.references`");
        }
    }
}

fn claim(
    comptime Row: type,
    comptime seen: [][]const u8,
    comptime n: *usize,
    comptime name: []const u8,
    comptime what: []const u8,
) void {
    comptime {
        for (seen[0..n.*]) |already| {
            if (std.mem.eql(u8, already, name)) @compileError(
                "nilo: " ++ @typeName(Row) ++ " names two constraints `" ++ name ++ "`.\n" ++
                    "  One of them is in " ++ what ++ ". The name is derived from the table " ++
                    "and the columns, so two entries over the same columns collide — give " ++
                    "one of them a `.name` that says what it is for.",
            );
        }
        seen[n.*] = name;
        n.* += 1;
    }
}

/// The foreign keys `Row`'s marker declares, **with no Dialect involved.**
///
/// `descOf` answers this too, and asking it costs a `columnType` for every
/// column of the table — which can refuse, for a column type the Dialect has
/// no name for, in the middle of a question that has nothing to do with column
/// types. The where walker asks this one, to find how two tables are joined
/// for an `.exists`, and it has no Dialect's opinion to spend
/// ([ADR 0171](../docs/adr/0171-a-row-over-there-is-a-condition.md)).
pub fn foreignKeysOf(comptime Row: type) []const Reference {
    return comptime blk: {
        const owner = row_mod.ownerOf(Row);
        const decl = @field(owner, row_mod.marker);
        break :blk referencesOf(owner, row_mod.qualifiedOf(owner).table, decl);
    };
}

// -- the columns ---------------------------------------------------------

fn columnsOf(
    comptime D: type,
    comptime Row: type,
    comptime table: []const u8,
    comptime keys: []const []const u8,
    comptime decl: anytype,
) []const Column {
    comptime {
        assertDefaultsAreColumns(Row, decl);
        const fields = @typeInfo(Row).@"struct".fields;
        var out: [fields.len]Column = undefined;
        var n: usize = 0;
        for (fields) |f| {
            // A field beside the columns has no column to describe (ADR 0217).
            if (row_mod.isBeside(Row, f.name)) continue;
            defer n += 1;
            const i = n;
            var is_key = false;
            for (keys) |key| {
                if (std.mem.eql(u8, f.name, key)) is_key = true;
            }
            const optional = @typeInfo(f.type) == .optional;

            if (is_key and optional) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s key `" ++ f.name ++ "` is optional.\n" ++
                    "  A key identifies a row, so there is no row for it to be null on. " ++
                    "Drop the `?`, or name another column with `.key`.",
            );

            out[i] = .{
                .name = f.name,
                .sql_type = D.columnType(f.type) orelse noColumnType(D, Row, f.name, f.type),
                .nullable = optional,
                .key = is_key,
                // **Only a key of one column is ever generated**, and that is
                // the rule rather than a limitation. A sequence fills in one
                // column; a key spanning two is made of values the program
                // already holds — a tenant and an id, two sides of a join —
                // so there is nothing for the database to invent.
                .generated = is_key and keys.len == 1 and generatedKey(f.type),
                .default = defaultOf(D, Row, f.name, f.type, decl),
                .values = enumValues(f.type),
            };
            // A key the database fills in from a sequence has a default
            // already, and it is the sequence. Writing a second one beside it
            // is a statement neither database takes.
            if (out[i].generated and out[i].default != null) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.default." ++ f.name ++ "` is on the " ++
                    "key, and the database fills that in itself.\n" ++
                    "  An integer key of one column comes from a sequence, which is the " ++
                    "default it already has. Take the entry out, or give the row its key.",
            );
            if (out[i].values.len > 0) checkIdentifier(
                constraintName(table, &.{f.name}, "check"),
                "the name nilo derives for the check over " ++ @typeName(Row) ++ "." ++
                    f.name ++ "'s words is `" ++ constraintName(table, &.{f.name}, "check") ++
                    "`, which",
                "Shorten the table or the column.",
            );
        }
        const frozen = out[0..n].*;
        return &frozen;
    }
}

/// The words a Zig enum column may hold, or nothing for every other column.
///
/// **An enum that says which database type it is keeps its silence**, and that
/// is the whole of the rule. `pub const nilo_column = "user_role"` names a
/// Postgres `ENUM` the database owns, whose words are added with `ALTER TYPE`
/// and are none of nilo's business. An enum that says nothing is a `text`
/// column nilo creates, and then the words are the type's
/// ([ADR 0221](../docs/adr/0221-the-marker-has-two-kinds-of-word.md)).
pub fn enumValues(comptime T: type) []const []const u8 {
    comptime {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        if (@typeInfo(Inner) != .@"enum") return &.{};
        if (types_mod.declaredColumn(Inner) != null) return &.{};

        const tags = @typeInfo(Inner).@"enum".fields;
        var out: [tags.len][]const u8 = undefined;
        for (tags, 0..) |t, i| out[i] = t.name;
        const frozen = out;
        return &frozen;
    }
}

// -- what a column is filled with when nothing says ----------------------

/// Every name in `.default` has to be a column of this Row.
fn assertDefaultsAreColumns(comptime Row: type, comptime decl: anytype) void {
    comptime {
        if (!@hasField(@TypeOf(decl), "default")) return;
        const D = @TypeOf(decl.default);
        const fields = if (isNamedForm(D)) @typeInfo(D).@"struct".fields else @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `.default` is a " ++ @typeName(D) ++ ".\n" ++
                "  It is keyed by the column it fills in: " ++
                "`.default = .{ .created_at = .now, .status = .draft }`.",
        );
        for (fields) |f| checkColumn(Row, "default", f.name);
    }
}

/// What this column's `DEFAULT` is, as the Dialect writes it.
///
/// **ADR 0153 put a default in the step and not in the type**, on the grounds
/// that the moment one is load-bearing is narrow — a `NOT NULL` column added to
/// a table that already has rows — and that such a default is dropped
/// afterwards. A 59-table schema settled it the other way: of its 126 defaults,
/// none is that case. Eighty-six are `now()` on a `created_at`, forty are
/// literals the program's every insert relies on for its whole life
/// ([ADR 0221](../docs/adr/0221-the-marker-has-two-kinds-of-word.md)).
///
/// What can be checked while compiling is all of it. `.now` on a column that is
/// not a `sql.Timestamp` does not compile; a literal that is not the column's
/// own Zig type does not compile; a word that is not one of a Zig enum's tags
/// does not compile. Anything wider — `DEFAULT (lower(x))` — is still a step.
fn defaultOf(
    comptime D: type,
    comptime Row: type,
    comptime name: []const u8,
    comptime T: type,
    comptime decl: anytype,
) ?[]const u8 {
    comptime {
        if (!@hasField(@TypeOf(decl), "default")) return null;
        if (!@hasField(@TypeOf(decl.default), name)) return null;
        const written = @field(decl.default, name);

        // `.now` is the one word `.default` has, and it is only a word at all
        // on a column that has no words of its own.
        if (@typeInfo(@TypeOf(written)) == .enum_literal and enumValues(T).len == 0) {
            if (!std.mem.eql(u8, @tagName(written), "now")) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.default." ++ name ++ "` is `." ++
                    @tagName(written) ++ "`, which is not a word `.default` takes.\n" ++
                    "  The one it has is `.now`, on a `sql.Timestamp`. Everything else is " ++
                    "a literal of the column's own type, and a default the database has to " ++
                    "work out is a step.",
            );
            if (unwrap(T) != types_mod.Timestamp) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.default." ++ name ++ "` is `.now` and " ++
                    "the column is " ++ @typeName(T) ++ ".\n" ++
                    "  `.now` is the moment the row was written, so it goes in a " ++
                    "`sql.Timestamp`.",
            );
            return D.now_default;
        }
        return literalText(Row, "`.default`", name, written);
    }
}

/// One value of the caller's, as SQL text the database reads straight.
///
/// **The two places in this module where a value becomes SQL rather than a
/// parameter**, and both are parts of the schema rather than of a statement: a
/// column's `DEFAULT` and a partial index's `WHERE`. There is nothing to bind
/// against in either, which is also why the value has to be one the compiler
/// can see.
fn literalText(
    comptime Row: type,
    comptime what: []const u8,
    comptime column: []const u8,
    comptime written: anytype,
) []const u8 {
    comptime {
        const T = row_mod.ColumnType(Row, column);
        const Inner = unwrap(T);
        const W = @TypeOf(written);
        const mine = @typeName(Row) ++ "." ++ column;

        // A column with words of its own takes one of them, written the way a
        // column is: `.draft`, not `"draft"`.
        const words = enumValues(T);
        if (words.len > 0) {
            if (@typeInfo(W) != .enum_literal) @compileError(
                "nilo: " ++ what ++ " gives " ++ mine ++ " a " ++ @typeName(W) ++ ", and " ++
                    "the column holds one of " ++ @typeName(Inner) ++ "'s words.\n" ++
                    "  They are written the way a column is: " ++ namedList(words) ++
                    " — so `." ++ words[0] ++ "` rather than `\"" ++ words[0] ++ "\"`.",
            );
            for (words) |w| {
                if (std.mem.eql(u8, w, @tagName(written))) return quoteLiteral(w);
            }
            @compileError(
                "nilo: " ++ what ++ " gives " ++ mine ++ " `." ++ @tagName(written) ++
                    "`, which is not one of " ++ @typeName(Inner) ++ "'s words.\n" ++
                    "  They are " ++ namedList(words) ++ ".",
            );
        }

        if (Inner == bool) {
            if (W != bool) wrongLiteral(what, mine, T, W);
            return if (written) "TRUE" else "FALSE";
        }
        if (@typeInfo(Inner) == .int) {
            if (@typeInfo(W) != .int and @typeInfo(W) != .comptime_int) wrongLiteral(what, mine, T, W);
            // The coercion is the check: a number the column could not hold
            // stops here rather than at the first insert.
            const fits: Inner = written;
            return std.fmt.comptimePrint("{d}", .{fits});
        }
        if (@typeInfo(Inner) == .float) {
            if (@typeInfo(W) != .float and @typeInfo(W) != .comptime_float and
                @typeInfo(W) != .int and @typeInfo(W) != .comptime_int) wrongLiteral(what, mine, T, W);
            const fits: Inner = written;
            return std.fmt.comptimePrint("{d}", .{fits});
        }
        if (isTextColumn(Inner)) {
            if (!isTextLiteral(W)) wrongLiteral(what, mine, T, W);
            const text: []const u8 = written;
            return quoteLiteral(text);
        }

        @compileError(
            "nilo: " ++ what ++ " gives " ++ mine ++ " a value, and the column is " ++
                @typeName(T) ++ ".\n" ++
                "  What nilo writes into a schema is text, a whole number, a fraction, a " ++
                "bool, or one of a Zig enum's words. Anything else the database has to " ++
                "work out, so it is a step.",
        );
    }
}

fn wrongLiteral(
    comptime what: []const u8,
    comptime mine: []const u8,
    comptime T: type,
    comptime W: type,
) noreturn {
    @compileError(
        "nilo: " ++ what ++ " gives " ++ mine ++ " a " ++ @typeName(W) ++ ", and the " ++
            "column is " ++ @typeName(T) ++ ".\n" ++
            "  A value written into the schema is of the column's own type, because " ++
            "nothing converts it on the way: the database reads the text as it stands.",
    );
}

fn unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Whether a column holds text — the same three shapes `dialect.acceptsInner`
/// calls text, plus the types that travel as it.
fn isTextColumn(comptime Inner: type) bool {
    comptime {
        if (Inner == core.Str) return true;
        if (types_mod.isBytes(Inner)) return false;
        if (types_mod.asText(Inner) != null) return true;
        return switch (@typeInfo(Inner)) {
            .pointer => |p| p.size == .slice and p.child == u8,
            else => false,
        };
    }
}

/// Whether a written value is text: a literal, a slice of bytes, or a `Str`.
fn isTextLiteral(comptime W: type) bool {
    comptime {
        if (W == core.Str) return true;
        return switch (@typeInfo(W)) {
            .pointer => |p| switch (p.size) {
                .slice => p.child == u8,
                .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
                else => false,
            },
            else => false,
        };
    }
}

/// Text as a SQL literal. A quote inside it is doubled, which is how both
/// databases spell one and the only escape either needs.
fn quoteLiteral(comptime text: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "'";
        for (text) |ch| out = out ++ (if (ch == '\'') "''" else &[_]u8{ch});
        return out ++ "'";
    }
}

/// Whether the database makes this key rather than the program.
///
/// **An integer key is generated and anything else is supplied.** That is a
/// rule rather than a marker word, and it is the right way round: a `Uuid` key
/// is made by the program before the insert, and an integer one is what a
/// sequence exists for. A program that supplies its own integer key writes the
/// create step by hand and gets a word here the day it says so.
fn generatedKey(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |i| i.signedness == .signed,
        else => false,
    };
}

fn noColumnType(
    comptime D: type,
    comptime Row: type,
    comptime name: []const u8,
    comptime T: type,
) noreturn {
    @compileError(
        "nilo: the " ++ D.name ++ " dialect has no column type for " ++ @typeName(Row) ++
            "." ++ name ++ ", which it reads as " ++ @typeName(T) ++ ".\n" ++
            "  A table cannot be created for a column nothing can name. Four ways " ++
            "out: `sql.AsText(\"<type>\")` for a type the database prints, " ++
            "`sql.Json(T)` for a document, a `pub const nilo_column = \"…\"` on the " ++
            "type so it says which column it belongs in, or leaving the column out " ++
            "of the Row and writing it in a step.",
    );
}

// -- the words -----------------------------------------------------------

/// The columns one entry of `.unique` or `.index` is over, and which of them
/// are read the other way up.
const Cols = struct {
    names: []const []const u8,
    descending: []const []const u8 = &.{},
};

/// What an entry of `.unique` may say beside its columns.
const unique_words = [_][]const u8{ "columns", "ignoring_case", "name" };

/// And of `.index`. `.where` is what makes a partial index expressible, and
/// `.name` is what stops two of them colliding.
const index_words = [_][]const u8{ "columns", "where", "name" };

/// Whether a value is the long form — a struct with field names — rather than
/// a tuple of columns.
fn isNamedForm(comptime E: type) bool {
    comptime {
        const info = @typeInfo(E);
        return info == .@"struct" and !info.@"struct".is_tuple;
    }
}

/// One entry of `.unique` or `.index`, in whichever of the shapes it was
/// written in. The three exist so the common case stays short:
///
/// - `.email` — one column
/// - `.{ .tenant_id, .name }` — several, as one constraint
/// - `.{ .columns = .{.email}, .ignoring_case = true }` — the long form
///
/// The long form is what makes the second one unambiguous. Without it,
/// `.{ .email, .ignoring_case }` could be a composite over a column honestly
/// called `ignoring_case`, and a marker that guesses is worse than one that
/// asks for a field name.
///
/// A column inside `.index`'s list may carry a direction —
/// `.{ .created_at = .desc }` — and inside `.unique`'s may not: a unique holds
/// whichever way the index behind it is read, so a direction there would be a
/// word that does nothing.
fn readColumns(
    comptime Row: type,
    comptime what: []const u8,
    comptime known: []const []const u8,
    comptime allow_direction: bool,
    comptime entry: anytype,
) Cols {
    comptime {
        const E = @TypeOf(entry);
        if (@typeInfo(E) == .enum_literal) {
            checkColumn(Row, what, @tagName(entry));
            const one = [_][]const u8{@tagName(entry)};
            const frozen = one;
            return .{ .names = &frozen };
        }
        if (@typeInfo(E) != .@"struct") @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `." ++ what ++ "` holds a " ++
                @typeName(E) ++ ".\n" ++
                "  Each entry is a column (`.email`), several as one constraint " ++
                "(`.{ .tenant_id, .name }`), or the long form " ++
                "(`.{ .columns = .{.email}, … }`).",
        );

        const named = isNamedForm(E);
        if (named) {
            assertKnownWords(Row, what, known, E);
            if (!@hasField(E, "columns")) @compileError(
                "nilo: " ++ @typeName(Row) ++ " has an entry of `." ++ what ++
                    "` that names no columns.\n" ++
                    "  The long form says which: `.{ .columns = .{ .tenant_id, .name }, … }`.",
            );
        }

        const inner = if (named) entry.columns else entry;
        const fields = @typeInfo(@TypeOf(inner)).@"struct".fields;
        if (fields.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ " has an empty entry in `." ++ what ++ "`.\n" ++
                "  A constraint over no columns is nothing, and writing it is more " ++
                "likely a half-finished line than a decision.",
        );

        var names: [fields.len][]const u8 = undefined;
        var down: [fields.len][]const u8 = undefined;
        var n_down: usize = 0;
        for (fields, 0..) |f, i| {
            const value = @field(inner, f.name);
            const V = @TypeOf(value);
            if (@typeInfo(V) == .enum_literal) {
                checkColumn(Row, what, @tagName(value));
                names[i] = @tagName(value);
                continue;
            }
            if (isNamedForm(V) and @typeInfo(V).@"struct".fields.len == 1) {
                const only = @typeInfo(V).@"struct".fields[0].name;
                if (!allow_direction) @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `." ++ what ++ "` reads `" ++ only ++
                        "` in a direction.\n" ++
                        "  Only `.index` has one. A unique constraint holds whichever way " ++
                        "the index behind it is read, so a direction on it would be a word " ++
                        "that does nothing.",
                );
                checkColumn(Row, what, only);
                names[i] = only;
                if (isDescending(Row, only, @field(value, only))) {
                    down[n_down] = only;
                    n_down += 1;
                }
                continue;
            }
            @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `." ++ what ++ "` names a column as " ++
                    @typeName(V) ++ ".\n" ++
                    "  A column is written the way it is everywhere else here, as " ++
                    "`.<name>` rather than as text" ++
                    (if (allow_direction) ", or as `.{ .<name> = .desc }`." else "."),
            );
        }
        const frozen_names = names;
        const frozen_down = down[0..n_down].*;
        return .{ .names = &frozen_names, .descending = &frozen_down };
    }
}

/// `.asc` or `.desc` on one column of an index, and nothing else.
fn isDescending(comptime Row: type, comptime column: []const u8, comptime written: anytype) bool {
    comptime {
        const shape = "nilo: " ++ @typeName(Row) ++ "'s `.index` reads `" ++ column ++
            "` in a direction that is not one.\n" ++
            "  The two are `.asc` and `.desc`, and an index with neither is read upwards.";
        if (@typeInfo(@TypeOf(written)) != .enum_literal) @compileError(shape);
        if (std.mem.eql(u8, @tagName(written), "desc")) return true;
        if (std.mem.eql(u8, @tagName(written), "asc")) return false;
        @compileError(shape);
    }
}

/// Every field of a long-form entry has to be one of the words it may carry.
///
/// Without this a misspelled `.ignorng_case` is a plain unique that compiles,
/// creates an index, and folds no case — which is found the day two rows that
/// differ by capitals both go in.
fn assertKnownWords(
    comptime Row: type,
    comptime what: []const u8,
    comptime known: []const []const u8,
    comptime E: type,
) void {
    comptime {
        for (@typeInfo(E).@"struct".fields) |f| {
            for (known) |ok| {
                if (std.mem.eql(u8, f.name, ok)) break;
            } else @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `." ++ what ++ "` sets `." ++ f.name ++
                    "`, which is not part of an entry.\n" ++
                    "  It takes " ++ wordList(known) ++ ".",
            );
        }
    }
}

fn wordList(comptime words: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (words, 0..) |w, i| {
            out = out ++ (if (i == 0) "" else if (i == words.len - 1) " and " else ", ") ++
                "`." ++ w ++ "`";
        }
        return out;
    }
}

/// A list of names, for a message: `` `a`, `b` ``.
fn namedList(comptime names: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (names, 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ "`" ++ n ++ "`";
        return out;
    }
}

fn checkColumn(comptime Row: type, comptime what: []const u8, comptime name: []const u8) void {
    comptime {
        if (!row_mod.hasColumn(Row, name)) row_mod.noSuchColumn(Row, name, "`." ++ what ++ "`");
    }
}

/// The name a constraint goes into the database under: the one the long form
/// gave it, or the one derived from the table and the columns.
///
/// **The name is the error message.** Postgres reports a violation by
/// constraint name and nothing else, so `work_epics_number_is_unique_per_board`
/// is a sentence a support engineer can act on where
/// `work_epics_department_id_number_key` is a column list they have to go and
/// read the schema for.
fn entryName(
    comptime Row: type,
    comptime what: []const u8,
    comptime table: []const u8,
    comptime columns: []const []const u8,
    comptime suffix: []const u8,
    comptime entry: anytype,
) []const u8 {
    comptime {
        const E = @TypeOf(entry);
        if (isNamedForm(E) and @hasField(E, "name")) {
            const written = entry.name;
            if (@typeInfo(@TypeOf(written)) == .enum_literal) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `." ++ what ++ "` is named `." ++
                    @tagName(written) ++ "`.\n" ++
                    "  A constraint's name is the whole of what Postgres says when a row " ++
                    "breaks it, so it is text: `.name = \"" ++ @tagName(written) ++ "\"`.",
            );
            const given: []const u8 = written;
            if (given.len == 0) @compileError(
                "nilo: " ++ @typeName(Row) ++ " gives an entry of `." ++ what ++
                    "` an empty `.name`.\n" ++
                    "  Leave `.name` out and nilo derives one from the table and the " ++
                    "columns; write one and it has to say something.",
            );
            checkIdentifier(
                given,
                @typeName(Row) ++ "'s `." ++ what ++ "` is named `" ++ given ++ "`, which",
                "Make it shorter.",
            );
            return given;
        }
        const derived = constraintName(table, columns, suffix);
        checkIdentifier(
            derived,
            "the name nilo derives for " ++ @typeName(Row) ++ "'s `." ++ what ++ "` over " ++
                namedList(columns) ++ " is `" ++ derived ++ "`, which",
            "Give the entry a `.name` that says what it is for.",
        );
        return derived;
    }
}

/// A name the database would take and then not hold.
///
/// Postgres truncates an identifier at 63 bytes on the way in and says so in a
/// `NOTICE`, which nothing here reads. The snapshot then records a name the
/// database does not have: a `DROP INDEX` still works, because the truncation
/// happens on the way in as well, and two constraints whose first 63 bytes
/// agree collide on the second `CREATE` with nothing having warned anybody.
fn checkIdentifier(
    comptime name: []const u8,
    comptime head: []const u8,
    comptime fix: []const u8,
) void {
    comptime {
        if (name.len <= max_identifier) return;
        @compileError(
            "nilo: " ++ head ++ " is " ++ std.fmt.comptimePrint("{d}", .{name.len}) ++
                " bytes, and 63 is all Postgres keeps.\n" ++
                "  It cuts a longer one down on the way in, in a NOTICE nothing here " ++
                "reads, so the snapshot would hold a name the database does not have. " ++
                fix,
        );
    }
}

fn uniquesOf(
    comptime Row: type,
    comptime table: []const u8,
    comptime decl: anytype,
) []const Unique {
    comptime {
        if (!@hasField(@TypeOf(decl), "unique")) return &.{};
        const entries = @typeInfo(@TypeOf(decl.unique)).@"struct".fields;
        var out: [entries.len]Unique = undefined;
        for (entries, 0..) |f, i| {
            const entry = @field(decl.unique, f.name);
            const cols = readColumns(Row, "unique", &unique_words, false, entry);
            const E = @TypeOf(entry);
            const folding = isNamedForm(E) and
                @hasField(E, "ignoring_case") and entry.ignoring_case;
            if (folding) for (cols.names) |c| checkText(Row, c);
            out[i] = .{
                .name = entryName(Row, "unique", table, cols.names, "key", entry),
                .columns = cols.names,
                .ignoring_case = folding,
            };
        }
        const frozen = out;
        return &frozen;
    }
}

/// `.ignoring_case` on a column that is not text has nothing to fold.
///
/// Both databases would accept the DDL and neither would do anything with it,
/// which is the shape of mistake that survives a review and is found by a
/// duplicate row.
fn checkText(comptime Row: type, comptime name: []const u8) void {
    comptime {
        const T = row_mod.ColumnType(Row, name);
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        // The same two shapes `dialect.acceptsInner` calls text, asked here in
        // the same order, so a column that reads as text is a column that can
        // have its case folded.
        const text = Inner == core.Str or switch (@typeInfo(Inner)) {
            .pointer => |p| p.size == .slice and p.child == u8,
            else => false,
        };
        if (!text) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s unique on `" ++ name ++
                "` asks to ignore case, and the column is " ++ @typeName(T) ++ ".\n" ++
                "  Only text has a case to ignore. Both databases would take the " ++
                "clause and neither would do anything with it.",
        );
    }
}

fn indexesOf(
    comptime D: type,
    comptime Row: type,
    comptime table: []const u8,
    comptime decl: anytype,
) []const Index {
    comptime {
        if (!@hasField(@TypeOf(decl), "index")) return &.{};
        const entries = @typeInfo(@TypeOf(decl.index)).@"struct".fields;
        var out: [entries.len]Index = undefined;
        for (entries, 0..) |f, i| {
            const entry = @field(decl.index, f.name);
            const cols = readColumns(Row, "index", &index_words, true, entry);
            out[i] = .{
                .name = entryName(Row, "index", table, cols.names, "idx", entry),
                .columns = cols.names,
                .descending = cols.descending,
                .where = whereText(D, Row, entry),
            };
        }
        const frozen = out;
        return &frozen;
    }
}

// -- what a partial index is over ----------------------------------------

/// The `WHERE` of a partial index, as SQL.
///
/// **ADR 0153 refused this and refused it as `.where = "deleted_at IS NULL"`,
/// a string** — and the refusal was right about the string. This is not one.
/// It is the same grammar the where walker already has, checked the same way:
/// a column that is not one is a Refusal naming the near miss, and a literal
/// that is not the column's own Zig type does not compile. What comes out is
/// SQL because an index predicate has nowhere to put a parameter — the
/// database stores it, and it is part of the schema rather than of a statement
/// ([ADR 0221](../docs/adr/0221-the-marker-has-two-kinds-of-word.md)).
///
/// Four terms, which is every shape a real schema turned out to need:
///
/// ```zig
/// .where = .{
///     .deleted_at = null,                    // IS NULL
///     .read_at = .{ .ne = null },            // IS NOT NULL
///     .state = .open,                        // = 'open'
///     .kind = .{ .ne = "draft" },            // <> 'draft'
/// }
/// ```
///
/// An index over an expression — `lower(btrim(site))` — is still a step, and
/// stays one until somebody brings a second.
fn whereText(comptime D: type, comptime Row: type, comptime entry: anytype) []const u8 {
    comptime {
        const E = @TypeOf(entry);
        if (!isNamedForm(E) or !@hasField(E, "where")) return "";
        const W = @TypeOf(entry.where);
        const shape = "nilo: " ++ @typeName(Row) ++ "'s `.index` has a `.where` that is a " ++
            @typeName(W) ++ ".\n" ++
            "  It is keyed by the column it tests, the way a condition is: " ++
            "`.where = .{ .deleted_at = null }`.";
        if (!isNamedForm(W)) @compileError(shape);
        const fields = @typeInfo(W).@"struct".fields;
        if (fields.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `.index` has an empty `.where`.\n" ++
                "  An index over every row is the ordinary kind: leave `.where` out.",
        );

        var out: []const u8 = "";
        for (fields, 0..) |f, i| {
            checkColumn(Row, "index", f.name);
            out = out ++ (if (i == 0) "" else " AND ") ++
                whereTerm(D, Row, f.name, @field(entry.where, f.name));
        }
        return out;
    }
}

fn whereTerm(
    comptime D: type,
    comptime Row: type,
    comptime column: []const u8,
    comptime written: anytype,
) []const u8 {
    comptime {
        const quoted = D.quote(column);
        const W = @TypeOf(written);
        if (W == @TypeOf(null)) return quoted ++ " IS NULL";

        if (isNamedForm(W)) {
            const fields = @typeInfo(W).@"struct".fields;
            if (fields.len != 1 or !std.mem.eql(u8, fields[0].name, "ne")) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.index` tests `" ++ column ++
                    "` with something that is not one of the four terms.\n" ++
                    "  They are `null`, `.{ .ne = null }`, a value of the column's own " ++
                    "type, and `.{ .ne = <value> }`. Anything wider than that is an " ++
                    "index written as a step.",
            );
            const inner = written.ne;
            if (@TypeOf(inner) == @TypeOf(null)) return quoted ++ " IS NOT NULL";
            return quoted ++ " <> " ++ literalText(Row, "`.index`'s `.where`", column, inner);
        }
        return quoted ++ " = " ++ literalText(Row, "`.index`'s `.where`", column, written);
    }
}

/// What an entry of `.references` may say beside its columns.
const reference_words = [_][]const u8{ "columns", "to", "on_delete", "name" };

fn referencesOf(
    comptime Row: type,
    comptime table: []const u8,
    comptime decl: anytype,
) []const Reference {
    comptime {
        if (!@hasField(@TypeOf(decl), "references")) return &.{};
        const D = @TypeOf(decl.references);
        const entries = @typeInfo(D).@"struct".fields;
        if (entries.len > 0 and entries[0].name[0] >= '0' and entries[0].name[0] <= '9')
            @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references` is a list.\n" ++
                    "  It is keyed by the column doing the pointing: " ++
                    "`.references = .{ .org_id = .{ Org, .id } }`.",
            );

        var out: [entries.len]Reference = undefined;
        for (entries, 0..) |f, i| {
            out[i] = oneReference(Row, table, f.name, @field(decl.references, f.name));
        }
        const frozen = out;
        return &frozen;
    }
}

/// Which table an entry points at, and how it said so.
///
/// **The two spellings answer here**, so that everything downstream of this
/// reads one shape. `row` is the Row when the marker named a type and null
/// when it named the table as text, and it is the only field the difference
/// survives into: what the type check needs, and nothing else
/// ([ADR 0222](../docs/adr/0222-a-foreign-key-is-columns-and-a-table-name.md)).
const Target = struct {
    row: ?type,
    schema: ?[]const u8,
    table: []const u8,
    columns: []const []const u8,
};

/// One reference's target, out of `.{ Org, .id }`, `.{ "orgs", .id }` or the
/// pair of column lists a composite key needs.
fn targetOf(
    comptime Row: type,
    comptime mine: []const u8,
    comptime named: anytype,
    comptime column_list: anytype,
) Target {
    comptime {
        const N = @TypeOf(named);
        const spelling = "  A foreign key names the Row that owns the table — " ++
            "`.{ Org, .id }` — or that table's own name when the Row cannot be " ++
            "imported — `.{ \"orgs\", .id }`.";

        const q: row_mod.Qualified, const target_row: ?type = blk: {
            if (N == type) {
                if (!row_mod.isRow(named)) @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ mine ++
                        "` points at " ++ @typeName(named) ++ ", which is not a Row.\n" ++
                        spelling,
                );
                break :blk .{ row_mod.qualifiedOf(named), named };
            }
            if (isTextLiteral(N)) {
                const written: []const u8 = named;
                if (written.len == 0) @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ mine ++
                        "` points at a table with no name.\n" ++ spelling,
                );
                break :blk .{
                    row_mod.qualifiedName(
                        written,
                        @typeName(Row) ++ "'s `.references." ++ mine ++ "` points at",
                    ),
                    null,
                };
            }
            @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ mine ++
                    "` points at a " ++ @typeName(N) ++ ", which is not a table.\n" ++
                    spelling,
            );
        };

        // One column or several, the way `.key` takes either. A tuple here is
        // the composite; a bare name is the ordinary one.
        const C = @TypeOf(column_list);
        const columns: []const []const u8 = if (@typeInfo(C) == .enum_literal)
            &.{@tagName(column_list)}
        else cols: {
            if (@typeInfo(C) != .@"struct" or !@typeInfo(C).@"struct".is_tuple) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ mine ++
                    "` names the column it points at as a " ++ @typeName(C) ++ ".\n" ++
                    "  It is a column of the other table — `.id` — or several of them " ++
                    "as one key: `.{ .id, .department_id }`.",
            );
            var out: [@typeInfo(C).@"struct".fields.len][]const u8 = undefined;
            for (@typeInfo(C).@"struct".fields, 0..) |f, i| {
                const written = @field(column_list, f.name);
                if (@typeInfo(@TypeOf(written)) != .enum_literal) @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ mine ++
                        "` names a column it points at as text.\n" ++
                        "  A column over there is written the way a column is: " ++
                        "`.{ .id, .department_id }`.",
                );
                out[i] = @tagName(written);
            }
            const frozen = out;
            break :cols &frozen;
        };
        if (columns.len == 0) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ mine ++
                "` names no column of `" ++ q.table ++ "`.\n" ++
                "  A foreign key points at the columns that identify a row over there.",
        );

        return .{ .row = target_row, .schema = q.schema, .table = q.table, .columns = columns };
    }
}

/// One entry of `.references`, in either of its two shapes.
///
/// - `.org_id = .{ Org, .id, .cascade }` — keyed by the column doing the
///   pointing, which is every foreign key of one column.
/// - `.epic = .{ .columns = .{ .epic_id, .department_id }, .to = .{ WorkEpic, .{ .id, .department_id } } }`
///   — the long form, whose key is a **label** rather than a column, because a
///   Zig field name cannot be a tuple. It is also where a `.name` goes.
fn oneReference(
    comptime Row: type,
    comptime table: []const u8,
    comptime key: []const u8,
    comptime entry: anytype,
) Reference {
    comptime {
        const E = @TypeOf(entry);
        const shape = "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ key ++
            "` is not a table and a column.\n" ++
            "  It is written `.{ <Row>, .<column> }`, with `.cascade`, `.restrict` " ++
            "or `.set_null` after it when the delete should do something. A key of " ++
            "several columns is the long form: `.{ .columns = .{ .a, .b }, " ++
            ".to = .{ <Row>, .{ .a, .b } } }`.";
        if (@typeInfo(E) != .@"struct") @compileError(shape);

        const long = isNamedForm(E);
        if (long) {
            assertKnownWords(Row, "references", &reference_words, E);
            if (!@hasField(E, "columns")) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ key ++
                    "` names no columns of its own.\n" ++
                    "  The long form says which do the pointing: " ++
                    "`.{ .columns = .{ .epic_id, .department_id }, .to = … }`.",
            );
            if (!@hasField(E, "to")) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ key ++
                    "` says no table.\n" ++
                    "  The long form points with `.to`: " ++
                    "`.to = .{ WorkEpic, .{ .id, .department_id } }`.",
            );
            const To = @TypeOf(entry.to);
            if (@typeInfo(To) != .@"struct" or !@typeInfo(To).@"struct".is_tuple or
                @typeInfo(To).@"struct".fields.len != 2) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ key ++
                    "`'s `.to` is not a table and its columns.\n" ++
                    "  It is the pair: `.to = .{ WorkEpic, .{ .id, .department_id } }`.",
            );
        } else {
            if (!@typeInfo(E).@"struct".is_tuple) @compileError(shape);
            const parts = @typeInfo(E).@"struct".fields.len;
            if (parts < 2 or parts > 3) @compileError(shape);
            checkColumn(Row, "references", key);
        }

        const columns: []const []const u8 = if (long)
            readColumns(Row, "references", &reference_words, false, entry.columns).names
        else
            &.{key};
        const target: Target = if (long)
            targetOf(Row, key, entry.to[0], entry.to[1])
        else
            targetOf(Row, key, entry[0], entry[1]);

        if (columns.len != target.columns.len) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ key ++ "` points " ++
                std.fmt.comptimePrint("{d}", .{columns.len}) ++ " column(s) at " ++
                std.fmt.comptimePrint("{d}", .{target.columns.len}) ++ " of `" ++
                target.table ++ "`.\n" ++
                "  The two sides of a foreign key line up one for one, in the order " ++
                "they are written.",
        );

        // The check the whole word is worth having. Two sides of a foreign key
        // that hold different types is a bug the database finds at the first
        // insert, in a message about a cast rather than about a design. It runs
        // here when the target is a type, and in `assertTargetsResolve` when it
        // is a name — the same check, one level up, where every Row is in one
        // list (ADR 0222).
        if (target.row) |Pointed| {
            for (columns, target.columns) |c, t| {
                if (!row_mod.hasColumn(Pointed, t))
                    row_mod.noSuchColumn(Pointed, t, "`.references." ++ key ++ "`");
                assertSidesAgree(Row, c, Pointed, t);
            }
        }

        // The long form says it by name; the short one says it by being three
        // long, `.{ Org, .id, .cascade }`.
        const said_on_delete = if (long)
            @hasField(E, "on_delete")
        else
            @typeInfo(E).@"struct".fields.len == 3;
        const on_delete: OnDelete = if (!said_on_delete) .no_action else read: {
            const written = if (long) entry.on_delete else entry[2];
            if (@typeInfo(@TypeOf(written)) != .enum_literal) @compileError(shape);
            break :read std.meta.stringToEnum(OnDelete, @tagName(written)) orelse @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ key ++ "` says `." ++
                    @tagName(written) ++ "` happens on delete.\n" ++
                    "  The three it can say are `.cascade`, `.restrict` and `.set_null`.",
            );
        };

        if (on_delete == .set_null) {
            for (columns) |c| {
                const held = row_mod.ColumnType(Row, c);
                if (@typeInfo(held) != .optional) @compileError(
                    "nilo: " ++ @typeName(Row) ++ "." ++ c ++ " is set to null on delete, " ++
                        "and it is " ++ @typeName(held) ++ ".\n" ++
                        "  A column the database will write a null into is optional in " ++
                        "the Row, or the first cascading delete is a row nothing can read.",
                );
            }
        }

        return .{
            .name = entryName(Row, "references", table, columns, "fkey", entry),
            .columns = columns,
            .schema = target.schema,
            .table = target.table,
            .targets = target.columns,
            .on_delete = on_delete,
        };
    }
}

/// Two sides of one foreign key hold the same value, so they are the same type.
fn assertSidesAgree(
    comptime Row: type,
    comptime column: []const u8,
    comptime Pointed: type,
    comptime target: []const u8,
) void {
    comptime {
        const mine = row_mod.ColumnType(Row, column);
        const theirs = row_mod.ColumnType(Pointed, target);
        if (unwrap(mine) == theirs) return;
        @compileError(
            "nilo: " ++ @typeName(Row) ++ "." ++ column ++ " is " ++ @typeName(mine) ++
                " and points at " ++ @typeName(Pointed) ++ "." ++ target ++ ", which is " ++
                @typeName(theirs) ++ ".\n" ++
                "  Two sides of a foreign key hold the same value, so they are the " ++
                "same type. One of the two is wrong about its column.",
        );
    }
}

/// A list of columns as one piece of text, for a message.
fn columnList(comptime columns: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (columns, 0..) |c, i| out = out ++ (if (i == 0) "" else ", ") ++ c;
        return out;
    }
}

/// The references whose target was written as **text**, for the one check that
/// cannot run inside the Row.
pub const NamedTarget = struct {
    /// What the marker keyed the entry by, for the message.
    key: []const u8,
    columns: []const []const u8,
    schema: ?[]const u8,
    table: []const u8,
    targets: []const []const u8,
};

/// Those entries of `Row`'s `.references` that named a table rather than a Row.
///
/// **Not a field on `Reference`**, and that is deliberate: how the Zig source
/// spelled a target is not a fact about the schema, and `Reference` is what the
/// snapshot holds. So it is asked for separately, by the one caller that has
/// every Row in one list (ADR 0222).
pub fn namedTargetsOf(comptime Row: type) []const NamedTarget {
    return comptime blk: {
        if (row_mod.isProjection(Row)) break :blk &.{};
        // The owner, the way `descOf` and `foreignKeysOf` do it: a borrowing
        // Row's marker is a type, and the references belong to the Row that
        // names the table.
        const owner = row_mod.ownerOf(Row);
        const decl = @field(owner, row_mod.marker);
        if (!@hasField(@TypeOf(decl), "references")) break :blk &.{};

        const entries = @typeInfo(@TypeOf(decl.references)).@"struct".fields;
        var out: [entries.len]NamedTarget = undefined;
        var n: usize = 0;
        for (entries) |f| {
            const entry = @field(decl.references, f.name);
            const long = isNamedForm(@TypeOf(entry));
            const spec = if (long)
                targetOf(owner, f.name, entry.to[0], entry.to[1])
            else
                targetOf(owner, f.name, entry[0], entry[1]);
            if (spec.row != null) continue;
            out[n] = .{
                .key = f.name,
                .columns = if (long)
                    readColumns(owner, "references", &reference_words, false, entry.columns).names
                else
                    &.{f.name},
                .schema = spec.schema,
                .table = spec.table,
                .targets = spec.columns,
            };
            n += 1;
        }
        const frozen = out[0..n].*;
        break :blk &frozen;
    };
}

/// Every `.references` that named its table as text, resolved against the list
/// of Rows the migrator was given.
///
/// **This is the check that moved rather than the check that was dropped**
/// (ADR 0222). A foreign key naming a Zig type is checked inside the Row,
/// because the type is right there. A program whose contexts may not import
/// each other cannot write that type, and the answer is not to give the check
/// up: every Row is in one comptime list one level up, so the name is resolved
/// there and the two sides' types are compared exactly as they were.
pub fn assertTargetsResolve(comptime Rows: []const type) void {
    comptime {
        @setEvalBranchQuota(20_000 + 4_000 * Rows.len * Rows.len);
        for (Rows) |Row| {
            for (namedTargetsOf(Row)) |want| {
                var found: ?type = null;
                for (Rows) |Other| {
                    const q = row_mod.qualifiedOf(Other);
                    if (!std.mem.eql(u8, q.table, want.table)) continue;
                    if (!sameSchema(q.schema, want.schema)) continue;
                    found = row_mod.ownerOf(Other);
                }
                const Pointed = found orelse @compileError(
                    "nilo: " ++ @typeName(Row) ++ "'s `.references." ++ want.key ++
                        "` points at the table `" ++ want.table ++ "`, and no Row in " ++
                        "this list names it.\n" ++
                        "  A foreign key written as text is checked against the Rows the " ++
                        "tool was given, because that is where every Row is in one place. " ++
                        "Put the Row for `" ++ want.table ++ "` in the list — with " ++
                        "`.managed = false` if this program only reads that table — or " ++
                        "point at its type.",
                );
                for (want.columns, want.targets) |c, t| {
                    if (!row_mod.hasColumn(Pointed, t)) row_mod.noSuchColumn(
                        Pointed,
                        t,
                        @typeName(Row) ++ "'s `.references." ++ want.key ++ "`",
                    );
                    assertSidesAgree(Row, c, Pointed, t);
                }
            }
        }
    }
}

fn renamesOf(comptime Row: type, comptime decl: anytype) []const Rename {
    comptime {
        if (!@hasField(@TypeOf(decl), "was")) return &.{};
        const entries = @typeInfo(@TypeOf(decl.was)).@"struct".fields;
        var out: [entries.len]Rename = undefined;
        for (entries, 0..) |f, i| {
            checkColumn(Row, "was", f.name);
            const from = @field(decl.was, f.name);
            if (@typeInfo(@TypeOf(from)) == .enum_literal) @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s `.was." ++ f.name ++ "` is `." ++
                    @tagName(from) ++ "`.\n" ++
                    "  The old name is text rather than a column, because it is not one " ++
                    "any more: `.was = .{ ." ++ f.name ++ " = \"" ++ @tagName(from) ++ "\" }`.",
            );
            // The old name being a column too would mean the Row has both, and
            // then a rename and a drop are the same statement written twice.
            if (row_mod.hasColumn(Row, from)) @compileError(
                "nilo: " ++ @typeName(Row) ++ " says `" ++ f.name ++ "` was called `" ++
                    from ++ "`, and it reads a column called `" ++ from ++ "` as well.\n" ++
                    "  Both cannot be true. A rename leaves one column, so one of the " ++
                    "two fields is the one that should go.",
            );
            out[i] = .{ .from = from, .to = f.name };
        }
        const frozen = out;
        return &frozen;
    }
}

/// The name nilo gives a constraint it creates.
///
/// Postgres's own convention, deliberately: `users_email_key`,
/// `users_org_id_fkey`. A `pull` from a database somebody else made then lines
/// up with what `generate` would have written, so the first diff against an
/// existing schema is empty rather than a rename of every index.
pub fn constraintName(
    comptime table: []const u8,
    comptime columns: []const []const u8,
    comptime suffix: []const u8,
) []const u8 {
    comptime {
        var out: []const u8 = table;
        for (columns) |c| out = out ++ "_" ++ c;
        return out ++ "_" ++ suffix;
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = @import("dialect.zig").Postgres;
const Lite = @import("dialect.zig").SQLite;
const types = @import("types.zig");

const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: []const u8,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{
            .{ .columns = .{.email}, .ignoring_case = true },
            .{ .org_id, .handle },
        },
        .index = .{ .created_at, .{ .org_id, .created_at } },
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
    email: core.Str,
    handle: []const u8,
    nickname: ?[]const u8,
    created_at: types.Timestamp,
};

test "a table is described entirely from the type, and the description is a constant" {
    const desc = comptime descOf(Pg, User);

    // If any of this were runtime work, the array below would not compile.
    const in_binary: [desc.columns.len]Column = desc.columns[0..desc.columns.len].*;
    try testing.expectEqual(@as(usize, 6), in_binary.len);

    try testing.expectEqualStrings("users", desc.table);
    try testing.expectEqual(@as(?[]const u8, null), desc.schema);
    try testing.expectEqual(@as(usize, 1), desc.keys.len);
    try testing.expectEqualStrings("id", desc.keys[0]);
}

test "a column's type is the one the dialect would write, and nullability is the `?`" {
    const desc = comptime descOf(Pg, User);

    try testing.expectEqualStrings("int8", desc.column("id").?.sql_type);
    try testing.expectEqualStrings("text", desc.column("email").?.sql_type);
    try testing.expectEqualStrings("timestamptz", desc.column("created_at").?.sql_type);

    try testing.expect(!desc.column("email").?.nullable);
    try testing.expect(desc.column("nickname").?.nullable);
}

test "an integer key is generated and a supplied one is not" {
    const desc = comptime descOf(Pg, User);
    try testing.expect(desc.column("id").?.key);
    try testing.expect(desc.column("id").?.generated);
    try testing.expect(!desc.column("org_id").?.key);

    const Doc = struct {
        pub const nilo_table = .{ .name = "docs", .key = .public };
        public: types.Uuid,
        title: []const u8,
    };
    const doc = comptime descOf(Pg, Doc);
    try testing.expect(doc.column("public").?.key);
    try testing.expect(!doc.column("public").?.generated);
}

test "the same type describes two databases, and only the column types move" {
    const pg = comptime descOf(Pg, User);
    const lite = comptime descOf(Lite, User);

    try testing.expectEqualStrings(pg.table, lite.table);
    try testing.expectEqual(pg.columns.len, lite.columns.len);
    try testing.expectEqual(pg.uniques.len, lite.uniques.len);

    try testing.expectEqualStrings("int8", pg.column("id").?.sql_type);
    try testing.expectEqualStrings("INTEGER", lite.column("id").?.sql_type);
    try testing.expectEqualStrings("timestamptz", pg.column("created_at").?.sql_type);
    // The one SQLite stores as an integer rather than as text (ADR 0136).
    try testing.expectEqualStrings("INTEGER", lite.column("created_at").?.sql_type);
}

test "a unique is written in whichever of the three shapes fits, and named the same way" {
    const desc = comptime descOf(Pg, User);
    try testing.expectEqual(@as(usize, 2), desc.uniques.len);

    try testing.expectEqualStrings("users_email_key", desc.uniques[0].name);
    try testing.expectEqual(@as(usize, 1), desc.uniques[0].columns.len);
    try testing.expect(desc.uniques[0].ignoring_case);

    try testing.expectEqualStrings("users_org_id_handle_key", desc.uniques[1].name);
    try testing.expectEqual(@as(usize, 2), desc.uniques[1].columns.len);
    try testing.expect(!desc.uniques[1].ignoring_case);
}

test "a bare column is one index and a tuple is one composite, which is the whole grammar" {
    const desc = comptime descOf(Pg, User);
    try testing.expectEqual(@as(usize, 2), desc.indexes.len);
    try testing.expectEqualStrings("users_created_at_idx", desc.indexes[0].name);
    try testing.expectEqualStrings("users_org_id_created_at_idx", desc.indexes[1].name);
    try testing.expectEqualStrings("org_id", desc.indexes[1].columns[0]);
    try testing.expectEqualStrings("created_at", desc.indexes[1].columns[1]);
}

test "a foreign key names the Row it points at, so the table comes from the type" {
    const desc = comptime descOf(Pg, User);
    try testing.expectEqual(@as(usize, 1), desc.references.len);

    const fk = desc.references[0];
    try testing.expectEqualStrings("users_org_id_fkey", fk.name);
    try testing.expectEqualStrings("org_id", fk.columns[0]);
    try testing.expectEqualStrings("orgs", fk.table);
    try testing.expectEqualStrings("id", fk.targets[0]);
    try testing.expectEqual(OnDelete.cascade, fk.on_delete);
    try testing.expectEqualStrings(" ON DELETE CASCADE", fk.on_delete.clause());
}

test "a foreign key over two columns lines them up with the two it points at" {
    const Board = struct {
        pub const nilo_table = .{ .name = "boards", .key = .{ .id, .org_id } };
        id: i64,
        org_id: i64,
    };
    const Card = struct {
        pub const nilo_table = .{
            .name = "cards",
            .key = .id,
            .references = .{
                .board = .{
                    .columns = .{ .board_id, .org_id },
                    .to = .{ Board, .{ .id, .org_id } },
                    .on_delete = .cascade,
                },
            },
        };
        id: i64,
        board_id: i64,
        org_id: i64,
    };
    const desc = comptime descOf(Pg, Card);
    const fk = desc.references[0];

    // The key of the entry is a label rather than a column — a Zig field name
    // cannot be a tuple — and the name still comes from the columns, so a
    // `pull` from a database somebody else made lines up.
    try testing.expectEqualStrings("cards_board_id_org_id_fkey", fk.name);
    try testing.expectEqual(@as(usize, 2), fk.columns.len);
    try testing.expectEqualStrings("board_id", fk.columns[0]);
    try testing.expectEqualStrings("org_id", fk.columns[1]);
    try testing.expectEqualStrings("id", fk.targets[0]);
    try testing.expectEqualStrings("org_id", fk.targets[1]);
    try testing.expectEqual(OnDelete.cascade, fk.on_delete);
}

test "a foreign key can name its table, and it is the same reference either way" {
    const ByName = struct {
        pub const nilo_table = .{
            .name = "users",
            .key = .id,
            .references = .{ .org_id = .{ "orgs", .id, .cascade } },
        };
        id: i64,
        org_id: i64,
    };
    const named = comptime descOf(Pg, ByName).references[0];
    const typed = comptime descOf(Pg, User).references[0];

    // The whole property the text spelling has to hold: what comes out is the
    // same `Reference`, so the DDL, the diff and the snapshot cannot tell the
    // two apart. Only the type check knows, and it runs one level up.
    try testing.expect(named.sameAs(typed));
    try testing.expectEqualStrings(typed.name, named.name);
}

test "a table named with its schema is split the way a Row's own name is" {
    const Scoped = struct {
        pub const nilo_table = .{
            .name = "app.members",
            .key = .id,
            .references = .{ .org_id = .{ "other.orgs", .id } },
        };
        id: i64,
        org_id: i64,
    };
    const fk = comptime descOf(Pg, Scoped).references[0];
    try testing.expectEqualStrings("other", fk.schema.?);
    try testing.expectEqualStrings("orgs", fk.table);
}

test "the long form is also where a foreign key of one column gets a name" {
    const Member = struct {
        pub const nilo_table = .{
            .name = "members",
            .key = .id,
            .references = .{
                .home = .{
                    .columns = .{.org_id},
                    .to = .{ Org, .id },
                    .name = "members_belong_to_one_org",
                },
            },
        };
        id: i64,
        org_id: i64,
    };
    const fk = comptime descOf(Pg, Member).references[0];
    try testing.expectEqualStrings("members_belong_to_one_org", fk.name);
    try testing.expectEqual(@as(usize, 1), fk.columns.len);
}

test "no delete behaviour written is no clause, rather than a guess at one" {
    const Post = struct {
        pub const nilo_table = .{
            .name = "posts",
            .key = .id,
            .references = .{ .org_id = .{ Org, .id } },
        };
        id: i64,
        org_id: i64,
    };
    const desc = comptime descOf(Pg, Post);
    try testing.expectEqual(OnDelete.no_action, desc.references[0].on_delete);
    try testing.expectEqualStrings("", desc.references[0].on_delete.clause());
}

test "a renamed column carries the name the database still has" {
    const Renamed = struct {
        pub const nilo_table = .{
            .name = "users",
            .key = .id,
            .was = .{ .email = "e_mail" },
        };
        id: i64,
        email: []const u8,
    };
    const desc = comptime descOf(Pg, Renamed);
    try testing.expectEqual(@as(usize, 1), desc.renames.len);
    try testing.expectEqualStrings("e_mail", desc.renames[0].from);
    try testing.expectEqualStrings("email", desc.renames[0].to);
}

test "a Row that says nothing about its table describes one with nothing on it" {
    const Plain = struct {
        pub const nilo_table = .{ .name = "plain", .key = .id };
        id: i64,
        label: []const u8,
    };
    const desc = comptime descOf(Pg, Plain);
    try testing.expectEqual(@as(usize, 0), desc.uniques.len);
    try testing.expectEqual(@as(usize, 0), desc.indexes.len);
    try testing.expectEqual(@as(usize, 0), desc.references.len);
    try testing.expectEqual(@as(usize, 0), desc.renames.len);
    try testing.expectEqual(@as(usize, 2), desc.columns.len);
}

test "a narrower Row describes the table it borrows, not a table of its own" {
    // The marker's words live on the Row that names the table, and a borrowing
    // Row's marker is a `type` — so there is nowhere to write them and nothing
    // to refuse. The language holds the rule.
    const UserCard = struct {
        pub const nilo_table = User;
        id: i64,
        email: core.Str,
    };
    const desc = comptime descOf(Pg, UserCard);
    try testing.expectEqualStrings("users", desc.table);
    try testing.expectEqual(@as(usize, 6), desc.columns.len);
    try testing.expectEqual(@as(usize, 2), desc.uniques.len);
}

// -- the words that live inside one Row (ADR 0221) ------------------------

const Priority = enum { urgent, high, normal, low };

/// An enum that named the database type it goes in. Its words are the
/// database's, added with `ALTER TYPE`, so nilo writes no check for it.
const Declared = enum {
    admin,
    member,

    pub const nilo_column = "user_role";
};

const WorkItem = struct {
    pub const nilo_table = .{
        .name = "work_items",
        .key = .id,
        .default = .{
            .created_at = .now,
            .priority = .normal,
            .position = 0,
            .is_active = true,
            .title = "untitled",
        },
        .unique = .{
            .{
                .columns = .{ .org_id, .number },
                .name = "work_items_number_is_unique_per_board",
            },
        },
        .index = .{
            .{ .columns = .{.assignee_id}, .where = .{ .assignee_id = .{ .ne = null } } },
            .{
                .columns = .{ .org_id, .{ .created_at = .desc } },
                .name = "work_items_board_newest_first",
            },
            .{
                .columns = .{.org_id},
                .where = .{ .priority = .urgent, .archived_at = null },
                .name = "work_items_urgent_and_open",
            },
        },
    };

    id: types.Uuid,
    org_id: i64,
    number: i64,
    title: []const u8,
    priority: Priority,
    position: i32,
    is_active: bool,
    assignee_id: ?i64,
    archived_at: ?types.Timestamp,
    created_at: types.Timestamp,
};

test "a column says what the database writes when an insert leaves it out" {
    const desc = comptime descOf(Pg, WorkItem);
    try testing.expectEqualStrings("now()", desc.column("created_at").?.default.?);
    try testing.expectEqualStrings("'normal'", desc.column("priority").?.default.?);
    try testing.expectEqualStrings("0", desc.column("position").?.default.?);
    try testing.expectEqualStrings("TRUE", desc.column("is_active").?.default.?);
    try testing.expectEqualStrings("'untitled'", desc.column("title").?.default.?);
    // A column the marker said nothing about gets the database's own answer.
    try testing.expectEqual(@as(?[]const u8, null), desc.column("number").?.default);
}

test "the same default is spelled by the database it is for" {
    // `now()` is one word on Postgres and an expression on SQLite, because a
    // Timestamp there is microseconds in an INTEGER column (ADR 0136). A
    // literal is the same text on both.
    const lite = comptime descOf(Lite, WorkItem);
    try testing.expectEqualStrings(Lite.now_default, lite.column("created_at").?.default.?);
    try testing.expectEqualStrings("'normal'", lite.column("priority").?.default.?);
    try testing.expectEqualStrings("TRUE", lite.column("is_active").?.default.?);
}

test "a column the Row reads as an enum carries the words it may hold" {
    const desc = comptime descOf(Pg, WorkItem);
    const priority = desc.column("priority").?;
    try testing.expectEqualStrings("text", priority.sql_type);
    try testing.expectEqual(@as(usize, 4), priority.values.len);
    try testing.expectEqualStrings("urgent", priority.values[0]);
    try testing.expectEqualStrings("low", priority.values[3]);
    // In declaration order, which is the order the CHECK lists them and the
    // order the snapshot compares.
    try testing.expectEqualStrings("high", priority.values[1]);

    // Every other column has none, so nothing else grows a constraint.
    try testing.expectEqual(@as(usize, 0), desc.column("title").?.values.len);
    try testing.expectEqual(@as(usize, 0), desc.column("created_at").?.values.len);
}

test "an enum that named its own database type keeps its words out of nilo's hands" {
    const Staff = struct {
        pub const nilo_table = .{ .name = "staff", .key = .id };
        id: i64,
        role: Declared,
    };
    const desc = comptime descOf(Pg, Staff);
    try testing.expectEqualStrings("user_role", desc.column("role").?.sql_type);
    try testing.expectEqual(@as(usize, 0), desc.column("role").?.values.len);
}

test "a partial index carries its predicate, and an ordered one its direction" {
    const desc = comptime descOf(Pg, WorkItem);
    try testing.expectEqual(@as(usize, 3), desc.indexes.len);

    try testing.expectEqualStrings("\"assignee_id\" IS NOT NULL", desc.indexes[0].where);
    try testing.expectEqual(@as(usize, 0), desc.indexes[0].descending.len);

    try testing.expectEqualStrings("", desc.indexes[1].where);
    try testing.expectEqual(@as(usize, 1), desc.indexes[1].descending.len);
    try testing.expectEqualStrings("created_at", desc.indexes[1].descending[0]);
    // The column is still in the list in the order it was written; the
    // direction is a second list beside it.
    try testing.expectEqualStrings("org_id", desc.indexes[1].columns[0]);
    try testing.expectEqualStrings("created_at", desc.indexes[1].columns[1]);

    // A literal of the column's own type, and a null, ANDed.
    try testing.expectEqualStrings(
        "\"priority\" = 'urgent' AND \"archived_at\" IS NULL",
        desc.indexes[2].where,
    );
}

test "a constraint keeps the name it was given, because the name is the error message" {
    const desc = comptime descOf(Pg, WorkItem);
    // Postgres reports a violation by constraint name and nothing else, so
    // this sentence is what a support engineer sees.
    try testing.expectEqualStrings("work_items_number_is_unique_per_board", desc.uniques[0].name);
    try testing.expectEqualStrings("work_items_board_newest_first", desc.indexes[1].name);
    // And an entry with no `.name` is derived the way it always was.
    try testing.expectEqualStrings("work_items_assignee_id_idx", desc.indexes[0].name);
}

test "a schema-qualified table keeps the schema out of its constraint names" {
    const Audit = struct {
        pub const nilo_table = .{
            .name = "app.audit",
            .key = .id,
            .index = .{.at},
        };
        id: i64,
        at: types.Timestamp,
    };
    const desc = comptime descOf(Pg, Audit);
    try testing.expectEqualStrings("app", desc.schema.?);
    try testing.expectEqualStrings("audit", desc.table);
    try testing.expectEqualStrings("audit_at_idx", desc.indexes[0].name);
}
