# A Row may carry its parent, its children, or a sum

**Status:** accepted
**Amends:** [ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md), [ADR 0171](./0171-a-row-over-there-is-a-condition.md)

## Context

[ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md) drew the module's line in one sentence, *one table, conditions that filter rows*, and sent everything past it to `db.raw`. [ADR 0171](./0171-a-row-over-there-is-a-condition.md) moved `EXISTS` across the line and said what the line actually protects: **the column list does not change**, so the Row still describes the answer, and **the row count does not change**, so `.limit = 20` still means twenty of the thing being listed. Joins, nested rows and aggregates stayed on the far side, in one roadmap entry, on the grounds that each of them breaks one of the two.

That was true of joins and aggregates as a query builder spells them, and it was measured against a module nobody had used for a whole application yet. Two applications have been built on it since, and every statement either of them hands to `db.raw` was read and sorted:

| | raw statements | one table | a join to one row | an aggregate | a join to many | CTE, union, lateral, window |
|---|---|---|---|---|---|---|
| nodeflux-os `backend-zig` (Postgres) | 178 | 58 | 46 | 51 | 1 | 12 |
| geotax (SQLite) | 94 | 12 | 17 | 53 | 1 | 2 |

The "one table" column is statements a typed call could already have written and did not, usually because they sat beside a join and one style per file won. The rest is what the line costs in practice. **A join to one row and an aggregate are 63 and 104 statements**, far more than everything else past the line put together, and they are the two ordinary things every list screen needs: *show the customer's name beside the order*, *count and sum by customer*. Each one is a `SELECT` list typed twice, once as SQL and once as a Row, held together by the positional check of [ADR 0148](./0148-a-raw-statement-is-counted-while-compiling.md) and nothing else. A column renamed in a migration is a runtime surprise in exactly the statements the module was built to make safe.

The other half of the evidence is what those statements look like. A join to many almost never appears as a join, because a join to many breaks pagination, which is ADR 0171's second property. It appears as a `LATERAL` subquery with `json_agg`, or as a second `db.raw` per parent in a loop. The first is a document parsed back per row; the second is N+1.

The question was whether any of this can be said without the builder ADR 0039 refused: a chain of calls, `.join(...)`, `.groupBy(...)`, `.having(...)`, carrying its state in its return type.

## Decision

**A narrower Row may say three more things about itself, and the call site does not change.** It is still `db.select`, `db.one`, `db.find`, `db.page`, `db.count`, `db.exists` and `db.stream` with `.where`, `.order`, `.limit` and `.offset`. There is no `.join`, no `.group_by` and no `.having` to write there, and no new option at all.

```zig
const CustomerName = struct {
    pub const nilo_table = Customer;
    name: Str,
};

const LineBrief = struct {
    pub const nilo_table = Line;
    sku: Str,
    qty: i32,
};

// A parent, and children.
const OrderCard = struct {
    pub const nilo_table = Order;
    id: i64,
    total: i64,
    customer: CustomerName,        // JOIN customers, through orders.customer_id
    approver: ?StaffName,          // LEFT JOIN, because approver_id may be null
    lines: []const LineBrief,      // a second statement, for every order at once
};

// A group.
const ByCustomer = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .orders = .count, .revenue = .{ .sum = .total } };
    customer: CustomerName,        // a key of the group
    orders: i64,
    revenue: i64,
};

const cards = try db.page(OrderCard, c, .{ .where = .{ .customer = .{ .name = "Acme" } }, .order = .{ .id = .desc }, .limit = 20 });
const best = try db.select(ByCustomer, c, .{ .where = .{ .revenue = .{ .gt = 1000 } }, .order = .{ .revenue = .desc } });
```

### A parent is a field whose type is a Row

A field of a narrower Row whose type is another Row, or an optional of one, is the row a reference points at. It is joined in the same statement, under the field's name, and its columns are read into it.

**Which reference it follows is read out of the schema**, with the rules `.exists` already uses: one `.references` from this table to that one is the join; none is refused, because a join guessed from a column name answers a question nobody asked; two is refused, because `owner_staff_id` and `approver_staff_id` both pointing at `staff` means the field's meaning has to be said. It is said with `pub const nilo_via = .{ .approver = .approver_staff_id };`, which may also name a column no `.references` covers, and then joins it to the other table's single key.

**The field is optional exactly when the reference can be null**, and both directions are refused. A nullable reference is a `LEFT JOIN`, and a field that cannot hold null would be filled from a row that is not there. A reference that cannot be null makes the `?` a branch no caller will take. Parents nest; a join under a `LEFT JOIN` is itself a `LEFT JOIN`, so a missing parent stays missing all the way down. An optional parent answers one more column, `(alias.key IS NOT NULL)`, because its own columns cannot say whether it is there: a parent that exists may hold nothing but nulls.

**This keeps both of ADR 0171's properties.** A reference points at one row or none, so the join cannot change how many rows there are, and the columns it adds belong to the field that asked for them. The Row still describes the answer; it describes it as a tree.

### Children are a slice field, read by a second statement

A field `[]const C`, where `C` is a Row whose table points back at this one, is the rows that point here. **They are never joined.** Once the parents are read, one more statement reads the children of every parent at once:

```sql
SELECT "lines"."sku" AS "sku", "lines"."qty" AS "qty", "#k"."key" AS "#parent"
FROM unnest($1::int8[]) WITH ORDINALITY AS "#k"("value", "key")
JOIN "lines" ON "lines"."order_id" = "#k"."value"
ORDER BY "#k"."key", "lines"."id"
```

SQLite spells the list `json_each(?1) AS "#k"`, which answers the same two columns. **The parents' keys go in as one list and come back as their positions**, sorted by position, so the reader walks the parents and the children in step and hands each parent a contiguous run of one list. No key is ever compared, hashed or collated on the way, which matters for a text key and for a `Uuid` whose two Dialects store it differently.

`.limit` has counted the parents by the time this runs, so a page is twenty orders whatever they hold, and that is ADR 0171's second property kept by construction rather than by care. Within one parent the children are in their table's key order. The Row has to read the column the children point at, since that is what they are handed out by, and forgetting it is a Refusal that names the field to add.

**It is one level.** A child may have parents of its own, which are joined into the children's statement, but not children: a second level would be a third statement per level with nowhere principled to stop, and it is a call of its own. A reference of several columns is refused for now, because the list is one value per parent. `db.stream` refuses children, because a stream never holds the rows the children would be handed to.

**Two statements are two snapshots unless a transaction makes them one.** Outside a `Tx`, a child inserted between them can appear under a parent read before it existed. That is stated rather than prevented: `tx.select` is the same call and holds, and a read that cannot tolerate it is already in a transaction for other reasons.

### A grouped Row says what it sums

`pub const nilo_aggregate` names the fields that are computed, and how:

| word | reads | field type |
|---|---|---|
| `.count` | `count(*)` | `i64` |
| `.{ .count = .col }` | `count(col)` | `i64` |
| `.{ .count_distinct = .col }` | `count(DISTINCT col)` | `i64` |
| `.{ .sum = .col }` | `sum(col)` | `i64` over whole numbers, `f64` over floating ones, the column's own type over a text-carried number such as `Decimal` |
| `.{ .min = .col }`, `.{ .max = .col }` | `min(col)`, `max(col)` | the column's type |
| `.{ .avg = .col }` | `avg(col)` | `f64` |

**Every other field is a key of the group**, a parent's columns included, and they are the `GROUP BY` in declaration order. The Row is one row per group, and says so in its type, which is what makes `.limit` count groups honestly: the thing being listed *is* a group.

**The type is a rule rather than a guess, and it is checked.** Both databases answer `sum` over an `integer` column as something wider, and Postgres answers it as `numeric`, which is why the Postgres Dialect writes `sum(x)::int8` and `avg(x)::float8`. A field is optional exactly when the computation can be null: over a nullable column, and for `sum`, `min`, `max` and `avg` on a Row with no keys at all, which answers even when nothing matched. `count` is never null. Each direction is a Refusal with the type to write.

**A condition goes where it belongs by what it names.** A term on a column of the table or of a parent is a `WHERE`, applied before grouping; a term on an aggregate field is a `HAVING`, applied after. One `.where` carries both, and nothing at the call site says which is which, because the Row already does. An aggregate inside `.any` is refused: an alternative cannot be half `WHERE` and half `HAVING`.

**A Row with no keys is exactly one row.** `db.select` of it would always hold one, and `db.one` would never say null, so it is read with a new call, `db.exactlyOne(Row, c, .{ .where = … })`, which answers the Row itself. A condition on its aggregates is refused, because it would turn "exactly one" into "maybe none".

### Every column is answered under the path to its field

A shaped statement names every column it answers: `"id"`, `"customer.name"`, `"approver.#"`, `"#total"`, `"#parent"`. `ORDER BY` of a bare name means the answer's column of that name in both databases, so `.order = .{ .customer = .{ .name = .asc } }` and `.order = .{ .revenue = .desc }` compile to `ORDER BY "customer.name" ASC` and `ORDER BY "revenue" DESC` with no second vocabulary. `sql.Ordering` takes the same names at run time, a parent's as a tuple, `.{ .customer, .name }`. Every column is also qualified by its relation, because two joined tables both have an `id`. The table the statement reads keeps its own name rather than an alias, which is what lets a nested `.exists` correlate with it exactly as before; a parent whose field name would collide with that relation is refused.

### Where each call stands

| | parent | children | grouped | no keys |
|---|---|---|---|---|
| `select`, `one`, `page` | yes | yes | yes | refused, `exactlyOne` |
| `find` | yes | yes | refused: a group has no key | refused |
| `count`, `exists` | yes, joining only the parents the condition names | yes | yes, counting groups | refused |
| `stream` | yes | refused | yes | refused |
| `exactlyOne` | | | | yes |
| `.lock` | refused | refused | refused | refused |
| writes, `raw`, `composed` | refused | refused | refused | refused |

Every call has its `tx.*` twin. A grouped `db.count` counts groups, by wrapping the grouped statement: `SELECT count(*) FROM (…) AS "#groups"`. A `.lock` is refused because it would lock a row of every table joined, which is not what anyone holding one order meant. A write through a shaped Row is refused because an answer is not written back.

## Against ADR 0018's four axes

- **Allocations per request: none added to a path that did not ask.** A flat Row is read by the same code it was: `readRow` is the loop `filling` had, generalised by kind, and `db.zig`'s allocation tests, `test "a select with a written-out limit reaches past the arena exactly once"` among them, pass unchanged. A parent adds nothing, because its columns are read into the Row that was going to be allocated anyway. **Children cost, per statement, one array of keys and one array of run ends, each one word per parent, plus the list the children are read into**, which doubles as it grows because how many will arrive is not known. On SQLite the key list is one JSON text, one allocation. A grouped Row allocates what a flat Row of the same width does.
- **Memory per idle connection: zero.** Nothing here lives on a connection.
- **Throughput and p99: one round trip for a parent or a group, the same as the `db.raw` it replaces; two for children, against N+1 for the loop it replaces.** What the database does with the join is the caller's plan, exactly as it was when the caller wrote it by hand.
- **Binary size: nothing for a program with no shaped Row.** `zig build size-sql`, stripped `ReleaseFast`, built from `3713789` and from this change: +80 bytes on the Postgres program and −352 on the SQLite one, and −160 on `bench-sql-server`. Layout rather than code; the statements are comptime and the flat reader it generalised does the same work ([`sql.md` §14](../../bench/result/sql.md#14-a-row-with-a-parent-children-or-a-sum-costs-a-program-without-one-nothing)).

## Alternatives rejected

**A `.join` option, or a chain of calls.** It is ADR 0039's rejection and it stands for the same reason: a chain carries its state in its return type, and what a reader gets when it does not fit is a tower of generics rather than a sentence. It would also split the answer's description across the call site and the Row. Here the Row is still the whole description, so a list and a detail endpoint reading the same Row read the same shape.

**A Row that describes the whole query**, with `pub const nilo_query = .{ .join = …, .group_by = … }`. It moves the builder into a declaration rather than removing it. Every clause it could hold is one this design derives from a field's type, and deriving it is what makes a mismatch between the SQL and the struct unrepresentable rather than checked.

**Inferred result types, the way Prisma's `include` and Drizzle's `with` work.** The answer's type is computed from the call, so the caller never writes it. That is the most convenient shape in a language with structural types and the least readable one in Zig: the type a handler returns is then something nobody wrote down, its compile errors name a generated struct, and the OpenAPI document of [ADR 0017](./0017-the-api-description-comes-from-the-signatures.md) describes a type that is not in the source. A Row written out is a line more and is the contract.

**Children as a `LATERAL` join with `json_agg`**, which is what nodeflux-os writes by hand. One round trip instead of two, and it costs a JSON document built by the database and parsed back per parent into the arena, with its own type story for every column inside it, on Postgres only. SQLite has `json_group_array` and no `LATERAL`, so the two Dialects would have answered with different statements of different shapes. Two plain statements are the same on both and read with the same code as every other row.

**Children matched by key rather than by position.** A hash map from key to parent costs an allocation per parent and a comparison per child, and makes a `Uuid` key on SQLite, stored as text, and on Postgres, stored as bytes, two code paths. The ordinal is the parent's position, which the reader already has.

## What is still refused

A join to a table that no reference or `nilo_via` connects; a join with a condition in its `ON`; a self-join through the same field twice (two fields do it, under two names); children of children; children through a reference of several columns; `DISTINCT`; window functions other than the page total; CTEs, unions and set operations; an aggregate over an expression rather than a column. Each is `db.raw`, which is unchanged, and each is written down so that the next person to want one starts from which of the two properties it would have to keep.

## Consequences

- **`nilo_via` and `nilo_aggregate` are markers on a narrower Row only.** A Row that describes its table, the one migrations read, is refused if it carries a parent, children or either marker, because its fields are the table's columns and its DDL would otherwise have a column for a customer.
- **`db.exactlyOne` and `tx.exactlyOne` are new**, and so are `sql.exactlyOneFor` and `sql.childrenFor` for reading the statements while compiling.
- **The `db.raw` column check refuses a shaped Row**, since only a statement nilo wrote can name a parent's columns for their path.
- **Twenty-five Refusals**, one per rule above, in `sql/refusals/shape_*.zig`.
- **The roadmap's joins entry closes**, with what is still refused moved to `docs/decided.md`.
- **Three words enter `CONTEXT.md`**: Parent field, Children field, Grouped Row. *Relation*, *association*, *include*, *eager load*, *preload* and *populate* are refused, the first because this module already uses it for a table's name in a statement and the rest because each names an ORM's mechanism rather than what the field is.
