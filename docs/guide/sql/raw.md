# Raw SQL

**When a query goes past what a Row can declare, you write the SQL yourself with `db.raw`, and nilo still fills your struct and checks the column count while compiling.**

**Reference:** [raw queries](../../reference/sql.md#queries), [a Row that owns no table](../../reference/sql.md#projection-a-row-with-no-table) · **Design:** [Raw statements](../../design/sql-raw.md)

`nilo_sql` writes the SQL for one table, the parents its references point at, the children that point back, and sums by group ([a Row with more in it](./shapes.md)). This page covers everything past that: `raw` and its variants. It follows [reading](./reading.md).

## Running a raw query

**A join through a condition rather than a reference, `DISTINCT`, window functions, CTEs, unions, an aggregate over an expression: none of these can be declared on a Row, so you write them with `raw`.**

<!-- compiles: body -->
```zig
const Tally = struct {
    // A shape no table has: `raw` fills it, and nothing builds or checks it.
    pub const nilo_table = .projection;

    country: nilo.Str,
    n: i64,
};

const tally = try db.raw(Tally, c,
    "SELECT u.country, count(*)::bigint AS n FROM users u " ++
    "JOIN orders o ON o.user_id = u.id GROUP BY u.country",
    .{},
);
```

`raw` still fills your struct, still uses the arena, and still follows the `Str` rule. The `SELECT` list is counted against the struct's fields while compiling, and a column with a plain name is checked against the field in the same position ([ADR 051](../../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md)). The only thing you give up is nilo writing the text for you.

### Column types, checked the first time it runs

**The first time a raw statement runs, nilo asks the database what each column is and checks the answer against the Row** ([ADR 233](../../adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)). It asks two things once per statement: the type each column arrives as, and whether the column comes from the side of an outer join that may find nothing. In a test, a column that does not fit fails the statement with a message naming the column and the fix. In a server it is a warning, and the statement still runs. These are the two it finds most often:

```
column 2 fills `n`, which reads int4, and the statement answers int8 there.
column 3 fills `title`, which is not optional, and comes from the side of an
outer join that may find nothing, where it is NULL.
```

`count(*)` is `int8`, so read it into an `i64` or cast it. A column read through a `LEFT JOIN` or a `LEFT JOIN LATERAL` goes into an optional field, or is wrapped in `coalesce`. The check reads the planner's view, so a `WHERE` that throws the join's NULLs away is taken into account and the column is not reported as NULL. This means a test that reaches a raw statement also checks it against its Row. A statement inside a transaction is not checked; the same statement outside one is.

The struct is still a **Row**, so it still has a `nilo_table`, and `.projection` is the value that says it owns no table. If it named a table it does not have, the schema check and the migrator would look for that table (say `country_tally`) and find nothing. A Row that *is* a table's columns, or a view's, names the table as usual, and `raw` fills it the same way.

### Fields no column holds

**A Row can also carry fields that the program fills in itself.** A line on a page sometimes holds a field no column has, such as a comment's attached files, read in a second statement or handed over by a service. `nilo_beside` names those fields. They are on the Row, in its JSON and in its API document, but in no statement: the `SELECT` list is counted against the columns only, and a read leaves them at their default for you to fill ([ADR 178](../../adr/178-a-row-can-carry-a-field-no-column-holds.md)):

<!-- compiles: body -->
```zig
// Attachment: the file's Row, and attachmentsOf(c, id) the second read.
const Line = struct {
    pub const nilo_table = .projection;
    pub const nilo_beside = .{.attachments};

    id: i64,
    body: nilo.Str,
    attachments: []const Attachment = &.{},
};

const lines = try db.raw(Line, c, "SELECT id, body FROM comments ORDER BY id", .{});
for (lines) |*line| line.attachments = try attachmentsOf(c, line.id);
```

When the **database** can build the list, use `sql.Json(T)` with `jsonb_agg` in the statement instead: one round trip, and the API document says `T`. The column is parsed by `std.json` into `T`'s field names **as written**. A `rename_all` on `T` changes the response and not the column, so the `jsonb_build_object` uses `content_type` and the response says `contentType`, from one type.

## Parameters

**The values are a tuple, one per placeholder, and the placeholders are `$1`, `$2`, … in the text.** `$n` is the `n`th value wherever it appears in the statement, and a `$n` written twice is one value. The text is comptime, so the count is checked while compiling: a statement that names `$3` but is given two values is a Refusal, not a run-time error on one database and a silent NULL on the other ([ADR 204](../../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).

A parameter can be anything a column takes, converted the same way a Row's field is written: an integer or a float, a `bool`, `[]const u8`, a `nilo.Str` as it is (no `.bytes()`), an enum (its tag name is sent), `sql.Timestamp` (its microseconds), `sql.Date`, `sql.Uuid`, `sql.Json(T)`, `sql.Bytes`. A literal `1` or `"open"` is fine in the tuple; a comptime value is given a run-time type before it is sent.

### An optional filter

**An optional binds NULL when it is null**, and that is how a filter a screen may or may not have set gets into a statement you wrote. The `IS NULL` guard is the raw SQL version of `sql.given`, written where the database can see it:

<!-- compiles: body -->
```zig
const Open = struct {
    pub const nilo_table = .projection;

    id: i64,
    name: nilo.Str,
};

const found = try db.raw(Open, c,
    "SELECT o.id, u.name FROM orders o JOIN users u ON u.id = o.user_id " ++
    "WHERE o.status = 'open' AND ($1 IS NULL OR u.name ILIKE $1) ORDER BY o.id",
    .{search},
);
```

With `search` absent, `$1` is NULL, the first half of the `OR` is true, and every open order comes back. With it set, the second half filters. One statement, one plan, and the same text on both databases.

### Lists and named values

A list written inline, `&.{ 1, 2, 3 }`, binds as an array for `= ANY($1)`, which works on Postgres and not on SQLite. A named struct of values is passed to the driver, which is zqlite's `:name` binding ([ADR 116](../../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)).

## Reading a single column

**For a statement that returns one column, pass the column's type instead of a Row.** A name from the catalogue, an id or a count does not need a struct. `raw` then reads column one of every row ([ADR 125](../../adr/125-a-row-that-owns-no-table.md)):

<!-- compiles: body -->
```zig
const names = try db.raw([]const u8, c, "SELECT name FROM pragma_table_info('downloads')", .{});
const newest = try db.rawOne(i64, c, "SELECT max(id) FROM comments", .{});
```

The type can be `[]const u8`, `i64`, `?bool`, a `nilo.Str`: anything a single column can be read as, or an optional of one. The value is read the same way a Row's field is, so a `Str` belongs to the Scope and a slice is kept in the arena. `rawOne` does the same and unwraps the single row. A `SELECT` list of two columns read into a scalar is a compile error, just like a short list read into a Row: the statement is still counted.

## Reports and aggregates

**Most dashboard reads are aggregates, and most of them do not need `raw`.** A count, sum, min, max or average over a column, grouped by columns and parents, is a [grouped Row](./shapes.md#grouping-and-aggregates). A `FILTER` on one of them is its entry's [`.where`](./shapes.md#filtering-one-aggregate). A count of the rows pointing back is a [count field](./shapes.md#ordering-filtering-and-counting-children). A total over everything is `db.exactlyOne`. What is left for `raw` is a report those cannot express: a `coalesce`, an expression inside the aggregate, a join no reference names. Three kinds come up, and each has its own call.

### A statement that always returns one row

**`rawExactlyOne` returns the Row directly, for a statement that can never return zero rows.** `SELECT count(*), sum(total) FROM invoices` returns one row whatever is in the table, and so does `RETURNING` on a write by key. `rawOne` would return a `?Row`, with a null that cannot happen. With `rawExactlyOne`, a statement that returned no row is `error.QueryFailed` rather than a zero-filled struct ([ADR 206](../../adr/206-a-statement-that-always-answers-answers-a-row.md)):

<!-- compiles: body -->
```zig
const Totals = struct {
    pub const nilo_table = .projection;

    invoices: i64,
    open: i64,
    paid: i64,
};

const totals = try db.rawExactlyOne(Totals, c,
    "SELECT count(*), count(*) FILTER (WHERE status = 'open'), " ++
    "coalesce(sum(total) FILTER (WHERE status = 'paid'), 0)::bigint FROM invoices",
    .{},
);
```

### One line per group

A `GROUP BY` returns zero or more rows, so use `raw` and a slice, with a Row shaped like one line. Wrap the sums in `coalesce`: `sum` over no rows is NULL, and a field that is not `?i64` rejects a NULL.

### A paged join (`rawPage`)

**`rawPage` reads a raw statement as a page: the rows and the total, from one statement.** A join the schema names is [a parent](./shapes.md#joining-a-parent-row), and `db.page` pages it. A join it does not name, or one with a condition in its `ON`, needs `rawPage`. `db.page` gets the rows and the total in one statement by adding `count(*) OVER ()` to the `SELECT` list, and a list screen that joins two tables wants the same. `rawPage` reads the Row's columns, then that window as one extra column at the end, which becomes `.total`. You write the `ORDER BY` and the `LIMIT` yourself, for the same reason `db.page` requires both ([ADR 205](../../adr/205-a-raw-statement-can-carry-its-total.md)):

<!-- compiles: body -->
```zig
const Line = struct {
    pub const nilo_table = .projection;

    id: i64,
    customer: nilo.Str,
    total: i64,
};

const page = try db.rawPage(Line, c,
    "SELECT i.id, u.name AS customer, i.total, count(*) OVER () " ++
    "FROM invoices i JOIN users u ON u.id = i.user_id " ++
    "WHERE ($1 IS NULL OR u.name ILIKE $1) " ++
    "ORDER BY i.id LIMIT 20 OFFSET $2",
    .{ search, id },
);
```

`page.rows` and `page.total` are what `db.page` returns, and a handler that returns the `Page(Line)` is described the same way in the API document. A `SELECT` list exactly as wide as the Row, with no window column at the end, is a Refusal that tells you what to add.

**A page past the last row still reports the total.** The window column rides on the rows, so a request for rows 200 onward of a list of 150 has no row to carry it. nilo then sends the same statement again with the offset at 0 (and the limit at 1, when the limit is a placeholder of its own), and reads the total from that one row. To do that it has to find the offset, so write it as one placeholder used nowhere else, `OFFSET $2` or `OFFSET $2::int`, and compute the number in Zig. An `OFFSET` written as a number, or as arithmetic like `($3 - 1) * 20`, is a Refusal that says so.

A list sorted by clicking its column headings uses `db.rawPageOrdered`: the same statement with `{order}` where the `ORDER BY` goes, and the `sql.Ordering` value the request chose as the last argument, the same way [`rawOrdered`](./reading.md) takes it. The rows and the total still come from one statement, so the count cannot disagree with the page it is shown with.

### Grouping by date

**Dates in a `GROUP BY` are where the two databases differ.** A `sql.Timestamp` is microseconds since the epoch. Postgres stores it as `timestamptz`, and `date_trunc('month', issued_at)` reads it. SQLite stores the integer, so a month is `strftime('%Y-%m', issued_at / 1000000, 'unixepoch')`; the [SQLite page](./sqlite.md#dates-from-a-timestamp) has the recipe. Read the group key into a `nilo.Str` and both versions fill the same Row.

## Statements that return nothing (`db.exec`)

**`db.exec` runs a statement that selects nothing, and returns the number of rows it changed.** `CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`, `ANALYZE`, a hand-written `DELETE`: there is no struct to fill.

```zig
_ = try db.exec(&run,
    \\CREATE TABLE IF NOT EXISTS accounts (
    \\  id    INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    \\  email TEXT NOT NULL UNIQUE COLLATE NOCASE
    \\)
, .{});
```

**A SQLite application needs this and a Postgres one usually doesn't**: there is no server where the DDL was run already, so creating the tables at startup is your job. `tx.exec` is the same call inside a transaction.

The query builder stops here on purpose. A builder's dialect support grows with the builder, and the statements beyond this point are where databases disagree most. A Row can declare a join the schema already names and a grouping its fields already describe. Anything more would be a second query language, and a limit you can state in one sentence is worth more than one further out.

## Building a statement at run time (`sql.Composed`)

**`sql.Composed` builds a statement at run time from names and values, never from run-time strings.** `db.raw`'s text is comptime, which rules out a program assembling SQL from run-time strings. One kind of program has no fixed set of statements: a query engine, where the tables, columns and aggregates come from a model that is data. It never needs a run-time *string* in a statement, only names and values, so that is all `sql.Composed` lets it write ([ADR 208](../../adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)):

<!-- compiles: body -->
```zig
const Line = struct {
    pub const nilo_table = .projection;
    key: ?[]const u8,
    total: i64,
};

var s = db.compose(c);           // spelled for this Db's dialect
try s.text("SELECT ");
try s.ident(dimension);          // a name out of the model; not a name → error.NotAnIdentifier
try s.text(", sum(");
try s.ident(measure);
try s.text(") FROM ");
try s.ident(rollup);
try s.text(" WHERE bucket >= ");
try s.param(1);
try s.text(" AND bucket < ");
try s.param(2);
try s.text(" GROUP BY 1 LIMIT ");
try s.number(limit);

const rows = try db.composed(Line, c, s, .{ from, to });
```

- `text` is `comptime`, so a slice that arrived at run time does not compile, and a `$1` inside it is a Refusal: a placeholder is `param(1)`.
- `ident` checks that a name is letters, digits and `_`, and writes it quoted.
- `param` writes the `n`th placeholder the way the dialect spells it: `$n` on Postgres, `?n` on SQLite.

A statement built where no `Db` is in scope uses `sql.Composed.init(arena, sql.Spelling.of(Dialect))`, and `db.composed` rejects one spelled for the other dialect. A `Composed` statement is filled by position like a `raw` one, with the width checked at run time and the same value conversion. Its values are counted against its placeholders at run time (`error.ParamCountMismatch`), the way `raw`'s are counted while compiling. It runs unnamed, because its text comes from the model, not the program. Use `raw` whenever the statement can be written down.

## What SQLite does differently

**The text of a raw statement is yours, so you write it in the database's dialect.** Four things to know when the file is SQLite:

- **`$1`, `$2`, … are the same text on both.** SQLite's own numbered placeholder is `?1`, and `$name` there is a *named* parameter numbered by first appearance, so `$2` written before `$1` used to bind the first value. nilo rewrites `$n` as `?n` while compiling for every call that takes comptime text: `raw`, `rawOne`, `rawExactlyOne`, `rawPage`, `rawOrdered`, `rawPageOrdered` and the `Tx` versions ([ADR 204](../../adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)). `exec` takes its text at run time and sends it as written: write `?1` there, or a bare `?`, or a statement with no parameters, which is what DDL is.
- **A `Timestamp` is an INTEGER of microseconds**, not a datetime that SQLite's date functions read directly. Divide by a million and add `'unixepoch'`: `strftime('%Y-%m', issued_at / 1000000, 'unixepoch')`. A `Date` is its ten characters of text, which `date()` and `strftime` read as they are.
- **Casts are written `CAST(x AS INTEGER)`**; `::bigint` is Postgres only. A `count(*)` is already an integer on both, and so is a `sum` over an INTEGER column, so `coalesce(sum(total), 0)` needs no cast.
- **`ILIKE` is Postgres only.** SQLite's `LIKE` already ignores case for ASCII, and `COLLATE NOCASE` on the column is the lasting way to write it. `FILTER (WHERE …)` on an aggregate and `count(*) OVER ()` both work on the SQLite that nilo links.

## UNION, INTERSECT and EXCEPT

**Over one table, a set operation is a condition in `.where`, not `raw`.** `UNION`, `INTERSECT` and `EXCEPT` combine two selects with the same column list, and a Row *is* the column list, so over one table all three are boolean logic on the `WHERE` clause:

| SQL | here |
|---|---|
| `… WHERE a UNION … WHERE b` | `.where = .{ .any = .{ .{ a }, .{ b } } }` |
| `… WHERE a INTERSECT … WHERE b` | `.where = .{ a, b }` (fields are ANDed) |
| `… WHERE a EXCEPT … WHERE b` | `.where = .{ a, not_b }` |

There is no group `NOT`, and none is needed. Every single condition has a negation (`.ne`, `.distinct_from`, `.not_in`, `.not_like`, and the comparisons negate each other), De Morgan's laws hold in SQL's three-valued logic, and `.any` can nest inside itself. So `NOT (x AND y)` is `.any = .{ .{ not_x }, .{ not_y } }`, and `NOT (x OR y)` is `.{ not_x, not_y }`. The full list of conditions is in [the reference](../../reference/sql.md#conditions).

Over **two** tables, a set operation belongs in the schema rather than in the call: write a view and put a Row over it, which works because views can be read like tables:

```sql
CREATE VIEW all_orders AS
  SELECT id, total, placed_at FROM current_orders
  UNION ALL
  SELECT id, total, placed_at FROM archived_orders;
```

([ADR 052](../../adr/052-a-set-operation-over-one-table-is-a-condition.md).)

## Several statements in one round trip

**There is no pipelining, because the round trip is not the cost worth saving.** It was measured: **a round trip to Postgres is 24 µs and the query inside it is about 2**, so latency is the cost, and concurrency hides it. A server here serves **215,000 requests a second with a real query in every one**, because a waiting fiber frees its thread ([ADR 053](../../adr/053-a-round-trip-is-not-the-cost-worth-chasing.md)).

When several statements really do have to happen together, SQL already does that in one round trip, and `db.raw` can send it:

<!-- compiles: body -->
```zig
const Revoked = struct {
    pub const nilo_table = .projection;

    id: i64,
};

_ = try db.raw(Revoked, c,
    "WITH gone AS (DELETE FROM sessions WHERE user_id = $1 RETURNING id) " ++
    "INSERT INTO audit (kind, ref) SELECT 'session_revoked', id FROM gone " ++
    "RETURNING ref AS id",
    .{user_id},
);
```

This is atomic without a transaction, which also saves the `BEGIN` and the `COMMIT`. Many rows of the same shape go through [`db.insertMany`](../../reference/sql.md#a-batch), which has always been one statement.
