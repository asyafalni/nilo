# A filter that is absent is not a filter that is null

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

[ADR 040](040-a-condition-holds-a-value-not-a-maybe.md) refuses an optional in a
condition, and the reason holds: a null reaching `= $1` sends `= NULL`, which is
never true in SQL. The query runs, matches nothing, and says nothing.

Nobody is asking for that back. What could not be spelled is a different
question.

## Two questions, one syntax

`.status = null` means *the rows whose status is nothing*. What a screen with a
search box and three dropdowns needs is *no condition on status at all* — and
those are opposites: the first matches a handful of rows, the second matches
every one.

The refusal's advice is to branch. What that costs, in the reporting port:

```zig
pub const Filter = struct {
    search: ?nilo.Str = null,
    capability: ?Capability = null,
    limit: ?i32 = null,
    offset: ?i32 = null,
};
```

**Two optional filters is four arms**, and each arm repeats the `.order`, the
`.limit`, the `.offset` and the `db.count` beside the `db.select` — the pairing
§"Counting" exists to make hard to get wrong. So the query stayed `db.raw`,
which is the escape hatch covering for a gap rather than carrying hard SQL.

And **every paging list in that product narrows on optional filters.** That is
what a filter *is* on a screen with a search box; the typed surface stopped at
the first one.

## `sql.given`, and why it is a word rather than an optional

```zig
.where = .{
    .name = .{ .icontains = sql.given(filter.search) },
    .status = sql.given(filter.status),
}
```

A word, because the two questions above have to stay tellable apart. Making
`.eq` take an optional would give one syntax two meanings decided by a value at
run time, which is the thing ADR 040 refused. The report said so itself: *"it
is deliberately not a request to make `.eq` take an optional."*

It compiles to the guard a hand-written statement uses:

```sql
("name" ILIKE '%' || $1 || '%' OR $1 IS NULL)
```

**Amended: the term comes first, and as first written it did not.** This ADR
shipped `($1 IS NULL OR "name" ILIKE …)`, with comptime tests asserting that
string and no live test running one. pg.zig sends a `Parse` with no parameter
types, so Postgres types each parameter at its first use — and `$1 IS NULL` is
a null test on an unknown, which fixes nothing. Every guard shape was *could
not determine data type of parameter $1* (`42P08`) from the database on the
first request, found by the port whose list endpoint is the example above. The
port's own hand-written guard had always been `$2::text IS NULL`, and a cast
was the fix it proposed; the order is the better one, because it needs no type
name — an enum column has none this module can write — and means the same
thing, `OR` being commutative in three-valued logic. `sql/live.zig` runs each
shape against Postgres now: text, a number, a pattern, a `timestamptz`, a
`uuid`, an enum and an `EXISTS`. The lesson is in
[`history.md`](../history.md#tests-that-could-not-fail).

## One statement, and the alternative that was rejected

The report suggested **two comptime plans and a runtime pick**. With `k`
optional filters that is 2ᵏ statements — and not only 2ᵏ strings: each variant
has its own parameter list, so it has its own values tuple, so `fill` is
instantiated 2ᵏ times per call site, with the Row's whole read loop inside it.
Four filters on one screen is sixteen copies of that, sixteen prepared
statements per connection, and a plan cache that thrashes as somebody clicks the
dropdowns.

The guard is one statement, one parameter list and one values tuple, and
**the same SQL the port already writes by hand**: its `db.raw` has a
`$2::text IS NULL OR` in front of it (the cast is what a hand-written guard
needs on Postgres; the amendment above is how the generated one does without). Nothing about `Statement` changes, so no
consumer of one has to learn that it might be a set of statements.

**What the guard costs is the planner, so the database is never handed it.**
A statement holding a `sql.given` is still compiled as the guard, and the
text a call sends is that statement with each guard cut out
(`statement.spliceOf`, `db.textOf`): a term whose value is there is written
alone, `("cust" = $1)`, and a term whose value is not is written as an
always-true test on the same placeholder, `($1::text IS NULL)` on Postgres and
`(?1 IS NULL)` on SQLite (`Dialect.absentTerm`). There is no `OR` left for a
plan made before the value was bound to stop on, so SQLite's plan at prepare
and Postgres's generic plan both seek. This is the way ADR 165 puts an
`ORDER BY` into a statement, and it keeps that ADR's property: **no run-time
string reaches the statement.** `spliceOf` reads the guards out of the
finished text while compiling and cuts it into pieces that are slices of it,
so every piece was checked with the statement, and the request only chooses,
for each guard, between two constants. The text is written into the arena in
one allocation sized while compiling, and an ordered statement writes its
cut head, the order and its tail into the same one.

**The numbering does not move.** The values tuple is the one the guard had,
and every placeholder stays in the text: the absent stand-in names it, because
SQLite counts parameters by the highest number it finds and binding one past
it is `SQLITE_RANGE`, and Postgres cannot leave `$2` out of a `Parse` that
sends no parameter types. The cast is what types it there. The term that used
to is gone, and the value is NULL whenever the cast is written, which is the
same bytes under `text`, an enum, a `uuid` and an array; `sql/live.zig` runs
each shape of the guard against Postgres, set and unset.

**One name for each combination, up to three guards.** The plan name is the
name of the full text and the combination after it (`statement.planNames`), so
a Db keeps at most 2ᵏ prepared texts of one call site on each connection,
k ≤ `max_named_guards` = 3, that is eight. Past three the statement is cut and
runs unnamed, so what a request can make a connection remember is a number
written in `statement.zig` and not the number of filters a screen has, the
objection ADR 165 raised to naming its thirty thousand texts. **A kept plan
is safe again because the text no longer holds a term the plan can go wrong on**:
a generic plan for `("cust" = $1) AND ($2::text IS NULL)` is the index scan
with a one-time filter (sql.md §25).

**Nothing is instantiated 2ᵏ times.** The tuple and `fill` are the ones of the
one statement. What the binary carries for a guarded statement is a second copy
of each guarded term, its stand-in, and the text between guards, which are bytes,
and none of it is code. That is the difference from the rejected 2ᵏ
statements.

**A statement whose guards cannot all be found is not cut.** A Dialect without
`splice_given`, a guard not written in the shape `where.zig` writes it, or one
nested in another leaves the statement as the guard, which is correct: SQLite
keeps it under its name and reads the table, and Postgres sends it unnamed and
plans each call for its values (`Dialect.plan_may_go_generic`,
`statement.dropsTerms`, `db.planOf`, which is the rule this section held
before and is still the floor). A statement with nothing that can drop keeps
its name and its 12 µs (ADR 051).

**A kept plan was the bug, not the lever.** This section used to say a
custom plan is used for the first five executions and for as long after as it
beats the generic one, and that the generic plan "is exactly the one the cost
comparison rejects". The comparison is against the *average* custom cost, and
a screen where most calls leave the filter out has an average that is a
scan's. The generic plan costs the same scan, wins, and the next call that
sets the filter reads the whole table: 500,000 rows, `Parallel Seq Scan` at
115 ms where the same call planned for its value is an index scan at 0.27 ms
([sql.md §22](../../bench/result/sql.md#22-a-guard-and-the-plan-a-kept-statement-settles-on)).
`SET plan_cache_mode = force_custom_plan` would have cured it and is a setting
of the connection, so it would also have taken the generic plan away from the
cheap key lookups that are the reason the default exists.

**On SQLite the cut is the whole cure, and the guard as written was a scan.**
A statement there is planned once, when it is prepared, before any value is
bound, so `("cust" = ?1 OR ?1 IS NULL)` is `SCAN` on the first call and on every
one after, and preparing it again plans it the same way: 29 ms a query against
0.044 ms for the bare term on 500,000 rows (§22). This ADR once left it there
and told a table where it mattered to branch on the filter and call `db.select`
twice. The text without the term when the filter is absent and without the guard
when it is present is what the cut sends, as a piece of the same statement: 69
ms against 0.055 ms with one of two filters set, and 63 ms against 1.1 ms with
both (sql.md §25). Past three guards it is prepared on every call, which cost
0 to 20 µs on a seek of 55 µs.

## Inside an `EXISTS` the guard goes round the outside

The port's capability filter is an `.exists` over a second table
([ADR 218](218-a-row-may-carry-its-parent-its-children-or-a-sum.md)), and guarding the term
*inside* it is wrong:

```sql
EXISTS (SELECT 1 FROM pc WHERE pc.partner_id = p.id AND (pc.capability = $2 OR $2 IS NULL))
```

With `$2` null that asks whether the partner has **any** capability row, which
excludes every partner that has none. It compiles, it passes, and the list is
missing rows — the shape of every item in the report.

So a `sql.given` inside an `.exists` drops the whole subquery, and the guard is
written around it. That leaves one case that could mean either thing, and it is
a Refusal rather than a guess: **a `sql.given` beside a condition that is always
there.** Write a second `.exists` for the fixed one.

## Three more Refusals

- **Inside `.any`.** `.any` is OR, so an alternative that is not there makes the
  condition match *fewer* rows. Everywhere else a term that drops widens the
  answer, which is what a filter nobody set has to do. One word cannot mean
  both.
- **In the condition of an `UPDATE` or a `DELETE`.** `.where = .{ .id =
  sql.given(maybe) }` is `DELETE FROM people` on the day `maybe` is null. The
  two refusals that already stand between those statements and the whole table
  exist because it is reached by leaving something out; this would be a third
  way to leave it out, decided at run time.
- **On `not_distinct_from`.** It already takes an optional and treats null as
  an ordinary value, so there is no term to drop.

And one on the way in: `sql.given` handed something that is not an optional is
refused, because a value that is always there is an ordinary condition and the
guard around it would never be taken.

## A list takes one too, and absent is not empty

`.stage = .{ .in = sql.given(q.stages) }` is the guard around a list:

```sql
("stage" = ANY($1) OR $1 IS NULL)
```

A filter bar's multi-select asks two different questions with one field: no
`?stage=` is *no filter*, and a list is *these stages*. Null drops the term,
and a list that is present keeps it, **empty included**: an empty `.in` still
means *no row matches* and an empty `.not_in` *every row*, which is what those
two operators say everywhere else. The parameter binds as an optional array on
Postgres, typed from `= ANY($1)` before the guard reads it, and as optional
JSON text on SQLite, where `json_each(NULL)` is no rows beside a guard that has
already said the term is gone. `sql/live.zig` runs both operators over integers,
text and a `uuid` column; `db.zig` runs them on SQLite.

## A condition a request emptied is refused at run time

`sql.given` is refused in an `UPDATE` or a `DELETE` because what narrows one
of those must not depend on a value that may not arrive. Two operators reach
the same place by a value that does arrive. `.not_in` with an empty list is
`"id" <> ALL('{}')`, true of every row, so "delete everything except these"
empties the table the day the list is empty. A pattern built from empty text,
`.contains = ""`, is `LIKE '%%'`, true of every row with the column, and so is
a raw `.like` or `.ilike` pattern of nothing but `%`, which those two bind
unescaped: a search box's `%` handed to `.ilike` as the condition of a delete
empties the table. An empty raw pattern is not the same case, since it matches
`''` alone. None of them can be seen while compiling.

So `update`, `delete` and their returning forms ask `where.filtersNothing`
before they send anything, and a condition that narrows nothing with the
values it was given is refused as `error.QueryFailed` with a line naming the
call. The terms of a struct are ANDed, so one term that narrows is enough to
send it: `.{ .tenant_id = t, .id = .{ .not_in = keep } }` with `keep` empty is
the tenant's rows, which is what it says. The alternatives of `.any` are ORed,
so one alternative that narrows nothing is enough to refuse. An empty `.in`
narrows to nothing and a negated pattern of empty text is true of no row, so
neither is refused. The walk is unrolled while compiling, so a condition with
no list and no pattern in it costs nothing. A read is not checked: an empty
filter that returns every row is a slow page, not lost data.

The compile-time half moved with it. The "no condition" Refusal used to count
parameters, so `.where = .{ .deleted_at = null }`, which is `IS NULL` and binds
nothing, was refused as though the `.where` were empty. It asks whether the
condition wrote any SQL now.

## In a `.set`, the same word keeps the column

A PATCH body is a struct of optionals, and each field the client left out is a
column the handler must not touch. Written with `db.update`, that was the 2ᵏ
arms again, one per combination of fields present, or a `db.raw`.

`sql.given` in a `.set` is the same word asking the same question, *was a
value handed over*, with the answer written where an assignment goes:

```sql
UPDATE "drafts" SET "title" = COALESCE($1, "title"), "words" = COALESCE($2, "words") WHERE "id" = $3
```

One statement and one parameter list, like the guard. The parameter binds as
an optional and is not marked `droppable`, because nothing drops: the
assignment is always in the statement and only its value is kept. Postgres
types `$1` from the column beside it inside the `COALESCE`, so no cast is
needed, and `sql/live.zig` runs it. A body with every field absent still
matches its row and writes each column back as it was; the count says one
row changed, and a trigger on the table fires.

**It is refused on a column that may be NULL.** There, null is a value too:
`{"nickname": null}` means *clear it*, and `COALESCE` cannot tell that from
the field being absent, so the request would answer 200 and keep the old
nickname. Telling the two apart needs a second value per field, which a
`?T` does not carry. Until a caller needs it, the column is set with a plain
`.nickname = value` in an update of its own.

## What was rejected

**Refusing `sql.given` on `.in` and `.not_in`**, the rule this ADR shipped with.
Its reasoning was that a list that may be absent is the empty list, so there is
no term to drop: pass an empty slice, or branch. That holds for a program with
only one of the two meanings. A filter bar has both, and the port that filed it
counted the cost: the `/deals` `WHERE` is twelve terms shared by the list, its
count and seven facet statements, and two of the twelve are multi-selects, with
a third list switched by a toggle. Branching is 2³ variants of each of nine
statements, so all nine stayed `db.raw`, `$n::text[] IS NULL OR x = ANY($n)`
written by hand. That is the guard this section already writes for one value,
held back from a list by a rule about a case the caller was not asking about.

**A kept, named statement with the guard left to the planner**, the rule
this ADR shipped with. It relied on Postgres choosing a custom plan for as long
as it matters, and it does not: see above and §22.

**The guard sent unnamed on Postgres and left as a scan on SQLite**, the rule
this ADR held from §22 until the cut. It cost Postgres a Parse and a plan on
every call, about 0.13 ms against a named cut text on the sample (§25, ten
times ADR 051's figure for the Parse alone), and it left SQLite reading the
table. Both come from the guard being in the text; it is not now, and
`plan_may_go_generic` is the floor for a statement that could not be cut.

**Naming every combination without a bound**, which the cut makes possible: a
call site with k guards has 2ᵏ texts, and a cache a client can grow by ticking
boxes is the one ADR 165 refused for an ordering. Up to three guards the 2ᵏ is
eight and is kept; past that the statement runs unnamed.

**Renumbering the placeholders so the absent one is left out of the text and
the tuple.** It would need a tuple of a different type per combination, which is
the 2ᵏ instantiations again. Keeping the placeholder in a test that is true costs
nothing and leaves the tuple alone.

**`SET plan_cache_mode = force_custom_plan` on the connection**, which was
offered as the lever. It applies to every statement the connection prepares,
so the key lookups and inserts that gain from a generic plan lose their
skipped planning to fix the one shape that needed it.

## Against ADR 017's four axes

- **Allocations per request: one, for a statement holding a `sql.given`, and
  zero for every other.** The wrapper is a struct holding an optional, passed by
  value into the same tuple every other parameter goes into; the one allocation
  is the cut text, sized while compiling (`db.splicedGuards`, no larger than the
  statement as written), and a statement ADR 165 orders takes it in the
  allocation it already made. A statement with no guard is `stmt.sql`, and the
  cut is one comptime-false branch.
- **Memory per idle connection: zero.** What a connection keeps is at most 2ᵏ
  prepared texts a call site, k ≤ 3, and only for combinations that were sent
  (the cap is `statement.max_named_guards`).
- **Throughput: on Postgres about 0.13 ms a call faster than the unnamed guard,
  and SQLite 69 ms to 0.055 ms on the sample (sql.md §25).** The cost is the
  writing of the text, one pass over a few hundred bytes, and, past three
  guards, a Parse or a prepare on each call, 0 to 20 µs on SQLite. The
  parameter binds as an optional where it would have bound as a value, the same
  branch `not_distinct_from` has had since ADR 040.
- **Binary size: the guarded terms twice, not 2ᵏ statements.** One tuple, one
  `fill`, and per guard a copy of its term, the stand-in and the text between,
  which is what the axis that decided the design allows.

## Consequences

- `db.select`, `db.one`, `db.page`, `db.count`, `db.exists` and `db.stream` take
  it. `db.update`, `db.updateReturning`, `db.delete` and `db.deleteReturning` do
  not take it in their condition; the updates take it in their `.set`, on a
  column that is not optional.
- With [ADR 150](150-a-page-knows-what-it-left-out.md) the ordinary list
  endpoint is one typed call: an optional search, an optional `EXISTS`, a page
  and its total. The report filed the two together for that reason.
- `Param` carries `droppable`, which is what `statement.zig` reads to refuse the
  update and the delete. It is set in `State.take` rather than at the six call
  sites that build parameters, so no operator has to remember it.
- `Dialect.splice_given` and `absentTerm`, both optional for a Dialect that does
  not cut; `statement.spliceOf` finds the guards, `planNames` names a text per
  combination, and `db.textOf`, `db.planFor` and `db.splicedGuards` are the run
  time half. The typed reads that take a `sql.given` (`select`, `one`, `page`,
  `feed`, `stream`, `count`, `exists`, and their `tx` forms) send the cut text.
  The text `Select`, `Count` and the other public statement types show is the
  guard as compiled, not the text of a call.
