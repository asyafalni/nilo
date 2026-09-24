# A statement that always answers answers a Row

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)
**Extends:** [ADR 146](./146-a-statement-with-a-key-in-it-has-a-single-row-answer.md)
(`rawOne` is the unwrap, not a narrower statement),
[ADR 125](./125-a-row-that-owns-no-table.md)

## Context

`rawOne` answers `?Row`, because a statement whose `WHERE` holds a key has
one row or none, and `?Row` is a 404 in the typed layer (ADR 146). A
dashboard is a different statement: `SELECT count(*), sum(paid) FROM bills`
has exactly one row whatever is in the table, and an application with six
of them wrote six `orelse Totals{ .objects = 0, … }` that could never run.
Small, and repeated at every aggregate.

`db.insert` already has the answer for its own case: a `RETURNING` on a
successful insert has one row, none is `error.QueryFailed`, and the answer
is the Row.

## Decision

**`db.rawExactlyOne(Row, c, sql, values)` answers the Row a statement has
by construction, and `error.QueryFailed` when the statement answered with
none.**

The same call as `rawOne` in every other way: comptime text, the list
counted against the Row, a scalar in place of a Row (ADR 125), the values
converted the way a Row's are, and no `LIMIT 1` added. What changes is the
answer, and the name says which statements it is for: an aggregate with no
`GROUP BY`, a `RETURNING` on a keyed write, a `SELECT` of constants.
`tx.rawExactlyOne` is the same inside a transaction.

A statement that can honestly answer with no rows is `rawOne`, and `?Row`
is the truth about it. `error.QueryFailed` rather than a zero-filled Row
for the reason `insert` gives: the statement and the database disagree
about what was asked, and a zero would hide that.

## What was rejected

**Leaving it at `orelse`.** One token per call is cheap, and it is also a
default value somebody has to write for every field, every time, for a
branch that is not reachable; ADR 146 added `rawOne` over three lines
repeated six times, and this is the same argument.

**Making `rawOne` answer `Row` when the statement has no `WHERE`.** Reading
enough SQL to know which statements always answer is parsing SQL, which
`rawcheck` deliberately does not do (ADR 051); a `GROUP BY` with no groups
answers with no rows and has no `WHERE`.

## What it costs

Nothing beyond `rawOne`. No refusal: the wrong statement is a run-time
error the database's own answer decides.

## Consequences

- `sql/db.zig`: `rawExactlyOne` on `Db` and `Tx`.
- `examples/sqlite/` reads its totals with it.
