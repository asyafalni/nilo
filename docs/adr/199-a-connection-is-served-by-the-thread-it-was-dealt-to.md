# A connection is served by the thread it was dealt to

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md).
**Found by:** [HttpArena](https://github.com/MDA2AV/HttpArena)'s
`latency-10k` profile — 1,024 connections, 10,000 req/s over sixty-four
threads, which is a server that is nearly idle — reporting nilo at 40 µs of
CPU a request where tokio spends 21, and the same server at 18 µs a request
on eight CPUs near saturation. The per-request work had not changed between
the two; what had was how often a thread went to sleep.

## Context

zio's scheduler steals work between executors, the way tokio's and Go's
do: an executor with nothing in its own ring takes half of a neighbour's.
Stealing a fiber moves where it *runs*, not where its I/O lives — a
socket's completions land on the ring of the executor that submitted them,
which is the one that accepted the connection — so a stolen task is one
that will be handed back next time it waits. To keep that churn down zio
**dozes** before it parks: an executor that has just run work and finds
nothing more does one non-blocking poll, then a park capped at 100 µs with
stealing switched off, then the real park. That grace window is a
`io_uring_enter` with a 100 µs timeout, and on a thread that is going to
sleep anyway it is a second context switch — the timeout fires, the thread
wakes to find nothing, and parks again.

On a busy server nothing dozes, because nothing is ever empty. On a server
that is not busy every request is followed by one. `bench/paced.py`
measures exactly that: a fixed offered rate over keep-alive connections,
and the server's CPU from `/proc/<pid>/stat` over the window.

| threads | migration | 500 req/s | 2,000 req/s | 8,000 req/s |
|---:|---|---:|---:|---:|
| 2 | on (zio's default) | **100 µs/req**, 2.02 switches/req | 64 µs, 1.23 | 44 µs, 0.62 |
| 2 | off | **70 µs/req**, 1.02 switches/req | 55 µs, 0.87 | 34 µs, 0.39 |
| 1 | on | 70 µs, 1.02 | 42 µs, 0.51 | 25 µs, 0.13 |
| 1 | off | 67 µs, 1.02 | 42 µs, 0.51 | 25 µs, 0.15 |

Two voluntary context switches a request against one, and 30% of the CPU
with it. The single-executor rows are the control: with nobody to steal
from zio skips the doze, and the two migration columns read the same. The
arena's shape is sixty-four threads at 156 req/s each, which is the
`500 req/s` column with the batching taken away — no executor ever sees a
second request before it has gone to sleep.

At saturation the other way round is what would have to be paid, and it
is not paid: `wrk -t1 -c64` on the two-core box, four interleaved pairs,
migration off reads **+2.5%, +4.0%, +0.8%, +4.1%** — all four the same
sign, so a small real gain rather than noise, from the parks and the
`seq_cst` traffic on `idle_mask` that a busy executor no longer does.

## Decision

**`enable_task_migration = false` on the Runtime.** A connection is
served, start to finish, by the executor that was dealt it: `spawn`
already deals new connections round-robin (`getNextExecutor`), so the
load is spread the same way it was; what stops is a fiber changing threads
between two waits.

It is not an `Options` field. ADR 001 says the Engine is not the user's
business, and a scheduler's stealing policy is the Engine's; a caller who
wants it back changes one line here and re-runs the two tables above.

**What a caller can now rely on that was not promised before:** a handler
runs on one OS thread from its first line to its last, across every
`sleep`, `fetch` and query in it. `threadlocal` state read before a wait is
the same after it. That was already true of everything nilo keeps per
thread — the `Date` cache, the scratch pool — and is now true of what a
handler keeps too. It is not a licence to drop `nilo.Mutex` (ADR 010):
two handlers on two threads still run at the same time.

## What it costs

Nothing on the four axes of ADR 017 — no allocation, no per-connection
byte, no binary — and a saving on the one this ADR is about, which is a
fifth axis the budget has not had a column for: **CPU per request at a
load below saturation.** The arena scores it at half the weight of two of
its three efficiency profiles, and it is the number a service running at
5% of its capacity pays for the other 95% of the day.

What it gives up is the case stealing exists for: a burst of completions
on one executor — several connections on the same thread all becoming
ready at once — is now drained by that executor alone, while its
neighbours sleep. For an HTTP server whose connections are dealt evenly
that is a queue of a few requests on one thread, each of which is a
handful of microseconds, and the saturation pairs above say it does not
show at 64 connections on two threads. It would show for a handler that
holds its thread for milliseconds — but that handler stalls its
neighbours either way, since their completions sit on its ring until it
polls again, and stealing never moved a task whose wake had not yet been
processed. `block_warning_ms` is the tool for that handler, not the
scheduler.

## Alternatives

**Leave it on and ask zio to shorten or skip the doze.** The right long
answer, and the table above is what an upstream issue would carry. A
doze that only happens after an executor has run more than one task in
its tick would keep the churn protection for the busy case and skip the
sleep for the idle one. Until then, nilo's numbers are nilo's.

**Spin before parking, the way Go's `findrunnable` does.** Burns the CPU
this is trying to save, to shave a wake that a server at 5% load does not
need shaved.

**Turn migration off at compile time (`zio_options.task_migration`).**
Removes the atomic on `parent_context_ptr` and the migration bookkeeping
from every task switch, which is a second saving worth measuring. Not
taken here because it is a build option that reaches every dependent's
build graph, and the runtime flag is the whole of the CPU finding.

**Expose it on `Options`.** A knob nobody can set from the documentation,
because the answer is the table and the table says off.

## Consequences

- `http/engine/zio.zig`: `.enable_task_migration = false` in
  `Runtime.init`, with the numbers in the comment.
- `bench/paced.py` is the instrument, beside `mem.py` and `burst.py`.
- [`http.md`](../../bench/result/http.md#what-a-request-costs-when-the-server-is-not-busy)
  carries the runs, and a second finding from the same instrument that is
  *not* acted on: a connection quiet for longer than `idle_peek_ms`
  (200 ms) pays ~57 µs on its next request for the pages ADR 062 gave
  back. That is the trade ADR 062 made on purpose, and the number is now
  written down beside it.
- The [Deploying](../guide/deploying.md#tuning) note on `threads` gains the
  sentence about a handler staying on one thread.
- HttpArena's next run is the reading this box cannot take: `latency-10k`
  and `latency-1m`, with 4,096 in the backlog as well (ADR 198). The
  prediction is 25–30 µs a request on the first, from 40.
