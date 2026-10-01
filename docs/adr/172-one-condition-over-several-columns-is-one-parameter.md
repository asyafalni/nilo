# One condition over several columns is one parameter

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

The fourth most common `WHERE` a list screen has, in a product of 398 named
queries, is a search box over several columns beside a handful of filters
that may not be set:

```sql
AND (q IS NULL OR code ILIKE q OR name ILIKE q OR trademark ILIKE q)
```

`sql.given` writes the filters ([ADR 149](149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)),
and the refusal on a `given` inside `.any` is right for the case it names: an
alternative that is not there makes an OR match *fewer* rows, and one word
cannot mean both. But it also caught this shape, where the same absent value
sits on every alternative and the bracket should drop as one — exactly what
`.exists` already does with a `given` inside it. On nilo the typed form was
two `db.select` calls, one with the `.any` and one without, with six `given`
filters written twice. Raw was the wrong alternative, because the six filters
are what `given` exists for.

## Why not `sql.given` inside `.any`

The port's proposed spelling puts `sql.given(q)` on each of three
alternatives. Three fields are three values, and nilo cannot see while
compiling that they hold the same optional: the statement would carry `$3`,
`$4` and `$5`, and a guard could test only one of them. Three copies that
happened to differ would run and answer wrongly, which is the failure this
module refuses everywhere else.

## `.across`

```zig
.where = .{
    .product_id = sql.given(f.product_id),
    .is_active = sql.given(f.active),
    .across = .{ .columns = .{ .code, .name, .trademark }, .icontains = sql.given(q) },
},
```

```sql
("product_id" = $1 OR $1 IS NULL) AND ("is_active" = $2 OR $2 IS NULL)
AND (("code" ILIKE … $3 … OR "name" ILIKE … $3 … OR "trademark" ILIKE … $3 …) OR $3 IS NULL)
```

One condition — the operators a column takes, ANDed as they are on a column —
tested against each named column and ORed. **The parameter is taken once.**
The operators are walked against the first column, which takes `$3`; against
every other column the walk is handed the same numbers back and records
nothing, so the statement names `$3` three times and binds it once. The value
is read at `.where.across.icontains.value`, as it is for any operator.

A `given` on it guards the bracket, the way `oneExists` guards the subquery:
the terms inside write no guard, and one goes around the whole. A `given`
beside a fixed operator in one entry is refused, for `.exists`'s reason — a
`<=` that dropped because the search box was empty. A tuple of entries is
several, ANDed.

**A negated operator is refused.** `.ne`, `.not_in`, `.not_like`,
`.not_ilike`, `.not_ieq`, `.distinct_from` and every `not_` pattern
(`.not_icontains`) are a Refusal in an entry. ORed, `.not_icontains = "test"`
over `code` and `name` keeps a row whose `name` contains "test" as long as its
`code` does not, and nobody who wrote "not" over two columns meant that: they
meant *none of these columns*, which is an AND of the negations. Both readings
are a plausible thing to write, so nilo does not pick one; the message names
the spelling that is unambiguous, one condition per column, each with its own
`sql.given` if the box may be empty. That costs the one-parameter property for
the negated case only, and nobody has asked for it. It also keeps NULL out of
the question: `NOT ILIKE` on a NULL column is NULL, so under an AND-of-
negations a row with a NULL `trademark` would drop out of "none of these
contain it", where a person reading that sentence keeps it. Writing the
per-column conditions makes that choice visible at the call site, where
`.trademark = .{ .not_distinct_from = … }` or an `.any` with `IS NULL` says
which was meant.

**The columns have to read as one Zig type**, optional stripped: a parameter
bound as text and named on a number is a cast nobody wrote. Two types is two
conditions, in `.any`. One column is refused as an ordinary condition. And
`across` joins `any`, `exists` and `not_exists` as a word a Row cannot name a
column.

## What was not done

**A word for search alone** — `.search = .{ .over = …, .icontains = … }`.
The port offered it; the shape is more general than text. A `uuid` matched
against `owner_id` or `assignee_id`, a date against `starts_at` or `ends_at`,
are the same statement with a different operator, and `.across` says that.

**Letting `.any` alternatives share a parameter by value.** Comparing the
optionals at run time and folding the placeholders would move a question the
statement settles while compiling to a value that arrives after it is a
constant ([ADR 036](036-the-shape-of-a-query-is-settled-while-compiling.md)).

## Against ADR 017's four axes

Nothing per request: one parameter where a hand-written statement has one.
Nothing per connection. The plan cache holds one entry for the screen,
however the box is set, which is ADR 149's property carried to the bracket.

## Consequences

- `.across`, `State.replay`, `bareOf`; `across` reserved.
- Five Refusals: a `given` beside a condition, one column, two types, an
  unknown column, a negated operator.
- A comptime test and a live one against Postgres, with the box empty and
  filled, on a nullable column and one that is not.
- The port's `product/sku.zig` list is one `db.select`.
