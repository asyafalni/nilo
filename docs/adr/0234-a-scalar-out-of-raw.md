# 0234 — a scalar out of `raw`

**Status:** accepted
**Extends:** [ADR 0155](./0155-a-row-that-owns-no-table.md)
and [ADR 0179](./0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md).

## Context

`db.raw(T, …)` took a Row. A `SELECT name FROM pragma_table_info(…)` answers
one text column, and reading it meant a one-field struct carrying
`pub const nilo_table = .projection;` — a marker that is right for a struct
that is not a table, and for one column is ceremony. fdm's first attempt
without it was a compile error pointing at the marker rather than at why a
projection needs one.

`count` and `exists` already read one value out of one row with no Row and
no marker, through `only`. What was missing was the same for many rows, and
for the caller's own statement.

## Decision

**`db.raw` and `db.rawOne` — and `tx.raw`, `tx.rawOne` — take a column
type as well as a Row.** `[]const u8`, `i64`, `?bool`, a `Str`: anything
`readable` says a column can be, or an optional of one. Column one of every
row, as `[]T`; `rawOne` is the same with the unwrap done.

```zig
const names = try db.raw([]const u8, run, "SELECT name FROM pragma_table_info('downloads')", .{});
const n = try db.rawOne(i64, run, "SELECT count(*) FROM downloads", .{});
```

The value goes through the same `readColumn` a Row's field does, so a
`[]const u8` is kept into the arena and a `Str` is the Scope's, and the
same funnel — the Db, the watcher, the drain. What is left out is the
marker: there is no struct to carry one, and the question it answers —
which table is this — has no answer for a catalogue query.

**The list is still counted while compiling.** A `SELECT id, email` into
`[]const u8` is one column nobody reads, and `rawcheck.assertOne` refuses it
the way `assertList` refuses a short list: *the statement handed to `db.raw`
selects 2 columns, and `[]const u8` is one value.* One new refusal,
`raw_scalar_with_two_columns`.

A struct carrying `nilo_table` is a Row whatever else it is. A list column
is not a scalar here: `db.raw([]i64, …)` would read as a slice of rows,
which is what the answer already is.

## Alternatives rejected

**A separate name — `db.column`, `db.values`.** One more function to find
for a thing that reads as `raw` with a different first argument. The
argument's type is the whole of the difference, and Zig can read it.

**Allow a struct with one field and no marker.** It would make a struct
that is *almost* a Row silently fillable, which is the ambiguity the marker
was added to remove ([ADR 0155](./0155-a-row-that-owns-no-table.md)).

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | the same as a Row's: one for the list, plus whatever the column type keeps |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 — a comptime branch |
| Binary size | not measured separately; one `fillScalar` per Db type, instantiated only where a scalar `raw` is written |

One refusal added to `sql_refusals`. Tested on SQLite in `sql/db.zig` — a
slice, an integer, a `Str`, an optional, `rawOne` with and without a match,
and inside a transaction — and on Postgres in `sql/live.zig`, off
`information_schema.columns`.
