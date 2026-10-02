# SQLite is compiled ReleaseFast whatever the program is

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 248](./248-gzip-is-libdeflate-when-a-build-asks-for-it.md) (C nilo compiles is `ReleaseFast`)
**Extends:** [ADR 064](./064-a-file-has-no-socket-to-wait-on.md) (zqlite and the amalgamation it bundles)
**Found by:** photon, a program that tests in Debug and `ReleaseSafe` and whose first `ReleaseSafe` build spent 48 seconds and a gigabyte compiling SQLite

## Context

ADR 064 took zqlite, which bundles the SQLite amalgamation, and passed it the program's optimize mode. zqlite's `build.zig` has one `optimize` for its Zig wrapper and for `lib/sqlite3.c` both, so the 9 MB of C was compiled once for every mode a program was built in, and in each mode's flags. Zig compiles C in Debug and `ReleaseSafe` under the undefined-behaviour sanitizer, and `ReleaseSafe` adds `-O2` on top of it, which is the slow combination: on a quiet Ryzen 7 9700X, `zig build-obj` of `sqlite3.c` alone takes 5.1 s and 746 MB in Debug, 34.3 s and 1,034 MB in `ReleaseSafe`, and 19.8 s and 704 MB in `ReleaseFast` ([`bench/result/build.md`](../../bench/result/build.md#what-sqlite-costs-a-cold-build)).

ADR 064 named this cost and left it: "a cold `zig build test-sql` spent about a minute of CPU inside `zig clang` on it". A program following nilo's own rule, both optimize modes, paid the `ReleaseSafe` compile on every cold cache, a CI runner's included, and a deploy built in `ReleaseSafe` paid it on its own.

## Decision

**The amalgamation is always compiled `ReleaseFast`, and zqlite's Zig in the program's mode.** `zqliteFor` in `build.zig` takes only zqlite's files: `src/zqlite.zig` becomes a module built in the mode asked for, `lib/sqlite3.h` is translated for it, and `lib/sqlite3.c` is a static library compiled `ReleaseFast` with zqlite's own `-std=c99`. One object then serves every mode: a build in Debug and one in `ReleaseSafe` on the same cache compile SQLite once, and the `ReleaseSafe` compile never runs. The published `nilo_sql`, its test roots in both modes and the benchmark copy all take it from `zqliteFor`.

**zqlite is not asked for `ReleaseFast` instead**, which would have been one word: its one option would take the bounds checks out of the wrapper in a `ReleaseSafe` program as well, and the wrapper is Zig that indexes slices the caller handed it.

**What the sanitizer would have caught is not on this side of the seam.** It traps undefined behaviour inside SQLite's C, which SQLite's own test suite exists for; a mistake in nilo's calls is in Zig, which keeps its checks in the mode it was built in. ADR 248 made the same choice for libdeflate for a different reason, that C at `-O0` is not the library that was measured, and it holds here too: the SQLite a Debug test ran was not the one a deploy runs.

## What it costs

Measured on the same machine at `0635e31` against the working tree, `zig build example-sqlite` with a cold local cache, two interleaved runs a side:

| | before | after |
|---|---|---|
| Debug, cold | 8.8 to 9.1 s | 22.1 to 23.5 s |
| `ReleaseSafe` after that Debug build, same cache | 69.8 to 71.5 s | 31.2 to 35.2 s |
| both, in that order | 79 to 80 s | 53 to 59 s |
| `ReleaseSafe` alone, cold | 71.9 to 72.6 s | 57.2 to 57.4 s |
| peak RSS of the `ReleaseSafe` build | 1,045 to 1,096 MB | 864 to 934 MB |

**A cold Debug build is 14 seconds slower**, once per cache, and that is the price. It buys back 15 seconds on a cold `ReleaseSafe` build, 25 on a cold build in both modes, and the gigabyte. It was taken because the build that runs cold most often is a CI runner's or a container's, which builds `ReleaseSafe` or both, and a developer's Debug cache stays warm for the life of the checkout.

On ADR 017's axes: **allocations per request, memory per idle connection: unchanged**, nothing on the request path moves. **Throughput**: a Debug or `ReleaseSafe` program now runs SQLite's C at `-O2` with no sanitizer, which is faster and not measured, because no number on the record was taken in either mode. **Binary size**: a `ReleaseFast` program links the same object it did; a Debug program's SQLite object is 7.8 MB where it was 18.6 MB.

## What was rejected

- **Keeping the program's mode** (ADR 064 as it stood): the 34-second `ReleaseSafe` compile for every program that tests the way nilo asks.
- **Debug stays Debug, only `ReleaseSafe` becomes `ReleaseFast`.** It keeps the 9-second cold Debug build, and pays two compiles on a cache that sees both modes, 5 s and 20 s, where one 20-second compile serves both. It also keeps an `-O0` SQLite under every Debug test, which is the "not the library that runs" problem ADR 248 named.
- **Asking zqlite for `ReleaseFast`**: the wrapper loses its checks, above.
- **Linking the system SQLite** (`system_sqlite3`): rejected in ADR 064, for the install story, and unchanged.

## Consequences

- `build.zig` gains `zqliteFor`; the three `lazyDependency("zqlite", …)` call sites become one. zqlite's own module and library are still declared by its `build.zig` and never built.
- A bump of the zqlite pin has to keep `src/zqlite.zig`, `lib/sqlite3.c`, `lib/sqlite3.h` and the `-std=c99` flag where they are, because `zqliteFor` names them; a pin that moves them fails to configure, which is loud.
