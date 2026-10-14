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

`rawcheck.spelled(D, sql)` reads the text as the tokens every reader in
`rawcheck.zig` shares (one pass; strings, `E'…'` strings, `$$…$$` and
`$tag$…$tag$` bodies, quoted names and nested comments are single tokens), and
where it finds a `$n` token writes `D.placeholder(n)` instead. A `$5` inside
a dollar-quoted body is text and is left alone. Text the tokenizer cannot
finish, an unterminated quote, is sent as written. For a Dialect whose own spelling
is `$n` it is the identity and the text is the same slice; Postgres pays
nothing and nothing about it changes. Every call that takes comptime text
goes through it: `raw`, `rawOne`, `rawExactlyOne`, `rawPage`, `rawOrdered`,
and the `Tx` versions. The plan name a prepared statement is kept under is
the respelled text's.

`rawcheck.assertParams(sql, V, call)` is Postgres's rule said while
compiling: the placeholders are `$1` up to `$n` with **no gap**, and a tuple
of `n` values binds them. `$1, $3` with three values is refused, naming the
number nothing uses; `$1` alone with two values is refused as before. A `$n`
used twice is one value. A statement with no `$n` is held by its `?n` the
same way (SQLite's own spelling: `b=?1 AND c=?3` with three values is the
same gap), unless it also has a bare `?`, which takes the next free number
and which Postgres reads as an operator; then, and for a named struct of
values, the driver reads it.

`db.exec` takes its text at run time and cannot be respelled without a copy,
so the SQLite Wire prepares it as written and **binds by what each
placeholder is called**: after the prepare it reads
`sqlite3_bind_parameter_name` for every slot. `$N` and `?N` take value N, so `$n` means in `exec` what it
means in `raw`, and Postgres reads `$n` natively. A statement of only bare `?` binds by position. **If any slot has a
name, every slot must have one**: SQLite gives a bare `?` and the slots a `?5`
skips over the same NULL name, and a bare `?` among numbered ones takes the
largest number so far plus one, not its position, so a statement that mixes
them or skips a number is refused with one message, and that is what makes
refusing an unused value sound. A `:name` or `@name` is
refused (`exec` takes a tuple and has no names), and so is a placeholder past
the values given and a value no placeholder names, as `QueryFailed` with a
message naming the placeholder, the same two mistakes `raw` refuses while
compiling. A struct of values keeps zqlite's by-field binding. The cost is
one `sqlite3_bind_parameter_count` call and, per placeholder, one `_name` call
and a short parse, no allocation unless it refuses; run-time text is not
cached, so it is paid on every call, on a path that is DDL and maintenance.

## What was rejected

**Binding by name in the SQLite Wire for every call.**
`sqlite3_bind_parameter_index(stmt, "$k")` for each value, falling back to
position. It costs a string search per value per execution, on the path a
prepared statement exists to make cheap, and the text is comptime for every
other call, so the work is done once while compiling. It is used for `exec`
alone, the one call whose text is not known then, and reads names slot by
slot instead of searching for them.

**Sending `exec` text as written and teaching `?1`.** That was the rule until
a `$2` before a `$1` in an `exec` changed no row and said nothing; the doc
said to write `?1`, and the same `$n` spelling that is right in `raw` was
accepted and meant something else.

**Refusing `$n` on SQLite.** A refusal would have made the guide's every
raw statement a compile error on the second database, for a difference the
Dialect already knows how to write across.

**Refusing only the non-monotone case.** `$2` appearing before `$1` is what
an `IS NULL` guard looks like, and it is correct SQL. The wrong thing was
the binding, not the order of appearance.

## What it costs

One comptime tokenizing pass over each raw statement's text, memoized by the
compiler so `scan`, `paging`, `spelled` and `assertParams` share it (they used
to walk the text once each, with their own copy of the quote handling), inside
the branch quota `scan` already asks for. Nothing at run time. Three refusals.

## Consequences

- `sql/rawcheck.zig`: `highestParam`, `spelled`, `assertParams`.
- `sql/db.zig`: `rawText`, called by every raw call with comptime text.
- `sql/refusals/raw_with_fewer_values_than_placeholders.zig` and
  `sql/refusals/raw_with_a_gap_in_its_placeholders.zig`.
- The raw guide gains a section on what a parameter may be and what SQLite
  does differently, and the SQLite page says `$n` is one text for both.
