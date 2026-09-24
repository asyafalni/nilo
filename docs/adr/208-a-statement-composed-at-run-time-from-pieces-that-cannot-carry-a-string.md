# A statement composed at run time, from pieces that cannot carry a string

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)

[ADR 051](051-a-statement-that-is-a-constant-can-be-prepared-once.md) made `db.raw`'s
text comptime and said, deliberately, that there is no replacement: a program
that builds SQL at run time assembles it at comptime instead, as a `switch`
over the finite set of statements it supports. Every call site anybody had
was a literal, and the escape hatch was carrying a feature nobody used.

[ADR 165](165-an-order-chosen-at-run-time-from-a-closed-set.md) then read
the property more carefully than the sentence: what ADR 036 protects is
narrower than "the text is a constant". It is that **no run-time string
reaches the statement** — the request decides *which* of the program's
fragments are written, never *what*.

## The caller that has no finite set

A semantic query engine — a model of sources, measures and rollups, held as
data, turned into `SELECT`s over the rollup that can answer each request —
has no finite set of statements to switch over. Which table, which columns,
which aggregate functions, how many of each and in what order come out of a
model that is edited at run time; that is the whole point of such a program.
Written as a `switch` it would be a `switch` over every model anybody might
write, which is to say it cannot be written.

And yet it never needs a run-time *string* in a statement. Everything that
varies is one of three things:

| piece | example | comes from |
|---|---|---|
| text the program wrote | `SELECT time_bucket(INTERVAL '1 hour', ` | a Zig literal |
| a name | `"q_dwelling__by_stream__h1"`, `"stream_id"` | the model, checked to be a name |
| a value | `$1`, `$2` — `?1`, `?2` on SQLite | the request, as a parameter |

That is ADR 165's property with one more kind of piece: a name that is
checked at run time to be nothing but a name.

## What changes

`sql.Composed` is a statement made only of those pieces
([`sql/composed.zig`](../../sql/composed.zig)):

```zig
var s = db.compose(c);           // spelled for this Db's dialect
try s.text("SELECT sum(");
try s.ident(measure);          // "visits" — from the model; refused unless it is an identifier
try s.text(") FROM ");
try s.ident(rollup);
try s.text(" WHERE bucket >= ");
try s.param(1);
try s.text(" AND bucket < ");
try s.param(2);
const rows = try db.composed(Total, c, s, .{ from, to });
```

- **`text` takes `comptime piece: []const u8`.** A slice that arrived at run
  time does not compile, and that is the whole check. The first draft checked
  the *type* instead — a literal is a pointer to an array — and refused
  anything else in nilo's words; review found the hole: a `*[N]u8` filled at
  run time is a pointer to an array too, and would have passed. `comptime`
  on the parameter is what a literal actually is, so there is no refusal to
  write for that and none is kept. What `text` does refuse is a `$n` inside
  the piece: a placeholder written as text is spelled for one database and
  counted by nobody, and the point of `param` is that it is neither.
- **`ident` checks and quotes.** Letters, digits and `_`, not starting with a
  digit, at most 63 bytes, written as `"name"`. `stream_id" OR 1=1 --` is
  `error.NotAnIdentifier` and nothing is written. `qualified(schema, name)`
  is two of them.
- **`param(n)` writes the `n`th placeholder spelled for the dialect** — `$n`
  on Postgres, `?n` on SQLite — the way `rawText` respells a raw `$n`
  ([ADR 204](204-a-raw-placeholder-is-spelled-for-the-dialect.md)). A
  `Composed` knows its `Spelling`: `db.compose(c)` hands one out with the
  Db's, and `Composed.init(arena, Spelling.of(Dialect))` builds one where no
  Db is in scope — a generator with table-driven tests. `db.composed` refuses
  a statement spelled for the other dialect (`error.WrongDialect`) before it
  is sent. `param(0)` is `error.NotAParameter`. `number(n)` writes the digits
  of a `u64` and nothing else; a negative number a statement needs is a
  `param`. Nothing else has a method.
- **`db.composed(Row, c, stmt, values)`** and `tx.composed` run it, and
  `db.composedOne` unwraps. The Row is filled by position; the run-time width
  check ([ADR 106](106-a-select-list-shorter-than-the-row-is-refused.md))
  holds; the values are converted the way a Row's are
  ([ADR 116](116-a-raw-parameter-is-converted-the-way-a-rows-is.md)); one
  column into a scalar works ([ADR 125](125-a-row-that-owns-no-table.md)). And
  the values are counted against the placeholders — what
  `rawcheck.assertParams` does while compiling for `raw`, done at run time
  here because the text is not there to read until the request is: a tuple
  with fewer or more values than the highest `param` is
  `error.ParamCountMismatch`, never a `NULL` bound where SQLite would say
  nothing.

## What it gives up, and what it costs

The two things ADR 051 bought for `raw`, because both need the text while
compiling: the column count against the Row, and the plan name. A composed
statement runs **unnamed**, which is the 12 µs of Parse and Describe
[ADR 051](051-a-statement-that-is-a-constant-can-be-prepared-once.md)
measured. For the caller this exists for, a query engine answering analytics
over pre-aggregated rows, the statement itself is milliseconds and the 12 µs
is not the cost worth chasing; a caller that finds it is has ADR 051's
answer, a finite set.

Nothing changes for `db.raw`: it keeps its comptime text, its column check
and its plan name, and ADR 051's reasoning about it stands. This is not the
second call with the old signature that ADR refused — a composed statement
cannot take text at run time, which is the property the old signature lacked.

Cost on the axes of [ADR 017](017-the-trade-budget-has-four-axes.md): no
allocation on any path that did not ask for one — the pieces are written into
the Scope's arena the caller handed over, which is the request's own arena
under a `Ctx`; nothing on an idle connection; a `Composed` and its three
methods link into a program that names them and into no other.

## Why not the alternatives

- **`db.rawText(Row, c, text, values)`** — the old signature under a new
  name. ADR 051 already refused it, and it would refuse it again: a call that
  takes any text at run time is the injection nobody meant to allow, waiting
  for a caller who concatenated a request into it.
- **A builder that also knows SQL** — conditions, joins, group-by as typed
  calls. This module's line is one sentence, *one table, conditions that
  filter rows*, and a query engine is past it on purpose. A builder that
  followed it there would grow with every function TimescaleDB adds. Three
  kinds of piece grow with nothing.
- **Quoting instead of refusing** — accept any `ident` and escape the quotes.
  It would work, and it would hide a model whose column is named
  `people; drop table` behind a working statement. Refusing puts the name in
  front of the caller.

## Consequences

- `sql/composed.zig`: `Composed`, `Spelling`, `isIdentifier` (exported, so a
  caller that validates names on the way in applies the same rule), five
  tests.
- `db.compose`, `db.composed`, `db.composedOne`, `tx.compose`, `tx.composed`.
- One refusal, `composed_text_naming_a_placeholder`: a `$1` inside a
  `text` piece. Not one for a run-time string handed to `text` — the
  parameter is `comptime`, and the compiler's own message is the whole of
  that.
- Two live tests: on Postgres, a statement composed from run-time names fills
  a projection and agrees with the same sum through `rawOne`, a name that is
  not one never reaches the database, and neither does a tuple short of a
  value; on SQLite, the same statement is spelled `?n`, a short tuple is
  refused, and a statement spelled `$n` is refused before it is sent.
