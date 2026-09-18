# 0233 — a column a shipped table has not got

**Status:** accepted
**Extends:** [ADR 0153](./0153-a-migration-is-a-diff-against-a-snapshot.md).
The step between `createMissing` and `apply`, for the program that wants
neither a ledger nor a version file.

## Context

`createMissing` creates what is not there and, by design, alters nothing.
`apply` wants versions and steps, a ledger table, and the `db generate`
workflow around them. Between the two there was nothing, and the program
that lives there is the commonest SQLite program of all: a single-file
tool that added a field to a Row after its first release.

fdm added `headers`, `named` and `sha256` to `downloads`. Its
`addMissingColumns` read `pragma_table_info` and ran three `ALTER TABLE`
strings written by hand, with the types copied from what `createMissing`
emits. If this module's type mapping moves, a file made through
`createMissing` and a file made through that path differ, and nothing says
so. `migrate.apply` would have been the honest tool, and a CLI's own SQLite
file does not want a ledger and version files for three columns.

Everything needed was already here. `tableOf` has the `Desc`; `ddl.addColumn`
writes the statement from it; `db.checkSchema` already asks the database
for a table's columns through the Dialect's `introspect` query, on both
Wires. What was missing was the twenty lines that put them together.

## Decision

**`sql.migrate.addMissingColumns(db, scope, &.{ Rows… })`: one
`ALTER TABLE … ADD COLUMN` per field a table lacks, from the same `Desc`
the create reads, in one transaction, and how many were added.**

```zig
try sql.migrate.createMissing(&db, &run, &.{ Download, Segment });
_ = try sql.migrate.addMissingColumns(&db, &run, &.{ Download, Segment });
```

The live columns come from `db.liveColumns`, which is `checkSchema`'s
question asked from outside `db.zig` — `pragma_table_info` on SQLite,
`pg_catalog` on Postgres, with the schema qualification each already does.
A column the Row has and the table has not is `ddl.addColumn`, exactly the
statement `plan` would have written for the same diff.

**A required column with no default is refused, `error.NeedsBackfill`, and
nothing is sent.** SQLite refuses that `ALTER` outright; Postgres refuses
it on a table with rows. On neither is it a statement this can send and
mean. The log carries the statement it would have sent and the three ways
out: a `.default` in the marker, an optional field, or a version. The
transaction is what makes "nothing is sent" true when the refused column is
the second of three.

**A table that is not there is skipped.** It is `createMissing`'s, and
calling that first is the order the two lines show.

Nothing else is touched. A column the table has that the Row does not is
left, a type that moved is left, and `db.checking` is what says so. This
adds and does not alter — the same line `createMissing` draws.

## Alternatives rejected

**Make it a `Step` for `apply` too.** The feedback's second half: one
function, both paths, the same DDL. `plan` already produces the same
`add_column` step from a snapshot, through the same `ddl.addColumn`, so the
DDL is already shared at the layer that matters. A runtime step that reads
the live schema would be a version whose contents depend on the database
it runs against, which is the property the hash chain exists to refuse.

**Emit the `ALTER` for a required column and let the database refuse.** On
Postgres that works on an empty table and fails on a full one, which is a
program that passes in development and fails at the first customer. Saying
it here, with the statement in the log, is one sentence earlier and the
same sentence every time.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none on a request path — this runs at startup, from the Scope it is given |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size | not measured separately; one function and a four-line helper |

Tested on both Wires: `sql/migrate_live.zig` against a SQLite file, and
`sql/live.zig` against Postgres, each widening a two-column table by three,
reading the row that was there back through the widened Row, and asking
`checkSchema` whether the result is the shape it would have accepted from
`createMissing`. The refusal test adds an optional column and a required
one in the same call and checks that neither landed.
