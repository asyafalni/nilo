# A raw placeholder is spelled for the dialect, and counted

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)
**Extends:** [ADR 051](./051-a-statement-that-is-a-constant-can-be-prepared-once.md)
(the text of a raw statement is read while compiling)
**Applies:** [ADR 055](./055-the-second-dialect-is-the-test-of-the-seam.md)
(a Dialect says how a parameter is spelled)

## Context

Every statement nilo composes spells its parameters through the Dialect:
`$1` on Postgres, `?1` on SQLite. A raw statement is the caller's text, and
the guide has always shown it with `$1`, because the guide was written
against Postgres.

On SQLite `$1` is legal and means something else. A `$AAA` is a *named*
parameter, indexed by the order in which distinct names first appear, and
zqlite binds a tuple by position. So `WHERE ($2 IS NULL OR o.kabupaten = $2)`
with no `$1` in it gave `$2` index one, the first value went into it, and
the statement answered wrong with no error. The same text on Postgres was
right. A SQLite application had to write `?1`, `?2` in every raw statement
and remember not to, and a program moving between the two databases had to
edit its SQL.

A second silent wrong answer sits beside it. A statement naming `$3` and
handed two values is a run-time error on Postgres naming the parameter; on
SQLite a numbered placeholder with nothing bound is NULL, and the statement
runs.

## Decision

**The `$n` in a raw statement are respelled the way the Dialect spells its
`n`th placeholder, while compiling, and their count is held against the
values.**

`rawcheck.spelled(D, sql)` walks the text with the same quote-and-comment
skipping `scan` uses, and where it finds `$` followed by digits at a word
boundary writes `D.placeholder(n)` instead. For a Dialect whose own spelling
is `$n` it is the identity and the text is the same slice; Postgres pays
nothing and nothing about it changes. Every call that takes comptime text
goes through it: `raw`, `rawOne`, `rawExactlyOne`, `rawPage`, `rawOrdered`,
and the `Tx` versions. The plan name a prepared statement is kept under is
the respelled text's.

`rawcheck.assertParams(sql, V, call)` is Postgres's rule said while
compiling: the placeholders are `$1` up to `$n` with no gap, and a tuple of
`n` values binds them. A `$n` used twice is one value. A statement with no
`$n` at all is left alone, so `?1`, a bare `?` and a named struct of values
are still the driver's to read.

`db.exec` takes its text at run time and sends it as written. Its
statements are DDL and `PRAGMA` almost without exception, and rewriting a
run-time string is an allocation on a path that did not ask for one.

## What was rejected

**Binding by name in the SQLite Wire.** `sqlite3_bind_parameter_index(stmt,
"$k")` for each value, falling back to position. It would have covered
`exec` too, and it costs a string search per value per execution, on the
path a prepared statement exists to make cheap. The text is comptime for
every other call, so the work can be done once.

**Refusing `$n` on SQLite.** A refusal would have made the guide's every
raw statement a compile error on the second database, for a difference the
Dialect already knows how to write across.

**Refusing only the non-monotone case.** `$2` appearing before `$1` is what
an `IS NULL` guard looks like, and it is correct SQL. The wrong thing was
the binding, not the order of appearance.

## What it costs

A comptime walk of each raw statement's text, paid once per statement per
compilation, inside the branch quota `scan` already asks for. Nothing at run
time. Two refusals.

## Consequences

- `sql/rawcheck.zig`: `highestParam`, `spelled`, `assertParams`.
- `sql/db.zig`: `rawText`, called by every raw call with comptime text.
- `sql/refusals/raw_with_fewer_values_than_placeholders.zig`.
- The raw guide gains a section on what a parameter may be and what SQLite
  does differently, and the SQLite page says `$n` is one text for both.
