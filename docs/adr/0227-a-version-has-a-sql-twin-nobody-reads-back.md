# 0227 — a version has a `.sql` twin nobody reads back

**Status:** accepted
**Extends:** [ADR 0153](./0153-a-migration-is-a-diff-against-a-snapshot.md),
§"Forward only". Authoring a version stays Zig, for every reason that ADR gives.
What changes is that applying one no longer has to be.

## Context

The 59-table port's tenth finding is the only one in the file that is not about
the vocabulary, and it is the one most likely to make a team outside this one
say no:

> What does not have to be Zig-only is **applying** a version, and today it is.

The source is a Zig type, the diff runs at comptime and `manifest.zig` is a
module the server imports, so nothing about *authoring* can happen without a Zig
compiler. dbmate, goose and flyway are language-agnostic because their unit is a
`.sql` file and a ledger table, and that is exactly the trade ADR 0153 makes the
other way. Prisma, Django, Ecto and Drizzle make the same trade nilo does; Atlas
is the one tool that diffs *and* stays language-agnostic, and it pays with a
full SQL parser.

Three things follow from that, and only the first was intended:

- `status --sql` prints the waiting versions' statements, but it opens a
  database to know which are waiting. Somebody with `psql` and no toolchain
  cannot get the SQL at all.
- What it prints has no ledger row. A DBA who applies it by hand leaves
  `nilo_migrations` behind, and the next boot refuses with "the database is at
  6" while every table is at 7.
- The ledger's shape — `version`, `name`, `hash`, `applied_at`, `ms` — is
  nowhere a non-Zig program can read it from.

This bites the first program whose database is shared with a service in another
language, and the first deployment where migrations are run by somebody who is
not shipping the binary.

## Decision

**`db generate` writes a `.sql` twin beside every version file, and `db check`
fails when one has gone stale.**

```
migrations/0007_work_items_get_a_priority.zig
migrations/0007_work_items_get_a_priority.sql
```

The twin holds the version's statements in order, each with its `why` above it
as a comment, and three things `status --sql` does not print — each of which is
what makes the file usable on its own:

```sql
BEGIN;

CREATE TABLE IF NOT EXISTS "nilo_migrations" ( … );

-- create work_items
CREATE TABLE "work_items" ( … );

INSERT INTO "nilo_migrations" ("version", "name", "hash", "applied_at", "ms")
VALUES (7, 'work_items_get_a_priority', '<hash>', now(), 0);

COMMIT;
```

The ledger table, made if it is not there, so a fresh database takes version 1.
`BEGIN`/`COMMIT`, so a version that fails halfway leaves nothing. The ledger
row, so a database brought to head this way is a database
`db.expecting(manifest.head)` will serve and `verify` still holds to the hash.
`ms` is zero because nobody timed it, and a number invented here would be a
worse answer than none.

**An output and never an input.** nilo reads the `.zig` and never this. A
version written in SQL by somebody else and picked up by nilo is authoring, it
stays Zig, and it should.

**The twin is written from the compiled `Version`, because the hash is
chained.** `hashOf` puts the parent hash in first, which is what makes editing
version 3 move every version after it. So a twin cannot be written from the
steps alone; it needs the versions before it, and those come from the generated
manifest the binary was built with. `migrations.Options.versions` is how they
get in, and `db generate` passes what `Tool.run` was already given.

Three cases follow, and each has an honest answer rather than a guess:

- **A new version.** `renderVersion` writes `before` and `after` empty, so the
  file's steps are exactly the ones in hand, and the parent is the compiled
  head. The twin is written, and it is exact.
- **`--baseline` deriving version 1 for the first time.** Same: no hand-written
  halves, no parent. Exact.
- **`--baseline` rewriting a version 1 that has hand-written steps in it.** The
  new file's steps are `before ++ new_generated ++ after`, and `before` and
  `after` are Zig this binary did not compile. **No twin is written**, the
  outcome says so, and `db check` asks for it after the rebuild.

**Every run refreshes every twin**, including a `generate` that has nothing to
generate. That is what makes `check`'s advice true, and a schema that has not
moved is exactly when a stale `.sql` is easiest to leave behind: nothing else in
the command has anything to do.

## Alternatives rejected

**Print it from `status --sql` and let people redirect.** It needs a database to
know which versions are waiting, which is the whole problem. Making it not need
one turns `status` into a second `generate` with a different name.

**Write the twin but leave the ledger row out.** Then applying it by hand is
half a job, and the half that is missing is the half that stops the next boot.
The row is the only part of this that could not have been got from
`status --sql` with a shell script.

**Put the hash in the `.zig` so the twin can be written from it alone.** ADR
0153's `Chain` refuses this on its own terms, and the reason still holds: a hash
written in the same file as the statements it covers is decoration, because
whoever edits a statement is looking straight at it.

**Write a twin with an unchained hash when the binary is behind.** It would put
a wrong hash in a file people apply by hand, and the failure would be a database
that reaches head and then fails `verify`. Writing nothing and saying so is
worse to read and better to be handed.

**Make `check` regenerate the twin instead of reporting it.** `check` is the
command CI runs and the one that is supposed to write nothing. A command that
fixes what it is asked to inspect is a command whose green build means nothing.

**Accept the twin as an input too, so a version can be written in SQL.** This is
the request underneath the finding, and it is refused for ADR 0153's reasons
rather than for convenience. A version nilo did not generate has no snapshot
behind it, so the next `generate` diffs against a schema that does not describe
the database.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — nothing here is reachable from a request |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | **0 bytes, measured** |

`nilo-size-pg_only` at 1,800,600 bytes and `nilo-size-sqlite_only` at 2,305,584,
`cmp`-identical against `git archive HEAD`. `migrations.zig` is the half of the
module that touches a disk, and a server that applies migrations at boot links
none of it.

**On disk it costs roughly what the version file costs**, once per version, and
the file is committed. A ported schema of sixty tables is a few hundred
kilobytes of `CREATE TABLE` written twice.

No refusals: every failure here is a file rather than a program. The wording is
held by tests calling `writeStale` and `writeTwins` directly, both free
functions rather than methods on `Tool`, for the reason ADR 0223's three are.

**The test that makes it a file rather than a claim is in
`sql/migrate_live.zig`.** Every other check compares text against text; that one
hands the statements to a real SQLite database in order, then asks
`migrate.expect`, which is what a server does at boot, and then runs
`db.checkSchema` against the same Rows. A twin that does not satisfy those is a
twin nobody should apply. Writing it found the bug the text comparisons would
also have found and nothing else would: the `INSERT`'s column list was opened
and never closed.
