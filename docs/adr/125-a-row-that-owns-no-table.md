# A Row that owns no table, and a scalar that owns none either

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)

## Context

`db.raw` is the way past one table: joins, aggregates, `UNION ALL`, window functions. The Row it fills is therefore often a shape no table has, and it was still made to name one:

```
nilo: activity.rows.Event is not a Row — it has no `nilo_table`.
  Add `pub const nilo_table = .{ .name = "<table>" };` to it, or `= <OtherRow>`
  to read the same table as another Row.
```

Six of one port's twelve Rows were projections: a `UNION ALL` over two tables, a `GROUP BY` rollup, a search across seven tables, three cards each joining four. Every one named a table it did not represent so that `assertRow` would pass, with a comment above it saying the name was decoration. That is a lie in the source with a note attached, the worst kind, and the note is only in the source, so nothing else in the program knows it.

A second, narrower gap turned up beside it. `SELECT name FROM pragma_table_info(…)` answers one text column, and reading it meant a one-field struct carrying `pub const nilo_table = .projection;`: a marker that is right for a struct that is not a table, and for one column is ceremony. A caller's first attempt without one was a compile error pointing at the marker rather than at why a projection needs one. `count` and `exists` already read one value out of one row with no Row and no marker at all, through `only`; what was missing was the same for many rows, and for the caller's own statement.

## Decision

### A Row may say it owns no table

```zig
const TimelineRow = struct {
    pub const nilo_table = .projection;

    at: sql.Timestamp,
    kind: Str,
};
```

`db.raw` and `tx.raw` fill one. Everything that writes its own SQL refuses it by name, because everything that writes its own SQL has to put a table after `FROM`: `select`, `find`, `count`, `insert`, `update`, `delete`, `db.checking`, and the migration tool. **One funnel, and it was already there.** `row.ownerOf` is what every question about a table goes through, `tableOf`, `keyOf`, `qualifiedOf`, and all of `table.zig`, so the refusal is one branch at the top of it rather than a check in nine places.

**One word, `.projection`, rather than `.view`, `.derived` or `.query`**, so a near miss is a typo refused with a sentence naming the one that exists, rather than a Row nobody has implemented yet. `.projection` rather than `.view`, because a database view *is* a table as far as every statement here is concerned, and nilo would be right to `SELECT` from it and `db.checking` it. What this word means is the opposite: there is no relation of any kind behind this shape.

**The refusal gets sharper, not looser.** Today, with a projection spelling a table's name to get past `assertRow`, `db.checking(&.{TimelineRow})` compiles and goes looking for a column on a table the Row was never about, and answers with a mismatch nobody can act on. With `.projection` that call is a compile error naming the Row instead.

### A single column needs no Row at all

**`db.raw`, `db.rawOne`, `tx.raw` and `tx.rawOne` take a column type as well as a Row.** `[]const u8`, `i64`, `?bool`, a `Str`: anything `readable` says a column can be, or an optional of one. Column one of every row, as `[]T`; `rawOne` is the same with the unwrap done.

```zig
const names = try db.raw([]const u8, run, "SELECT name FROM pragma_table_info('downloads')", .{});
const n = try db.rawOne(i64, run, "SELECT count(*) FROM downloads", .{});
```

The value goes through the same `readColumn` a Row's field does, so a `[]const u8` is kept into the arena and a `Str` is the Scope's, through the same funnel: the Db, the watcher, the drain. What is left out is the marker: there is no struct to carry one, and the question it answers, which table is this, has no answer for a catalogue query.

**The list is still counted while compiling.** A `SELECT id, email` into `[]const u8` is one column nobody reads, and `rawcheck.assertOne` refuses it the way `assertList` refuses a short list: the statement handed to `db.raw` selects two columns, and `[]const u8` is one value. This is the refusal `raw_scalar_with_two_columns` catches. A struct carrying `nilo_table` is a Row whatever else it is, and a list column is not a scalar here: `db.raw([]i64, …)` reads as a slice of rows, which is what the answer already is.

## What was rejected

**No marker at all: let `db.raw` take any struct.** The smallest change, and it gives up the thing the marker buys, that a plain struct handed to `select` is refused by name rather than by a missing field three frames in. It would also make `db.raw` the one call in the module with no opinion about what it fills.

**A wrapper type, `Projection(T)`.** A second type to declare and unwrap at every call site, to say something the Row can say about itself in one line. The markers in this repository are declarations on the caller's own type precisely so that nothing has to be wrapped ([ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)).

**Inferring a projection from the absence of a table name.** `pub const nilo_table = .{}` is a marker with a typo in it far more often than it is a projection.

**A separate name for the scalar path, `db.column`, `db.values`.** One more function to find for a thing that reads as `raw` with a different first argument. The argument's type is the whole of the difference, and Zig can read it.

**Allow a struct with one field and no marker, for the scalar case.** It would make a struct that is almost a Row silently fillable, which is the ambiguity the marker was added to remove.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | the same as a Row's: one for the list, plus whatever the column type keeps. |
| Memory per idle connection | 0. |
| Throughput and p99 | 0, a comptime branch either way. |
| Binary size | not measured separately for the scalar path; one `fillScalar` per Db type, instantiated only where a scalar `raw` is written. |

Two refusal files and two rows in `sql_refusals` for `.projection`; one more, `raw_scalar_with_two_columns`, for the scalar path. Tested on SQLite in `sql/db.zig`, a slice, an integer, a `Str`, an optional, `rawOne` with and without a match, and inside a transaction, and on Postgres in `sql/live.zig`, off `information_schema.columns`.

## Consequences

- `row.isProjection` is public; `ownerOf` refuses one; `assertRow` still passes it, which is what lets `db.raw` fill it.
- Six Rows in the port that reported this stop naming a table they are not.
- `db.stream` refuses a projection too, and that is a gap rather than a decision: it builds its own `SELECT`, so there is nothing for it to stream from. A raw stream would take one, and nothing here rules that out.
- A struct carrying `nilo_table` is a Row whatever else it is, so the scalar path and the projection path never compete for the same call site: `scalarColumn` is checked before `rawcheck.assertList` runs.
