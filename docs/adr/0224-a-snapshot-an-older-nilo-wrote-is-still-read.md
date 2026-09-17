# 0224 — a snapshot an older nilo wrote is still read

**Status:** accepted
**Amends:** [ADR 0222](./0222-a-foreign-key-is-columns-and-a-table-name.md),
§"What it costs", which said an older snapshot "is refused with a parse
diagnostic naming `column`" and that `db generate` rewrites it. The first half
was true of `snapshot.parse` and of nothing a person could reach; the second
half was false for any repository past version 1.

## Context

ADR 0222 renamed two fields in the snapshot. `.column` became `.columns` and
`.target` became `.targets`, because a foreign key is a list of columns and not
one. Every other word the marker has gained since ADR 0153 arrived as a **field
with a default**, and `std.zon` fills a missing field from its default — so a
snapshot written before that word existed still parses. A rename is the one
change that does not have that property, and ADR 0222 knew it and wrote down
the wrong answer.

Round two of the 59-table port in
[`docs/input_from_nodeflux.md`](../input_from_nodeflux.md) ran the command the
documentation told it to and got this:

```console
$ zig build db -- generate --name schema --baseline
error: ParseZon
/…/lib/std/zon/parse.zig:1043:9: 0x1351d9a in failTokenFmtNote__anon_179448 (std.zig)
        return error.ParseZon;
        ^
… forty more lines of stack …
```

Three separate things were wrong, and each of them is worth naming because each
one was believed to be right by somebody who had read the code.

**`--baseline` read the snapshot before it ignored it.** `migrations.generate`
called `read()` and branched on `opts.baseline` afterwards. The one command
whose entire purpose is to get a repository out of a snapshot it can no longer
parse was the one command that stopped on it.

**No caller passed a `Diagnostics`.** `read()` called
`snapshot.parse(gpa, text, null)`. `std.zon` formats a parse failure with the
line, the column and the offending text, and the whole of that was thrown away
before it reached anybody. What arrived was `error.ParseZon` and a stack trace.

**The instruction in the ADR and in the CHANGELOG was impossible to follow.**
"`db generate` rewrites it" is true of a repository at version 0 and false of
every other, because `generate` reads the snapshot before writing one. The way
out was supposed to be `--baseline`, and `--baseline` refuses to run under a
version 2 — correctly, for the reason ADR 0223 gives. So a repository at
version 7 that upgraded nilo had no command at all: the documented fix was
`rm migrations/snapshot.zon`, which is the shell script ADR 0223 set out to
retire.

**The test that should have caught this was one layer under the bug.**
`snapshot.zig` had `test "a snapshot in the older shape is refused with a
diagnostic"`, which called `parse` directly, passed it a `Diagnostics`, and was
green. It tested a function nobody reached that way. Everything between it and a
person — `read`, `generate`, `doGenerate` — passed `null`.

## Decision

**A snapshot in a shape an older nilo wrote is read, upgraded in memory and
diffed against.** `generate` against it is an ordinary diff rather than a
rewrite, and nothing on screen says anything except one line noting that the
file itself is still the old one until the next `generate` replaces it.

The mechanism is a mirror struct, read and never written:

```zig
const Older = struct {
    version: u32 = 0,
    dialect: []const u8,
    tables: []const Table = &.{},

    const Table = struct { … references: []const Reference = &.{} … };

    /// The whole of the difference: one column each side rather than a list.
    const Reference = struct {
        name: []const u8,
        column: []const u8,
        schema: ?[]const u8 = null,
        table: []const u8,
        target: []const u8,
        on_delete: table_mod.OnDelete = .no_action,
    };
};
```

`snapshot.parseWith` tries the current shape first and the older one second, and
says which it got through an `Origin` the caller may ignore:

```zig
pub const Origin = enum { current, upgraded };
```

`migrations.State` carries it, `db generate` and `db check` print one line when
it is `.upgraded`, and the next `generate` writes the current shape out. Nobody
has to do anything.

The two bugs under it are fixed where they were:

- `migrations.readWith` takes a `Read` with `snapshot: bool` and
  `diag: ?*std.zon.parse.Diagnostics`. `generate` passes
  `.{ .snapshot = !opts.baseline }`, so `--baseline` does not read the file it
  exists to replace.
- `sql/cli.zig` catches `error.ParseZon` in `doGenerate` and `doCheck`, reads
  the directory a second time with a `Diagnostics` of its own, and prints
  `std.zon`'s own sentence with the line and column under it. An error value
  carries nothing; the second read is what turns it back into a message.

**One mirror struct per shape that renamed a field.** They go at 1.0, with a
line in the CHANGELOG. The number of them is the number of renames this module
has made, which is one, and the bar for the next one is now visible: a rename
costs a struct that lives forever, and a new field with a default costs nothing.

## Alternatives rejected

**Refuse, and tell people to delete the snapshot.** This is what ADR 0222 wrote
down. It is what the port did. It cannot be right, because the snapshot is the
other half of every diff: deleting it at version 7 and running `generate` writes
a version 8 that creates every table the database already has. The only safe
deletion is `--baseline`, and `--baseline` is refused past version 1.

**Refuse, and add a `--force-baseline`.** A flag that says "renumber over the
versions a deployed database has already run" is the thing ADR 0223 refused on
its own terms, and it would be reached here by somebody whose only actual
problem is two field names.

**Version the snapshot file and branch on it.** The file already carries
`.version`, and that number is the *schema* version — how far the migrations
have got — not the format's. Adding a second one means a field somebody has to
remember to bump, and the failure mode of forgetting is exactly this bug again.
Trying both shapes needs no bookkeeping at all: the current shape either parses
or it does not.

**Write the upgrade back to disk as its own step.** Tempting, because then
`--baseline` under a version 2 becomes unnecessary. Refused because a command
that silently rewrites a committed file is a command whose diff nobody reads,
and the next `generate` rewrites it anyway with a step everybody already looks
at.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — nothing here is reachable from a request |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | **0 bytes, measured** |

`nilo-size-pg_only` at 1,800,600 bytes and `nilo-size-sqlite_only` at 2,305,584,
`cmp`-identical against `git archive HEAD`. `snapshot.zig` is reachable only
from the command line, and a server that applies migrations at boot links the
runner and not the generator.

**A parse that fails leaks one allocation when it is handed no
`Diagnostics`,** and that is std's rather than nilo's.
`std.zon.parse.fromSliceAlloc` owns the ast and the zoir either way; with `null`
it frees the two it can see and not what `fromZoirAlloc` made. Four lines of
std and no nilo reproduce it. `upgraded()` works around it by owning a local
`Diagnostics` nobody reads and deiniting it, with the reason written where the
variable is.

No refusals: every failure here is a file on disk rather than a program, so the
wording is held by tests calling `writeSnapshotRefusal` and `writeOlderSnapshot`
directly — two of them, both free functions rather than methods on `Tool`, for
the same reason ADR 0223's three are.

**The tests go through `generate`, not through `parse`.** That is the lesson
this ADR is really about, and it has a name now: *a test one layer under the bug
is a test that stays green while nobody can reach the behaviour.* The new ones
write a snapshot in the older shape into a temporary directory and call
`generate`, which is the path a person takes.
