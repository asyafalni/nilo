# A table is a struct

**A Row is a plain Zig struct that names its table, and its fields are the columns; everything else in this guide reads and writes one.**

**Reference:** [A Row](../../reference/sql.md#a-row), [Types](../../reference/sql.md#types) · **Design:** [SQL column types](../../design/sql-types.md)

## Declaring a Row

This is the first page of [Talking to a database](./README.md): the Row, and what its fields may be.

<!-- compiles -->
```zig
const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.email},
        .default = .{ .age = 0, .orders = 0, .created_at = .now },
    };

    id: i64,
    email: nilo.Str,
    name: nilo.Str,
    age: i32,
    orders: i32,
    created_at: sql.Timestamp,
};

comptime {
    _ = User;
}
```

`.unique = .{.email}` is the constraint that upserts on the writing page conflict on, and the one `sql.violated(c, User, .{.email})` names when a signup collides. [Migrations](./migrations.md) covers everything else the marker can say.

**The table name is written out, never guessed.** Guessing `User` → `users` looks clever until `Category`, and every framework that guesses ends up shipping a list of irregular nouns.

`.name = "app.users"` means a schema and a table. It is quoted as two identifiers and looked up in that schema. A bare name is whatever `search_path` resolves to, as it always was. Only one dot with something on each side is allowed; anything else is a compile error, because `a.b.c` names a relation nobody created and Postgres would only say so at run time.

`.key` names the column that identifies a row. It defaults to `id` when there is a field called that.

## A column the Row does not read

**A column the response should not show goes in [`.unread`](../../reference/sql.md#a-row), with its type.** The Row that names its table is often the response too, and every field becomes a key of the JSON it writes. A `created_at` the API never served is the usual case:

<!-- compiles -->
```zig
const Note = struct {
    pub const nilo_table = .{
        .name = "notes",
        .default = .{ .created_at = .now, .updated_at = .now },
        .unread = .{ .created_at = sql.Timestamp, .updated_at = sql.Timestamp },
    };

    id: i64,
    body: nilo.Str,
};

fn newest(db: *sql.Db, c: *nilo.Ctx) ![]Note {
    return db.select(Note, c, .{ .order = .{ .created_at = .desc }, .limit = 20 });
}
```

To everything except this Row's `SELECT` list, it is still a column of the table: the migration creates it, [`db.checking`](../../reference/sql.md#db) holds it against the database, and `.where`, `.order` and `.set = .{ .updated_at = .now }` can name it, on this Row and on every Row that borrows the table. A Row that wants to read it carries it as a field. An insert of `Note` cannot write it, so a column that is not optional needs a `.default` or `.filled`, and the compiler asks for one by name ([ADR 234](../../adr/234-a-table-row-may-declare-a-column-it-does-not-read.md)).

## Money

**[`sql.Decimal`](../../reference/sql.md#types) reads a `numeric` column, and it holds text:**

<!-- compiles: body -->
```zig
const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,        // numeric
};

const invoice = (try db.find(Invoice, c, 1)).?;
const total = invoice.total.text;                    // "1234.56"
_ = try db.insert(Invoice, c, .{ .total = sql.Decimal{ .text = "9.99" } });
```

There is no `.add` and no `.round`, the same as `sql.Timestamp`: **a type here holds a value and knows how to write itself, but does no arithmetic.** Decimal arithmetic is a library of its own, and a bigger one than it looks (rounding modes alone are a standard). What this type guarantees is that the digits you put in are the digits you get back, which a live test checks with a value twenty-nine significant digits wide.

Comparisons are numeric, not textual: `.{ .total = .{ .gt = sql.Decimal{ .text = "50" } } }` finds `100.00` and not `9.99`.

**In a JSON body it is a string**, `"1234.56"` rather than `1234.56`. A bare number is exact on the wire but stops being exact in the consumer, where `JSON.parse` returns a double: the same `f64` the column type was chosen to avoid, handed over silently on the other side of the network. A string arrives intact ([ADR 049](../../adr/049-a-column-type-can-come-from-outside-this-module.md)). It is also the only form that can carry `nan` and `inf`, which Postgres allows and JSON has no number syntax for.

Unlike `sql.Json(T)` it **streams**: in a `Borrowed` row the field is a plain `[]const u8`, so `db.stream` still allocates nothing per row.

## Lists

**An array column is a plain Zig slice**, with no wrapper around it:

<!-- compiles -->
```zig
const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const nilo.Str,    // text[]
    scores: ?[]const i32,      // integer[], and the column may be null
    owners: []const sql.Uuid,  // uuid[]
};

comptime {
    _ = Ticket;
}
```

Reading one is an ordinary Zig `for`:

<!-- compiles: body -->
```zig
const ticket = (try db.find(Ticket, c, 1)).?;
for (ticket.tags) |tag| std.log.info("{s}", .{tag.view()});
```

`[]const u8` already means text, so a list of text is `[]const Str` or `[]const []const u8`, never `[]const u8`. Writing one looks the way you would expect:

<!-- compiles: body -->
```zig
_ = try db.insert(Ticket, c, .{ .tags = &.{ "urgent", "billing" }, .scores = null, .owners = &.{} });
```

Postgres allows two things in an array that a Zig slice cannot hold:

- **A NULL among the elements.** Any Postgres array may contain one, and no column definition can forbid it. Read into `[]const Str`, it fails the request; read the column as `[]const ?nilo.Str` and the nulls come through.
- **More than one dimension.** A column declared `integer[]` will happily store `ARRAY[[1,2],[3,4]]`. A slice is one level deep, so that fails the request too.

Both used to crash the process inside the driver ([ADR 045](../../adr/045-an-array-is-a-slice-and-a-slice-is-one-deep.md)).

`[]const sql.Uuid` is `uuid[]`. It reads, writes and works as an `.in` list, which is what prevents an N+1 on a page that attaches children to its rows ([ADR 116](../../adr/116-a-raw-parameter-is-converted-the-way-a-rows-is.md)).

**An array's type is checked exactly at startup**: an `int4[]` column reads into a `[]const i32`, and not into a `[]const i64` the way a scalar `int4` reads into an `i64`. A Row that reads an array also cannot be used with `db.stream`, for the same reason a `Json` column cannot; see [Streaming](./reading.md#streaming-a-large-result-set).

## A column type of your own

**The column types are not a closed list: `sql.AsText` makes any Postgres type a column type.** The types above are the ones this module knows about, and Postgres has hundreds more: `interval`, `inet`, `money`, `tsvector`, and everything an extension installs.

<!-- compiles: body -->
```zig
const Money = sql.AsText("money");

const Sale = struct {
    pub const nilo_table = .{ .name = "sales", .key = .id };

    id: i64,
    amount: Money,           // money
};

const sale = (try db.find(Sale, c, 1)).?;
const shown = sale.amount.text;    // "$1,234.56", as Postgres printed it
```

`sql.Interval` and `sql.Inet` are two of these already written for you, and `sql.Decimal` is a third. None of them is a special case underneath.

A type that wants **structure** rather than text implements the protocol itself. Three declarations make anything a column type ([reference](../../reference/sql.md#a-column-type-of-your-own)):

```zig
const Cents = struct {
    value: i64,

    pub const nilo_column = "numeric";

    pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Cents {
        … parse "12.34" into 1234 …
    }

    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{d}.{d:0>2}", .{ … });
    }
};
```

The value travels as the text Postgres prints (`"amount"::text` on the way out, `$1::numeric` on the way in). Every Postgres type has a text form, which is why this module does not need to know what your type is ([ADR 049](../../adr/049-a-column-type-can-come-from-outside-this-module.md)). The column is checked against the table at startup like any other, and the type works everywhere a column type works: conditions, `.set`, `insert`, a batch.

### A `numeric` that is not money

**To read a `numeric` as an `f64` on purpose, write a column type that does the rounding.** Think of a quantity, a weight or a percentage: a `numeric(14,3)` column whose value is multiplied by a price rather than added to a ledger. `sql.Decimal` keeps the digits and does no arithmetic, and a plain `f64` field on a `numeric` column is rejected by the schema check at startup, because an `f64` reads a `float8` and the column type was chosen so that nothing rounds. So write the type once and name it for what it holds:

<!-- compiles -->
```zig
/// A quantity: a `numeric(14,3)` read as the `f64` the arithmetic wants. Past
/// fifteen significant digits an `f64` rounds, which a quantity never reaches
/// and a total of money does.
const Quantity = struct {
    value: f64,

    pub const nilo_column = "numeric(14,3)";
    pub const nilo_openapi = .{ .type = "number" };

    pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Quantity {
        _ = arena;
        return .{ .value = try std.fmt.parseFloat(f64, text) };
    }

    pub fn nilo_write(self: Quantity, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{d}", .{self.value});
    }

    pub fn jsonStringify(self: Quantity, jw: anytype) !void {
        try jw.write(self.value);
    }
};

const RabLine = struct {
    pub const nilo_table = .{ .name = "rab_lines", .key = .id };

    id: i64,
    quantity: Quantity,        // numeric(14,3)
    unit_amount_minor: i64,
};

comptime {
    _ = sql.selectFor(RabLine, @TypeOf(.{}));
}
```

The rounding is then a decision carried by the type's name, in one file, rather than a field type somebody changes from `sql.Decimal` to `f64` on one Row and forgets on the next. In JSON it goes out as a number, `"quantity": 1.5`, because that is what `jsonStringify` writes and what `nilo_openapi` declares.

Two mistakes are caught at compile time: having only one of `nilo_read` and `nilo_write`, and having both without a `nilo_column`. One limit remains: an **array** of such a type is not read, the same limit `[]const sql.Decimal` has always had.
