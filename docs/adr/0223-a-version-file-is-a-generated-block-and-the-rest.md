# 0223 — a version file is a generated block and the rest

**Status:** accepted
**Amends:** [ADR 0153](./0153-a-migration-is-a-diff-against-a-snapshot.md),
§"What a generated file looks like". The file still holds one `Version` and no
hash; what changes is that the steps `generate` wrote are now a block inside it
rather than the whole of it, and that `generate` can derive version 1 again.

## Context

Porting a schema is not "add a column". It is fourteen files being written and
checked against a reference over and over, and every round of the 59-table port
in [`docs/input_from_nodeflux.md`](../input_from_nodeflux.md) ran this:

```sh
rm migrations/0001_schema.zig migrations/snapshot.zon
# reset manifest.zig to head 0 by hand
zig build db -- generate --name schema
# rewrap 0001_schema.zig so .steps = generated ++ schema.steps
zig fmt … && zig build db -- check
```

Two things forced the script, and both are this module's.

**`generate` cannot re-derive.** The second run diffs against the snapshot the
first one wrote, so it says "nothing to do". The only way back to a baseline was
to delete the snapshot, delete the version file and edit the manifest, which is
three files hand-edited in a loop that ran dozens of times. Nothing in the tool
said "forget the snapshot and derive from nothing".

**The version file has no slot for a hand-written step.** `generate` writes
`.steps = &.{ … }` and that is the whole file, so the port's 141 hand-written
steps — the ones that live beside their Rows in the fourteen section files —
had nowhere to go. The port wrapped the generated list by hand after every run:

```zig
const generated: []const migrate.Step = &.{ … };   // what generate wrote
pub const version: migrate.Version = .{
    .number = 1, .name = "schema",
    .steps = generated ++ schema.steps,             // the wrap, re-applied by hand
};
```

There is a third thing the port did not hit and said so: **generated steps run
first and hand-written steps run second**, so a hand-written object that a
generated step *needs* has nowhere to go at all. `timescaledb` and
`set_updated_at()` were only needed by other hand-written steps. The first
program with a `citext` column finds out differently.

## Decision

**The shape the port wrapped by hand is the shape `generate` writes**, and
`--baseline` makes re-deriving it a command rather than a script.

A version file is now four declarations, and only one of them is generated:

```zig
const migrate = @import("nilo_sql").migrate;

/// Steps of your own that have to run *before* the generated ones: the
/// extension a generated column's type comes from, a function a default calls.
pub const before: []const migrate.Step = &.{};

/// And the ones that run after: a backfill, a seed row, a `create_hypertable`.
pub const after: []const migrate.Step = &.{};

pub const version: migrate.Version = .{
    .number = 1,
    .name = "schema",
    .steps = before ++ generated ++ after,
};

// nilo:generated begin
const generated: []const migrate.Step = &.{ … };
// nilo:generated end
```

Three things about that layout are decisions rather than formatting.

**The generated block is at the bottom and the part a person edits is at the
top.** A ported schema puts four thousand lines of `CREATE TABLE` in this file,
and a `version` underneath them is a `version` nobody ever sees.

**`before` exists as well as `after`**, which answers the ordering note the port
raised before it bit anybody. A `CREATE EXTENSION citext` has to run before the
column whose type comes from it, and `before ++ generated ++ after` is where it
goes.

**The block is delimited by two whole-line markers**, and `--baseline` replaces
what is between them and keeps every byte outside. A file that has lost a marker
is **refused**, not rewritten: the only other reading of a file with no markers
is "all of it is generated", and acting on that throws somebody's 141 steps away
and reports success.

### `--baseline`

`db generate --name schema --baseline` ignores `snapshot.zon` entirely, diffs
the Rows against nothing, and rewrites version 1 where it stands. The manifest
and the snapshot are rewritten to match, so `db check` immediately afterwards is
green. The port's loop becomes one command.

It refuses in three places, each naming the file it is about:

- **A version it is not re-deriving is in the directory.** Version 2 is a diff
  against what version 1 left behind, so a re-derived version 1 leaves it
  describing a schema nothing ever had. The message lists the files.
- **`--name` disagrees with version 1 on disk.** Writing `0001_initial.zig`
  beside `0001_schema.zig` gives a directory `read` refuses, and that is not
  undoable by the tool. The message says both names.
- **The file being rewritten has no generated block.** As above.

`--baseline` is the only thing in this module that writes over a file that is
already there, and those three are why it is safe to say that out loud.

## Alternatives rejected

**`reset`, as a command of its own.** ADR 0153 §"Forward only" already has a
`reset`, and it is a different thing: it drops the objects nilo owns in a
*database* and replays from zero. This touches three files and opens no
connection, so borrowing the name would have put two unrelated operations behind
one word. A flag on `generate` also keeps `--name` and `--dir` meaning what they
already mean, and puts the three refusals in the one place that knows about
version files.

**Let `--baseline` renumber, so it works at any head.** The tempting version:
delete versions 2 and up, re-derive, done. Refused because the thing it deletes
is the only record of what a deployed database has already run. A tool that
silently makes `nilo_migrations` unreadable is worse than a tool that stops and
says which files are in the way.

**One hand-written slot rather than two.** `after` alone is what the port
actually wrote, and it covers the cases it hit. It does not cover the case the
port named and did not hit, and the second empty slice costs one line in a
generated file.

**A marker that is a bare comment like `// ---`.** Not distinctive enough to
match on, and a file that happens to contain one gets spliced in the wrong
place. `// nilo:generated begin` is ugly on purpose; it is a token, and the
refusal message prints it verbatim so the fix is copy and paste.

**Keep everything and diff the old file's steps.** Parsing Zig to find out which
steps were generated means shipping a Zig parser to read a file this module
wrote. Two marker lines answer the same question exactly.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — nothing here is reachable from a request |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | **0 bytes, measured** |

`migrations.zig` is the half of the module that touches a disk, and a server
that only applies migrations at boot links none of it. The measurement is the
same one ADR 0222 records, and it covers both changes: `nilo-size-pg_only` at
1,800,600 bytes and `nilo-size-sqlite_only` at 2,305,584, `cmp`-identical
against `git archive HEAD`.

No refusals: every one of these is a command-line mistake rather than a
compile-time one, so they are sentences in `sql/cli.zig` held by tests instead —
three of them, one per refusal, calling `writeBaselineRefusal` directly. That
function is free rather than a method on `Tool` for exactly that reason: the
wording is reachable without a `Db`.

**A generated file is never handed to the compiler by this suite**, which is the
one gap the shape opens. The tests write version files into a temporary
directory and read them back as text, so `before ++ generated ++ after` — three
slices concatenated into a `Version` — would have shipped unchecked. `test "the
shape the file is written in is a shape that compiles"` in `sql/migrations.zig`
writes that line out where the compiler does see it.
