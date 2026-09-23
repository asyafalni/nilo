# 0221 — the marker has two kinds of word

**Status:** accepted
**Amends:** [ADR 0153](./0153-a-migration-is-a-diff-against-a-snapshot.md), in two
places. Its §"The line: nilo generates what a type can say" settles the
vocabulary at three words and calls a check constraint and a partial index
"not a gap"; its §"A default belongs to the step, not to the type" refuses
`.default` outright. Both are amended here. The bar 0153 set — **a word gets
into the marker if the compiler can check it** — is kept exactly as it was
written, and that is the whole of the argument: the line was drawn short of the
bar.

## Context

A 59-table program was ported onto `sql.migrate` in one session, and
[`docs/input_from_nodeflux.md`](../input_from_nodeflux.md) is what it reported.
The generated schema was right: a normalised `pg_dump --schema-only` of the
nilo-migrated database against a goose-migrated one differed in six
unique-constraint names and nothing else. The complaint is about what had to be
written by hand beside the Rows to get there.

| What the port wrote by hand | How much |
|---|---|
| `ALTER TABLE … SET DEFAULT` steps | 126 defaults, on 53 of the 59 tables. 86 are `now()` on a `created_at`; 40 are literals every insert relies on for the life of the program |
| `CHECK (col IN (…))` lists | 29, each one sitting beside a Zig enum with the same words in it |
| `CREATE INDEX` steps | 39 of the 92 indexes. 34 are partial, 18 order a column downwards; nilo generated the other 47 |
| Constraint names | 6 lost their meaning to the derived spelling, and **2 were silently truncated by Postgres at 63 bytes** |
| `pub const Date = sql.AsText("date")` | declared in four files of the one program, and every query that reads one carries a `::text` |

None of that is a database the compiler cannot see. A default of `.now` on a
`sql.Timestamp`, a literal of the column's own Zig type, the words of a Zig
enum, a predicate over the Row's own columns, a name's length in bytes: every
one of them is decidable while compiling, and 0153's own bar therefore lets
them in. What 0153 was actually refusing is visible in the sentence it rejected
them with — `.where = "deleted_at IS NULL"`, a string the database reads. That
refusal is still right, and this does not propose one.

The second half of the finding is about the bar itself. A migration tool has a
job the compiler has nothing to do with: **diffing**. A `CHECK` body is a string
no compiler can read, and it is also a *named object with a text*, which a diff
owns completely — same name and same text, nothing to do; same name and a new
text, replace; name gone, drop. So "checked while compiling" is the right bar
for one kind of word and not the only bar there is.

## Decision

**The marker has two kinds of word, and this ADR builds the first kind.**

| Kind | Checked by | Diffed by | Words |
|---|---|---|---|
| Typed | the compiler | the snapshot | columns, `.key`, `.unique`, `.index` (with `.where` and a direction), `.references`, `.default`, an enum column's `CHECK`, a `.name` on any of them |
| Named text | the compiler checks the name and where it hangs; the database checks the body inside the version's transaction | the snapshot, by name and hash | `.check`, `.trigger`, and at schema level functions, views and extensions |

The second kind is accepted in principle and **not built here**. It needs its
own ADR, because what closes it is a list of object kinds whose replace is
mechanical rather than a general escape hatch, and that list is the decision.
Until it exists, a check constraint written by hand and a trigger are what they
have always been: SQL in a step, marked in the snapshot as an object nilo does
not own.

> **Closed by
> [ADR 0226](./0226-the-marker-has-a-word-the-database-checks.md).** The list is
> five — a `CHECK`, a trigger, a function, a view, an extension — and ADR 0226
> builds the two that hang off a table, as `.check` and `.trigger`. The other
> three hang off a schema and wait on a `sql.Schema` that does not exist yet.
> An enum column's `CHECK` can be named there too, with
> `.check = .{ .<name> = .{ .words_of = .<column> } }`.

### The five typed words, and what each is checked against

```zig
pub const nilo_table = .{
    .name = "work_items",
    .key = .id,
    .default = .{ .created_at = .now, .priority = .normal, .position = 0 },
    .unique = .{
        .{ .columns = .{ .department_id, .number },
           .name = "work_items_number_is_unique_per_board" },
    },
    .index = .{
        .{ .columns = .{.assignee_id}, .where = .{ .assignee_id = .{ .ne = null } } },
        .{ .columns = .{ .department_id, .{ .created_at = .desc } } },
    },
    .references = .{ .department_id = .{ Department, .id, .cascade } },
};
```

**`.default`.** `.now` is the one word it has, and it is refused on a column
that is not a `sql.Timestamp`; everything else is a literal of the column's own
Zig type, so a number the column could not hold and a string where an integer
goes are both compile errors. `DEFAULT (lower(x))` is still a step, and that is
the line: a default the database has to work something out for is not one the
compiler can check.

0153 refused this on the grounds that a default is load-bearing only in a narrow
moment — a `NOT NULL` column added to a table that already has rows — and is
dropped afterwards. Of the port's 126, **not one is that case**. The narrow
moment is real and it is now handled by the same field rather than argued about:
`add_column` asks for a backfill only when the column is `NOT NULL` *and* has no
default.

**An enum column's `CHECK`.** A Zig enum the Row reads as a column is a `text`
column with `CHECK ("col" IN ('urgent', 'normal'))` on it, named
`<table>_<column>_check` — or whatever `.check`'s `.words_of` calls it
([ADR 0226](./0226-the-marker-has-a-word-the-database-checks.md)). The words go
in the snapshot, so adding a tag to the enum is a migration rather than an
insert the database refuses at run time.

**An enum that says which database type it is keeps its silence.**
`pub const nilo_column = "user_role"` names a Postgres `ENUM` whose words are
the database's, added with `ALTER TYPE`, and nilo neither writes them nor
judges them. That distinction is what makes the boot check safe to tighten:
`schema.expectationsOf` now judges an enum column, but **only on a Row this
program builds**. A `.managed = false` Row reading somebody else's table is
declined exactly as before, because the column under it may be a real `ENUM`
and guessing its type name is how an honest schema gets refused.

**`.index` gained `.where` and a direction.** The predicate is not a string. It
is the grammar the where walker already has, read the same way: a name that is
not a column is a Refusal naming the near miss, and a literal that is not the
column's own type does not compile. Four terms, which is every shape the port's
34 partial indexes needed:

```zig
.where = .{
    .deleted_at = null,           // IS NULL
    .read_at = .{ .ne = null },   // IS NOT NULL
    .state = .open,               // = 'open'
    .kind = .{ .ne = "draft" },   // <> 'draft'
}
```

**This is where the spelling deviates from the document that asked for it**,
which proposed `.where = .{ .assignee_id = .not_null }`. `where.zig` already
spells that `.{ .ne = null }` in every `db.select` anybody writes, and a marker
that spells the same test a second way is a second thing to learn for no gain.
An index over an expression — `lower(btrim(site))` — is still a step, and stays
one until somebody brings a second case.

**A `.name`, and 63 bytes checked on both databases.** A derived name is a
column list a support engineer has to go and read the schema for; Postgres
reports a violation by constraint name and nothing else, so `.name` is how the
violation becomes a sentence. The guard behind it is the one the port actually
needed: Postgres cuts an identifier down at 63 bytes on the way in, says so in a
`NOTICE` nothing reads, and the snapshot then holds a name the database does not
have. **Checked whatever the Dialect is.** SQLite has no limit, and a schema
that compiles for one database and quietly loses a name on the other is the
opposite of what one type describing both is for.

Two entries that derive the same name are also a Refusal now, which is the
mistake that used to arrive as a `CREATE` failing against a database where the
first one had already run.

### Rendered while compiling, so the DDL and the diff cannot disagree

A `Column.default` holds `now()` or `'normal'` — the text, as this Dialect
spells it — and not the value it was written from. That is the arrangement
`sql_type` has had all along, and the reason is the same: one string is both
what the `CREATE` writes and what the diff compares, and two strings can fall
out of step. The checking happens *before* the rendering, so nothing about the
Refusals is weakened by it.

It is also what makes the two databases' answers honest rather than averaged.
`now()` on Postgres; on SQLite,
`(CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER) * 1000)`, which is
milliseconds where Postgres is microseconds. **That is a stated cost rather than
a bug**: SQLite has no microsecond clock to call, and a default that pretends
otherwise would be a column whose values disagree with the ones nilo writes.

### What SQLite cannot do, it says in one sentence

SQLite cannot alter a column's default and cannot replace a constraint, so
`Dialect.can_alter_column` and the new `can_alter_constraint` are both false
there. When a column moves in a way SQLite cannot follow, the diff raises **one**
Problem naming everything that moved — the type, the nullability, the default
and the words — rather than one per thing, because a column that changed three
ways needs one rewrite and not three.

### `sql.Date` is read out of the column, not out of a `::text`

`sql.AsText("date")` works and costs a cast: a text-carried type is asked for as
`column::text` in every `SELECT` list, so a `db.raw` statement reading one has to
carry the cast and `rawcheck` refuses it when it does not. `sql.Date` is asked
for as itself.

- **Postgres** stores a `date` as four bytes, a day count from 2000-01-01.
  pg.zig has no `date` codec — `Int32.decode` refuses the OID — so the Wire
  reads `row.values[col]` and shifts by 10,957 days. One shift, not a parse.
- **SQLite** has no date type at all, so the column is `TEXT` and the ten ISO
  characters are what is stored, which is what SQLite's own date functions read.
- **Writing is the same ten characters on both**, with `::date` around the
  placeholder on Postgres. That asymmetry is the driver's and not a design
  choice: pg.zig has no encoder to bind one with.

`Date` holds this file's line — a type carries a value and knows how to write
itself, it does not calculate. There is no `.addDays` and no `.weekday`. The two
conversions it does offer are named for the assumption they make (`utcOf`,
`atMidnightUtc`), because assuming a zone silently is how a report for the 1st
picks up rows from the 2nd.

Building it turned up two things worth writing down. `Timestamp.writeRfc3339`
stops at the epoch and answers `error.BeforeEpoch`, which is a reasonable answer
for a moment and the wrong one for a day: **the first thing anybody puts in a
`date` column is a date of birth.** So `Date` walks the calendar itself, in both
directions, over the whole range four digits spell. And zero-padding a *signed*
integer in Zig writes the sign, so `{d:0>4}` on an `i64` year prints `+1945`;
nothing had met that before because the year std hands back is unsigned. It was
found by a round trip through a real SQLite column, which is the only place it
could have been found.

**`Decimal` stays `sql.AsText("numeric")`**, deliberately. Its binary form is a
base-10000 digit vector with a weight, a sign and a display scale — a parser
rather than a shift — and the text form already round-trips every digit, which
a live test holds at twenty-nine of them. A column that wants its precision in
the DDL writes `sql.AsText("numeric(14,3)")` today and that is one declaration,
which was the complaint.

### An older snapshot still parses

Every field this adds to the snapshot has a default: `Column.default`,
`Column.values`, `Index.descending`, `Index.where`. `std.zon` omits a field
equal to its default when writing and fills it in when reading, so a
`snapshot.zon` written before any of this existed parses as the schema it
described. A test holds it, against a hand-written older file rather than
against one this code round-tripped.

### `.filled`, and an insert that leaves out what nothing fills

**An insert that leaves out a column nothing fills is a Refusal, naming every such column.** An insert writes a subset of the columns on purpose (ADR 0039), so that the ones the database fills need not be written. A column that is not optional, not the integer key a sequence fills, and has no `.default` has nothing to fill it, and leaving it out was a `NotNullViolated` the first time the insert ran. An application found it that way: a column added to `bills` in one release, the seed updated, one insert elsewhere missed, and assessing a new year answered 500, with no warning from the compiler. `insert`, `insertMany` and both upserts ask; the error names the columns and the ways out.

**`.filled` is the word for a column the database fills by a means the marker cannot say**: a `DEFAULT` written in a step, `gen_random_uuid()` on a `Uuid` key, a trigger. `.filled = .{ .number, .created_at }`, or `.filled = .created_at` for one. It renders no DDL and no diff; it tells an insert that leaving the column out is meant. It is not the fourth kind of word refused below, which would be text the database reads. This one is read by nothing but the check, and the compiler can hold it: every name is a column, and a column already filled another way, by a `.default` or by its sequence, is refused rather than said twice.

**A table this program does not build is not checked** (`.managed = false`, ADR 0162). Its defaults are the database's and were never written in the marker, so the marker cannot say which columns an insert may leave out. The check is read off the owner, the Row that names the table, so a narrow Row that borrows it cannot hide a required column it has no field for.

The cost is paid once, by programs that compile today: every managed Row whose table has a default the marker does not carry needs `.filled` or `.default` before its inserts compile again. The guide's own `User` was one of them. Its inserts left out `name`, `orders` and `created_at`, a table made by `createMissing` has no default for any of them, and the page had been teaching an insert that could not run.

None of it runs. The check and the word are comptime, and every statement's text is what it was, so no axis in ADR 0018 moves; what it spends is compile time and six Refusals, one for each mistake it can be handed.

## What was rejected

**Reading the words back out of `pg_constraint.conbin` at boot.** It would let
the startup check say that the database's `CHECK` has a word the Zig enum does
not, which is a real failure and the one `db.checking` exists for. It also means
parsing a normalised expression tree back into a list of strings, per enum
column, on every boot. Not in this round; the migration owns the words, and a
database whose check disagrees with the snapshot is what `verify` is for.

**`.default` as free text.** `.default = .{ .status = "'draft'::text" }` covers
everything in one line and checks nothing, which is the vocabulary 0153 was
right to refuse. What is in is what the compiler can hold an opinion about.

**`.where` as a string**, for the same reason, and it is the sentence 0153
rejected by name.

**A fourth kind of word for the things neither kind covers** — a generated
column, a collation, a rule, a policy. Each is a `.data` step until somebody
brings a case, which is 0153's own rule and is unchanged.

**An insert variant that checks, beside the one that does not**, `insertWhole` say, for the left-out column. Nothing would break, and nothing would be caught either: the insert that was missed is the one nobody thought to switch over.

**Making the column optional as the only way out**, with no word for a default the database has. A `gen_random_uuid()` key or a trigger-stamped column is not null once it is read, and a `?` on it would be a lie told to every reader to satisfy one insert.

**Spelling an enum default as text.** `.priority = "normal"` reads naturally and
puts the column's type and the default's type out of step; a column that holds
one of an enum's words takes one of its words, written the way a column is:
`.priority = .normal`. The document that asked for this proposed the text form.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — nothing here is reachable from a request |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | **0 bytes, measured** |

The binary-size row is measured rather than reasoned, and it is measured the way
`CLAUDE.md` says to: `git archive HEAD` into a scratch directory, both sides
built with `zig build size-sql`, stripped `ReleaseFast`. **`nilo-size-pg_only`
is 1,800,600 bytes and `nilo-size-sqlite_only` is 2,305,584 on both sides, and
`cmp` reports the two pairs byte for byte identical.** All of the marker is
comptime, the DDL and the diff are reachable only from a program that names
`migrate`, and the `date` branches in both Wires are inside a `comptime` test
that a Row with no `Date` in it never takes.

What it costs instead is compile time and error messages, which is where this
repository spends. `zig build refusals-sql` goes from 105 programs to 120, and
the fifteen are the mistakes each word makes:

- **`.default`** — `.now` on a number, a word `.default` does not have
  (`.gen_uuid`), a literal of another type, a word the enum does not have, an
  enum default written as text, and one on a generated key.
- **`.index`** — a direction that is not `.asc` or `.desc`, a direction on a
  `.unique`, a `.where` term that is not one of the four, and a `.where`
  literal of another type.
- **A name** — one written as `.an_enum_literal` where text goes, a given name
  of 72 bytes, a derived name of 70, two constraints deriving one name, and a
  misspelled word in an entry (`.ignorng_case`, which used to compile into a
  unique that folded no case).
