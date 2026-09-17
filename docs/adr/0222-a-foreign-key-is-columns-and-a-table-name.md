# 0222 — a foreign key is columns and a table name

**Status:** accepted
**Amends:** [ADR 0153](./0153-a-migration-is-a-diff-against-a-snapshot.md),
§"The line: nilo generates what a type can say", in one sentence: "`Org` has to
be a Row". It no longer has to be. The check that sentence was defending — the
two sides of a foreign key hold the same value, so they are the same Zig type —
is kept in full, and the only thing that changes is where it runs.

## Context

The 59-table port in [`docs/input_from_nodeflux.md`](../input_from_nodeflux.md)
reported two things about `.references`, and they look unrelated until you write
them both down.

**The first is that a foreign key can span two columns.** Two in that schema do:

```sql
FOREIGN KEY (epic_id, department_id) REFERENCES work_epics (id, department_id)
FOREIGN KEY (kind_id, department_id) REFERENCES work_item_kinds (id, department_id)
```

"A Work Item's Epic has to be on the same board." A one-column foreign key
cannot say that, and nowhere else in the program says it as cheaply: the port
wrote both as `.data` steps, with the `(id, department_id)` uniques they need
declared separately as `.unique` entries, so one rule lived in three places and
one of them was a string.

**The second is that `.references` names a Zig type, and a program organised by
context cannot write one.** nodeflux-os is one directory per context and
**contexts never import each other** — a rule carried over from the Go original,
where it is load-bearing. So no context can name a sibling's Row, and no context
can be the module that owns the schema. The only shape that compiled was a
`src/schema/` module declaring all 59 tables in full, imported by nobody and
importing nobody, beside the 68 Rows the contexts actually query through:

| | Rows | Lines |
|---|---|---|
| `src/schema/`, managed, every column | 59 | 3,876 |
| Context `rows.zig`, unmanaged, the columns each reads | 68 | already existed |

Every column declared twice. Change `deals.value_amount_minor` from `i64` to
`?i64` in one and not the other and the program compiles; `db.checking` catches
it at boot, on the reading side only. The schema Rows are never queried. They
exist to be diffed.

The port offered two ways out and said it did not know which was right: let a
reference name its table as text and **give the type check up**, replacing it
with a boot-time read of `pg_constraint`; or write in the ADR that a program
organised by context declares its tables twice and call that the shape.

## Decision

**A `.references` entry is a list of columns and a target, and the target is a
Row type or the table's name.** Both spellings produce the same `Reference`, and
the type check runs on both.

```zig
pub const nilo_table = .{
    .name = "work_items",
    .key = .id,
    .references = .{
        // The short form, unchanged: the field name is the column.
        .department_id = .{ Department, .id, .cascade },
        // By name, for a table whose Row this file may not import.
        .assignee_staff_id = .{ "staff", .id },
        // Composite. Keyed by a label, because a Zig field name cannot be a
        // tuple, and `.columns`/`.to` because a tuple of tuples reads as noise.
        .epic = .{
            .columns = .{ .epic_id, .department_id },
            .to = .{ "work_epics", .{ .id, .department_id } },
        },
    },
};
```

### The type check moved; it was not dropped

This is the whole of the argument, and it is why the "give it up and read
`pg_constraint` at boot" option was refused.

A foreign key that names a type is checked inside the Row, because the type is
right there. A foreign key that names a table cannot be — but **one level up,
every Row in the program is in one comptime list**. `sql.cli.Tool(Db, Rows)`
takes it, `db.checking` takes it, `migrate.tablesOf` takes it, and all three
reach `migrate.orderOf`, which already had to walk every reference to sort the
`CREATE TABLE`s. So `table.assertTargetsResolve(Rows)` runs there: it resolves
each named table against the list, then runs exactly the two checks the short
form runs — the target column exists, and the two Zig types are the same.

A name that matches no Row in the list is a compile error that names both
spellings:

```
error: nilo: User's `.references.org_id` points at the table `orgs`, and no Row
in this list names it.
  A foreign key written as text is checked against the Rows the tool was given,
  because that is where every Row is in one place. Put the Row for `orgs` in the
  list — with `.managed = false` if this program only reads that table — or
  point at its type.
```

That last clause is what closes the loop for a context-per-directory program:
the context declares its own Row managed, and the tool's list is the one place
the 59 names are resolved. One declaration per column, and the check that was
supposedly the price of getting there is still a compile error.

`namedTargetsOf(Row)` is a separate comptime walk rather than a `by_name: bool`
on `Reference`, and that is deliberate: **how the Zig source spelled a target is
not a fact about the schema**, and `Reference` is what the snapshot holds. Only
`assertTargetsResolve` reads it.

### Composite keys are table constraints; one-column keys stay inline

A column clause cannot say "and that one too", so a composite foreign key is
appended to `CREATE TABLE` as `CONSTRAINT … FOREIGN KEY (…) REFERENCES … (…)`.
A one-column key keeps the inline `REFERENCES` it has always had, so **every
table this repository wrote before today is byte-identical**, which is what
keeps the change out of every existing snapshot's diff.

### `.exists` joins on every column of the key

`where.Link` was a pair of names and is now a pair of lists. Joining a composite
key on its first column alone is the shape of mistake this module exists to
refuse: the query runs, reads correctly, and answers a wider question than the
schema asked — every item whose Epic id matches, on any board.
`sql/where.zig`'s `test "an exists over a foreign key of two columns joins on
both of them"` is what holds that.

`.exists` needed nothing else for the by-name form: `where.correlation` already
matched on `ref.table`, which is text on both sides.

### What breaks

`Reference.column` is now `columns` and `Reference.target` is now `targets`,
both lists. **That breaks `snapshot.zon`**, the same way `.key` → `.keys` did in
ADR 0221 and for the same reason: `std.zon` fills a *missing* field from its
default, so a new field with a default is free, and a renamed one is not. A
snapshot written before this is refused with a parse diagnostic naming `column`
rather than read as something it is not. The fix is `db generate`, and
`sql/snapshot.zig`'s `test "a snapshot whose foreign keys are the older
single-column shape is refused, not read"` is what says so out loud.

## Alternatives rejected

**Keep the type requirement and document the two-declaration shape.** The
port's own second option, and it is defensible — the `src/schema/` module does
work. What decided it is that the cost is not a one-off: 3,876 lines that no
query names, and a column whose two declarations can disagree for as long as
nobody boots the reading side. A rule that a program has to be laid out a
particular way to use a module is the kind of thing this repository refuses
elsewhere (ADR 0042 is a build step for exactly that reason).

**Name the table and check it at boot against `pg_constraint`.** What the port
proposed. It trades a compile error for a runtime one, needs a live database to
find a typo, and only catches it on a database that has already been migrated
wrong. The check does not have to be given up to get the name, which is the
finding of this ADR rather than a refinement of it.

**A tuple of tuples for the composite form**, `.{ .{ .epic_id, .department_id },
.{ WorkEpic, .{ .id, .department_id } } }`. Shorter and unreadable: three
nesting levels with no word saying which side is which. `.columns` and `.to`
cost nine characters and are the difference between a line you can read at a
glance and one you have to count brackets in.

**`by_name: bool` on `Reference`.** Would have made `assertTargetsResolve` a
loop over `Desc`s rather than a second comptime walk. Refused because it puts a
fact about the Zig source into the value the snapshot serialises, which is the
one place in this module where only facts about the *schema* belong.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — nothing here is reachable from a request |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | **0 bytes, measured** |

Measured the way `CLAUDE.md` says to: `git archive HEAD` into a scratch
directory, both sides built with `zig build size-sql`, stripped `ReleaseFast`.
**`nilo-size-pg_only` is 1,800,600 bytes and `nilo-size-sqlite_only` is
2,305,584 on both sides, and `cmp` reports both pairs byte for byte identical.**
All of it is comptime, and the one extra comparison at runtime — a `Reference`
diff walking a list instead of one name — is inside `migrate`, which a server
that only serves never links.

What it costs instead is compile time and error messages. `zig build
refusals-sql` goes from 120 programs to 125:

- **`table_references_a_table_nobody_declares`** — the check that moved,
  refusing the name it was given nowhere to resolve.
- **`table_references_by_name_type_mismatch`** — the same `i64` against
  `[]const u8` the by-type form has always refused, now caught one level up.
- **`table_references_uneven_columns`** — two columns pointed at one.
- **`table_references_long_form_without_to`** — a `.columns` with no target.
- **`table_references_unknown_word`** — `.on_dlete`, which would otherwise
  compile into a foreign key with no `ON DELETE` at all.

The fourth is the one that decided where `assertTargetsResolve` is called from.
Run before the `Desc`s are built, it read `entry.to` on an entry that has no
`to` and the program failed with Zig's "no field named 'to'" instead of nilo's
sentence. `orderOf` calls it after the `descOf` loop for that reason, with a
comment saying so.
