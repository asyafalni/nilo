# SQL column types

**A column type is whatever the database stores it as, checked while compiling against the Dialect it is actually bound through, and a type this module has never heard of can still declare one.** How to write a Row with one is the guide ([`guide/sql/tables.md`](../guide/sql/tables.md)); every shipped type and the column-type protocol are the reference ([`reference/sql.md#types`](../reference/sql.md#types), [`reference/sql.md#a-column-type-of-your-own`](../reference/sql.md#a-column-type-of-your-own)). The code is `sql/types.zig` (the shipped types, `AsText`), `sql/wire.zig` (`Bytes`, `assertWire`'s list of what a Wire owes, `readList`), `sql/dialect.zig` (`accepts`, `acceptsSqlite`, the storage-form declarations), `sql/db.zig` (`forWire`) and `sql/table.zig` (the marker, `nilo_beside`, a composite `.key`).

## How the pieces fit

```
  a Row's field type
        │
        ├── a scalar, Str, an enum ──────────► accepts / acceptsSqlite: exact per Dialect
        ├── []const T (a slice) ─────────────► one array column, one allocation per row
        ├── sql.Uuid, sql.Timestamp, sql.Date,
        │   sql.Decimal, sql.Bytes ──────────► shipped types; storage form declared on
        │                                       the Dialect (UuidForm, ValueForm, …)
        └── nilo_column + nilo_read + nilo_write
                                              ► a column type this module never heard of;
                                                travels as text Postgres prints, whoever
                                                wrote the three declarations

  every value, on the way in: forWire(To, value, c) reads the Dialect's declared
  form and the destination type, and a NULL into a non-optional column is
  error.QueryFailed on both Wires, not a zero or an empty string
```

## The rule in force

1. **A list column is a plain Zig slice, no wrapper.** `[]const i32` is `int4[]`, `?[]const i32` is a nullable column, `[]const ?i32` is one whose elements may be null, and `[]const Str` or `[]const []const u8` is a list of text; an array's element type is judged exactly, with no widening the way a scalar column gets. Reading one costs one allocation per row, two when the elements are `Str`. Not available in `db.stream`, and an array of a declared column type such as `Decimal` is not read. [ADR 045](../adr/045-an-array-is-a-slice-and-a-slice-is-one-deep.md)
2. **A column type this module has never heard of is a protocol, not a list.** Any struct or enum carrying `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)` is a column type, whoever wrote it; it travels as the text Postgres prints on both sides (`"col"::text` out, `$1::name` in), because text is the one representation every Postgres type guarantees, including the ones behind an extension. Half the pair without the other, or both without `nilo_column`, is a Refusal. [ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)
3. **`sql.AsText(name)` is the protocol's smallest instance**, and `sql.Decimal`, `sql.Interval` and `sql.Inet` are three of them. `Decimal` holds its digits as text and does not calculate: no `.add`, no `.round`, and it writes into JSON as a string so a consumer's `JSON.parse` cannot round it into an `f64`. [ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md)
4. **A column both databases store differently declares its storage form on the Dialect, and `WireWrite`/`forWire` read the Dialect rather than the field type alone.** `sql.Uuid` is `.bytes` on Postgres and `.text` on SQLite; `sql.Json(T)` and an enum column are `.native` on Postgres and `.text` on SQLite; `sql.Timestamp` is routed to an integer affinity on SQLite (`INTEGER`, `INT`, `BIGINT`, `NUMERIC`, `DATETIME`, `TIMESTAMP`) and never `TEXT`. `.in`/`.not_in` on SQLite are written as `json_each` over a JSON-encoded list rather than bound as a native array. [ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md)
5. **Bytes are a type, not a second protocol.** `sql.Bytes { bytes }` is `bytea` on Postgres and `BLOB` on SQLite, kept separate from text because the two are the same Zig type over two different reads (`sqlite3_column_text` versus `sqlite3_column_blob`) that are not interchangeable. `sql.AsText("bytea")` still compiles and is now the wrong tool: it round-trips through hex printing. [ADR 141](../adr/141-bytes-are-a-type-not-a-second-protocol.md)
6. **A NULL in a column the Row says is not optional is refused on both Wires**, `error.QueryFailed` with a `warn` naming the column index and the Zig type, never a silent zero or empty string. The startup check catches a nullable table column; this catches the cases it cannot, a view or a `Db` nobody called `checking` on. [ADR 094](../adr/094-a-null-is-refused-by-both-wires-or-by-neither.md)
7. **A key is as many columns as it takes.** `.key = .{ .tenant_id, .id }` is a tuple of column names, the same spelling `conflictColumns` already uses; the call site is a struct (`db.find(Seat, c, .{ .tenant_id = t, .id = id })`), never a tuple, so two columns of the same type cannot be swapped and compile anyway. Leaving a key column out, writing a tuple, or naming a column that is not part of the key are each a Refusal. A composite key is never generated. [ADR 139](../adr/139-a-key-is-as-many-columns-as-it-takes.md)
8. **A value coerces into a nullable column; an error union does not.** A column type's `nilo_write` answers `!T`, and `!T` does not coerce into `!?T` on its own; the fix inside `forWire` is `try` before the value, so the payload is a value again and Zig coerces it into the optional slot the way every other branch's value does. [ADR 164](../adr/164-a-value-coerces-into-a-nullable-column-and-an-error-union-does-not.md)
9. **A Row can carry a field no column holds.** `nilo_beside` names fields that are on the Row, in its JSON and in its document, but in no statement: no `SELECT` list reads one, no `.where`/`.order`/`.set`/insert may name one, the migrator does not look for one, and every read leaves it at its default for the caller to fill from a second source. [ADR 178](../adr/178-a-row-can-carry-a-field-no-column-holds.md)

## Decisions

| ADR | What it decides |
|---|---|
| [045](../adr/045-an-array-is-a-slice-and-a-slice-is-one-deep.md) | A list column is a plain slice, judged exactly against the array's own element type |
| [049](../adr/049-a-column-type-can-come-from-outside-this-module.md) | The `nilo_column`/`nilo_read`/`nilo_write` protocol, text-on-the-wire, and `AsText` as its smallest instance |
| [067](../adr/067-a-value-is-whatever-the-database-stores.md) | Storage form is declared per Dialect (`Uuid`, `Json`/enum, `Timestamp`, `.in`), not assumed from the field type |
| [094](../adr/094-a-null-is-refused-by-both-wires-or-by-neither.md) | A NULL into a non-optional field is `QueryFailed` on both Wires, never a coerced zero or empty string |
| [139](../adr/139-a-key-is-as-many-columns-as-it-takes.md) | `.key` is a tuple of column names; the call site is a named struct, never positional |
| [141](../adr/141-bytes-are-a-type-not-a-second-protocol.md) | `sql.Bytes`, kept apart from text because the two Wires read binary and text columns differently |
| [164](../adr/164-a-value-coerces-into-a-nullable-column-and-an-error-union-does-not.md) | `forWire` unwraps a column type's error union with `try` so its payload coerces into an optional column |
| [178](../adr/178-a-row-can-carry-a-field-no-column-holds.md) | `nilo_beside`: a field on the Row, in the JSON and the document, in no statement |

Beside this topic: [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md), whose topic is [sql-migrations](sql-migrations.md), decides the marker's two kinds of word and still holds the rule for `sql.Date`, read out of the column rather than a `::text` cast, a day count on Postgres and ten ISO characters on SQLite; a document field's own JSON shape (`sql.Json(T)` as a document rather than a wrapped value) is [ADR 163](../adr/163-a-document-is-its-value.md); a type that also parses out of a path or query param, which is what lets `Timestamp` round-trip a keyset cursor, is [ADR 113](../adr/113-a-path-param-can-parse-itself.md) and [ADR 127](../adr/127-what-a-server-prints-it-can-read.md); a view's columns answering `UNKNOWN` and being skipped by the startup check is [ADR 050](../adr/050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md); the trade budget every one of these ADRs is priced against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md).

## Open

- **A SQLite storage form for `Timestamp` as text.** Reading RFC 3339 text back would need a parser, which now exists (`Timestamp.nilo_parse`, built for ADR 127), but no `time_form` has been built; a program wanting text timestamps on SQLite today reaches for `sql.AsText("timestamptz")`. On record in [ADR 067](../adr/067-a-value-is-whatever-the-database-stores.md) and [`docs/decided.md`](../decided.md).
- **An array of a declared column type**, such as `[]const Decimal`. Not judged by `accepts` and not read; writing one works through `arrayOf`. Named as still closed in [ADR 049](../adr/049-a-column-type-can-come-from-outside-this-module.md).
