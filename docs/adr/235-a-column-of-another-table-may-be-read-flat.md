# A column of another table may be read flat, through a reference

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)
**Extends:** [ADR 218](./218-a-row-may-carry-its-parent-its-children-or-a-sum.md)

## Context

A parent field is a Row, so it is a nested object in the response: `customer: { name }` ([ADR 218](./218-a-row-may-carry-its-parent-its-children-or-a-sum.md)). Every response in nodeflux-os is flat instead: `dealName`, `ownerName`, `stateCategory`, `customerName`. The contract is an `openapi.yaml` generated from the Go server, and the port serves it byte for byte to the same frontend. So a response Row that gained a parent was an API break. Every read that joined for a name either stayed raw or copied the parent into a flat struct by hand, which is the DTO layer item 46 deleted. Fourteen of the port's 89 raw statements were this (item 83). The internal reads converted fine, because nothing serialises them.

## Decision

**`pub const nilo_through` names a field that reads one column of another table, reached through the references a path of columns follows.**

```zig
const DealLine = struct {
    pub const nilo_table = Deal;
    pub const nilo_through = .{
        .owner_name = .{ .owner_staff_id, .full_name },
        .customer_kind = .{ .org_unit_id, .customer_id, .kind },
    };
    id: sql.Uuid,
    title: Str,
    owner_name: Str,
    customer_kind: ?CustomerKind,
};
```

Every name but the last is a column with a `.references` of that one column, followed from the table before it, starting at the Row's own. The last is a column of the table reached, unread ones included ([ADR 234](./234-a-table-row-may-declare-a-column-it-does-not-read.md)). **The field is a field of the Row, so the response is flat without the HTTP module knowing anything.** The JSON writer writes the struct it is given.

Everything else goes the way a parent's does:

- **One join per hop**, under an alias its path names, `"#t/org_unit_id.customer_id"`, shared by every field that goes the same way. A `LEFT JOIN` when the reference may be null, or when a join above it is outer. A reference points at one row or none, so the row count and `.limit` are untouched.
- **The field is optional exactly when a reference on the way, or the column itself, may be null.** Each direction is a Refusal with the type to write, for the reason a parent's `?` is checked.
- **`.where` and `.order` name the field like a column.** A condition is written against the joined column, and a count joins only the hops its condition reads. On a grouped Row the field is a key of the group.
- **It is a field of a narrower Row.** The Row that names its table describes the table, so `nilo_through` there is refused beside `nilo_via` and the rest. A parent's Row may carry one, joined under the parent's path.

**A row the path does not reach reads null unless the entry says otherwise** (item 109). The entry is then a struct with the path in it:

```zig
pub const nilo_through = .{
    .tracks_range = .{ .path = .{ .kind_id, .tracks_version_range }, .otherwise = false },
    .deal_name = .{ .path = .{ .deal_id, .name }, .join = .inner },
};
```

- **`.otherwise = <value>`** is what the field reads when the path does not reach or the column is null: `COALESCE(column, value)`. The value is a literal of the column's type, written the way a `.default` is, and the field is the column's own type. The `SELECT` list, a condition, an order and a group all name the same expression, so `.where = .{ .tracks_range = false }` matches the unclassified row the answer shows as `false`.
- **`.join = .inner`** leaves out a row the path does not reach: every hop of the path is an inner join. The join belongs to the Row, so another field through the same hop reads a row that is there, and is held to the type that says so. A count joins it whatever its condition names, so `db.page`'s total and `db.count` agree with the list. It is refused inside a parent that may be missing, where an inner join after the outer one would leave out every row whose parent is missing.
- Each is refused where it says nothing: `.join = .inner` on a path with no reference that may be null, `.otherwise` on a column that is never null behind references that never are, and `.join = .left`, which is what a join already is wherever it may miss.

**A raw statement may read into a Row with a through field** (item 108). The field is one column, which is what a raw statement fills by position, and the first run holds its type the way it holds any column's ([ADR 233](./233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)).

The path is of reference columns, not of parent fields. The field is not a parent, and a path of columns is how an aggregate's `.where` already reaches another table: `.org_unit_id = .{ .customer_id = .{ .kind = … } }`.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none. The column is read into the Row like any other, and `.otherwise` is a literal in the statement. |
| Memory per idle connection | zero. |
| Throughput and p99 | one join per hop, which is the join the hand-written statement had. |
| Binary size | not measured. The reader treats the field as a column, so no run-time code is added. |

## What was rejected

**A flattening option on the JSON side**, `nilo_json` with a prefix for a parent. The SQL module may not reach the HTTP module's writer ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)). The field would also keep its nested type in Zig, and the flat name would exist only on the wire, where the compiler cannot check it.

**`.{ .deal, .name }`, a path through a parent field the Row does not have.** It names a field that is not there. Where the Row does have that parent, the column is already on the wire, nested.

**`.otherwise` as the field's default value**, `tracks_range: bool = false`, with the reader putting it in for a null. It is Zig, and it would be read after the database answered, so a condition or an order on the field would see the null and the answer would show `false`: a filter on `false` would miss exactly the rows it shows.

**`.required` as a word at the end of the path**, `.{ .deal_id, .name, .required }`, the port's suggestion. A column may be called `required`, so the word would be read as a column the day one is. It also says what the field is, not what the statement does to the row, and leaving a row out is the part a reader has to see.

**A non-optional field over a nullable reference taken as an inner join**, with no word. It would make a type change drop rows from every list over the Row, and the refusal that catches `added_by_name: ?Str` over a reference that is never null is the same check the other way round.

**Only one hop.** "Won deals by customer kind" is two references from a deal, and an aggregate's `.where` already goes that far. Allowing it here too costs no new rule.
