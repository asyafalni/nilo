# 0279 — a raw statement can carry its total

**Status:** accepted
**Extends:** [ADR 0185](./0185-a-page-knows-what-it-left-out.md) (a page is
one statement with `count(*) OVER ()` on it),
[ADR 0148](./0148-a-raw-statement-is-counted-while-compiling.md)

## Context

`db.page` answers the rows and the total in one statement, because two
statements against a table somebody else can write between disagree with
nothing saying so (ADR 0185). It composes the statement, so it is one table
and conditions that filter rows.

Every list screen in an application is a page, and most of them are a join:
the object and the name of whoever owns it, the invoice and its customer.
That is past one table, so it is `raw`, and `raw` had no page. The
application wrote two statements with one `WHERE` pasted into both, which is
the disagreement ADR 0185 closed, reopened at the first join.

## Decision

**`db.rawPage(Row, c, sql, values)` reads the caller's statement as a page:
the Row's columns, and the total from the column after the last of them.**

The statement is the caller's, and so is the window: `count(*) OVER ()` goes
on the end of the `SELECT` list, where `db.page` would have written it. The
list is counted while compiling as the Row's fields and one more, the names
of the Row's own columns are checked as `raw` checks them, and a list
exactly the Row's width is a Refusal that says what to add. The total is
read once per statement from the same `filling` that reads `db.page`'s, so
a statement matching nothing is an empty page and a total of zero. A
`Page(Row)` comes back, the same type `db.page` answers, so a handler that
returns one is described the same way. `tx.rawPage` is the same inside a
transaction.

The `ORDER BY` and the `LIMIT` are the caller's to write, for the reason
`db.page` requires both.

## What was rejected

**Appending the window to the caller's text.** Adding text to a statement
this module did not write is the thing `raw` exists not to do: after a
`UNION ALL` or inside a CTE the window would mean something else, and
`rawOne` declined a `LIMIT 1` on the same grounds (ADR 0179).

**A `nilo_beside`-like field the module fills.** The total is not a field of
a row, it is a fact about the statement, and every row would carry a copy of
it. `Page(Row)` already has the right shape.

**Reading the total from a column named `total`.** A name is a convention,
and the module counts columns by position everywhere else. The position
after the last field is the one place the total can be with no name.

## What it costs

One `i64` read per statement, not per row, which is what `db.page` pays.
One refusal.

## Consequences

- `sql/db.zig`: `rawPage` on `Db` and `Tx`.
- `sql/rawcheck.zig`: `assertPaged`.
- `sql/refusals/raw_page_without_a_total.zig`.
- `examples/sqlite/` lists invoices with it.
