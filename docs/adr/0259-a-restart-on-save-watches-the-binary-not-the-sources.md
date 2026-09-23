# 0259 — a restart on save watches the binary, not the sources

**Status:** accepted
**Extends:** [ADR 0125](./0125-a-file-is-described-by-the-descriptor-being-sent.md),
whose `staticWith(.{ .reload = true })` was the half of "reload without a
restart" that could live inside `App`; this is the other half, and it
lives in the build.
**Applies:** [ADR 0098](./0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md),
[ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0170](./0170-a-test-does-not-need-the-optimiser.md).

## Context

A file that changes under a running server is served fresh since ADR 0125,
and a `.zig` file that changes still needs the person to stop the server,
rebuild and start it again. The roadmap held the entry at *ready* with one
sentence of design — jetzig sums the mtimes of its source tree and rebuilds
when the sum moves, "about as much machinery as this deserves" — and one
constraint: none of it may end up in a release binary.

The question that reshaped it was asked before a line was written: **does
this eat the disk?** Zig's cache evicts nothing
([ziglang/zig#15358](https://github.com/ziglang/zig/issues/15358), closed to
[Codeberg #30193](https://codeberg.org/ziglang/zig/issues/30193) with no
eviction in 0.16.0's release notes), and a watcher that ran `zig build` on
every save would be a leak with a good excuse. So the loop was measured
before it was designed, five ways, on this machine — the table is in
[`bench/result/build.md`](../../bench/result/build.md#what-a-restart-on-save-costs-per-save)
— and two of the five rows moved the decision.

## Decision

**`nilo-dev` runs one `zig build <step> --watch` and leaves it running,
starts the server whenever the binary that build writes changes, and
watches nothing else.** It spawns two processes and reads the size and
mtime of one file every 250 ms. It imports `std` and nothing of nilo's,
ships as `nilo.artifact("nilo-dev")`, and no server links it — which is
the release-binary constraint met by construction rather than by a flag.

```zig
const dev = b.addRunArtifact(nilo.artifact("nilo-dev"));
dev.addArgs(&.{ "--zig", b.graph.zig_exe, b.getInstallPath(.bin, exe.out_filename) });
if (b.args) |args| dev.addArgs(args);
b.step("dev", "Rebuild and restart on every save").dependOn(&dev.step);
```

**The build system watches the sources, because it already does.** A
watcher of nilo's own would be a second reading of which files matter, kept
in step with `build.zig` by hand; `zig build --watch` reads the same graph
the build does. Watching the *output* instead of the inputs is also what
makes a failed build free: the watch prints the errors, the binary on disk
is the last one that compiled, and the server running is the one serving
it. There is no code for that case.

**And it reacts only to the files the build read, which is what makes it the back end's loop and not the repository's.** The watch marks the directories holding a step's inputs and answers to those names alone, so a front end kept beside the server is outside it: under `zig build dev-spa`, a save to `public/app.js` moved nothing in the fifteen seconds it was watched, and a save to `main.zig` had the new server listening one to two seconds later. A file the binary `@embedFile`s is inside the line, because saving it changes the binary; `build.zig`, and a `.zig` file nothing imports yet, are outside it. `bench/devloop.py` runs that probe against any dev step, so the line is a check rather than a paragraph ([`build.md`](../../bench/result/build.md#what-a-save-has-to-touch)).

**The old server is asked to stop, in a process group of its own.** SIGTERM
is what nilo drains on (ADR 0098), and SIGKILL comes only after five
seconds. Each child gets a process group of its own so a Ctrl-C at the
terminal reaches `nilo-dev` alone: nilo reads a *second* signal as "stop
waiting" and exits without the drain, and the terminal's group would have
delivered one before the runner's TERM arrived. The build's group is also
what makes the compilers it keeps under it one `kill` on the way out — a
`zig build --watch` sent SIGTERM on its own leaves them running, which was
found the first time it was tried.

**A change is acted on once it has been seen twice.** Two polls with the
same stamp, 250 ms apart, before a restart, so a binary still being copied
is not started half way through.

**The first server is the current one, or none.** Before the watch starts, `nilo-dev` runs the same `zig build <step>` once to the end, without `--watch` and with `-fincremental` and every `-D` option it was given. The binary on disk is whatever the last run left, and nothing but a build can say whether it still describes the sources. Started on the first two polls, as this loop first did, it was served before the watch had rebuilt it: an application whose schema changed with the loop stopped had its SQLite file created and seeded by the old binary, one index the edit had removed included, and `listening` printed twice. A server is not a pure function of its binary, so serving a stale one for a moment is not free. When the first build compiles, the watch's first pass is a cache hit that writes nothing, so there is no restart after the start.

**When that first build fails, the stale binary is removed.** Remembering its stamp as already served does not work, and was tried: a fix that puts the sources back to the ones the old binary was built from compiles, the install step finds the file on disk already right and does not write it, the stamp never moves, and the loop waits for ever beside a build that succeeded. Removed, the first build that compiles writes it, whatever it compiles to. A Ctrl-C during that build stops it the way the loop stops the watch.

**After every restart the stale builds are deleted.** One save leaves
exactly one new file in the cache — `.zig-cache/o/<hash>/<exe>`, the whole
Debug binary, 27 MB for `examples/hello` and the size of the program for
anything else — and Zig never removes it. So once the new server is up
the runner walks `o/`, keeps the one directory whose copy of the binary is
byte for byte the one it just started, and deletes every other directory
holding a file of that name. Four saves that alternated an edit and its
undo left the cache 0.0 MB larger, with one directory in it at every step.

Deleting is safe because the directory's name is a hash of the build's
content: an undo back to the previous version does not hit a manifest
whose output is gone, it rebuilds into the same directory — which was
tried before it was relied on, by deleting a build's directory, reverting
the source to it, and building. It runs after a restart and not at the
first start, because at a restart the build has just finished writing and
is idle, and at the first start it is running. It does not run under
`--incremental`, where the one directory is patched in place and nothing
is stale. `--keep-cache` turns it off.

**`--incremental` is opt-in, and on Zig 0.16.0 it wants LLVM.** This is the
row of the table that was most surprising, and the reason the flag is not
the default:

| the same edit to `examples/hello`, 2 cores | rebuild | `.zig-cache` per save | binary |
|---|---|---|---|
| `zig build` per save, self-hosted | 2.8 s | +23 MB | runs |
| `--watch`, self-hosted | 3.6 s | +23 MB | runs |
| `--watch -fincremental`, self-hosted, new ELF linker | 0.12 s | 0 | **does not run** |
| `--watch -fincremental`, self-hosted, old ELF linker | never finishes | 0 | not written |
| `--watch -fincremental`, LLVM + LLD | 7.4–9.4 s | 0 | runs |

The 0.12 s row is the one everybody wants, and its binary dies at exec with
`undefined symbol: main`: the new ELF linker's incremental output does not
run when libc is linked, and every nilo server links libc through zio. A
five-line program reproduces it — `zig build-exe main.zig -lc -fincremental`
— and the old linker, tried next, spins at 100% CPU for minutes on the first
update. The LLVM backend's incremental mode works, keeps the cache flat, and
costs an LLVM emit per save; the release notes say as much about what
incremental does and does not skip under LLVM. So the flag exists, keeps
the cache at zero growth, and asks for `exe.use_llvm = true` beside it —
`-Dllvm` for nilo's own examples. A server that dies within a second of
starting under `--incremental` gets a message naming that fix.

**The default is the 23 MB row with the 23 MB deleted afterwards**,
because it is the one that works with nothing else set, on the backend the
loop already runs on (ADR 0170), and pruning brings its cache cost to what
the incremental row's is. What the flag still buys is the compile time on
a machine with the cores for LLVM; on this one it does not.

## What it costs

Against ADR 0018's axes: nothing. Not one byte of `nilo_http` changes;
`nilo-dev` is an executable nobody imports. What it costs the machine:

- **Per save, default:** one compile of the changed module, 2.8–3.6 s here,
  27 MB written to `.zig-cache` and the previous 27 MB deleted after the
  restart — a read of the new binary to compare it, and one `rm -rf`.
- **Per save, `--incremental`:** an LLVM emit, 4.8 s to a served response
  here, and 0 MB.
- **Resident:** the build runner and, under `--incremental`, one compiler
  kept alive per artifact the step builds — 180 MB for the self-hosted
  backend, 406 MB for LLVM, measured as RSS. `zig build examples` under
  the flag would keep nine, which is why the dev steps build one example
  each.
- **The runner itself:** one `stat` every 250 ms.

## Alternatives

**A watcher of nilo's own, summing mtimes, running `zig build` per change.**
The roadmap's sketch, and the first design. Rejected on the first row of
the table: it is the 23 MB row with a second copy of the file list.

**`zig build run --watch`, with the server as the Run step.** The watch
waits for every step to finish before it listens again, and a server never
finishes.

**`-fincremental` as the default.** Rejected by the third row: a default
that produces a binary that does not run is worse than one that is slow.
The roadmap keeps the row under `nilo_http`'s known gaps, waiting on
upstream, because it is the number this loop wants to be.

**Watching the sources as well as the binary**, so the restart could be
announced before the build finished. Nothing to announce: the server keeps
serving until there is a new one.
That is true of every save after the first, and was not of the first start, which is why the loop now builds before it serves rather than watching more.

**`dev.step.dependOn(&install.step)` in `build.zig`**, so the outer `zig build dev` builds before `nilo-dev` runs at all. Every dependent's four lines would change, one that never re-reads the guide keeps the stale start through every release, and a tree that does not compile fails `zig build dev` before the loop exists rather than waiting for the save that fixes it.

**Logging that the first server may be stale**, and starting it anyway. The database is seeded by the old schema all the same.

**Waiting for a binary newer than the moment the loop started.** A build with nothing to do does not rewrite `zig-out`, so an up-to-date tree would never start.

**A cache directory of the loop's own**, `--cache-dir .zig-cache/dev`,
pruned whole on exit. Race-free by construction, and a second copy of
everything the shared cache already holds — a cold build per machine, and
hundreds of megabytes standing where the per-save leak was 27. Pruning by
name in the shared cache touches only directories holding a copy of the
one binary this loop serves, and a concurrent build of that same binary is
the one thing nobody runs beside its dev loop.

## Consequences

- `dev/main.zig`: `nilo-dev`, with `--zig`, `--build`, `--incremental`,
  `--keep-cache`, `--trace`, `-D…` pass-through, and `-- <server args>`;
  `dev` in `build.zig.zon`'s `.paths` and in `shipped_roots`.
- `zig build dev-<example>` for each example, `zig build example-<name>` to
  build one, `-Dllvm` for the examples, `zig build test-dev` on `test`.
- The guide's getting-started page gains the three lines; the roadmap loses
  "Reloading the server without a restart" and gains the upstream gap.
- [`bench/result/build.md`](../../bench/result/build.md) carries the table
  and the machine.
- `bench/devloop.py`: a save the build never reads must leave the server up, and a save it reads must restart it; the guide's [What a save has to touch](../guide/getting-started.md#what-a-save-has-to-touch) is the same line for a reader.
- The first build before the watch: `bench/devloop.py` makes `--inside` stale with the loop stopped and fails on a restart after the first start. Before, the server started and then restarted into the new binary; after, it started once and stayed up for the six seconds watched. A failed first build deletes the binary at the path the loop was given, which is a build output the loop owns while it runs.
