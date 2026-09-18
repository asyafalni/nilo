# 0253 — a schema is one value, and the tool owns the order

**Status:** accepted
**Extends:** [ADR 0153](./0153-a-migration-is-a-diff-against-a-snapshot.md),
whose desired half gains three lists beside the tables, and
[ADR 0226](./0226-the-marker-has-a-word-the-database-checks.md), whose
name-and-hash record now holds a function and a view as well as a check.
**Applies:** [ADR 0222](./0222-a-foreign-key-is-columns-and-a-table-name.md).
**Breaks:** every call that took `&.{ Row, Row }`.

## Context

`.check` and `.trigger` hang off a table and ship. A function, a view and an
extension hang off a schema, and the only place to put one was a version
file's `before` slot — which works, and which means a `CREATE OR REPLACE
FUNCTION` is a hand-written step that no diff owns: change the body and
nothing notices, drop the function and nothing drops it. A 59-table port
wanted the shape written down in the roadmap, with `@embedFile` on each
text, and the roadmap held it at *waiting on a design* for one sentence:
`sql.Schema` would replace the `&.{ Row, Row }` list that `cli.Tool`,
`db.checking` and `migrate.tablesOf` all take, so either it is a second
spelling beside the list — two ways to say one thing — or it is the only
spelling, which is a break. That choice is this ADR.

## Decision

**`sql.Schema` is the only spelling.** Every call that took a list of Rows
takes the one value:

```zig
pub const schema = sql.Schema{
    .extensions = &.{"pgcrypto"},
    .functions = &.{
        .{ .name = "set_updated_at", .body = @embedFile("sql/set_updated_at.sql") },
    },
    .tables = &.{ Org, User, Post },
    .views = &.{
        .{ .name = "sku_catalogue", .body = @embedFile("sql/sku_catalogue.sql") },
    },
};

db.checking(schema);
const Tool = sql.cli.Tool(Db, schema);
try sql.migrate.createMissing(&db, &run, schema);
```

A program with tables and nothing else writes `.{ .tables = &.{ … } }`, which
is the old list with seven characters in front of it. The break is accepted
because the alternative is the thing ADR 0222 built the single list to
prevent: two spellings of "what this program's database is" are two lists
that can disagree, and the whole reason the list is one value is that the
tool, the startup check and the boot cannot then be given different ones.

**The tool owns the order.** Extensions, functions, tables by reference, each
table's indexes and triggers, then views — settled in `createMissing` and in
the plan, and nothing the caller writes decides it. The diff has the same
shape at both ends: a stale or moved view is dropped *first*, before any
table moves, because a view that reads a column about to go is what makes
`DROP COLUMN` refuse; and a new or moved view is made *last*, after every
table is in its final shape. A function nobody names any more is dropped
after the tables, whose triggers were what named it; an extension last of
all.

**Three shapes are held at compile time**, because each is a failure that
would otherwise arrive at apply:

- A **function is the whole statement, and it opens `CREATE OR REPLACE
  FUNCTION <name>`.** The signature — arguments, return type, language — is
  part of the definition and nilo cannot compose it, so the text is the
  caller's; what nilo holds it to is the head, because that is what makes
  applying it twice applying it once and what lets a moved body be one step.
  A plain `CREATE FUNCTION` is a Refusal naming what the text opens with.
- A **view is the `SELECT`**, and nilo writes `CREATE VIEW "name" AS` — the
  reason a trigger is two words (ADR 0226): the name is the thing the schema
  already knows, and a second copy stops matching the day it is renamed. A
  body that opens `CREATE` is a Refusal.
- **SQLite refuses `.extensions` and `.functions`.** A SQLite function is a
  callback registered on the connection and an extension is a shared library
  loaded into it; neither is a statement, so a list of either is text the
  database cannot read. Views it has, with `IF NOT EXISTS`.

**The snapshot records an extension by name and a function or a view as a
name and a hash**, the way it records a check. The three fields default to
empty, so a snapshot written before they existed reads as one with none and
`generate` on an old repository writes a plan of nothing. `std.zon` omits a
default, so a program with tables only writes the file it wrote before.

`Schema.Text` is `table.NamedText`, the same struct `.check` and `.trigger`
compile to — one type for every named text, so the hash is computed in one
place and a view is not a second kind of thing to keep in step.

## What it costs

Against ADR 0018's axes, and all of it at compile time or in the tool:

- **Allocations per request:** none. Nothing here runs on a request.
- **Memory per idle connection:** unchanged.
- **Compile time:** `assertSchema` walks the three lists once, from
  `orderOf`, where every Row is already in one list. A function head is a
  four-word case-insensitive compare.
- **Binary size:** the four `ddl` helpers and the schema branches of `plan`,
  linked only by a program that names them. A `createMissing` with no
  extensions, functions or views loops over two empty comptime lists, which
  the compiler folds away.

## Alternatives

**A second spelling beside the list.** `cli.Tool(Db, Rows)` and
`cli.Tool(Db, schema)` both accepted, through `anytype`. Rejected as the
roadmap said: two ways to say one thing, and the way to say it wrong is to
hand the tool the schema and the check the list. Seven characters is the
price of one spelling.

**The roadmap's literal, `.functions = .{ .set_updated_at = @embedFile(…) }`.**
The field name as the object's name reads better and is what the marker's
`.check` does. A struct field cannot be `anytype`, so a `Schema` taking that
literal would have to be a function of it — a different type per program,
which cannot be declared `pub const schema: sql.Schema` and cannot be named
in a refusal. `.{ .name, .body }` is one type, and `NamedText` already
existed.

**Functions as a body with nilo composing the head**, the way a view is.
Would need the arguments, the return type and the language as fields, which
is a second grammar for `CREATE FUNCTION`, and the one thing the marker's
grammars refuse to be is a second copy of SQL's.

**`CREATE OR REPLACE VIEW` for a moved view.** One statement rather than
two, and Postgres refuses it when a column went away or was renamed, which
is the common reason a view moves. A drop and a create is always right, and
the diff already writes pairs for a check and a trigger.

**Sending the extension and function statements on SQLite and letting it
fail.** The failure would arrive at boot, from `createMissing`, in a program
that compiled — the shape every Refusal here exists to prevent.

## Consequences

- `sql.Schema`, `migrate.Desired`, `migrate.desiredOf`, `migrate.leadingOf`,
  `migrate.trailingOf`; `orderOf`, `tablesOf`, `missingOf`, `createMissing`,
  `addMissingColumns`, `db.checking` and `cli.Tool` take a `Schema`; `plan`,
  `snapshotOf` and `migrations.generate`/`check` take a `Desired`.
- `Kind` gains `create_extension`, `drop_extension`, `create_function`,
  `drop_function`, `create_view`, `drop_view`.
- `snapshot.Doc` gains `extensions`, `functions`, `views`, each defaulted.
- `Dialect` gains `has_extensions`, `has_functions`, `view_repeatable_head`.
- Four refusals under `sql/refusals/schema_*`; `refusals-sql` is 144.
- `CHANGELOG.md` says what to change under `### Breaking`; the roadmap loses
  the entry.
