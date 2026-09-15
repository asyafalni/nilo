# Roadmap input for nilo, from nodeflux-os

Findings from porting a working 59-table Postgres schema to `sql.migrate`
(ADR 0153), so that the Zig port of **nodeflux-os** owns its schema instead of
borrowing the Go binary's goose migrations.

nodeflux-os is an internal ERP: Go + TimescaleDB, 30 goose migrations totalling
5,165 lines of SQL, 59 tables, 96 foreign keys, 85 CHECK constraints, 126
column defaults, 92 indexes of which 34 are partial, 31 `updated_at` triggers,
one view, one hypertable and 113 rows of reference data. A Zig port
(`backend-zig/`) has been serving the same API on nilo for some time, with every
context Row declared `.managed = false` (ADR 0162) and checked at boot.

Assessed against nilo **v0.4.0** at `eb545fa`, Zig 0.16.0. Every number below
was measured on that port; the files are under
`nodeflux-os/backend-zig/src/schema/` and `nodeflux-os/backend-zig/migrations/`.

This document is blunter than `input_from_photon.md`, on request. Where the
design is wrong I say so, with the number that shows it. Where it is right I say
that too, and there is more of that than the summary table suggests.

---

## Summary

| # | Finding | Module | Size of the problem | Conflicts with a stated non-goal? |
|---|---|---|---|---|
| 1 | `.default` belongs in the marker | `nilo_sql` | 126 defaults on 53 of 59 tables, all written as `ALTER TABLE` steps | **Yes.** ADR 0153 §"A default belongs to the step" |
| 2 | An enum column should generate its `CHECK` | `nilo_sql` | 29 `IN (…)` lists written by hand, each beside a Zig enum with the same words; the boot check never reads them | **Yes.** ADR 0153 §"The line" |
| 3 | Partial and ordered `.index` | `nilo_sql` | 34 of 92 indexes are partial, 18 are `DESC`; nilo generated 47, by hand 39 | Yes, and the ADR's own objection is answered by `where.zig` |
| 4 | Composite `.references` | `nilo_sql` | 2 foreign keys, both load-bearing | No |
| 5 | A `.name` on `.unique`, and a 63-byte guard | `nilo_sql` | 6 names lost their meaning, 2 were silently truncated by Postgres | No |
| 6 | `.references` names a type, so a context-per-directory program declares every table twice | `nilo_sql` | 59 Rows, 3,876 lines, beside 68 unmanaged Rows the contexts already had | No, but unstated |
| 7 | `generate` cannot re-derive a baseline, and the version file has no slot for hand-written steps | `sql.cli` | one shell script, run on every round of the port | No |
| 8 | `app.start(io)` then `listen()` with a Postgres pool never exits | `nilo_http` + `nilo_sql` | the shape ADR 0079 and `App.start`'s doc comment show; the process holds its port until killed | Bug |
| 9 | `Date`, `Decimal`, `Jsonb` exist only as `sql.AsText` | `nilo_sql` | `AsText("date")` is declared in 4 files of one program | No |
| 10 | A version is applicable only from Zig | `sql.cli` | nothing but this binary can bring a database to head, and `status --sql` needs a database to print | No, but a consequence of the design worth naming |

Items 1 to 3 are one argument, and it is the one the document is for: **the
"three words" line in ADR 0153 is drawn in the wrong place, and its own
reasoning says so.** Items 4 to 7 are ordinary gaps. Item 8 is a bug with a
repro. Item 10 is the one thing a SQL-file tool has that this design gives
up, and the cheap half of it can be had back.

---

## Where this stands

| Item | Status |
|---|---|
| 8 | Done at `09cb02c`, ADR 0220. |
| 5, 9, 1, 2, 3 | Next, as one change: the words that live inside one Row. `.name` and the 63-byte guard, `sql.Date` and `sql.Decimal(p, s)`, `.default`, an enum column's `CHECK`, partial and ordered `.index`. One ADR amending 0153, because all five are checked while compiling and the line was drawn short of them. The snapshot only gains fields with defaults, so an older file still parses. |
| 4, 6, 7 | After that: the words that cross tables, and the tool. Composite `.references`, `.references` by table name with the type check moved to the list every Row is in, `generate --baseline` and the `generated ++ by_hand` version file. `Reference.column` becomes `columns`, which breaks the snapshot the way `.key` → `.keys` did. One ADR for the references, one short one for the version file. |
| `.check`, `.trigger`, `sql.Schema` | After that, under an ADR of its own. |
| 10 | Not decided. |

---

## What worked, so the rest is read in proportion

- **The tool needed 40 lines.** `src/db.zig` is `sql.cli.Tool(sql.Db, schema.tables)`,
  argument parsing, and a `Settings` read so `DATABASE_URL` is spelled once.
  `generate`, `check`, `status`, `migrate` and `verify` all worked the first
  time they were run.
- **The output is right.** After `migrate` into an empty database, a
  normalised `pg_dump --schema-only` of the nilo-migrated database and of a
  fresh goose-migrated one differ in **six unique-constraint names and nothing
  else**: every column, type, nullability, default, CHECK, foreign key with its
  action, partial index, trigger, the view and the hypertable agree. The 113
  reference rows agree as sets. The port's own suite passes on the
  nilo-migrated database, 479 of 481 with 2 skipped.
- **The two boot guards are the best part of the design**, and both work:
  `migrate.expect` refused the goose-migrated database with

  > `nilo_sql: this binary was built for schema version 1, and the database is at 0. 1 migration(s) have not been applied. Run them before serving: a request that reads a column the database does not have is a 500, and the first one arrives the moment this process accepts a connection.`

  which is the right sentence, and `db.checking` held 68 unmanaged Rows
  against the live schema on the same boot.
- **`.managed = false` is the right default for a port.** Every context kept
  its Row as a projection and nothing about reading changed.
- **One transaction per version behind an advisory lock, no `down`,
  `destructive` named in the header.** No complaints; ADR 0153's argument for
  each holds.
- **The whole port took one working session**, fourteen section files written
  in parallel, because each section is self-contained: its Rows and the steps
  that complete them, in one file. That property is worth keeping whatever
  else changes.

---

## The verdict on the line, stated once

ADR 0153 draws the vocabulary at three words (`.unique`, `.index`,
`.references`) and says everything else "is not a gap": a check constraint, a
partial index, a default and a trigger "are strings the database reads, so
nothing about them can be checked while compiling", and "a vocabulary that
stops being checked starts growing".

Applied to a real schema, here is what the line produced:

| | Count |
|---|---|
| Steps `generate` wrote from the Rows | 149 |
| Steps written by hand as SQL in `.data` steps | 141 |
| Of those, `ALTER TABLE … SET DEFAULT / ADD CONSTRAINT … CHECK` | 56 statements carrying 126 defaults and 85 CHECKs |
| Of those, `CREATE INDEX` a Row could not describe | 39 |
| Of those, `CREATE TRIGGER` | 31 |
| Lines of SQL inside Zig string literals | 637 |
| Lines in the schema module, comments included | 3,876 |
| Lines in the Go baseline it replaces, comments included | 1,483 |

Half the schema is SQL either way. The half nilo does not own is not exotic:
it is `created_at DEFAULT now()`, `currency DEFAULT 'IDR'`, `state IN ('draft',
'sent', …)`. Those are on nearly every table in every business application,
and each one became an `ALTER TABLE` in a string, next to a Row that already
named the column.

The cost is not the typing. It is that **`work_items` used to be one
`CREATE TABLE` block that read top to bottom, and is now a Row at line 138
of `work.zig` and eight `.data` steps starting at line 418**, and a reader
has to hold both to know what the table is. Every table with a default or a CHECK is
split this way; that is 56 of 59.

The ADR's two reasons for the line do not survive contact with this schema:

1. **"A default belongs to the step, not to the type … the moment it is
   load-bearing is narrower than that: a `NOT NULL` column added to a table
   with rows in it fails without one. That is a fact about one migration,
   often dropped afterwards."** In this schema there are 126 defaults and
   **none of them is that case**. 86 are `now()` on `created_at`/`updated_at`,
   40 are literals (`'IDR'`, `'draft'`, `0`, `false`), and every `INSERT` in
   the program relies on them for the life of the program. A default is a
   property of the column here, exactly as the ADR says it looks like.

2. **"A check constraint and a literal default are strings the database
   reads, so nothing about them can be checked while compiling."** A literal
   default of the column's own Zig type can be checked completely: `.default =
   .{ .currency = "IDR" }` coerces to `Str` or does not compile; `.now` on a
   column that is not `sql.Timestamp` does not compile. And 29 of the 85
   CHECKs are `col IN ('a', 'b', 'c')` where the words **are the tags of a Zig
   enum the program already has**. Nothing about those needs to be written at
   all; the type says it.

The consequence of refusing to model these is the opposite of the ADR's aim.
The words did not go away; they went into strings the compiler cannot see, so
the schema ended up **less** checked than a marker with two more words would
be. Sections 1 to 3 below are the concrete proposals, each with the check that
runs while compiling, which is the bar the ADR sets.

---

## 1. `.default` in the marker

### What's missing

A column cannot say its default. The port writes, per table:

```zig
.{ .kind = .data, .why = "departments: defaults", .sql =
    \\ALTER TABLE departments
    \\  ALTER COLUMN created_at SET DEFAULT now(),
    \\  ALTER COLUMN updated_at SET DEFAULT now(),
    \\  ALTER COLUMN default_view SET DEFAULT 'table'
},
```

56 such statements, one per table that has anything to say. `generate`
cannot see them, so a Row whose column is later changed from `Str` to `?Str`
generates `DROP NOT NULL` and leaves the default alone, which is right by
accident.

### The checked form

```zig
pub const nilo_table = .{
    .name = "departments",
    .key = .id,
    .default = .{
        .created_at = .now,          // only on sql.Timestamp, refused elsewhere
        .updated_at = .now,
        .default_view = "table",     // must coerce to the column's Zig type
        .position = 0,
        .is_active = true,
    },
};
```

Every entry is checked while compiling: the column exists (`checkColumn`,
which `.unique` already uses), the literal is of the column's type, and `.now`
is only accepted on a timestamp. `.gen_uuid` on `sql.Uuid` would cover the
other common one. Anything else (`DEFAULT (lower(x))`) is still a step, and
that is fine, because there were zero of those here.

The snapshot gains a `default` field per column and `generate` diffs it, so
changing `'draft'` to `'open'` produces `SET DEFAULT`, which today nothing
produces.

### What it unlocks

126 defaults leave the strings. 20 of the 56 `ALTER TABLE` steps carried
nothing else and disappear outright; the other 36 shrink to their CHECKs.
It also removes the class of bug where a Row adds a `NOT NULL` column and the
`.data` step that gives it a default is in a different file and forgotten:
the compiler can refuse a required column with no `.default` in a version
that is not the baseline, which is the case the ADR itself names as
load-bearing.

---

## 2. An enum column generates its `CHECK`

### What's missing

A managed Row refuses a plain Zig enum column:

```
nilo: the postgres dialect has no column type for …DefaultView, which it reads as …
```

An enum that declares `pub const nilo_column = "text"` is accepted, and then
it is a bare `text` column: the tags go nowhere. Either way the port ends up
declaring `default_view: nilo.Str` in the schema Row, writing
`CHECK (default_view IN ('table', 'board', 'timeline', 'epic'))` by hand in a
`.data` step, and keeping `default_view: DefaultView` (a Zig enum) in the
context's unmanaged Row for reading. **The four words are now in two files
that nothing holds together.** Add `.kanban` to the enum and the program
compiles, the router accepts it, and the database refuses the row at runtime.

It is worse than two places, because the boot check does not cover the gap
either. `sql/schema.zig:86-88`: for an enum without `nilo_column`,
`Expectation.accepts` is empty, "declined to judge", so `db.checking` passes
the column against any column type; with `nilo_column = "text"` it checks the
type and still never reads the constraint. A comment in the port claimed the
check "holds the four against `departments_default_view_check`"; it does
not, and I only found that by reading nilo. 29 of the 85 CHECKs here are this
shape.

### The checked form

An enum field on a managed Row is `text NOT NULL` plus
`CHECK (col IN (<tags>))`, named `<table>_<col>_check`, with nothing written by
the caller:

```zig
default_view: DefaultView,   // generates: default_view text NOT NULL,
                             //            CONSTRAINT departments_default_view_check
                             //              CHECK (default_view IN ('table','board','timeline','epic'))
```

The tags go into the snapshot; adding or renaming one diffs to `DROP
CONSTRAINT … ADD CONSTRAINT …`, and removing one is `destructive` for the
reason a dropped column is. `db.checking` gains the comparison it currently
declines: read `pg_constraint.conbin` for the column's `IN` list and hold the
tags against it, or at least read the column's `udt` and accept only `text`.

This passes the ADR's bar exactly: nothing is a string, the compiler already
knows the words, and the database gets a constraint it does not have today
from any nilo program. It also removes a Refusal that surprises: a Zig enum
is the most natural type for a state column, and it is the one type a table
cannot own.

### What it unlocks

29 constraints here, and with item 1 the `ALTER TABLE` step vanishes on
31 of the 56 tables that have one; the 25 that remain carry the 56 CHECKs
that are genuinely expressions (`amount_minor >= 0`, `btrim(name) <> ''`,
`expires_at > created_at`), which is exactly the residue the ADR's argument
is right about. Beyond this schema: every state machine in every nilo
program. Postgres `CREATE TYPE … AS ENUM` is deliberately not proposed:
renaming a value there is `ALTER TYPE … RENAME VALUE`, which cannot run in a
transaction on older versions, and a `text` + `CHECK` diffs cleanly.

---

## 3. Partial and ordered `.index`

### What's missing

`.index` writes a plain btree over columns in ascending order. In this schema
**34 of 92 indexes are partial** and 18 carry `DESC`. The 39 a Row could not
describe:

| Shape | Count |
|---|---|
| `WHERE col IS NOT NULL` | 27 |
| `WHERE col IS NULL` (conjunctions of it) | 2 |
| `WHERE col = 'literal'` / `<> 'literal'` | 1 |
| `WHERE` mixing the three | 2 |
| no `WHERE`, only a `DESC` column | 6 |
| an expression, `lower(btrim(site))` | 1 |

38 of the 39 are a column, a direction and a predicate over columns and
literals. They were all written as `.data` steps, so nilo generated 47
indexes and the port wrote 39 by hand, and a partial index on a column that
is later dropped is a `.data` step nilo cannot diff and Postgres will refuse
to run.

### The checked form

ADR 0153 refuses this with the example `.where = "deleted_at IS NULL"`, a
string, and says it "is also harder to read than the SQL it replaces". Agreed,
and it is not the proposal. **nilo already has a typed predicate
vocabulary**, `sql/where.zig`, 99 KB of it, which checks a column name and a
literal's type while compiling. A partial index is that vocabulary in the
marker:

```zig
.index = .{
    .{ .columns = .{ .recipient_staff_id, .{ .created_at = .desc } },
       .where = .{ .recipient_staff_id = .not_null, .read_at = .null } },
},
```

Column names are checked as `.unique`'s are; a literal is checked against the
column's type as a `where` clause's is; `.desc` is a tag. The Dialect spells
it. An expression index (`lower(btrim(site))`, one in this schema) stays a
step.

### What it unlocks

38 of the 39 here, and the Rows that carry them become diffable. `notification_outbox`
is the sharpest case: it has one `.unique` and four partial indexes, so today
the Row says almost nothing true about how the table is read.

---

## 4. Composite `.references`

Two foreign keys in this schema are composite, and both enforce a rule the
program cannot enforce anywhere else as cheaply:

```sql
FOREIGN KEY (epic_id, department_id) REFERENCES work_epics (id, department_id)
FOREIGN KEY (kind_id, department_id) REFERENCES work_item_kinds (id, department_id)
```

("a Work Item's Epic must be on the same board"). They are `.data` steps and
the `(id, department_id)` uniques they need on the referenced tables are
`.unique` entries, so the rule is split across two files and one string.

The check ADR 0153 prizes for `.references`, that the two sides' Zig types
line up, is exactly as computable for two columns as for one:

```zig
.references = .{
    .epic = .{ .columns = .{ .epic_id, .department_id },
               .to = .{ WorkEpic, .{ .id, .department_id } } },
},
```

The named entry (`.epic`) rather than a column name is the only syntactic
change, because a Zig struct field cannot be a tuple. Two here; small, but the
argument for the word is the ADR's own.

---

## 5. A `.name` on `.unique`, and a guard at 63 bytes

nilo names a unique `<table>_<col>_<col>_key` and emits it as
`CREATE UNIQUE INDEX`. Two problems, one of them a bug.

**The name is the error message.** Postgres reports a violation by constraint
name, and the Go schema used that: `work_epics_number_is_unique_per_board`,
`linked_identities_one_person_per_account`,
`work_item_dependencies_pair_is_unique`. nilo's are
`work_epics_department_id_number_key`, `linked_identities_provider_external_id_key`.
Six constraints lost a sentence for a column list. The named form of `.unique`
already exists (`.columns`, `.ignoring_case`); `.name` is one more field and
the diff already tracks names.

**Two names exceeded 63 bytes and nothing said so.** nilo emitted

```
skus_product_type_id_platform_id_acquisition_id_product_id_term_id_key       (70)
work_item_dependencies_from_work_item_id_to_work_item_id_relation_key       (69)
```

and Postgres created

```
skus_product_type_id_platform_id_acquisition_id_product_id_term
work_item_dependencies_from_work_item_id_to_work_item_id_relati
```

with a `NOTICE` the tool does not surface. The snapshot now records a name the
database does not hold. `DROP INDEX` would still work because Postgres
truncates on the way in too, but two `.unique` entries whose first 63 bytes
agree would collide on the second `CREATE`, and `verify` compares hashes of
step text rather than names, so it would not notice either. `constraintName`
runs at comptime and can refuse a name over 63 bytes with the fix in the
message: name it.

---

## 6. `.references` names a type, so this program declares every table twice

This is the largest cost of the port and it is not in the ADR.

`.references = .{ .department_id = .{ Department, .id, .cascade } }` needs
`Department` to be a Row **type** in scope. nodeflux-os is organised by
context, one directory each, and **contexts never import each other**; that
rule is load-bearing in the Go original (its ADR 0010) and was kept in the
port. So no context can write a `.references` to a sibling's table, and no
context can be the module that owns the schema.

The only shape that compiles is a separate `src/schema/` module that declares
all 59 tables in full, imports no context and is imported by none, while
every context keeps its own Row, `.managed = false`, for reading. Result:

| | Rows | Lines |
|---|---|---|
| `src/schema/`, managed, full columns | 59 | 3,876 |
| Context `rows.zig` files, unmanaged, the columns each reads | 68 | (already existed) |

Each column now has two declarations. Change `deals.value_amount_minor` from
`i64` to `?i64` in one and not the other and the program compiles; the boot
check catches it, but only at boot, and only on the reading side. The schema
Rows are not otherwise used by the program: no query names one. They exist to
be diffed.

Two ways out, and I do not know which is right:

- **Let a Row reference a table by name when the type is not importable**:
  `.references = .{ .department_id = .{ "departments", "id", .cascade } }`.
  The type-alignment check is lost for that one edge and replaced by a
  boot-time check against `pg_constraint`, which `db.checking` is already
  positioned to run. Then each context owns its Row managed, and there is one
  declaration.
- **Say in the ADR that the schema module is the shape**, and that a program
  organised by context will declare its tables twice. It is a defensible
  trade; it is just not a stated one, and it was the first thing the port had
  to design around.

---

## 7. `generate` cannot re-derive a baseline, and the version file has no slot

Porting an existing schema is not "add a column"; it is fourteen files being
written and checked against a reference over and over. Each round meant:

```sh
rm migrations/0001_schema.zig migrations/snapshot.zon
# reset manifest.zig to head 0
zig build db -- generate --name schema
# rewrap 0001_schema.zig so .steps = generated ++ schema.steps
zig fmt … && zig build db -- check
```

Two things forced the script. First, `generate` refuses to run when a
snapshot exists and the diff is empty, and there is no `--baseline` that says
"forget the snapshot and derive from nothing". Second, the version file it
writes is `.steps = &.{ … }` with no place for the 141 hand-written steps that
live beside their Rows in fourteen section files; the port wraps the
generated list into a `const generated` and appends `schema.steps`:

```zig
const generated: []const migrate.Step = &.{ … };          // what generate wrote
pub const version: migrate.Version = .{
    .number = 1, .name = "schema",
    .steps = generated ++ schema.steps,                    // the wrap
};
```

That is a fine shape, and it should be the one `generate` writes: emit
`generated` as its own decl and a `version` that concatenates, and on a rerun
preserve everything below the generated block. `--baseline` (or `reset` as
ADR 0153 sketches it) then makes porting a loop rather than a script.

One ordering note while here: generated steps run first, hand-written second.
A hand-written object a generated step needs (an extension a column type
comes from, a function a default calls) has nowhere to go. It did not bite
this schema, because `timescaledb` and `set_updated_at()` are only needed by
other hand-written steps, but it will bite the first program whose column is
`citext`.

---

## 8. `app.start(io)` then `listen()` never exits, with a Postgres pool

**Done at `09cb02c`, ADR 0220.** The wait was two loops: a pool opened on
`std.Io.Threaded` and closed from a zio fiber, and a worker started on the
`Threaded` with nothing driving it once `listen()` owned the loop. Three
things landed:

- `listen()` after `app.start(io)` is refused when a service kept the `Io`:
  one line naming the services, `error.StartedOnAnotherLoop`, exit 1.
- `app.before(f, args)` is the phase, inside `listen()`: after the services,
  before the work `spawn` registered, on the Engine's loop, with a
  `*nilo.Run` first. Three refusals while compiling.
- `db.expecting(manifest.head)` runs `migrate.expect` inside `nilo_start`,
  beside `checking`. A call rather than a field on `Opts`: the field cost
  17,296 bytes in every program with a `Db`, the call costs 16.

The bisect and the port's workaround are summarised in the ADR's Context.

---

## 9. `Date`, `Decimal` and `Jsonb` are `AsText`

`sql.AsText("date")`, `AsText("char(3)")`, `AsText("numeric(14,3)")`,
`AsText("jsonb")` cover the DDL, and they work. But `pub const Date =
sql.AsText("date");` is now declared in four files of one program
(`commitment/rows.zig`, `project/rows.zig`, `activity/rows.zig`,
`schema/columns.zig`), and every query that reads one casts `::text` because
the type reads as text. A `sql.Date` and `sql.Decimal(14, 3)` that read as
themselves would be one declaration and no casts. Minor beside the rest;
listed because every business schema has all three.

---

## 10. A version is applicable only from Zig

This is not a gap in the design; it is the design. The source is a Zig type,
the diff runs at comptime and `manifest.zig` is a module the server imports,
so nothing about *authoring* a version can happen without a Zig compiler.
dbmate, goose and flyway are language-agnostic because their unit is a `.sql`
file and a ledger table, and that is exactly the trade ADR 0153 makes the
other way, for the reasons it gives. Prisma, Django, Ecto and Drizzle make the
same trade; Atlas is the one tool that diffs *and* stays language-agnostic,
and it pays with a full SQL parser, which this design rightly refuses.

What does not have to be Zig-only is **applying** a version, and today it is:

- `status --sql` prints the waiting versions' statements, but it opens a
  database to know which are waiting, so a person with `psql` and no Zig
  cannot get the SQL at all.
- What it prints has no ledger row. A DBA who applies it by hand leaves
  `nilo_migrations` behind, and the next boot refuses with "the database is
  at 6" while every table is at 7.
- The ledger's shape (`version`, `name`, `hash`, `applied_at`, `ms`) is
  nowhere a non-Zig program can read it from.

The cheap half: **`generate` writes a `.sql` twin beside every version**,

```
migrations/0007_work_items_get_a_priority.zig
migrations/0007_work_items_get_a_priority.sql
```

containing the version's statements in order, wrapped in `BEGIN`/`COMMIT`,
ending with the ledger row `generate` already knows every field of
(`INSERT INTO nilo_migrations (version, name, hash, applied_at, ms) VALUES
(7, 'work_items_get_a_priority', '<hash>', now(), 0)`), and regenerated
whenever the `.zig` is. `check` compares the two so a `.sql` cannot go stale.
Then `psql -f`, dbmate, a CI job with no toolchain, or a DBA on a jump host
can bring a database to head, `expect` accepts it, and `verify` still holds
the hash. The ledger's columns go in `reference.md` as a contract.

What that does not give: a version written in SQL by somebody else and
picked up by nilo. That is authoring, it stays Zig, and it should; the
`.sql` twin is an output, never an input.

For nodeflux-os this does not bite, since the Go binary and its goose
migrations are the thing being replaced. It bites the first program whose
database is shared with a service in another language, and the first
deployment where migrations are run by somebody who is not shipping the
binary.

---

## The shape to aim for

The nine items above are gaps. This section is the other question: if nilo
migrations are being designed to be the most pleasant version of this, what
is the end state? Written as a target, so the items can be judged by whether
they move toward it.

### One principle, and it is a correction to the ADR

ADR 0153 has one bar: "a word gets into the marker if the compiler can check
it." That bar is right for **what the compiler owns** (a column's type, a key,
a foreign key's two sides) and wrong as the only bar, because a migration tool
has a second job the compiler has nothing to do with: **diffing**. A `CHECK`
body is a string the compiler cannot read. It is also a **named object with a
text**, and a diff engine can own a named text completely: same name, same
hash, nothing to do; same name, new hash, replace; name gone, drop. Nothing
about that needs the compiler, and it is exactly what a person otherwise
writes by hand as `ALTER TABLE … DROP CONSTRAINT …, ADD CONSTRAINT …`.

So the marker has two kinds of word, and both belong:

| Kind | Checked by | Diffed by | Examples |
|---|---|---|---|
| Typed | the compiler | the snapshot | columns, `.key`, `.unique`, `.index` (with `.where` and `.desc`), `.references` (single and composite), `.default`, an enum column's `CHECK` |
| Named text | the compiler checks the **name** and where it hangs; the database checks the body at `migrate`, inside the transaction | the snapshot, by name + hash | `.check`, `.trigger`; at schema level `.functions`, `.views`, `.extensions` |

The "vocabulary that stops being checked starts growing" worry is answered by
closing the second kind at **the object kinds whose replace is mechanical**:
a CHECK is drop+add, a trigger is drop+create, a function and a view are
`CREATE OR REPLACE`, an extension is `CREATE IF NOT EXISTS`. Five kinds. A
generated column, a collation, a rule, a policy: still a `.data` step until
somebody brings a case, which is the ADR's own rule for the third kind:

| Kind | Checked by | Diffed by | Examples |
|---|---|---|---|
| `.data` | nobody | never; placed by hand in one version | seed rows, a backfill, `create_hypertable(...)` |

### What a table looks like

Every fact about `work_items` in one place, in the context that owns it:

```zig
pub const WorkItem = struct {
    pub const nilo_table = .{
        .name = "work_items",
        .key = .id,
        .default = .{ .created_at = .now, .updated_at = .now, .priority = "normal", .position = 0 },
        .unique = .{
            .{ .columns = .{ .department_id, .number }, .name = "work_items_number_is_unique_per_board" },
        },
        .index = .{
            .{ .columns = .{ .assignee_staff_id }, .where = .{ .assignee_staff_id = .not_null } },
            .{ .columns = .{ .department_id, .{ .created_at = .desc } } },
        },
        .references = .{
            .department_id = .{ "departments", .id, .cascade },
            .epic = .{ .columns = .{ .epic_id, .department_id },
                       .to = .{ "work_epics", .{ .id, .department_id } } },
        },
        .check = .{
            .sku_product_and_deal_never_together =
                "NOT (sku_product_id IS NOT NULL AND deal_id IS NOT NULL)",
        },
        .trigger = .{
            .updated_at = "BEFORE UPDATE FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
        },
    };

    id: sql.Uuid,
    department_id: sql.Uuid,
    priority: Priority,           // enum: text + CHECK (priority IN ('urgent','high','normal','low'))
    target_date: ?sql.Date,
    created_at: sql.Timestamp,
    updated_at: sql.Timestamp,
    // …
};
```

Two things in that block are new beyond items 1 to 5.

**`.references` names a table, not a type**, and loses no check. The type
check ADR 0153 prizes (the two sides' Zig types agree) is done today in the
Row's own `comptime`, which is why the target has to be an imported type.
The same check runs one level up, in `sql.cli.Tool(Db, tables)` and in
`snapshot`, where every Row is already in one comptime list: resolve
`"departments"` in `tables`, find `.id`, compare its type to
`department_id`'s. Still `@compileError`, still before any database exists.
A name that matches no Row in the list is a compile error naming the two
spellings. This is what lets a program organised by context keep one Row per
table, managed, in the directory that owns it, with a `schema.zig` that is
nothing but `pub const tables = &.{ org.Department, org.Staff, … }`.

**`.check` and `.trigger` are named texts on the Row**, so the table stays
one declaration and the diff owns them. `generate` emits them after the
table's `CREATE`, and a changed body in a later version emits the replace.
The compiler checks the name is a valid identifier under 63 bytes and that
the trigger's table is this one; the body is checked by Postgres at
`migrate`, in the version's transaction, which is the same moment a `.data`
step is checked today, so nothing is lost against the present design.

### What the schema looks like

```zig
// schema.zig, the one file that may import every context
pub const schema = sql.Schema{
    .extensions = &.{"timescaledb"},
    .functions = .{
        .set_updated_at = @embedFile("sql/set_updated_at.sql"),
    },
    .tables = &.{ org.Department, org.Staff, work.WorkItem, … },
    .views = .{
        .sku_catalogue = @embedFile("sql/sku_catalogue.sql"),
    },
};
```

Order is fixed by kind and the tool owns it: extensions, functions, tables
(in dependency order, which the references give), each table's checks and
triggers, views, then whatever `.data` steps the version file adds by hand.
That closes item 7's ordering note, and it puts a 60-line view in a `.sql`
file with highlighting rather than in sixty `\\` lines.

### What a version looks like

`generate` writes it and a person adds to it, and both halves are visible:

```zig
// migrations/0007_work_items_get_a_priority.zig
const migrate = @import("nilo_sql").migrate;

pub const version: migrate.Version = .{
    .number = 7,
    .name = "work_items_get_a_priority",
    .steps = generated ++ by_hand,
};

// Written by `generate`. Regenerated in place; do not edit.
const generated: []const migrate.Step = &.{
    .{ .kind = .add_column, .why = "work_items.priority", .sql = … },
    .{ .kind = .add_check, .why = "work_items.priority: the enum's four words", .sql = … },
};

// Yours. Kept across a regenerate.
const by_hand: []const migrate.Step = &.{
    .{ .kind = .data, .why = "existing work is normal priority", .sql =
        \\UPDATE work_items SET priority = 'normal' WHERE priority IS NULL
    },
};
```

Plus `generate --baseline`, which forgets the snapshot and writes version 1
from the whole schema, for the day a schema is ported rather than grown; and
the `.sql` twin of item 10 beside every version, so a database can be brought
to head without the binary. And the version guard is on `Db` now (item 8):

```zig
db.expecting(manifest.head);
```

checked inside `nilo_start` beside `checking`, so no program opens a pool
under `Threaded` to ask a question the pool was going to be asked anyway.

### What it does to this port

| | Today | Target |
|---|---|---|
| Declarations per table | 2 (schema Row + context Row) | 1 |
| Hand-written steps | 141 | 11: ten seed inserts and `create_hypertable` |
| Tables split across a Row and its steps | 56 | 0 |
| Files under `src/schema/` | 16, 3,876 lines | 1, the `tables` list |
| Regenerating the baseline | a shell script | `generate --baseline` |
| A changed CHECK body | hand-written `ALTER TABLE` | diffed |
| `.references` across contexts | impossible without the duplicate module | by name, checked at comptime |

And the two things this design deliberately does not do: it does not parse
SQL (a named text is opaque to nilo, compared by hash), and it does not
model a Postgres `ENUM` type, a policy, a rule or a generated column. Those
stay `.data` until they have a caller, which is how the vocabulary stays
closed while being larger than three.

---

## What I would do with nodeflux-os today

Two shapes were on the table, and the numbers above decide it for this
schema, on nilo as it is:

**A. Rows own the schema** (what was built). One declaration per table in
`src/schema/`, `generate` diffs it, 141 steps of SQL beside it for what Rows
cannot say. Cost: every table split in two, every column declared twice, the
regen script for as long as the baseline is being ported.

**B. SQL owns the schema, nilo owns the ledger.** Keep the Go baseline as one
SQL file in a single `.data` step, write later versions as `.data` steps, keep
every Row `.managed = false`, keep `expect` and `checking` at boot. Cost:
`generate` and `check` have nothing to diff, so a Row change has to be
noticed by a person; the snapshot is empty.

**For this codebase, B.** It keeps everything that turned out to be valuable
(the ledger, one transaction per version, `expect`, `checking`, the CLI) and
gives back the one thing A took, a table that reads as one block. What A
adds on top, a diff that writes `ADD COLUMN` for you, is worth less than half
the schema here because half the schema is outside the diff.

**Items 1, 2 and 3 flip that, and the target shape above finishes it.** With `.default`, enum-derived `CHECK`s and
typed partial indexes, the hand-written half of this schema drops from 141
steps to 71: 25 `ALTER TABLE`s carrying the 56 expression CHECKs, 31
triggers, one expression index, the view, the hypertable, the extension, the
function and 10 seed inserts. Every one of those is a string the ADR is right
to leave as a string. 31 tables stop being split, the 25 still split keep
only the CHECKs that are expressions, and `generate` diffs the defaults, the
state words and the partial indexes it cannot see today. At
that point A is clearly better than B, and nilo would be generating what
this program's Go original had to write by hand and keep in step with sqlc.
That is the version of the feature the ADR's title promises, and it is three
words away.
