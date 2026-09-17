# 0226 — the marker has a word the database checks

**Status:** accepted
**Closes:** [ADR 0221](./0221-the-marker-has-two-kinds-of-word.md), §"The second
kind", which named this kind, accepted the principle and built none of it. It
left one question open — what closes the kind — and this answers it.

## Context

ADR 0153 drew the line that has held every marker word since: **a word gets into
the marker if the compiler can check it.** ADR 0221 said there is a second kind
of word that the line as written excludes wrongly, and described it without
shipping it:

> A `CHECK` body is a string the compiler cannot read, and it is also a **named
> object with a text**, which a diff owns completely.

The 59-table port in [`docs/input_from_nodeflux.md`](../input_from_nodeflux.md)
is what made the case concrete. After ADR 0221, ADR 0222 and ADR 0223 landed,
the port still had 73 hand-written steps and 46 tables split between a Row and a
step. Almost all of it was two things:

```sql
CONSTRAINT work_items_sku_product_and_deal_are_exclusive
    CHECK (sku_product_id IS NULL OR deal_id IS NULL),

CREATE TRIGGER work_items_updated_at BEFORE UPDATE ON work_items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

Neither is expressible as a typed word. A `CHECK` body is arbitrary SQL, and
building a grammar for it means shipping a SQL parser, which ADR 0153 refused on
its own terms and this ADR does not reopen. But **the diff does not need to
read the body.** Same name and same hash, nothing to do; same name and a new
hash, drop and create; a name the types no longer have, drop. That is the whole
of the algorithm, and it is complete without anything understanding a single
token of what is inside.

The port also asked which object kinds get in, and answered it from its own
schema: a `CHECK`, a trigger, a function, a view and an extension were the five
whose replace is mechanical, and nothing in 59 tables asked for a sixth.

There was a twelfth finding beside it, which turns out to be the same word.
`sku_product_types.kind` is `text CHECK (kind IN ('product', 'other'))`, and the
hand-written schema named that constraint `sku_product_types_kind_is_known`.
nilo derives `<table>_<column>_check` for an enum column's generated check and
offered no way to say otherwise, so a test reading `pg_constraint` by the first
name found nothing — and that one column stayed a `nilo.Str` with its `CHECK` in
a step.

## Decision

**Two words, `.check` and `.trigger`, each keyed by the name the object goes
into the database under.**

```zig
pub const nilo_table = .{
    .name = "work_items",
    .key = .id,
    .check = .{
        .work_items_sku_product_and_deal_are_exclusive =
            "sku_product_id IS NULL OR deal_id IS NULL",
        .work_items_priority_is_known = .{ .words_of = .priority },
    },
    .trigger = .{
        .work_items_updated_at = .{
            .when = "BEFORE UPDATE",
            .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
        },
    },
};
```

Four things in that are decisions rather than syntax.

**The key is the name.** `.unique` and `.index` derive a name from the table and
the columns, so their entries are anonymous and `.name` is an override. A check
and a trigger have no columns to derive one from, and an object nobody named is
reported by the database under a name it made up — which nothing on this side
can predict, and the name is the whole of what Postgres says when a row breaks
a constraint. Keying by name also buys two checks for free: the 63-byte guard
applies as it does to a `.unique`, and two entries of one name is a duplicate
struct field, which Zig refuses before `sql/table.zig` is reached.

**A trigger is two halves, and the table is not one of them.** The port proposed
one string, `"BEFORE UPDATE FOR EACH ROW EXECUTE FUNCTION set_updated_at()"`,
with `ON "work_items"` to be inserted in the middle. Finding where the middle is
means parsing SQL. Asking the marker to write `ON "work_items"` itself means the
table is written twice, and the second copy stops matching the day the table is
renamed — a trigger left on the old table is a trigger that silently stops
running. So `.when` is what goes before, `.run` is what goes after, and nilo
writes `ON "work_items"` between them. Hashing puts a `\x00` between the halves,
so moving a word across the gap is a change rather than the same text twice.

**The snapshot records the name and a hash, not the body.** Sixteen hex
characters of SHA-256 of `body ‖ \x00 ‖ tail`. A `CHECK` body is one line and a
view is sixty, and a `.zon` file carrying sixty lines of SQL stops being
readable — which is the property the format was chosen for in ADR 0153.
`NamedText.digest` answers from whichever half the value has, so nothing
downstream knows or cares which side of the diff it is holding.

**`.{ .words_of = .kind }` is the same word, not a second one.** It is not a
check of its own: it names the one an enum column already generates. Keyed by
the constraint's name like every other entry, rather than by the column beside
`.default`, which is where the finding suggested putting it. One word with two
key rules is how a reader ends up sure they know which one they are looking at,
and the name is what both spellings are actually about. `Column.check` carries
it into the snapshot, so moving the name is a migration: the constraint in the
database still has the old one, and dropping by the new one would find nothing.

**Where each one is written is the database's doing.** A `CHECK` goes inside the
`CREATE TABLE` as a table constraint, for the third time for the same reason
`referenceClause` and `checkClause` already do: SQLite has no
`ALTER TABLE … ADD CONSTRAINT`, so a constraint not written at creation cannot
be written at all. A trigger cannot go inside a `CREATE TABLE` on either
database, so it is a statement after the table and its indexes.

**The kind is five objects and this ADR builds two.** `CHECK` and trigger hang
off a table, which is where the marker is. A function, a view and an extension
hang off a schema, and there is nowhere to write them until there is a
`sql.Schema` — which changes `Tool`'s signature and is a piece of its own. The
`before` slot a version file has had since ADR 0223 already covers what the port
needs from them today.

## Alternatives rejected

**Keep refusing and let them be `.data` steps.** This is the status quo, and the
numbers are what moved it: 73 hand-written steps and 46 tables described in two
places, in one schema, after three ADRs aimed at exactly that. A `.data` step
also gets no diff at all — a changed `CHECK` body is a hand-written
`ALTER TABLE` somebody has to remember, and a renamed trigger is a `DROP` and a
`CREATE` in the right order, by hand.

**A typed grammar for `CHECK` bodies.** The where walker already spells four
terms and `.index`'s `.where` reuses them, so `CHECK (deleted_at IS NULL)` could
have been typed. Refused because it closes almost nothing: the port's checks are
`a IS NULL OR b IS NULL` and `a IS NULL OR b IS NULL OR a <= b`, which need
disjunction, and the one after that needs a function call. A vocabulary that
grows to meet arbitrary SQL is a SQL parser arrived at one word at a time.

**Compare the body rather than a hash.** The bodies are in the binary already,
so the snapshot could hold them and `std.mem.eql` would answer. Refused for the
file: a schema with views in it puts hundreds of lines of SQL inside a `.zon`
document, and the diff of that document is what two branches merge. The hash
costs sixteen characters a line and answers the only question asked.

**`CREATE OR REPLACE TRIGGER` for a replace on Postgres.** It exists in 14 and
up and it is one statement instead of two. Refused because a replace keeps the
old definition if the new one fails halfway through a version, and two
statements a reader can see is what a generated file is for. Postgres 14 is
still a floor this puts under the module, because `createMissing` uses
`CREATE OR REPLACE TRIGGER` — there is no `CREATE TRIGGER IF NOT EXISTS` in any
version of Postgres, and `createMissing` sends one statement per object.

**Let nilo validate the body by sending it to a database.** A `generate` needs
no database, and that is ADR 0153's first property. The body is checked inside
the version's transaction at `migrate`, which is the same moment a `.data` step
is checked and the same moment it always was.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — nothing here is reachable from a request |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | **0 bytes, measured** |

`nilo-size-pg_only` at 1,800,600 bytes and `nilo-size-sqlite_only` at 2,305,584,
`cmp`-identical against `git archive HEAD`. A program that names no `.check` and
no `.trigger` links none of this: the words are read at comptime and the diff
lives in `migrate.zig`, which a server that only applies versions at boot
reaches through `apply` and not through `plan`.

**Eleven refusals**, taking `refusals-sql` from 125 to 136 and the whole table
from 306 to 317. They are the shape around the body rather than the body: a
`.check` written as a list, a body that is not text, a body that is empty, a
name past 63 bytes, a struct that is not `.{ .words_of = … }`, a `.words_of`
naming something that is not a column, a `.words_of` on a column with no words,
two entries naming one column's check, a trigger written as one string, a
misspelled word inside a trigger, and a trigger with an empty half.

**The proof that the body means anything is against Postgres.** Everything
comptime can say is that nilo carried the text through unchanged. `sql/live.zig`
creates the table from the marker's own `CREATE TABLE`, watches an insert come
back as `error.CheckViolated`, reads both constraint names out of
`pg_constraint` scoped by `conrelid`, and updates a row to see the trigger fire
— which is also what proves nilo wrote the `ON "table"` the marker deliberately
cannot say.
