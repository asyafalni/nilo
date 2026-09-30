# A page knows what it left out

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

A trimmed list has to say what it trimmed. *"20 of 47"* is the ordinary shape of
every list screen, and it needs two numbers out of one condition.

The documented answer was the pairing in §"Counting":

```zig
const where = .{ .status = "open" };
const total = try db.count(Order, c, .{ .where = where });
const page  = try db.select(Order, c, .{ .where = where, .order = .{ .id = .asc }, .limit = 20 });
```

## The round trip is the smaller half of the problem

That is two statements against a table somebody else can write between. Between
the count and the select, one order is closed and another opened: the screen
says *"20 of 47"* while holding 20 of 46, and nothing anywhere says so.

`count(*) OVER ()` rides on the page and cannot come apart from it, because
there is only one statement to be inconsistent with.

## `db.page`

```zig
const found = try db.page(Order, c, .{
    .where = .{ .status = "open" },
    .order = .{ .id = .asc },
    .limit = 20,
    .offset = page * 20,
});
// found.rows is []Order, found.total is every order that matched.
```

```sql
SELECT "id", "status", count(*) OVER () FROM "orders"
  WHERE "status" = $1 ORDER BY "id" ASC LIMIT 20 OFFSET $2
```

A type of its own rather than an out-parameter, for the reason `db.one` is not
`db.select`: the shape of the answer changed, and a caller who has to remember
to read a second thing is a caller who will forget.

**One extra integer read per statement, not per row.** The window function
answers the same number on every row of the result, so only the first is read; a
condition matching nothing answers with no rows and a total of zero, which is
the same branch the empty result already takes.

**It is computed over every row the condition matches, before the `LIMIT`
applies**, so a page costs its whole match and not its twenty rows. Over a
million rows with an index on the order, the same page took 124 ms with the
window and 0.024 ms without it; narrowed by a condition, 42 ms
([sql.md §18](../../bench/result/sql.md#18-the-count-a-page-reads-keyset-paging-and-a-stream-let-go-early)).
That is the price of "20 of 47", and a list that does not show the 47 should
not pay it: that list is `db.feed`, below.

## A page past the last row

The window rides on the rows, so a page with none has no total. An empty
answer is two different facts: nothing matched, or the page asked for rows past
the last one, `.offset = 200` on a list that shrank to 150. The first is a total
of zero. The second used to read as zero too, and a screen said "nothing
matches" about a list of 150.

**So an empty page that skipped rows, or asked for none, sends `db.count` with
its own `.where`**, and that is the total. An empty page with no offset matched
nothing and sends nothing more. The count is a second statement, which is what
this ADR exists to avoid, and here it cannot do the harm that was avoided:
there are no rows on the page for the number to disagree with. A count is
cheaper than asking the page again from its first row: no sort and no columns.
A grouped Row counts groups, as `db.count` does over one.

The same text in both Dialects. Window functions are SQL:2003 and SQLite has had
them since 3.25, so this is not a Postgres-only call and `dialect.zig` gains
nothing.

## A page ends in the key

**An order a `LIMIT` or an `OFFSET` cuts ends in the table's key**, running the way the last term the caller named runs, where the caller's order does not name it already: `.order = .{ .created_at = .desc }` on a page is `ORDER BY "created_at" DESC, "id" DESC`, and `.order = .{ .created_at = .desc, .age = .asc }` ends in `"id" ASC`. Rows the order ties come back in whatever order the plan reaches them, and Postgres may reach them differently at each `OFFSET`: a thousand rows over ten values, paged by 25, showed 179 rows twice and 179 never, while the total said a thousand. With the key last every row has one place, and pages add up to the list. `db.page`, `db.one` and a `db.select` or `db.stream` with a `.limit` or an `.offset` all take it, on a plain Row and a shaped one, which names the key through its table because a parent's columns share the statement. Children have done the same since ADR 218. A statement nothing cuts is left as written, since every row is in it whatever the order among ties. A grouped Row has no key, because a group is not a row of the table, and its `GROUP BY` list is what tells one group from another: the tiebreak is every column it groups by that the order did not name, including the key of each parent it reads (ADR 218), running the same way. An order chosen at run time by an `sql.Ordering` takes it too: which terms the request chose is known only per request, so the statement carries every key column with its term (`statement.Tie`), and the clause is written with each one the request did not order by itself. Those terms always ascend, since nothing reads a run-time ordering with a cursor, and `.after` is the one reader that needs the pages to agree on a direction. The room for them is added to the clause's size while compiling, so it is still one arena allocation. A list screen sorted by a column two rows share showed one of them on two pages and the other on neither until it did.

It costs what the index on the order column no longer covers. Postgres answers with an incremental sort over the tie group the page lands in, so the price is that group's size: on a million rows, `ORDER BY status` over ten values went from 0.07 ms to between 6.6 and 14.4 ms, and a date with a thousand rows a value from 1.2 ms to 2.4 ([sql.md §19](../../bench/result/sql.md#19-the-key-a-cut-order-ends-in)). An index ending in the key, `(status, id)`, takes it back to 0.09 ms. The key goes on anyway, because the statement without it answers a wrong list, and a wrong list is not a speed.

## A feed counts nothing

**`db.feed` is the rows up to `.limit` and whether a row came after them**,
`sql.Feed(Row){ .rows, .more }`, for a "load more" button or an endless scroll.
The statement reads `LIMIT n + 1`, and the row past the page is dropped and
answers `more`: nothing is counted, so a screen costs its rows. A written
`.limit` is raised while compiling; one a request handed over is raised as it
is bound, so the text is the same statement for every request. It takes the
page's three Refusals and for the same reasons, and `tx.feed` is the same call
inside a transaction.

**A second call rather than an option on `db.page`.** `.total = false` would
make the type a page answers depend on an option, or make `total` an optional
that every page caller unwraps for the sake of the ones who never read it.

**`.after` reads the rows after a cursor, the last row seen, as one row
comparison**: `.order = .{ .created_at = .desc, .id = .desc }` with `.after =
.{ .created_at = last.created_at, .id = last.id }` is `("created_at", "id") <
($1, $2)`, which both databases answer with a seek on an index over the same
columns: 0.013 ms at a million rows, where the `.any` of `<` and `= … AND <`
the guide wrote filtered from the first row and cost 17.8 ms, what the `OFFSET`
it replaced did. It goes on `db.feed`, on `db.select` and on `db.explain`, and
on a shaped Row over its own table's columns. **Four rules, each a cursor that
would skip or repeat rows otherwise, and each a Refusal**: the columns are
`.order`'s, in its order and written out; every term runs the same way, since a
row comparison does; no term says where NULLs go and no column may hold one,
since a comparison with a NULL in it is true of nothing; and the order ends in
the table's key, or two rows sharing every sorted column stand at one cursor
and the second is skipped. `db.page` refuses a cursor: it counts every match
and skips by `OFFSET`, and after a cursor there is no page for a count to be
relative to.

## Three Refusals

- **No `.limit`.** With no ceiling this is the whole table, and the window
  function it cost answers what `rows.len` already says. `db.select` is the call
  for every row that matched.
- **No `.order`.** Postgres owes a `LIMIT` nothing without one, so two requests
  for the same page can hold one row twice and miss another. It compiles, it
  passes, and the list is wrong — which is the shape of every item the port
  filed.
- **A `.lock`.** `FOR UPDATE` and a window function cannot be in one statement;
  Postgres refuses the pair at run time, on whichever request got there first. A
  page is a read.

The second is stricter than `db.select`, which takes a `.limit` with no `.order`
and always has. That is deliberate rather than an oversight: a `select` with a
ceiling is often *"give me any twenty of these"*, and a **page** is by name the
thing whose second page has to line up with its first.

## Against ADR 017's four axes

- **Allocations per request: zero more than `db.select`.** The same arena list,
  reserved to the same `.limit`; the total is an `i64` on the caller's stack.
- **Memory per idle connection: zero.**
- **Throughput: one statement where the documented shape was two**, so one round
  trip rather than two and one prepared statement rather than two. Against
  `db.select` alone it is one `readColumn` per statement and the window
  function's own cost, which is a pass over every matching row before the
  limit (above). `db.feed` costs one row more than `db.select` and no window.
  A page that comes back empty after skipping rows sends one `db.count` more,
  and no other page does.
- **Binary size: one more call**, generic over the Row like every other. `fill`
  is unchanged and `filling` is what it always was with one parameter added, so
  no call site is duplicated.

## What was rejected

**Saying zero past the last row and writing it down.** It is what
`count(*) OVER ()` answers on its own, and nodeflux-os filed it as item 97: the
two-statement shape this replaced answered the real number, and the server the
port mirrors does too. A total that is right on every page but the empty one
is a total a caller has to second-guess on every page.

**One statement that always carries a row**, the page `LEFT JOIN`ed to a
`count(*)` of the same condition. It answers past the end in one round trip,
and every other page pays for it: the condition is evaluated twice and the
plan is a different shape from the one `db.select` gets, to cover a request
the frontend rarely sends.

**A tiebreak that always ascends.** It was the first shape, and a descending feed broke on it: a first page ordered `.created_at = .desc` was `ORDER BY "created_at" DESC, "id" ASC`, while the page after it, which `.after` forces to name `.id = .desc` and read `("created_at", "id") < ($1, $2)`, was `"id" DESC`. With ids 101 to 110 sharing a `created_at` across the boundary, page 2 repeated 101 to 104 and nothing showed 106 to 110. The mixed order also cannot be read straight off a `(created_at, id)` index. The tiebreak runs the way the last named term runs, so the first page and the ones after it are one order.

**A tiebreak the caller writes, as the guide asked.** Every test ordered by the key, so the rule was invisible where it was checked and broken where it was not: a list screen ordered by a status or a date.

**`.total = false` on `db.page`, or `total: ?i64`**, above.

**A cursor that allows an order running both ways**, written as the
expanded `OR` the guide had. It is correct and it cannot seek, which is the
only reason to want a cursor; a caller who needs the mixed order writes it in
`.where` with `.any`, and the Refusal says so.

**`.after = sql.given(cursor)`, one statement for the first screen and the
rest**, dropping the comparison when the cursor is null. The dropped term is
spelled `$1 IS NULL OR …`, and an `OR` beside the comparison is what stops the
seek on a generic plan. Two calls, with a cursor and without, are two prepared
statements each with its own plan.

## Consequences

- With [ADR 149](149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)
  the ordinary list endpoint is one typed call. The report filed the two
  together and said plainly that either alone leaves the query raw.
- `tx.page` exists for the same reason `tx.select` does. A repeatable-read
  transaction is the *other* way to make a count and a page agree, and it costs
  a transaction where this costs a clause.
- `db.count` is unchanged and still right for the caller who wants a total and
  no rows.
- `wideEnough` takes the extra column into account, so a `db.page` against a
  result set that is one column short is the same named refusal a `db.raw` gets
  rather than a read past the end (ADR 106).
