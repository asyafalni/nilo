# A value is whatever the database stores it as, per Dialect

**Status:** accepted
**Topic:** [sql-types](../design/sql-types.md)

## Context

`guide/sql.md`'s SQLite section opens with a promise: swap two lines and the rest of the page is unchanged, and the handler does not change at all. A Row with `public: sql.Uuid`, the type this module exports so that generating a key and reading a column are one value, did not build against SQLite:

```
zig-pkg/zqlite-…/src/conn.zig:399:21: error: Pass a string slice, rather than an
array, to bind a text/blob. String arrays will be supported when
https://github.com/ziglang/zig/issues/15893#issuecomment-1925092582 is fixed
```

That is zqlite's `@compileError`, three layers below anything the application wrote, naming a Zig issue rather than saying `Uuid`, saying SQLite is the problem, or naming a route out, in a repository whose `refusals/` directories exist so that a mistake gets a message nilo wrote. And the two halves of `sql/` already disagreed about the column: `dialect.acceptsSqlite` routed a type with a `declaredColumn`, which `Uuid` has (`"uuid"`), to TEXT, while `WireWrite` mapped a `Uuid` to a Zig array of sixteen bytes for every Wire, which pg.zig binds and zqlite refuses while compiling.

That was the first of three column types with exactly this shape, found one at a time because a method on a generic struct is analysed only where it is called, and almost nothing in this repository's own tests called the SQLite arms of `WireWrite`, `forWire` and `Values` for anything past a scalar and text. So each arrived as a compile error four frames inside somebody else's driver:

- **`Json(T)` and an enum column** compiled for `db.select` and failed at `db.insert`, because `WireWrite` handed the driver the `Json(T)` wrapper struct and the Zig enum itself, and zqlite's bind takes only an integer, a float, a bool, a `[]const u8` and its own `Blob`. Both columns *read* correctly, since `WireRead` maps both to `[]const u8` and the text path works, so `acceptsSqlite` (which answers TEXT for both) said they were fine.
- **`.in` and `.not_in`** were claimed to work in three places, `dialect.zig`'s header, the guide's table of what SQLite will not do (which did not list this), and never turned a list into the JSON text `where.zig`'s own SQL reads: `"id" IN (SELECT value FROM json_each(?1))` has been written since the second Dialect landed, and nothing filled the placeholder, because `WireWrite` mapped a list column to a native Zig slice whatever the Dialect was.
- **`Timestamp`** was checked against the wrong shape in the other direction: `acceptsSqlite` routed every declared-column type, `Timestamp` included, to TEXT, while `WireWrite` answers `i64` for a `Timestamp` regardless of Dialect. So `created_at INTEGER`, the column that matches what is actually bound, **failed the startup check**, and `created_at TEXT`, the column that passed, stored microseconds as digits in a TEXT column, where SQLite's TEXT affinity converts the integer on the way in, `ORDER BY` then sorts them as text, and no SQLite date function reads them as a time. A check that refuses the correct schema and accepts the one that silently corrupts ordering is worse than no check.

A related gap sits beside these: there is no migration runner in this module (a defensible decision, since a Row cannot declare an index or a constraint, and one that could would be a migration file in disguise), so `CREATE TABLE` was the application's job and `db.raw`, whose first argument is a Row, was the only door: passing the Row of the table being created, which returns no rows and exists only to satisfy the type check. Every SQLite application hit this, because there is no server to have run the DDL elsewhere.

## Decision

**Each column type that the two databases store differently declares its own storage form on the Dialect, and `WireWrite` reads the Dialect rather than the field type alone.**

| Form | Postgres | SQLite | What it governs |
|---|---|---|---|
| `UuidForm` | `.bytes` (a real `uuid` column, sixteen bytes) | `.text` (thirty-six hyphenated characters) | `Uuid` |
| `ValueForm` (`json_form`) | `.native` (`jsonb`, written through `std.json`) | `.text` (the document written out) | `Json(T)` |
| `ValueForm` (`enum_form`) | `.native` (a Postgres enum, bound by tag) | `.text` (`@tagName`) | a Zig enum column |
| SQLite's `acceptsSqlite` special case | (Postgres has no equivalent branch: `Timestamp` there is native) | routed to `INTEGER`, `INT`, `BIGINT`, `NUMERIC`, `DATETIME`, `TIMESTAMP`, never `TEXT` | `Timestamp` |

`assertDialect` owes every one of these declarations like any other piece of the contract.

### `Uuid`: text on SQLite, and there is no Dialect on the read side

On the write side, `WireWrite` reads `uuid_form` and answers `[16]u8` or `[]const u8`; the text form is kept in the Scope's arena, because the tuple the driver reads from outlives the call that built it, the same reason Postgres binds an array rather than a slice. Threading the Dialect through `WireWrite`, `Values`, `BatchWrite` and `BatchValues`, four comptime functions that previously took only the field type, is a wider signature for one type's sake; the alternative, a Wire-level conversion, would put a column type's knowledge inside a driver file, the line between Dialect and Wire this module otherwise holds.

**On the read side there is no Dialect at all, deliberately.** `uuidOf` takes sixteen bytes *or* thirty-six characters, because the two lengths cannot be confused and a Wire-specific reader would make one column read two ways for no gain. Text is the right shape for SQLite beyond making it compile: `sqlite3` shows the id, `WHERE public = '…'` is typeable, and every SQLite uuid convention in the wild is the hyphenated string.

**And `db.exec(c, sql, values) !usize`**, a statement that answers nothing but the rows it changed: `CREATE TABLE`, `CREATE INDEX`, `PRAGMA`, `VACUUM`, `ANALYZE`, a hand-written `DELETE`. A few lines over the Wire call `raw` already makes, with no row filling, removing the one place in this module where a caller passed a type it did not mean. `tx.exec` is the same call inside a transaction, where a migration that has to be all or nothing puts it.

### `Json(T)` and an enum column: `.native` or `.text`, and `forWire` reads the answer off the type

`WireWrite` reads the Dialect and answers `[]const u8` for either column under `.text`; `forWire` reads the answer back off the destination type on the way in, which is how the conversion stays in one place, the arrangement `Uuid` made and the reason the Dialect is not threaded into `forWire` itself. A tag under `.text` is `@tagName`, a constant in the binary; a `Json(T)` document is written into the request arena.

### `.in` and `.not_in`: written as JSON when the Dialect says so

`Values` answers `[]const u8` rather than `[]const F` for a list parameter when `list_form == .json_each`, and each element is converted through `forWire` into a slice in the request arena, then serialised with `std.json` over that slice. Converting first is what makes a list of `Str`, of `Uuid`, or of tags come out as what the column holds rather than as whatever Zig would stringify the struct as.

### `Timestamp`: checked against what is actually bound

One branch in `acceptsSqlite`, ahead of the declared-name branch every other column type falls into, keeps an integer an integer: the three names carrying `INT` are INTEGER affinity, and `NUMERIC`, `DATETIME`, `TIMESTAMP` fall through to NUMERIC, which also stores an integer as an integer. `DATETIME` and `TIMESTAMP` are in the list because they are what somebody writing the table by hand reaches for, and they are correct, not a courtesy. `TEXT` is refused for this column, which is the point of the branch rather than a side effect: it used to be accepted and silently store the wrong sort order.

## What this changed about how the module is tested

Everything in `db.zig` ran against `wire.Fake`, and that is most of the point: the same code serves both Wires and a fake proves it with no database anywhere. Neither the `Uuid` bind nor the two SQLite write-path gaps could be found that way, since a fake has no opinion about whether zqlite will bind an array or about a call that does not exist. `db.zig` gained tests over a real in-memory SQLite database: a `Uuid` written, read back by the uuid, and read again as text to confirm the storage form; the schema check agreeing with the wire about the same column; `db.exec` counting rows and running inside a transaction; a handler naming every `Db` and `Tx` call over a Row carrying a `Uuid`, a `Timestamp`, a `Json(T)` and an enum, with `checkSchema` agreeing about all eight columns; and `.in`/`.not_in` over a number, text, a tag and a `Uuid`, asserting the rows that came back rather than that the call compiled, since the JSON being accepted and the JSON being read are different claims. An empty list matches nothing, which is what `json_each('[]')` does and what `= ANY('{}')` does on Postgres.

## What was rejected

**A Refusal naming the Dialect, for `Uuid`.** The right shape for something that cannot work, and this could: a uuid in a TEXT column is what SQLite users already do.

**Sixteen bytes in a BLOB column, for `Uuid`.** Would have kept one wire format and cost the schema check its agreement, `sqlite3` its readability, and the id its typeability; the bind would still have needed a slice, so it is the same change with a worse column.

**An application-supplied column type for `Uuid`**, the escape hatch the application that found this bug actually shipped: thirteen lines of `nilo_column`/`nilo_read`/`nilo_write` storing the hyphenated text ([ADR 049](./049-a-column-type-can-come-from-outside-this-module.md)). It works, and it is the documented escape hatch used for something that should not have needed one.

**Making `.in` a Refusal on SQLite and correcting the three documents that claimed it worked.** The honest answer for something that cannot work, and this can: `json_each` is SQLite's own idiom, `where.zig` had already written the SQL, and `list_form` had already been given a fourth value specifically so the statement stays a constant on a database with no array type. Refusing it would have thrown away work that was ninety per cent done to make three documents true by subtraction.

**One `binds` declaration on the Dialect covering both `Json(T)` and an enum**, since the two move together for these two Dialects. Rejected because that is not a reason to write down that they always will; both are storage questions, exactly as `uuid_form` is, and Postgres has the types where SQLite does not.

**Threading the Dialect into `forWire`.** `WireWrite` already decided the form; `forWire` reading the decision off the destination type keeps one answer in one place.

**A `time_form` beside `uuid_form`**, so SQLite could store `Timestamp` as RFC 3339 text, the shape the roadmap had sketched and the shape the three text-form declarations already have. Not taken here, because at the time reading it back would have meant **parsing** RFC 3339, and `Timestamp` then only wrote it. `Timestamp.nilo_parse` exists now ([ADR 127](./127-what-a-server-prints-it-can-read.md), built for a paged cursor round-tripping through a path or query param), so the parser this rejection leaned on is no longer missing; a `time_form` for SQLite storage is still not built, and stays open in [`docs/decided.md`](../decided.md) as a caller who needs to read a SQLite file whose times were written as text by something else, which the check that agrees with what is actually bound does not serve. The cheapest true fix for a check that disagreed with the write was to make the check agree with what is actually bound. A program wanting text timestamps on SQLite today has `sql.AsText("timestamptz")`.

**Accepting both INTEGER and TEXT for `Timestamp`.** Would keep every existing schema starting, at the price of continuing to accept the one that sorts wrongly, the failure this exists to catch.

**Widening `nilo_column` into a per-Dialect name.** A bigger change than the problem: the declared name is a *Postgres* name, and every other consumer of it is right to read it that way.

## What it costs

Nothing on any of the four axes for a Postgres program: `WireWrite` answers what it always answered for `Uuid`, `Json(T)` and an enum, the Dialect parameter is comptime, and it keeps binding a native array for a list. Nothing on any path a Postgres program takes for `Timestamp` either, since the comptime branch is keyed on a Dialect declaration.

| Axis | Cost (SQLite) |
|---|---|
| Allocations per request | one arena `dupe` of thirty-six bytes per `Uuid` parameter (twenty extra bytes over a BLOB's sixteen, the price of a column a person can read); one arena allocation plus a converted-elements slice per `.in` on a list column; a `Json(T)` document costs the same allocation reading one already pays. An enum costs nothing, since `@tagName` is a constant. All of this is inside a request that was already going to allocate. |
| Memory per idle connection | none. |
| Throughput and p99 | comptime, keyed on a Dialect declaration; nothing on a path that does not use one of these column types. |
| Binary size | `zig build size-sql` unmoved by the `Uuid` change: 1,677,464 and 2,202,304, a difference of 524,840, both before and after. |

## What holds it

`.lock`, `insertMany`, `updateMany` and `tx.deadline` stay compile errors on SQLite and are left out of the handler these tests drive, which is the seam refusing rather than lying, worth knowing before somebody plans a migration on the assumption that swapping the Dialect is free.
