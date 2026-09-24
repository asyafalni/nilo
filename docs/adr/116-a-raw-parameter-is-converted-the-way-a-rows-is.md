# A raw parameter is converted the way a Row's is

**Status:** accepted
**Topic:** [sql-raw](../design/sql-raw.md)

## Context

Every statement this module writes for a Row takes a `sql.Uuid` without complaint: the Row says what the column is, `valuesOf` looks the parameter up against it, and `forWire` turns the value into the shape the driver binds. `db.raw` and `db.exec` have no Row, so the tuple went to the driver exactly as the caller wrote it, and a `Uuid` arrived as a Zig struct:

```zig
_ = try db.exec(c,
    \\INSERT INTO partner_capabilities (partner_id, capability)
    \\VALUES ($1, $2)
    \\ON CONFLICT DO NOTHING
, .{ partner_id, tag });        // partner_id: sql.Uuid
```

It compiled. On Postgres it was `error.QueryFailed` at run time with nothing logged anywhere ([ADR 117](./117-a-statement-that-failed-says-what-the-database-said.md) is the other half of that afternoon). On SQLite it was a `@compileError` from inside zqlite. Adding `::uuid` changed nothing, because the value never reached the server to be cast. The workaround was to send the thirty-six characters and cast them back, at every call site, costing an arena allocation per id and thirty-six bytes on the wire where sixteen would do. On a schema with 145 uuid columns, a bare `$1` id is most of what a hand-written statement binds.

`docs/reference/sql.md` had said, since lists landed, that as a column both `[]const Str` and `[]const []const u8` describe an array of text. As a `db.raw` parameter only the second worked, and the first stopped inside nilo with a type error naming a line of nilo's own and no call site, the shape [ADR 014](./014-what-nilo-borrows-and-from-whom.md) exists to prevent:

```
sql/db.zig:2642:12: error: expected type '…!?[]const []const u8',
found '?[]const str.Str'
    return value;
           ^~~~~
```

## Decision

**No Row was ever needed for this.** `forWire` switches on the value's own type, and the Dialect it is given never consulted a Row. The mapping a Row's parameter goes through was already available on the raw path; the only thing missing was somebody calling it. `rawValuesOf(values, c)` walks the tuple and runs each field through the same `forWire`. `RawValues(D, V)` answers `V` itself when nothing needs converting, which is most calls, and `rawValuesOf` hands the caller's own tuple straight to the driver the way it always did: nothing is allocated and nothing is copied on a statement that binds integers and text.

### Three shapes only a hand-written call carries

A column's type is declared; a `db.raw` parameter is whatever somebody typed at the call site, and three shapes turn up there that never reach `WireWrite`.

**A list written where it is used is `&.{ … }`**, a pointer to an array rather than the slice a column is declared as. `WireWrite` answers about columns and does not see one, and `= ANY($1)` is the whole reason anybody writes a list into a raw statement, so this is not an edge.

**A value with no runtime representation cannot be a tuple field.** `.{ 1, 1.5, null }` is three comptime fields and the tuple built here is read at run time. Each becomes the type both drivers already bind identically: `comptime_int` to `i64`, `comptime_float` to `f64`, `null` to `?u8`. Nothing about the bytes changes.

**An enum literal** gets better rather than merely surviving: zqlite refuses one while compiling, and `@tagName` is how both drivers send an enum anyway.

### It stays a tuple, and that is a fact about the drivers

pg.zig binds with `inline for (values)`, which takes a tuple and nothing else. zqlite branches on `is_tuple` and binds a plain struct's fields by name, so a rebuilt non-tuple would silently bind nothing to `?1`. A named struct is therefore left exactly as it arrived. `RawValues` answers `V` for anything that is not a tuple.

### An array parameter converts an element at a time, and `ArrayElement` is the name for both directions

`.in` is the spelling of `WHERE x = ANY($1)`, and it is what stops an N+1 on every list that attaches children to its rows. A `Uuid` inside an array is `[]const u8`, not the `[16]u8` a scalar one binds as, for two independent reasons: the parameter tuple is all the driver has to read from and a slice would point at a copy `where.valueAt` just returned, while an array parameter has somewhere better to point, the caller's own list, alive for the whole call; and pg.zig's `UUIDArray` encoder reads `[]const u8` elements and takes either sixteen bytes or thirty-six characters, while `[]const [16]u8` fails four frames inside the driver. `ArrayElement` (renamed from `BatchWrite`, which reached the same answer for the batch path first) answers the wire type an element of an array parameter converts to, for both a batch's one array per column and an `.in`'s one array of matched values.

**A list of `Str`, `[]const Str`, converts the same way a list of `Uuid` does.** `WireList([]const core.Str)` already answered `[]const []const u8`; only the conversion was missing. `RawWrite` reads `Item == core.Str or Item == ?core.Str` and runs `strList`, which allocates once for the slice headers and none for the text: each element is a view onto text somebody else owns, outliving the statement by the rule that made it a `Str`. `uuidList` does the same with sixteen bytes, for the same reason. `strList` is a function of its own rather than folded into `uuidList`: the two differ in one line, `&item.bytes` against `item.view()`, and two twenty-line functions that each say what they do beat one that says "it depends".

Reading is the other direction and needed the same answer. `WireList` maps a `Uuid` element to `[]const u8` and `keptList` takes a second walk to rebuild the type from the sixteen bytes, because the driver hands back the bytes and the bytes are not the type; the walk allocates nothing beyond the `[]Uuid` itself, since a `Uuid` is a value rather than a view of a buffer. `dialect.Postgres.accepts` had no case for `[]const Uuid` at all: it fell to the `else`, answered null, and `schema.Expectation.accepted` reads an empty list as accept anything, so a Row with a `uuid[]` column passed the startup check without anything having looked at the column and failed on the first read. It answers `_uuid` now, which is Postgres's own name for the type.

## What was rejected

**A Refusal instead of a conversion.** Right about the symptom and wrong about the cause: a Refusal here would be this module declining to do something it already knows how to do, four frames from the code that does it for `db.select`, and the message would have to end by telling the caller to write `$1::text::uuid`, a refusal whose remedy is a workaround. The rule the module runs on is that a type means one thing; a `Uuid` bound to `db.select` and a `Uuid` bound to `db.raw` meaning different things is two rules for one type, and the second one was only there because nobody had called the converter.

**A Refusal naming the spelling, for the `Str` list.** The cheaper half of that same ask: tell the caller to write `[]const []const u8` instead of `[]const Str`. It would have been the right answer if the two spellings meant different things. They do not: the reference says so, the column path already treats them as the same, and refusing one of two equivalent spellings is asking a reader to remember which of them a particular call site takes.

**Requiring a Row for `raw`.** Not considered for long. `db.raw` exists for the statements a condition cannot express, and most of them answer something no Row describes.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none added. `RawValues` answers the caller's own type when no field moves, so a statement binding integers and text builds nothing. A statement binding a `Uuid` or a `Str` list now allocates less than the workaround it replaces: the arena copy of thirty-six characters, or of the whole list, is gone. |
| Bytes on the wire | 16 rather than 36 per uuid parameter. |
| Throughput and p99 | unmeasured and expected to be nil. The walk is `inline for` over a tuple whose length is comptime, and the branch that skips it is a comptime type comparison. |
| Binary size | nothing in a program that binds no type this module has a word for: `RawValues` answers `V` and no code is generated. |

## Consequences

- `RawValues`, `RawWrite` and `rawValuesOf` in `sql/db.zig`; `ArrayElement` (the batch path's `BatchWrite`, given the wider name once `.in` needed it too) called from both places.
- `WireList` and `keptList` handle a `Uuid` element, so a `[]const Uuid` column reads; `strList` does the same for `[]const Str`, and `.in = &.{ a, b }` over `Str` values works for the same reason it works for `Uuid`.
- `dialect.Postgres.accepts` answers `_uuid`, with assertions in its test saying so.
- No new Refusal on either finding. Nothing here is a mistake somebody makes while compiling any more, and nothing changes for a caller who already wrote `[]const []const u8`.
