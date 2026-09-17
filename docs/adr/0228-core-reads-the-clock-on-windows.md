# 0228 — Core reads the clock on Windows

**Status:** accepted
**Amends:** [ADR 0045](./0045-core-knows-what-time-it-is.md), §"What it
costs", the bullet that guards `std.posix` on Windows.

## Context

ADR 0045 put the wall clock in Core on the argument that reading it needs no
event loop: `clock_gettime` is a read from a page the kernel keeps mapped. It
then refused Windows with a `@compileError`, on the reasoning that Windows is
not a platform the Engine supports either, so nothing would ever get as far as
calling it.

Something did. A program on the Fitting and Service layers alone — `nilo_fetch`
for the wire, `nilo_sql` for the file, `nilo_job` for the queue, no `nilo_http`
anywhere — has no Engine to be unsupported by, and `std.Io.Threaded` runs on
Windows. Cross-compiling one for `x86_64-windows` failed on exactly two lines
in the whole dependency graph: the two guards. Everything else in the four
modules compiled as it stood.

## Decision

**`nowMicros` and `monotonicMicros` read the clock on Windows** the way
`std.Io.Threaded` does: `RtlGetSystemTimePrecise` for the wall clock, in 100 ns
units from 1601, and `RtlQueryPerformanceCounter` over
`RtlQueryPerformanceFrequency` for the monotonic one. Both are reads from
`KUSER_SHARED_DATA`, the page the kernel maps into every process — the same
argument ADR 0045 makes for the vDSO, and the reason this stays in Core rather
than moving up a layer.

The two guards go. Nothing else in ADR 0045 changes: still free functions, still
no arithmetic, still no duration on the wall clock.

## Alternatives rejected

- **Leave the guard and tell the program to bring its own clock.** The two
  calls are made by `nilo_job`, `nilo_id.v7` and `sql.Timestamp.now`, none of
  which the program calls directly. It would have to fork three modules to
  supply ten lines.
- **Take an `Io` and call `Io.Clock.now`.** That is the design ADR 0045
  rejected, for a reason that has not changed: a Scope owns nothing about the
  time, and threading an `Io` through `id.v7` to read a page is the wrong cost
  for the right answer.

## What it costs

Ten lines and one `@import("std").os.windows` in `core/clock.zig`. The Engine
still does not run on Windows, and this ADR does not say it should; it says the
layers under it do, because they already did.
