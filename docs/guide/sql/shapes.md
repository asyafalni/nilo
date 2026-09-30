# Parents, children and aggregates

**A Row can carry its parent row, its child rows, or sums over a group, so a list screen that shows more than one table is still `db.select`, `db.page` or `db.find`, not `db.raw`.**

**Reference:** [A parent, children, a group](../../reference/sql.md#a-parent-children-a-group) · **Design:** [The query builder](../../design/sql-query.md)

A list screen almost never shows one table. An invoice is listed with its customer's name, opened with its lines, and summed by customer on the dashboard. None of that needs `db.raw`. This page follows [reading](./reading.md).

A Row can declare three more things about itself:

- **a parent**: a field whose type is a Row of another table, joined in the same statement;
- **children**: a field `[]const C` of rows that point back at this one, read by one extra statement for all rows at once;
- **a sum**: `nilo_aggregate`, which makes the Row one row per group.

All three go on a narrower Row, one with `pub const nilo_table = <TheTablesRow>`. The Row that describes the table keeps only the table's columns, because that is what migrations read ([ADR 218](../../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).

## The example tables

**The links between tables come from `.references`**, which the tables already declare for their foreign keys:

<!-- compiles -->
```zig
const Customer = struct {
    pub const nilo_table = .{ .name = "customers", .key = .id };
    id: i64,
    name: Str,
    region: ?Str,
};

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id };
    id: i64,
    full_name: Str,
};

const Invoice = struct {
    pub const nilo_table = .{
        .name = "invoices",
        .key = .id,
        .references = .{
            .customer_id = .{ Customer, .id },
            .owner_id = .{ Staff, .id },
            .approver_id = .{ Staff, .id },
        },
    };
    id: i64,
    customer_id: i64,
    owner_id: i64,
    approver_id: ?i64,
    total: i64,
    year: i32,
};

const InvoiceLine = struct {
    pub const nilo_table = .{
        .name = "invoice_lines",
        .key = .id,
        .references = .{ .invoice_id = .{ Invoice, .id } },
    };
    id: i64,
    invoice_id: i64,
    sku: Str,
    qty: i32,
};
```

## Joining a parent row

**A field whose type is a Row of another table holds the row a reference points at**, joined in the same statement:

<!-- compiles -->
```zig
const CustomerName = struct {
    pub const nilo_table = Customer;
    name: Str,
};

const StaffName = struct {
    pub const nilo_table = Staff;
    full_name: Str,
};

const InvoiceCard = struct {
    pub const nilo_table = Invoice;
    pub const nilo_via = .{ .owner = .owner_id, .approver = .approver_id };
    id: i64,
    total: i64,
    customer: CustomerName,
    owner: StaffName,
    approver: ?StaffName,
};

fn invoices(db: *sql.Db, c: *nilo.Ctx, search: []const u8) !sql.Db.Page(InvoiceCard) {
    return db.page(InvoiceCard, c, .{
        .where = .{ .customer = .{ .name = .{ .icontains = search } } },
        .order = .{ .customer = .{ .name = .asc }, .id = .desc },
        .limit = 20,
    });
}
```

```sql
SELECT "invoices"."id" AS "id", "invoices"."total" AS "total",
       "customer"."name" AS "customer.name", "owner"."full_name" AS "owner.full_name",
       ("approver"."id" IS NOT NULL) AS "approver.#", "approver"."full_name" AS "approver.full_name",
       count(*) OVER () AS "#total"
FROM "invoices"
JOIN "customers" AS "customer" ON "customer"."id" = "invoices"."customer_id"
JOIN "staff" AS "owner" ON "owner"."id" = "invoices"."owner_id"
LEFT JOIN "staff" AS "approver" ON "approver"."id" = "invoices"."approver_id"
WHERE "customer"."name" ILIKE '%' || … || '%' ESCAPE '\'
ORDER BY "customer.name" ASC, "id" DESC LIMIT 20
```

**The join is taken from the schema.** The one `.references` from `invoices` to `customers` is the join for `customer`. Two references pointing at `staff` are a compile error until `nilo_via` says which column each field follows, because which one `staff` means is a question only you can answer. `nilo_via` can also name a column that no `.references` covers, and then it joins to the other table's key.

**`?` means the parent can be missing, and the schema has to agree.** `approver_id` may be null, so `approver` has to be `?StaffName`, and it becomes a `LEFT JOIN`. `customer_id` is never null, so `customer: ?CustomerName` is rejected too: the `?` would be a branch that never runs. A missing approver is `null`, not a `StaffName` full of nulls.

**Conditions and ordering reach into a parent through its field**, as in `.customer = .{ .name = … }`. They take the same operators as a column of the table. A parent can have parents of its own; nest them the same way.

A parent never changes how many rows come back, because a reference points at one row or none. So `.limit = 20` is still twenty invoices, and `db.count` over `InvoiceCard` joins only the parents its condition names.

### Reading a parent's column as a flat field

**[`nilo_through`](../../reference/sql.md#a-parent-children-a-group) reads a column of another table into a field of its own, so the response stays flat.** A parent is a nested object in the response, `customer: { name }`. When the API has always served `customerName` beside `total`, `nilo_through` gives you that shape:

<!-- compiles -->
```zig
const InvoiceFlat = struct {
    pub const nilo_table = Invoice;
    pub const nilo_through = .{
        .customer_name = .{ .customer_id, .name },
        .approver_name = .{ .approver_id, .full_name },
    };
    id: i64,
    total: i64,
    customer_name: Str,
    approver_name: ?Str,
};

fn flatInvoices(db: *sql.Db, c: *nilo.Ctx, search: []const u8) ![]InvoiceFlat {
    return db.select(InvoiceFlat, c, .{
        .where = .{ .customer_name = .{ .icontains = search } },
        .order = .{ .approver_name = .asc_nulls_last },
    });
}
```

Each entry lists the reference columns to follow and, last, the column to read, so `.{ .org_unit_id, .customer_id, .kind }` goes two tables away. The join is the same one a parent would use, under an alias of its own (`"#t/customer_id"`), and two fields that go the same way share it. `approver_id` may be null, so `approver_name` is `?Str`. The rule is the same as for a parent: the field is optional exactly when a reference on the way, or the column itself, may be null. In `.where` and `.order` you name the field like a column.

**A row the path does not reach reads null.** When the response should have no null there, the entry says what to do instead, and becomes a struct with the path in it:

<!-- compiles -->
```zig
const InvoiceApproved = struct {
    pub const nilo_table = Invoice;
    pub const nilo_through = .{
        .customer_region = .{ .path = .{ .customer_id, .region }, .otherwise = "unassigned" },
        .approver_name = .{ .path = .{ .approver_id, .full_name }, .join = .inner },
    };
    id: i64,
    customer_region: Str,
    approver_name: Str,
};

fn approvedInvoices(db: *sql.Db, c: *nilo.Ctx) ![]InvoiceApproved {
    return db.select(InvoiceApproved, c, .{ .order = .{ .customer_region = .asc } });
}
```

`.otherwise` is `COALESCE(column, 'unassigned')`, and the condition and the order use the same expression, so a filter on `"unassigned"` finds exactly the rows the answer shows that way. `.join = .inner` leaves out the invoices nobody approved, and a count and a page's total leave them out too. Both fields are `Str`, because neither can be null any more. Two fields through the same reference share its join, so a second field through `approver_id` on this Row is never null either.

A raw statement can read into a Row like this one: a through field is one column of the `SELECT` list, filled by position like the rest ([ADR 235](../../adr/235-a-column-of-another-table-may-be-read-flat.md)).

## Reading child rows

**A field `[]const C`, where `C` reads a table that points back here, holds every row that points at this one:**

<!-- compiles -->
```zig
const LineBrief = struct {
    pub const nilo_table = InvoiceLine;
    sku: Str,
    qty: i32,
};

const InvoiceDetail = struct {
    pub const nilo_table = Invoice;
    id: i64,
    total: i64,
    customer: CustomerName,
    lines: []const LineBrief,
};

fn invoice(db: *sql.Db, c: *nilo.Ctx, id: i64) !?InvoiceDetail {
    return db.find(InvoiceDetail, c, id);
}
```

**Children are never joined.** After the invoices are read, one more statement reads the lines of all of them at once, so a page of twenty invoices is two statements, not twenty-one:

```sql
SELECT "invoice_lines"."sku" AS "sku", "invoice_lines"."qty" AS "qty", "#k"."key" AS "#parent"
FROM unnest($1::int8[]) WITH ORDINALITY AS "#k"("value", "key")
JOIN "invoice_lines" ON "invoice_lines"."invoice_id" = "#k"."value"
ORDER BY "#k"."key", "invoice_lines"."id"
```

Each invoice gets its own lines, in the lines' key order, and an invoice with none gets an empty slice. `.limit` has already counted the invoices by then, so a page is twenty invoices however many lines they have.

The Row has to read `id`, the column the lines point at, because that is how each line finds its invoice. Leaving it out is a compile error that says so.

**Two statements see two snapshots unless a transaction makes them one.** Outside a `Tx`, a line added between the two statements can appear under an invoice read before the line existed. Inside a `Tx`, `tx.select` and `tx.find` are the same calls and cannot see that.

Children go one level deep. A child can have parents, which are joined into the second statement, but it cannot have children of its own. `db.stream` rejects a Row with children, because a stream never holds the rows the children would be attached to.

### Ordering, filtering and counting children

**`pub const nilo_children` sets the rest, keyed by field name:**

<!-- compiles -->
```zig
const InvoiceSummary = struct {
    pub const nilo_table = Invoice;
    pub const nilo_children = .{
        .lines = .{ .order = .{ .qty = .desc }, .where = .{ .qty = .{ .gt = 0 } } },
        .line_count = .{ .count = InvoiceLine },
        .bulk_lines = .{ .count = InvoiceLine, .where = .{ .qty = .{ .gte = 100 } } },
    };
    id: i64,
    lines: []const LineBrief,
    line_count: i64,
    bulk_lines: i64,
};

fn busiest(db: *sql.Db, c: *nilo.Ctx) ![]InvoiceSummary {
    return db.select(InvoiceSummary, c, .{
        .where = .{ .line_count = .{ .gt = 0 } },
        .order = .{ .line_count = .desc },
        .limit = 20,
    });
}

comptime {
    _ = sql.childrenFor(InvoiceSummary, "lines");
}
```

**A list of children takes `.order` and `.where`.** The order uses columns of the child's table, and the child's key is always added last, so two lines with the same `qty` come back in the same order every time. A key minted as a v7 id follows the order rows were created in, which is not the order a user just set by dragging lines around, so a list with a `position` column wants `.order = .{ .position = .asc }`.

**A count is an `i64` field that reads no child rows.** It is a subquery on each row, in the same statement:

```sql
(SELECT count(*) FROM "invoice_lines" AS "#c" WHERE "#c"."invoice_id" = "invoices"."id") AS "line_count"
```

So a badge that says *12 lines* costs one index lookup per invoice on the page, instead of reading every line into memory to take `.len`. Put an index on the column that points back: Postgres does not create one for a foreign key. A count can be used in `.order` and `.where` like a column, and it can be on a parent's Row too.

**A `.max` or `.min` is the same subquery with a different function.** It names the Row and the column together, `.{ .max = .{ Invoice, .total } }`, because a column alone does not say which table it is on. The field is an optional of the column's type, because a customer with no invoices has no biggest one:

<!-- compiles -->
```zig
const CustomerPulse = struct {
    pub const nilo_table = Customer;
    pub const nilo_children = .{
        .biggest = .{ .max = .{ Invoice, .total } },
        .budi_approved = .{ .count = Invoice, .where = .{ .approver_id = .{ .full_name = "Budi" } } },
    };
    id: i64,
    name: Str,
    biggest: ?i64,
    budi_approved: i64,
};

comptime {
    _ = sql.selectFor(CustomerPulse, @TypeOf(.{ .order = .{ .biggest = .desc_nulls_last } }));
}
```

The second entry's `.where` goes through `approver_id` into the staff row it points at, the same way an aggregate's does below. That table is joined once, inside the subquery, and a reference points at one row or none, so what is counted is still invoices.

Every `.where` here has its values written in, because it is part of the Row, not of a request. It accepts a value, `null`, `.eq`, `.ne`, `.gt`, `.gte`, `.lt`, `.lte`, `.in` and `.not_in`, `.now` and `.today`, and a path through a reference. A filter that comes from the request goes in the read's own `.where`. A `.limit` on a list of children is rejected, because one statement reads the children of every row and a limit there would cut across rows.

## Grouping and aggregates

**`nilo_aggregate` names the fields that are computed; every other field is a group key:**

<!-- compiles -->
```zig
const ByCustomer = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{
        .invoices = .count,
        .revenue = .{ .sum = .total },
        .largest = .{ .max = .total },
        .mean = .{ .avg = .total },
    };
    customer: CustomerName,
    invoices: i64,
    revenue: i64,
    largest: i64,
    mean: f64,
};

fn bestCustomers(db: *sql.Db, c: *nilo.Ctx, year: i32) ![]ByCustomer {
    return db.select(ByCustomer, c, .{
        .where = .{ .year = year, .revenue = .{ .gt = 1_000_000 } },
        .order = .{ .revenue = .desc },
        .limit = 10,
    });
}
```

```sql
SELECT "customer"."name" AS "customer.name", count(*) AS "invoices",
       sum("invoices"."total")::int8 AS "revenue", max("invoices"."total") AS "largest",
       avg("invoices"."total")::float8 AS "mean"
FROM "invoices" JOIN "customers" AS "customer" ON "customer"."id" = "invoices"."customer_id"
WHERE "invoices"."year" = $1
GROUP BY "customer"."name"
HAVING sum("invoices"."total") > $2
ORDER BY "revenue" DESC LIMIT 10
```

`year` is not a field of `ByCustomer`, yet it is in the condition. **A grouped Row's condition can name any column of the table, not only the Row's fields**, because the rows being grouped are the table's rows. A term on a column or a parent's column becomes `WHERE`, applied before grouping; a term on an aggregate field becomes `HAVING`, applied after. You do not mark which is which at the call site, because the Row already says.

The aggregate words are `.count`, `.{ .count = .col }`, `.{ .count_distinct = .col }`, `.{ .sum = .col }`, `.{ .min = .col }`, `.{ .max = .col }` and `.{ .avg = .col }`. **Each has a required field type, and a wrong type is a compile error that names the right one:**

| word | field |
|---|---|
| any count | `i64`, never null |
| `sum` | `i64` over whole numbers, `f64` over floating ones, the column's own type over a `Decimal` (Postgres only; SQLite refuses an aggregate over a `Decimal`) |
| `min`, `max` | the column's type |
| `avg` | `f64` |

A field is `?` exactly when the result can be null: over a nullable column, where a group of nulls sums to null. `db.page` on a grouped Row counts groups, and so does `db.count`.

### Filtering one aggregate

**An aggregate entry can carry its own `.where`, which limits only the rows that one aggregate reads.** It becomes `FILTER (WHERE …)`, on both databases:

<!-- compiles -->
```zig
const RevenueByCustomer = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{
        .this_year = .{ .sum = .total, .where = .{ .year = 2026 } },
        .large = .{ .count = .id, .where = .{ .total = .{ .gte = 1_000_000 } } },
    };
    customer: CustomerName,
    this_year: ?i64,
    large: i64,
};

comptime {
    _ = sql.selectFor(RevenueByCustomer, @TypeOf(.{}));
}
```

```sql
sum("invoices"."total") FILTER (WHERE "invoices"."year" = 2026)::int8 AS "this_year",
count("invoices"."id") FILTER (WHERE "invoices"."total" >= 1000000) AS "large"
```

The values are written into the statement as given, using the same operators a children entry's `.where` accepts, over the table's columns. **A column with a `.references` also lets the filter look at the row it points at**, which is how you count by a category that lives in another table:

<!-- compiles -->
```zig
const RevenueByRegion = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{
        .west = .{ .sum = .total, .where = .{ .customer_id = .{ .region = "west" } } },
        .unapproved = .{ .count = .id, .where = .{ .approver_id = null } },
    };
    year: i32,
    west: ?i64,
    unapproved: i64,
};

comptime {
    _ = sql.selectFor(RevenueByRegion, @TypeOf(.{}));
}
```

```sql
sum("invoices"."total") FILTER (WHERE "#f.customer_id"."region" = 'west')::int8 AS "west"
… JOIN "customers" AS "#f.customer_id" ON "#f.customer_id"."id" = "invoices"."customer_id"
```

The other table is joined once, however many aggregates read it, and a reference that may be null becomes a `LEFT JOIN`, so a row without one still counts for the other aggregates. References can chain: `.org_unit_id = .{ .customer_id = .{ .kind = .government } }` is two joins. **A filtered `sum`, `min`, `max` or `avg` is always `?`, whatever its column**, because a customer with no invoice this year has nothing to sum. A filtered count is zero in that case. To count the matching rows, name a column that is never null, usually the key: `.{ .count = .id, .where = … }`.

## A total over all rows

**A grouped Row with no group keys is one row over everything the condition matched.** Read it with `db.exactlyOne`, which returns the Row itself rather than a list or a `?`:

<!-- compiles -->
```zig
const Totals = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{ .invoices = .count, .revenue = .{ .sum = .total } };
    invoices: i64,
    revenue: ?i64,
};

fn totals(db: *sql.Db, c: *nilo.Ctx, year: i32) !Totals {
    return db.exactlyOne(Totals, c, .{ .where = .{ .year = year } });
}
```

`revenue` is `?i64` here even though `total` is never null: a year with no invoices still returns one row, and the sum of no rows is null. `invoices` is zero in that case.

## What still needs `raw`

**A Row with a parent, children or aggregates is read-only.** It is a result, so an insert, an update or a `.lock` through one is rejected, and so is `db.raw` into one that has a parent or children. `DISTINCT`, window functions, CTEs, a join on a condition rather than a reference, and an aggregate over an expression still need [raw SQL](./raw.md).
