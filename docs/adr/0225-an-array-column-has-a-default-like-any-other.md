# 0225 — an array column has a default like any other

**Status:** accepted
**Extends:** [ADR 0221](./0221-the-marker-has-two-kinds-of-word.md), §"`.default`".
The word is the same word; what changes is which Zig values it takes.

## Context

ADR 0221 put `.default` in the marker on the strength of a count: of the
59-table schema's 126 defaults, eighty-six were `now()` on a `created_at` and
forty were literals every insert relies on. `literalText` reads text, a number,
a bool or a Zig enum's word, and refuses anything else with a sentence naming
the column's own type.

Round two of the port found the two it refused:

```sql
read_tags            text[] NOT NULL DEFAULT '{}',
write_capabilities   text[] NOT NULL DEFAULT '{}',
```

`[]const Str` is none of the four shapes, so those two `SET DEFAULT` clauses
were the last two defaults in the whole schema still written by hand. The
column type already came from the marker — `arrayOf` has been there since the
list work — so the table was a Row and its default was a step, which is the
exact split ADR 0221 was written to close.

`'{}'` is the whole of the common case. Every `NOT NULL` array column in a
hand-written schema has it, because the alternative is a null the application
has to think about on every read.

## Decision

**An empty list is `&.{}`, and a list with things in it is a list.**

```zig
pub const nilo_table = .{
    .name = "agents",
    .key = .id,
    .default = .{
        .read_tags = &.{},
        .write_capabilities = &.{ "deals", "work" },
        .weights = &.{ 1, 2, 3 },
    },
};
```

`literalText` asks `types.listElement` before it gives up, and renders the
Postgres array literal: `'{}'`, `'{"deals","work"}'`, `'{1,2,3}'`. Each element
goes through the column's own element type, so a word that is not the element's
Zig type does not compile — the same check every other default already gets, one
level down.

**The escaping is the part that had to be got right.** A Postgres array literal
is not SQL: inside the braces, `,` separates, `{` and `}` nest, `"` quotes an
element and `\` escapes inside a quoted one. An element carrying any of those
read as more or fewer elements than were written. So every element is quoted and
`\` and `"` inside it are escaped, and then the whole literal goes through
`quoteLiteral`, which doubles an apostrophe the way both databases spell one.
Five elements say so in one test:

```zig
.default = .{ .tags = &.{ "a,b", "{c}", "say \"hi\"", "back\\slash", "it's" } },
```

renders `'{"a,b","{c}","say \"hi\"","back\\slash","it''s"}'`.

**Anything else stays a step.** A default that is an expression —
`ARRAY(SELECT …)` — is not a literal and never becomes one here, which is the
same line ADR 0153 drew for scalars.

## Alternatives rejected

**`.read_tags = "{}"`, as text.** It compiles today and it is wrong in a way
nothing would catch: the column is `text[]` and the literal would be checked
against `[]const Str`'s element type, so `"{}"` is a one-element array holding
the two characters `{` and `}`. Taking a list is what lets the elements be
checked at all.

**`.read_tags = .empty`.** A word for the common case and nothing for the rest,
which is two spellings to learn and a cliff the first time somebody wants
`&.{"a"}`. `&.{}` is the same Zig the field's own type takes.

**Build the literal in the driver's binary array format.** `pg.zig` can send an
array as a parameter, and a `DEFAULT` has nowhere to put a parameter — the
database stores the text. This is the same reason `Column.default` holds
rendered text rather than a value, and it is the reason a Dialect is chosen
before a `Desc` is built.

**Refuse on SQLite.** SQLite has no array type, so `columnType` already has no
name for `[]const Str` there and the Row does not compile with or without a
default. Nothing new to say.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — the literal is a comptime constant in the `CREATE TABLE` |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | **0 bytes, measured** |

`nilo-size-pg_only` at 1,800,600 bytes and `nilo-size-sqlite_only` at 2,305,584,
`cmp`-identical against `git archive HEAD`.

No new refusals. A default that is not the column's type already has one, and a
list goes through the same function per element — so
`.weights = &.{ "a", "b" }` on a `[]const i32` fails with the message that was
already written.

**The proof is against a database rather than against a string.** The comptime
half can only say that nilo wrote the text it meant to; whether that text means
what nilo thinks is Postgres's opinion. `sql/live.zig` creates the table from
the marker's own `CREATE TABLE`, inserts a row naming no array column, reads it
back and compares five awkward elements byte for byte. One Zig gotcha turned up
on the way and is worth keeping: `&.{ "a", "b" }` is a pointer to an anonymous
**tuple struct**, not a pointer to an array, so a predicate that only looked for
`.array` missed every non-empty literal.
