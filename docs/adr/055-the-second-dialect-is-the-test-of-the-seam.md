# The second Dialect is the test of the seam

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

`sql/dialect.zig`'s header said, for as long as one Dialect shipped, that the point of the seam is that `$1` is not hardcoded, not that a second Dialect exists yet. A seam nothing has ever been passed through is a guess about where the joins go, so a second Dialect was written, the SQL half only and deliberately: a Dialect is comptime and touches no I/O, so it can be finished and tested on its own, with no dependency, no database and no event loop.

## Decision

**A Dialect is comptime, and where the two databases cannot agree it is a Refusal naming the dialect rather than a spelling that quietly means something else.** SQLite has shipped a Wire since; the Dialect described here is what it writes.

### Twelve of thirteen declarations fitted unchanged

The whole statement compiler, `select`, `insert`, `update`, `delete`, conditions, orders, limits, casts, `RETURNING`, the schema check's query, writes correct SQLite through the seam as it stood. Placeholders, identifier quoting, schema qualification, `LIMIT`/`OFFSET` and the write forms all came out right on the first compile. Four things needed saying, and one needed the seam widened.

**`ListForm` had three answers and SQLite needs a fourth.** Postgres writes `.in` as `= ANY($1)`, keeping the statement a constant however long the list is. The enum offered `.any_array` (Postgres; SQLite has no array type), `.expanded` (`IN ($1, $2, …)`, which makes the text depend on a runtime length and breaks [ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)), and `.unsupported` (`.in` becomes a Refusal, on a database where every real schema uses it). The fourth answer is SQLite's own idiom, `.json_each`:

```sql
"id" IN (SELECT value FROM json_each(?1))
```

One parameter carrying a JSON array as text, constant statement, any length. It costs a Wire one thing that is not free, the list has to arrive as JSON text rather than as a native array, written into the enum value's own doc comment.

**A Postgres spelling had leaked into the walker.** `where.zig`'s `listSpelling` answered `"= ANY"` and `"<> ALL"` directly, Postgres's words handed straight to the writer, and it survived review because with one Dialect there was nothing to disagree with it. It now answers which operator, and the dialect branch spells it: a hardcoded string does not look hardcoded while there is only one of it.

**Casts had to be whole expressions, and nearly were not.** Postgres writes a suffix, `"balance"::text`; SQLite writes a function, `CAST("balance" AS TEXT)`. `readAs` and `bindAs` return the entire expression rather than the cast to append, which was already the shape, a seam that had asked for "the cast suffix" would have had to be rewritten. Worth recording as a near miss, because nothing had tested it.

**`introspect` has one loose joint.** SQLite reads a table's columns with `pragma_table_info`, and the schema qualifies the function's name rather than sitting in a `WHERE`, so it cannot be a bound parameter where Postgres binds it. `columnsOf` hands a Wire the query text and both values, so a SQLite Wire puts the schema in the text itself; the contract now says it may.

**On Postgres a domain answers the type under it.** The column's own `typname` for a domain over `text` is the domain's name, which no `accepts` list can name, so a `Str` over `email_address` stopped a server whose table was right. `introspect` follows `typbasetype` (a recursive CTE, because a domain may sit over another) and answers the first type that is not a domain. `citext` joins `text_accepts` by name, since an extension's type has no fixed oid. A domain's own `NOT NULL` is not read; the column still reports by `attnotnull`.

**The startup check asks the catalog two questions, however many Rows there are.** `checkSchema` used to send `introspect` once per Row and `enum_values` once per enum column, before the first request on every replica: fifty tables were fifty round trips. It sends `introspect_all` once per schema the Rows name (one, unless a `nilo_table` says `schema.table`) and `enum_values` once for every named enum type. `columnsOfMany` and `labelsOfMany` on the Wire hand back one list per name asked, in the order asked, and an empty list is a table or a type that is not there. Postgres binds the names as `text[]` (`c.relname = ANY($2::text[]::name[])`), SQLite as the JSON array it binds every list as, with `pragma_table_info(m.name)` joined to `sqlite_master`. **The batch text has to answer what `introspect` answers**, the affinity and the domain resolution above included; a test in `live.zig` and one in `db.zig` hold the two together, and `introspect` stays for the callers that ask about one table (`liveColumns`, `addMissingColumns`, a migration's own transaction). The cost is a second copy of the query text per Dialect, kept honest by that test; the gain is measured in [sql.md §24](../../bench/result/sql.md#24-the-startup-check-and-the-ledger-ask-once). **A mismatch is logged at `err` when `schema_mismatch_is_fatal` will stop the server and at `warn` when it will not**, since `err` means the server is refusing to start (ADR 145).

### What SQLite gives up, stated rather than discovered

- **No row locks.** SQLite serialises writers over the whole database, so there is no row to hold. `.lock` is the Refusal `noRowLock` writes, naming the dialect.
- **No `insertMany`.** There is no `unnest` and no array parameter. The batch form SQLite has is `VALUES (…), (…), (…)`, whose text grows with the batch, no longer a constant, which is the rule this module is built on. A row at a time inside one transaction is the answer, and it is cheaper here than it sounds because there is no round trip to pay per statement.
- **A coarser schema check.** A SQLite column's declared type is free text; what the database enforces is one of five affinities. `accepts` answers with affinity names, and so does `introspect`: it derives the affinity from the declared type by SQLite's five rules (`INT`, then `CHAR`, `CLOB` or `TEXT`, then `BLOB`, then `REAL`, `FLOA` or `DOUB`, else NUMERIC), so `VARCHAR(255)` under a `Str` passes, and so do `DATE`, `UUID` and `DECIMAL` (NUMERIC affinity) under the types that declare a column name. That catches a `Str` field over an `INTEGER` column and does not catch an `i32` field over a column holding values that do not fit. A column with no declared type has BLOB affinity and stores whatever it is given, so it answers `ANY` and fits every field; a column declared `BLOB` still answers `BLOB`. The first version compared the declared text against the affinity names and refused to start on those correct tables. It declines a `u64` rather than accepting it optimistically, the safe direction to be coarse in; so does Postgres, and a Row reading a `u64` or a `usize` is a Refusal on both, since neither database keeps an integer past a signed 64 bits.
- **No numeric comparison of a `Decimal`.** A `sql.Decimal` is a `TEXT` column here, so `.gt`, `.gte`, `.lt`, `.lte`, `.order`, `.after` and `sum`, `avg`, `min` and `max` over one would compare and add text. They are Refusals (`decimal_compares = false`, `dialect.assertDecimalCompares`), naming the fix: an integer of the smallest unit, or Postgres. Equality stays ([ADR 049](./049-a-column-type-can-come-from-outside-this-module.md)).

### `.like` and `.not_like` are Refusals on SQLite too, naming `.ilike` and `.not_ilike`

SQLite's `LIKE` folds ASCII case and cannot be told not to by a statement: `PRAGMA case_sensitive_like` is a property of the connection, so a case-sensitive match there would depend on how the file was opened rather than on what the query says. The case-sensitive half of the pattern family, `.contains`, `.starts_with`, `.ends_with`, was a Refusal from the widening above, each naming the folding spelling that means what the database does. `.like` and `.not_like` predated that rule and kept compiling on SQLite while folding, matching `Ada@` against `ada@` on that database only, the lie the seam exists not to tell.

They now reach `noPatternForm`, the same message `.contains` gets, naming `.ilike` and `.not_ilike` in the last line. **The break is one letter and is worth it for the consistency.** A program that wrote `.like` on SQLite and wanted folding writes `.ilike`, what the database was doing; one that wanted case sensitivity was getting the wrong answer and is now told. There is no third program: on SQLite `.like` and `.ilike` compiled to the same statement, so nothing a program could observe changes for the first kind except that the operator's name now says what it does.

Refusing rather than spelling `.like` some other way: `GLOB` is case-sensitive and uses `*` and `?`, so a caller's `%` pattern would mean something else; `lower(col) LIKE lower(?)` is the folding spelling again; a pragma at open would change what every other statement on the connection means, including `db.raw`. None of the three is `.like`.

## What was rejected

**Leaving `.like` and `.not_like` folding on SQLite, documented in the reference.** A sentence in a table is not a Refusal, it is a reading a program has to know to do, for the same reason the rest of the pattern family was not shipped that way.

**Refuse to build the SQLite Wire until the hop-versus-fiber question below is answered.** Writing the Dialect first and testing it with no I/O is what let the seam be checked before that design question needed an answer at all.

## What is a design question rather than a gap in this Dialect

**SQLite is a blocking file read, not a socket.** pg.zig holds an `Io.net.Stream` and reads through the `Io` it was handed, so a Postgres wait suspends the fiber and frees the thread, measured at 215,000 requests a second ([ADR 053](./053-a-round-trip-is-not-the-cost-worth-chasing.md)). A SQLite query has no descriptor to wait on: every call either holds its thread for the duration or goes through `nilo.blocking` and pays a thread-pool hop, and which of those is right depends on numbers a Dialect alone cannot produce. [ADR 065](./065-one-writer-is-not-a-setting-it-is-the-database.md) is where that question was answered for the pool's shape, and the Wire it describes is what `columnsOf`'s loose joint above is written against.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:

| Axis | Cost |
|---|---|
| Allocations per request | None. A Dialect is comptime. |
| Memory per idle connection | Nothing. |
| Throughput and p99 | Nothing. `listSpelling` returning an enum instead of a string moves a comparison from run time to still comptime, where it always was. |
| Binary size | +0 stripped ReleaseFast on every example. A Dialect nothing instantiates is code the compiler never analyses. |

## Consequences

- `ListForm` has four values, and the fourth has a user.
- `sql/dialect.zig`'s header no longer claims one Dialect ships: two do, and one predates the other having a Wire.
- `sql/where.zig`'s two case-folding operators reach `noPatternForm` on a Dialect whose `like_folds` is true, and the reference's conditions table and the SQLite guide's table say so.
- A second driver is exactly one thing, a Wire, and the question in front of it (hop or run in the fiber) is written down rather than guessed at.
