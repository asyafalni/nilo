# 0263 — `.like` on SQLite is refused the way `.contains` is

**Status:** accepted
**Extends:** [ADR 0061](./0061-the-second-dialect-is-the-test-of-the-seam.md),
whose rule this applies to the two operators that predate it, and
[ADR 0173](./0173-the-database-escapes-the-pattern-it-is-going-to-match.md),
whose pattern family was written under that rule from the start.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md).

## Context

SQLite's `LIKE` folds ASCII case and cannot be told not to by a
statement: `PRAGMA case_sensitive_like` is a property of the connection,
so a case-sensitive match there would depend on how the file was opened
rather than on what the query says. ADR 0061 made that a Refusal for the
case-sensitive half of the pattern family — `.contains`, `.starts_with`,
`.ends_with` — each naming the folding spelling that means what the
database does.

`.like` and `.not_like` predate that rule. They compiled on SQLite and
folded, matching `Ada@` against `ada@` on that database only, which is the
lie the seam exists not to tell. The roadmap held the entry at *waiting on
a design* for one question: refusing is consistent and breaks code that
runs today, since a program on SQLite that wrote `.like` and wanted the
folding has been getting it.

## Decision

**`.like` and `.not_like` are Refusals on SQLite, naming `.ilike` and
`.not_ilike`.** The same `noPatternForm` message `contains` gets, with
the operator that does work there in its last line.

**The break is worth the consistency, and it is one letter.** A program
that wrote `.like` on SQLite and wanted folding writes `.ilike`, which is
what the database was doing. One that wanted case sensitivity was getting
the wrong answer and is now told. There is no third program: on SQLite
`.like` and `.ilike` compiled to the same statement, so nothing a program
could observe changes for the first kind except that the operator's name
now says what it does.

**Refusing rather than spelling `.like` some other way.** `GLOB` is
case-sensitive and uses `*` and `?`, so a caller's `%` pattern would mean
something else. `lower(col) LIKE lower(?)` is the folding spelling again.
A pragma at open would change what every other statement on the
connection means, including `db.raw`. None of the three is `.like`.

## What it costs

Nothing at run time: a compile error on a shape that was wrong. A program
on SQLite that names `.like` stops compiling until it says which of the
two it meant, and the message says which one it was getting.

## Alternatives

**Leaving it.** The roadmap's own "waiting on: a design" was this option
held open. Rejected: the second Dialect is the test of the seam (ADR
0061), and an operator that means one thing on Postgres and another on
SQLite fails the test in the way the seam was built to catch.

**A `.like` that folds on SQLite and says so in the reference.** A
sentence in a table is not a Refusal; it is the reading a program has to
know to do. Rejected for the reason the pattern family was not shipped
that way.

## Consequences

- `sql/where.zig`: the two operators reach `noPatternForm` on a Dialect
  whose `like_folds`.
- `sql/refusals/sqlite_like.zig`; `refusals-sql` is 145.
- The reference's conditions table and the SQLite guide's table say so;
  the roadmap loses "`.like` on SQLite folds ASCII case and says
  nothing". `CHANGELOG.md` carries the break.
