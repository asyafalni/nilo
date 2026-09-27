# A table's Row may declare a column it does not read

**Status:** accepted
**Topic:** [sql-migrations](../design/sql-migrations.md)
**Extends:** [ADR 181](./181-the-marker-has-two-kinds-of-word.md), [ADR 218](./218-a-row-may-carry-its-parent-its-children-or-a-sum.md)

## Context

The Row that names its table describes it column by column, and that is what the migration diff and `db.checking` read ([ADR 181](./181-the-marker-has-two-kinds-of-word.md)). The guide also recommends that Row as the response, and a field of a Row is a key of the JSON it writes. The two uses disagree about one kind of column: one the table has and the response has no reason to show. In nodeflux-os that is `created_at` and `updated_at` on 8 of 59 tables. The Go API never served them, and the port serves its `openapi.yaml` byte for byte.

Since item 96, a narrower Row may order and narrow by a column of its table it does not carry ([ADR 218](./218-a-row-may-carry-its-parent-its-children-or-a-sum.md)). But "a column of its table" meant a field of the table's Row. `sales.deal.succeeding` orders the Deals that follow one by `created_at`, got "Succeeding has no column `created_at`", and stayed raw. The workaround was a second Row for the table with every column, and the response Row narrowed from it. For `deals` that meant changing every write. The same gap kept the 8 tables' schema in a hand-written module, because a managed Row has to carry every column and adding the field changes the JSON (item 102).

## Decision

**The marker takes `.unread`: columns the table has, each with the type it would be read as, that this Row does not read.**

```zig
pub const Deal = struct {
    pub const nilo_table = .{
        .name = "deals",
        .default = .{ .created_at = .now, .updated_at = .now },
        .unread = .{ .created_at = sql.Timestamp, .updated_at = sql.Timestamp },
    };
    id: sql.Uuid,
    title: Str,
};
```

An unread column is a column of the table to everything that asks whether the table has one, and it is left out of what this Row reads:

- **It is in the table.** It is in the `CREATE TABLE`, the snapshot and the migration diff. A `.default`, `.filled`, `.index`, `.unique` or `.references` may name it, and `db.checking` holds it against the live table like any other column.
- **It is a column to a statement.** `.where` and `.order` name it on this Row and on every Row that borrows the table, and its value binds as the declared type. `.set = .{ .updated_at = .now }` writes it, and an insert may be handed a value for it.
- **It is in no `SELECT` list of this Row.** A narrower Row that wants it reads it as a field, at the declared type, the way it reads any other column.
- **An insert of this Row cannot write it**, so one that is not optional needs a `.default` or `.filled`. The existing insert refusal ([ADR 181](./181-the-marker-has-two-kinds-of-word.md)) names it when it has neither.

Two things are refused. A name the Row also reads as a field is refused, because a column is read or unread and saying both gives it two types. A `.key` that is unread is refused, because a row is found and handed out by its key.

It is done in the two places everything else asks, `row.hasColumn` and `row.ColumnType`, and in the three that walk the columns themselves: the table's description, the insert check, and `db.checking`. That is why the list of what an unread column takes is the list of what a column takes.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none. It is comptime: a statement over the table is the text it would be with the column carried, minus the column in the `SELECT` list. |
| Memory per idle connection | zero. |
| Throughput and p99 | none added; one column fewer read than a Row carrying it. |
| Binary size | not measured. Nothing is added at run time: the statements are constants either way, and a Row with `.unread` is read by the same reader over fewer fields. |

## What was rejected

**A column `db.checking` finds on the live table, with no Row declaring it**, the port's first suggestion. Its type would be known only once a database answered, so a `.where` on it could not be checked or bound while compiling, and a misspelled name would first fail on a live server. That is the mistake the whole module exists to move to `zig build`.

**A field left out of the JSON**, a marker on the field that the response writer skips. It puts a SQL marker in the HTTP module's writer, which is a layering break ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)). It also still reads the column on every select, only to throw it away.

**A second Row for the table with every column**, which is what the port did for checklists. It works, and it moves every write to the wide Row and every read to the narrow one. It also leaves the response Row with no way to name the column in its own `.order`.
