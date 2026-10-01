# A release is measured against the one before it, in instructions and not in requests a second

**Status:** accepted
**Topic:** [principles](../design/principles.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) (every module, not only the server)

## Context

Every number on ADR 017's four axes was taken by hand, for a decision, and written into `bench/result/`. Nothing took the same numbers again for a release, so a regression that no decision went looking for was found when somebody happened to measure, or not at all. The question was how to track all four, for every module, cheaply enough that it happens every time.

The obvious answer is a CI job that runs the load generator on each tag and keeps the req/s. It measures the runner. A GitHub runner is a shared vCPU whose model changes between runs; `docs/history.md` has three runs spreading 1.8x at load average 5 on two cores, and ADR 017's tolerance for throughput is 10%. Keeping a number per tag and comparing the next tag's against it is also the thing `bench/README.md` refuses by name: build the before, never quote it.

What a shared runner *can* read exactly is anything that does not depend on time. Measured while this was designed, on the server and on each module's program below:

- **Instructions**, counted by cachegrind: two runs of the server serving 5,000 requests differed by 2,264 instructions in 67.7M (0.003%), and every module's program gave identical counts on every run, `s3` only once its clock was held still (Consequences).
- **Allocations**, counted by an allocator: exact by construction.
- **Bytes an idle connection**: RSS, page-granular, and agreeing to within 66 bytes a rebase apart (`bench/result/http.md`).
- **Stripped binary bytes**: exact for one compiler and one set of flags.

## Decision

**Each release is measured against the one before it, both built and measured in the same job, on every module, on what a shared runner can read exactly.** `bench/release.py` does it; `.github/workflows/release-numbers.yml` runs it.

**When:** a published release measures its tag against the tag before it and attaches the numbers to the release page. A manual run measures any ref against any other, which is how a release is read before it is tagged ([`releasing.md`](../releasing.md)) and how an old tag is backfilled. Nothing runs on a push to `main`.

**It is a report, not a gate.** It fails only when it cannot measure. A change is called one when the two refs' ranges over the interleaved rounds do not overlap, and the person cutting the release decides what it means.

**What is measured, for each module:**

| axis | how | for ADR 017's |
|---|---|---|
| instructions an operation | cachegrind on one CPU at two counts; the difference over the difference is one operation, with start, setup and stop taken out | throughput |
| allocations and bytes an operation | an allocator counting an arena reset after every operation, again at two counts | allocations per request |
| bytes an idle connection | `http` only: the marginal RSS at 2,000 keep-alive connections, `bench/result/http.md`'s method | memory per idle connection |
| stripped binary bytes | `ReleaseFast`, `-Dstrip=true` | binary size |

**`http`'s operation is the server answering `GET /users/7`**, the primary metric, measured from outside the process, so it includes the Engine and the parser and is comparable at any tag that has `bench/main.zig` (v0.2.0 on). Its allocations stay with `test "the request path stays inside its allocation budget"`, which is exact on every push already. **Every other module's operation is one program in `bench/release/`**, a module's everyday call (a row found by key, a token verified, a GET through the pool), each saying in its header why that call.

**The harness is today's and the modules are the ref's.** `release.py` exports each ref with `git archive`, copies `bench/release/` from its own checkout into the tree, and builds it against that tree's modules by path. So a tag from before the harness existed is measured by the harness of now. A program the ref cannot compile, or a module the ref does not export, is "n/a" for that ref with the compiler's first error, and the programs pick between API forms with `@hasField` where a call moved, so a rename does not lose the history.

**The build is pinned**, `-Dcpu=x86_64_v3` and `-Dtarget=x86_64-linux-gnu`, so an instruction count does not follow whichever CPU the runner was given. The server still links glibc, whose string functions are chosen by CPU at load, so **a figure is comparable with the figures of its own run, and the change between two refs is the record**, not either absolute.

## What it costs

Nothing a user builds: `bench/release/` is its own package that nilo's `build.zig` never names, and the workflow runs only on a release or by hand. One run of two refs is two cold builds, nilo's with `-Dsql` among them, and about a hundred cachegrind runs; [`releases.md`](../../bench/result/releases.md) records how long one took.

## What was rejected

**Requests a second on the runner, kept per tag.** Its spread is larger than the 10% it would be checking, and keeping a number from another day is quoting the before. Requests a second are still measured on a box, by hand, for a decision, and written into `bench/result/`.

**On every push to `main`.** The deterministic axes are cheap enough, and a red mark on `main` for a change that is not wrong yet, or is the trade a feature meant to make, is noise people learn to ignore. A release is where the four axes are read as a whole, and a manual run covers a change somebody suspects.

**A gate with thresholds.** ADR 017's 10% is about requests a second, and an instruction count is a proxy for them that does not see a cache miss or a lock. A threshold on the proxy would be a number with no run behind it.

**`perf stat -e instructions`.** It needs the hardware counters, and a GitHub runner is a virtual machine that does not expose them.

**The harness inside each ref, built by its own `build.zig`.** A tag from before it has none, so the first release after it would be compared with nothing and no history could be backfilled.

**Postgres for `nilo_sql`.** It needs a service and puts a socket and another process into the count. SQLite with `.in_fiber` measures the module and the driver on the thread that asked.

## Consequences

- **cachegrind sees work, not time.** A cache miss, a lock held across threads, a syscall's kernel side and a scheduler decision are invisible, and threads are serialised. A regression of that kind is still found on a box.
- **A program may use only the API every measured ref shares**, or pick between forms while compiling. When a module's API breaks, its older refs read "n/a" with the compile error, which is itself the record of the break.
- **A module that prints the wall clock is measured for every ref inside one minute, from second 10.** `s3`'s `x-amz-date` costs ~190 instructions a request more for each field under ten, so the same binary read 0.35% higher in seconds :00 to :09; `CLOCKED` in `release.py` names the modules this applies to, and a new one that formats a time belongs there.
- **`fetch` and `s3` carry their upstream in the process**, on a thread, as `bench/fetch_server.zig` does. It is the same code at every ref, so its instructions cancel in the difference.
- **A release page carries its numbers**, as JSON and as the table, and [`releases.md`](../../bench/result/releases.md) keeps one table per release in the repository.
