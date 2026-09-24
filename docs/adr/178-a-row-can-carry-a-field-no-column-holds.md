# A Row can carry a field no column holds

**Status:** accepted
**Topic:** [sql-types](../design/sql-types.md)

[ADR 148](148-a-field-name-is-a-spelling-too.md) made the Row the response
and deleted ten DTOs. The port's timeline is a `UNION ALL` into a
projection, and the projection is the response; then a comment line grew its
files — `[{id, filename, contentType, byteSize, contentUrl, inline}]` — which
no column holds. The two shapes on offer were the DTO back (a second struct
copying the Row's fields so an array can sit beside them) or
`jsonb_agg(jsonb_build_object(…))` in a correlated subquery read into a
`?sql.Payload`, which keeps the Row the answer and puts the field's JSON
spelling in a statement string, with the document saying *object*.

The second is honest SQL and half right. `sql.Json([]const Attachment)`
rather than `Payload` makes the document say `Attachment`
([ADR 163](163-a-document-is-its-value.md)), and that is the shape for a
list **the database can build**. It is not the shape for a field the
*program* fills — from a second read, from a service, from the request —
and that is the one place a Row could not be the response.

## `nilo_beside`

```zig
const Line = struct {
    pub const nilo_table = .projection;
    pub const nilo_beside = .{ .attachments };

    id: i64,
    body: Str,
    attachments: []const Attachment = &.{},
};
```

A second declaration on the Row, naming the fields **beside** its columns.
A field named there is on the Row, in its JSON and in its document as the
ordinary typed field it is, and in **no statement**: `columnsOf` steps over
it, so no `SELECT` list reads it and `db.raw` counts the statement's columns
against the columns; `hasColumn` says no, so a `.where`, an `.order`, a
`.set` or an insert naming it is refused by name; `db.checking` and the
migrator do not look for it; a borrowing Row need not find it on the table
it borrows; and every read — `select`, `find`, `page`, `raw`, a stream —
leaves it at the default the field declares, for the caller to fill.

The marker is a declaration on the struct rather than something on the
field, for the reason ADR 168 gave: Zig has no field attributes, and a
declaration beside the field would be a naming convention pretending to be
one. It is a second marker rather than a word in `nilo_table` because a
projection's `nilo_table` is a literal with nowhere to write a list, and one
spelling across the three Row shapes beats two.

## What is checked

Five Refusals, where the marker is written or the field is used:

- the name has to be a field of the Row, with the near miss named;
- the field has to have a default, because nothing else fills it and an
  undefined field in a Row is the failure ADR 007 says nilo cannot recover
  from;
- the key cannot name one, because a key is what a statement finds a row by;
- a condition cannot name one;
- a write cannot name one — which is what handing a filled Row back to
  `insert` does.

## What was not done

**A wrapper type**, `sql.Beside(T)`. The type is where nilo reads things,
and it would have carried the rule without a marker. But the JSON writer and
the document read the field's type, and a wrapper would have needed a way to
say *describe me as T* that `http/` could read without `sql/` importing it —
a third cross-module name for a job the plain type already does.

**Filling it for the caller.** `.beside = .{ .attachments = fetchAttachments }`
would run a function per row after the read. It is a second query per row
dressed as a field, and the round-trip-per-row is exactly what
`sql.Json` with `jsonb_agg` exists to refuse.

## Against ADR 017's four axes

Nothing. Every check is comptime; a read writes one default per beside
field per row, which is a pointer and a length.

## Consequences

- `nilo_beside`, read by `row.besideOf` / `row.isBeside`, and every column
  list in `sql/` reads through it.
- Five Refusals.
- A Row that is the response can carry what the program adds to it.
