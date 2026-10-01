# The query builder

**A query is a struct of options over a Row, and everything about its shape is decided before the program runs; only the values come from the request.**

**Guide:** [Reading](../guide/sql/reading.md), [Writing](../guide/sql/writing.md) · **Reference:** [Queries](../reference/sql.md#queries), [Conditions](../reference/sql.md#conditions)

The code is `sql/where.zig` (conditions, `sql.given`, `.across`, `.exists`), `sql/ordering.zig` (`sql.Ordering`), `sql/shape.zig` (a parent, children, a group), `sql/statement.zig` (batches, upserts, the compile-time budget) and `sql/dialect.zig` (the SQL each database gets).

## Overview

```
   Row (nilo_table, nilo_aggregate,        .{ .where = …, .order = …,
        .references)                             .limit = … }
        │                                              │
        └───────────────────────┬──────────────────────┘
                                 ▼
                  comptime: the Dialect writes the SQL
                  (table, columns, joins, clause text, all fixed)
                                 ▼
                  runtime: the Wire binds the values, runs it
                                 ▼
                     Row, [Row], Page(Row), Feed(Row) or ?Row back,
                            in the request's Scope
```

Everything after the first arrow is a `const`. The request can only supply a value for a parameter, a sort direction chosen from a fixed set, or which of a fixed set of compile-time checks applies; nothing it sends is ever pasted into the statement.

## Rules

1. **A query's shape is fixed while compiling; only its values are not.** Which table, which columns, which operators and which order are all decided before the binary exists, so what reaches the socket is a constant plus its parameters. [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md)
2. **A query is a struct of options, not a chain of method calls.** `db.select(Row, c, .{ .where = …, .order = …, .limit = … })`. There is no `.where()` returning another type to call `.limit()` on, because when a chain fails, the error shows the whole stack of types instead of a field name. [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md)
3. **An optional value in a condition is a compile error, judged by the type of the value written.** In `.where`, a `?T` is ambiguous between `= $1` and `IS NULL`, so `zig build` rejects it. `.set` and an insert accept one without complaint, because in a write it has only ever meant one thing. [ADR 040](../adr/040-a-condition-holds-a-value-not-a-maybe.md)
4. **`sql.given` removes a condition; it never sends it as null.** When the filter is absent, the whole clause is skipped behind a guard the database optimises away in its own plan. On `.in` and `.not_in` it takes a list: null removes the condition, and an empty list is still an (empty) list. It is not allowed inside `.any`, next to a fixed `.exists` condition, or in the condition of an `UPDATE` or `DELETE`. In an update's `.set`, it keeps the column's current value instead (`COALESCE($n, "column")`), on a column that is not optional. An `UPDATE` or `DELETE` whose condition the request emptied (an empty `.not_in`, or a pattern of empty text) is rejected at run time before it is sent. [ADR 149](../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)
5. **One condition checked against several columns binds its value once.** `.across` joins the same operator over the named columns with OR and binds the value a single time, so a search box costs one placeholder and one plan entry, whichever fields it searches. [ADR 172](../adr/172-one-condition-over-several-columns-is-one-parameter.md)
6. **`.exists` takes the join from whichever Row declares the reference.** The inner Row's column is named with `.on`, the outer Row's with `.via`. Two references, none, or both `.on` and `.via` together are rejected instead of guessed. With no `.where` it asks whether any row points back, and only when the key is the inner Row's. [ADR 175](../adr/175-an-exists-reads-the-reference-from-either-side.md), [ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)
7. **A narrower Row can declare a parent, children, or a grouping, and the call site stays the same.** A field typed as another Row is joined and read into it. A `[]const` field of Rows is read by a second statement and matched to its parent by position, in the order and under the condition `nilo_children` gives. An `i64` field counting the rows that point back is read by a correlated subquery, and a `.max` or `.min` over them is an optional of the column's type, read by the same kind of subquery. `nilo_aggregate` makes the Row one row per group, with conditions split into `WHERE` and `HAVING` by what each refers to, and an entry's own `.where` written as a `FILTER` with its values included. [ADR 218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)
8. **`UNION`, `INTERSECT` and `EXCEPT` over one table are just boolean logic in `WHERE`, not keywords.** `.any` is the OR, an ordinary struct is the AND, and negating a leaf gives the EXCEPT. Over two different Rows, a union is a database view, read like any other table. [ADR 052](../adr/052-a-set-operation-over-one-table-is-a-condition.md)
9. **The database escapes the pattern it is going to match.** `contains`, `starts_with` and `ends_with` build the pattern and escape `%` and `_` inside the statement, so the caller's text is bound unchanged, at no cost. SQLite has no case-sensitive `LIKE`, so `contains` there is a compile error pointing to `icontains`. The one pattern built on nilo's side is `istarts_with` on SQLite, bound whole in the arena, because its planner reads an index range only off a pattern it is handed. [ADR 140](../adr/140-the-database-escapes-the-pattern-it-is-going-to-match.md)
10. **A batch is one array per column, not one placeholder per row.** `db.insertMany` and `db.updateMany` compile to `unnest($1::t[], …)`, two placeholders whatever the batch size. A list column, or an enum without a `nilo_column` name, cannot be batched. [ADR 047](../adr/047-a-batch-is-one-array-per-column.md)
11. **`DO NOTHING` does not ask for a key it does not need.** A pure join table with a composite key and no `id` can still use `insertOrIgnore`, because for the one upsert that writes no `SET`, the part that would name a key is removed while compiling. [ADR 114](../adr/114-do-nothing-has-no-key-to-leave-out.md)
12. **A conflict target is named once, and must be backed by a constraint.** On a managed table it must be the key or a declared `.unique`, and not a case-insensitive unique. `.key` at the call site reuses the tuple already declared on `nilo_table` instead of spelling it out again. `key` as an ordinary column name is only rejected where a conflict target is expected. [ADR 151](../adr/151-a-key-is-named-once.md)
13. **A sort order chosen at run time picks from constants; it never writes SQL.** `sql.Ordering(Row, keys)` builds every possible ORDER BY fragment while compiling; the request picks one by an enum value it parses itself. The statement then runs unnamed, because once its text depends on the request, it is no longer the single fixed text a plan name assumes. Where a `LIMIT` or an `OFFSET` cuts it, it ends in the key the request did not order by, as a written `.order` does. [ADR 165](../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md), [ADR 150](../adr/150-a-page-knows-what-it-left-out.md#a-page-ends-in-the-key)
14. **A page returns its own total in the same statement as its rows.** `db.page` reads `count(*) OVER ()` together with the page, so the count and the rows come from one snapshot, not two queries a write could land between. `.order` and `.limit` are required, and `.lock` is rejected next to a window function. The total costs a pass over every match, so a list that shows no total is `db.feed`: the rows and whether there are more, read as one row past the limit. Its `.after` is a cursor, one row comparison an index seeks on, refused wherever it would skip or repeat a row. [ADR 150](../adr/150-a-page-knows-what-it-left-out.md)
15. **A compile-time walk over a wide Row gets a budget sized for it.** `statement.budget` raises the evaluation quota before every builder, based on the Row's width and the number of values written, so a twenty-column table with seventeen values written compiles where the default quota did not. [ADR 169](../adr/169-a-statement-pays-for-the-width-of-its-row.md)
16. **A column of another table can be a flat field.** `nilo_through` names the reference columns to follow and, last, the column to read. It is joined like a parent and named in `.where` and `.order` like a column, so a response whose contract is flat needs no second struct. `.otherwise` says what a row the path does not reach reads, and `.join = .inner` leaves that row out. [ADR 235](../adr/235-a-column-of-another-table-may-be-read-flat.md)

## Decisions

| ADR | What it decides |
|---|---|
| [036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md) | A query is an options struct compiled against a Row; no method chains, no ORM machinery |
| [040](../adr/040-a-condition-holds-a-value-not-a-maybe.md) | An optional in a condition is a compile error, because it hides a choice between two statements |
| [047](../adr/047-a-batch-is-one-array-per-column.md) | A batch writes one array per column through `unnest`, not a `VALUES` list sized to the call |
| [052](../adr/052-a-set-operation-over-one-table-is-a-condition.md) | `UNION`/`INTERSECT`/`EXCEPT` over one table are conditions; over two Rows, a view |
| [114](../adr/114-do-nothing-has-no-key-to-leave-out.md) | `DO NOTHING` does not ask a join table without a key to name one |
| [140](../adr/140-the-database-escapes-the-pattern-it-is-going-to-match.md) | `contains`/`starts_with`/`ends_with` build and escape the pattern inside the statement, except a prefix on SQLite, bound whole |
| [149](../adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md) | `sql.given` removes a condition instead of sending it as null, and where it cannot be used |
| [150](../adr/150-a-page-knows-what-it-left-out.md) | `db.page` returns rows and total from one statement; `db.feed` returns rows and whether there are more, and reads after a cursor |
| [151](../adr/151-a-key-is-named-once.md) | `.key` reuses the conflict target from `nilo_table` instead of repeating it |
| [165](../adr/165-an-order-chosen-at-run-time-from-a-closed-set.md) | `sql.Ordering` lets a request choose an order from constants fixed while compiling |
| [169](../adr/169-a-statement-pays-for-the-width-of-its-row.md) | The compile-time budget a statement builder gets, sized to its Row |
| [172](../adr/172-one-condition-over-several-columns-is-one-parameter.md) | `.across` binds one value and tests it against several named columns |
| [175](../adr/175-an-exists-reads-the-reference-from-either-side.md) | `.exists` takes its join from either Row's declared reference, named with `.on` or `.via` |
| [218](../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md) | A narrower Row may declare a parent, children, or a grouping, without a `.join` at the call site |
| [235](../adr/235-a-column-of-another-table-may-be-read-flat.md) | `nilo_through` reads a column of another table into a flat field, through a path of references |

Related topics: [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) is the four axes every rule above is measured against; [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) is why a query is a typed call rather than hand-written SQL run through `nilo.blocking`; [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md) (sql-runtime) is what a constant statement gains, and what ADR 165 gives up by writing one that is not constant; [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md) and [ADR 004](../adr/004-http-errors-via-fail-functions.md) (errors) are how `?Row` and `error.AlreadyExists` become HTTP responses; [ADR 055](../adr/055-the-second-dialect-is-the-test-of-the-seam.md) (sql-runtime) is why a Dialect may reject a shape instead of generating the wrong SQL, which `contains` and `.exists` both rely on.

## Open questions

- **Two measurements ADR 036 still owes.** The throughput of `db.select` against hand-written pg.zig, held to ADR 017's 10% limit, and pg.zig's `read_buffer` sizing for the row-heavy queries this module produces. Recorded as owed in [ADR 036](../adr/036-the-shape-of-a-query-is-settled-while-compiling.md).
- **Whether a Row's `jsonStringify` on `Timestamp` and `Uuid` costs enough to matter.** `covers()` sends such types through `std.json` instead of the generated writer, and ADR 036 puts off deciding whether this module may use nilo's JSON writer until `zig build profile` shows it is over the 10% limit.
