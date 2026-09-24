# A view or a rowid alias is not a column that may be null

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

The schema check read `information_schema.columns`, the obvious source and wrong in three separate ways on Postgres, none of them tested because every fixture in the suite was an ordinary table owned by the role running it.

- A materialized view is not in `information_schema.columns` at all: it is not in the SQL standard, so the standard's catalog does not describe it. A Row over one was reported as no such table, and with `schema_mismatch_is_fatal` at its default that is a server refusing to start over a relation sitting right there.
- `information_schema` shows only the columns the current role holds a privilege on. A deployment that grants `SELECT` on some columns and not others gets no such column for the rest.
- A view's columns are all nullable, whatever their source columns were. Postgres does not track `NOT NULL` through a view and never has, so a Row over a view reported one `unexpected_null` per non-optional field, which is every field anybody would write.

The third was the check reading the answer correctly. The database said nullable; it was the question that was wrong, and a second, unrelated case turned out to be the same question asked on SQLite. `id INTEGER PRIMARY KEY` is an alias for the rowid rather than a constraint, so SQLite's `pragma_table_info` reports `notnull = 0` for it, meaning there is no `NOT NULL` clause here, not this may be null, because a rowid never is. Reading that `0` as nullable stopped the server on the most ordinary SQLite table there is, the spelling every tutorial, every migration tool and SQLite's own documentation writes. It survived because the suite's own fixture wrote the redundant `id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL`, a spelling nobody uses, so the one SQLite schema-check test walked around the bug.

## Decision

**Nullability has three answers, not two, and each Dialect's introspection query answers `UNKNOWN` for exactly the columns its database cannot tell the truth about.** `wire.Column.nullable` is `?bool`, and `null` means the database does not know. The check skips it: the type is still compared, because a view knows that on both databases, and only the nullability is left alone. `true` would flag correct code; `false` would claim something nobody checked; there is no bool that means unknown, and encoding one as a default is how a check ends up lying.

### Postgres: `pg_catalog`, not `information_schema`

```sql
SELECT a.attname, t.typname,
       CASE WHEN c.relkind IN ('v', 'm') THEN 'UNKNOWN'
            WHEN a.attnotnull THEN 'NO' ELSE 'YES' END
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
WHERE n.nspname = COALESCE($1, current_schema())
  AND c.relname = $2
  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum
```

The five relation kinds accepted are an ordinary table, a partitioned table, a view, a materialized view and a foreign table; an index and a sequence are relations too and are not things a Row reads. Leaving `information_schema` is safe because this query lives in the Postgres Dialect, the one place portability is not a property to protect: a second Dialect writes its own `introspect`. One behaviour changed that nothing in the suite covers: a domain type now reports the domain's own name where `udt_name` reported the base type's.

### SQLite: the rowid alias is the third branch, behind the view check

```sql
SELECT i.name, upper(i.type),
       CASE WHEN m.type = 'view' THEN 'UNKNOWN'
            WHEN i."notnull" = 1 THEN 'NO'
            WHEN i.pk = 1 AND upper(i.type) = 'INTEGER'
                 AND (SELECT count(*) FROM pragma_table_info(?1) k
                      WHERE k.pk > 0) = 1 THEN 'NO'
            ELSE 'YES' END
FROM pragma_table_info(?1) i
LEFT JOIN sqlite_master m ON m.name = ?1
ORDER BY i.cid
```

A SQLite view answers `notnull = 0` for every column exactly as a Postgres view does, so `UNKNOWN` is reached the same way, through `sqlite_master.type`. The rowid branch sits behind it, and each of its three conditions is load-bearing:

- **`pk = 1` and exactly one primary-key column.** A rowid table's composite key may hold a NULL in any of its columns, the long-standing quirk, so `PRIMARY KEY (tenant_id, id)`, which is what every multi-tenant schema is, has to keep answering `YES`.
- **The declared type is exactly `INTEGER`, not INTEGER affinity.** `INT PRIMARY KEY` and `BIGINT PRIMARY KEY` share the affinity, are not aliases, and really do accept a NULL. SQLite's rule is the spelling, narrower and simpler than the affinity rule once proposed for it.
- **Not a view**, which the branch above already answered.

`PRIMARY KEY (id DESC)` over an INTEGER column is not an alias either, and this answers `NO` for it: a check that fails to fire rather than one that fires wrongly, the direction the whole branch exists to move in.

`pragma_table_info` is now named twice in the query, once in the `FROM` and once in the subquery that counts a table's primary-key columns, and `sqlite.Wire.columnsOf` qualifies **every** occurrence with the schema, not the first. Qualifying only the first would ask the attached database for the columns and `main` for the key, one question answered by two databases: a table absent from `main` would report no primary key at all, and every `INTEGER PRIMARY KEY` in an attached schema would go back to being reported as nullable. The rewrite buffer in `columnsOf` is 1,024 bytes of stack, on a function that runs once per Row at startup.

### Sequences, identity and generated columns already worked

The checklist had these as a third item and they needed no code at all, worth recording because the reason is a design made for something else:

```zig
const Auto = struct {
    pub const nilo_table = .{ .name = "auto", .key = .id };
    id: i64,               // GENERATED ALWAYS AS IDENTITY
    label: []const u8,
    slug: ?[]const u8,     // GENERATED ALWAYS AS (label || '-x') STORED
};
const made = try db.insert(Auto, c, .{ .label = "alpha" });
// made.id is the database's; made.slug is "alpha-x"
```

An insert names a subset of the Row's columns and `RETURNING` is not optional ([ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)), and those two together are the whole of what an identity key or a generated column needs. A generated column carries no `NOT NULL` unless one was written, so the Row reads it as an optional and the check agrees.

### Indexes, constraints and foreign keys are refused, not deferred

A Row names its columns and its key, and nothing else about the table is sayable. The check cannot notice a missing index, because a Row never said there should be one, and nothing could generate one for the same reason. Adding a way to say it, `pub const nilo_indexes = …`, is annotation, and the first line of this project's README is that nothing is annotated anywhere. A Row is a struct that happens to be a table; a Row carrying a DDL description is a migration file with Zig syntax. Indexes and constraints are written where every other DDL statement is written, or through the migration marker's typed words ([ADR 181](./181-the-marker-has-two-kinds-of-word.md)), and a unique constraint violated is already `error.AlreadyExists` with a 409 by default.

## What was rejected

**Matching INTEGER affinity for the rowid alias**, the first instinct. It says `NO` for `INT PRIMARY KEY`, which accepts a NULL, trading a check that fires wrongly for a check that silently does not fire. The exact spelling costs nothing and is the actual rule.

**Asking `pragma_index_list` whether a `pk`-origin index exists**, which would make the rule exact for `PRIMARY KEY (id DESC)` as well. It is a second table-valued function to schema-qualify for one exotic spelling, and the error it leaves is a check that does not fire rather than one that fires wrongly. Written down here rather than built.

**Making `schema_mismatch_is_fatal` default to false**, which would have turned either failure into a warning. That treats the symptom and gives up the property the check exists for.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:

| Axis | Cost |
|---|---|
| Allocations per request | None. Introspection runs once per Row at startup, in a scratch arena, and never again. |
| Memory per idle connection | Nothing. |
| Throughput and p99 | Nothing on the request path. The Postgres startup query is cheaper than the one it replaced: `information_schema.columns` is a view over several catalog joins with privilege filtering on top. The SQLite query adds one correlated subquery over `pragma_table_info`, once per Row while the server starts. |
| Binary size | +0 stripped ReleaseFast on every example. |

## Consequences

- A Row over a view is checked for its column types and not for nullability, and that is stated in the reference rather than left to be discovered.
- A Wire now has three things to say about a column instead of two; the Fake says all three.
- The next relation kind Postgres adds is a one-character change to a `WHERE` clause rather than a second query.
- `sqlite.Wire.columnsOf` qualifying every occurrence of a table-valued function's name, not the first, is now the rule for any query that names one twice.
