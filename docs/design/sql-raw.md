# Raw statements

**`db.raw` is how you go beyond one table with filtering conditions (a join, an aggregate, a window function) while keeping the arena, the `Str` rule and automatic row filling. Its columns are counted and named while compiling, and their types and outer-join NULLs are checked against the Row the first time it runs.**

**Guide:** [Past one table](../guide/sql/raw.md) · **Reference:** [Queries](../reference/sql.md#queries), [A Row that owns no table](../reference/sql.md#projection-a-row-with-no-table)

The code is `sql/db.zig` (`raw`, `rawOne`, `rawExactlyOne`, `rawOrdered`, `rawPage`, `rawPageOrdered`, `compose`, `composed`, `composedOne`, and their `Tx` equivalents; `vetRaw`), `sql/rawcheck.zig` (everything checked while compiling), `sql/schema.zig` (`readingsOf` and `fit`, the first-run comparison), `sql/plan.zig` (which columns a Postgres plan's outer joins make NULL) and `sql/composed.zig` (`Composed`, built only from pieces that cannot carry a string).

## Overview

```
  comptime SQL text                    run-time pieces (sql.Composed)
  (raw, rawOne, rawExactlyOne,           .text(comptime literal)
   rawOrdered, rawPage, and Tx)          .ident(name)   -> checked, quoted
        │                                .param(n)      -> dialect's $n / ?n
        │  rawcheck, while compiling:          │
        │  column count vs. the Row,           │  checkComposed, at run time:
        │  a text column not cast,             │  dialect match, param count
        │  $n respelled for the dialect        │  against the value tuple
        ▼                                       ▼
  db.raw / rawOne / rawExactlyOne / rawPage    db.composed / composedOne
        │                                       │
        └───────────────────┬───────────────────┘
                             ▼
              fill(): same Str rule, same arena,
              same run-time width guard (ADR 106)
                             │
             Row  │  a scalar (ADR 125)  │  Page(Row) (ADR 205)
```

`db.exec` is outside this picture: its text is read at run time and sent exactly as written, for DDL and `PRAGMA` calls that have no Row to check against.

## Rules

1. **A `SELECT` list shorter than the Row is an error, not a crash.** Before reading any column, `fill` compares the Wire's `width(rows)` with `columnsOf(Row).len`; if it is short, it returns `error.QueryFailed` naming both numbers. The check runs after the first row is fetched, because SQLite reports zero columns before a statement has been stepped. [ADR 106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md)
2. **A longer list is not an error.** `SELECT *` into a narrower Row is a normal thing to write, and the first N columns are exactly what it means. [ADR 106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md)
3. **A raw parameter is converted the same way a Row's column is.** `rawValuesOf` passes each tuple field through the same `forWire` a typed statement uses, so a `Uuid` binds as sixteen bytes and a `[]const Str` list binds like a list column, with nothing allocated for a field that needs no conversion. [ADR 116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)
4. **A raw statement cannot cast a column it did not write.** `rawcheck` looks at what each column in the `SELECT` list *is*, and rejects a bare column, or a `*`, where the matching field is a text column (`Decimal`, `Interval`, an `AsText` type): those are the two forms that cannot carry the `::text` cast nilo adds to every statement it writes itself. Comments and a leading `DISTINCT`, `DISTINCT ON (…)` or `ALL` are taken off first, since they leave the column bare. Any expression, including a correct cast, passes without being examined. [ADR 124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md)
5. **A Row can declare that it owns no table.** `pub const nilo_table = .projection;` marks a shape that is not a table, for a join, a rollup, or a search across several tables. `db.raw`, `tx.raw` and `db.composed` fill one. Everything that writes its own `FROM` (`select`, `insert`, `db.checking`, migrations) rejects it by name, all through one function, `row.ownerOf`. [ADR 125](../adr/125-a-row-that-owns-no-table.md)
6. **A single column needs no Row.** `db.raw`, `db.rawOne`, `tx.raw` and `tx.rawOne` accept a column type instead of a Row (`[]const u8`, `i64`, a `Str`, or an optional of one), read through the same `readColumn` a Row's field uses. A two-column list read into a scalar is rejected (`assertOne`), just as a short list is (`assertList`). [ADR 125](../adr/125-a-row-that-owns-no-table.md)
7. **A statement filtering by a key returns `!?Row`, without adding a `LIMIT`.** `rawOne` unwraps the result the way `db.one` does for a typed select; it is not a cheaper statement. `raw` did not write the `WHERE`, so there is nowhere honest to put a `LIMIT 1`, and a condition matching several rows still pays for all of them. `updateReturningOne` and `deleteReturningOne` reject a `.where` that does not pin the key or a unique with `=`, because writing every matching row and returning one would hide the rest. [ADR 146](../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)
8. **A statement that always returns a row returns a Row, not an optional.** `rawExactlyOne` is for an aggregate without `GROUP BY`, a `RETURNING` on a keyed write, or a `SELECT` of constants. It returns the Row, or `error.QueryFailed` if no row came back, never a zero-filled default that would hide the problem. [ADR 206](../adr/206-a-statement-that-always-answers-answers-a-row.md)
9. **A raw `$n` is rewritten for the dialect, and counted, while compiling.** `rawcheck.spelled` rewrites `$1`, `$2`, … into the Dialect's own form (unchanged on Postgres, `?1`, `?2` on SQLite) in every call that takes compile-time text. `assertParams` rejects a gap in the numbering (`$1, $3` with three values), or a tuple whose length is not the highest `$n`; SQLite's own `?n` is held the same way. `db.exec`'s run-time text is sent as written and gets neither check. [ADR 204](../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)
10. **A raw statement can return its own total.** `db.rawPage` and `tx.rawPage` add `count(*) OVER ()` after the Row's own columns (checked while compiling as the Row's width plus one) and return the same `Page(Row)` a typed `db.page` does. `rawPageOrdered` is the same, with the request's `{order}` in it. A page that comes back empty past its last row is sent again from row one to get its total, which is why the statement's own `OFFSET` has to be a single placeholder. [ADR 205](../adr/205-a-raw-statement-can-carry-its-total.md)
11. **A statement built at run time is made only from pieces that cannot carry a string.** `Composed.text` takes `comptime piece: []const u8`, so a run-time slice does not compile. `.ident` checks a run-time name against identifier syntax and quotes it, rejecting anything else. `.param(n)` writes the dialect's own placeholder. No method accepts a run-time string as SQL. [ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)
12. **`db.composed` checks at run time what could not be checked while compiling.** A `Composed` built for the other dialect is `error.WrongDialect`; a value tuple that does not match the highest `param` written is `error.ParamCountMismatch`. It runs unnamed, giving up the plan name and the compile-time column count that `raw` keeps. [ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)
13. **The first time a raw statement runs, the database is asked what it returns, and the answer is checked against the Row.** The Wire's `describe` gives each column's type (on Postgres, the description's OIDs, a domain by its base type, and a string or enum marked as text; on SQLite, the declared type's affinity) and, on Postgres, whether the generic plan shows the column coming from the side of an outer join that may find nothing. Types are checked with `Dialect.reads`, which requires exact numbers where `accepts` lets an `i32` stand for an `int8`. A mismatch is `error.QueryFailed` in a test binary and a warning in a server. A flag per statement, Row and call makes every later call one atomic load. It does not run inside a transaction, or for `db.composed`. [ADR 233](../adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)

## Decisions

| ADR | What it decides |
|---|---|
| [106](../adr/106-a-select-list-shorter-than-the-row-is-refused.md) | A short `SELECT` list is a run-time error instead of an out-of-range read |
| [116](../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md) | A raw parameter goes through the same conversion as a column's value |
| [124](../adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md) | A bare column or `*` matched to a text column is rejected while compiling |
| [125](../adr/125-a-row-that-owns-no-table.md) | `.projection` for a Row with no table, and a column type instead of a Row |
| [146](../adr/146-a-statement-with-a-key-in-it-has-a-single-row-answer.md) | `rawOne`, which unwraps without adding a `LIMIT`; `updateReturningOne` and `deleteReturningOne`, which change the one row the condition pins |
| [204](../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md) | `$n` rewritten and counted for the dialect, while compiling |
| [205](../adr/205-a-raw-statement-can-carry-its-total.md) | `rawPage` and `rawPageOrdered`: a raw statement that returns a `Page(Row)`, with its total even past the last row |
| [206](../adr/206-a-statement-that-always-answers-answers-a-row.md) | `rawExactlyOne` for a statement that cannot honestly return no rows |
| [208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md) | `Composed`: a run-time statement built only from literal text, checked names and parameters |
| [233](../adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md) | A raw statement's types and outer-join NULLs are checked against its Row the first time it runs: a failure in a test, a warning in a server |

Related topics: what `db.raw` goes beyond (one table and filtering conditions) is [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md) (sql-query); why a raw statement is prepared and named at all is [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md) (sql-runtime); the page a typed `db.page` returns, which `rawPage` matches, is [ADR 150](../adr/150-a-page-knows-what-it-left-out.md) (sql-query); the column types a raw or composed statement reads and binds are covered by sql-types' ADRs, including [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md).

## Open questions

- **Checking a raw statement inside a transaction against its Row.** `describe` takes a connection of its own, and a transaction holding SQLite's writer or a small pool's last connection would wait on itself. Running it on the transaction's connection needs a savepoint around the prepare, so a rejection cannot abort the caller's transaction. [ADR 233](../adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md) leaves this for a caller whose raw statements run only inside transactions.
- **Streaming a raw statement with `db.stream`.** `db.stream` builds its own `SELECT`, so a projection has nothing to stream from today. [ADR 125](../adr/125-a-row-that-owns-no-table.md) calls this a gap, not a decision, and does not rule it out.
- **Letting `Composed` understand enough SQL to add a builder's conditions or joins.** Considered and declined in [ADR 208](../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md), and not on the roadmap: this module's scope is one table with filtering conditions, and a query engine is deliberately beyond it.
