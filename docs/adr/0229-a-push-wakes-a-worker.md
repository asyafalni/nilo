# 0229 — a push wakes a worker

**Status:** accepted
**Amends:** [ADR 0198](./0198-a-queue-is-a-table-in-the-database-you-already-have.md), the
worker loop: `poll_ms` is the fallback rather than the latency.

## Context

`Jobs.serveOn` was one `claim` per worker per `poll_ms`, then a sleep, and
nothing else moved it. The default was a second. That is the right cost for
an idle queue and the wrong latency for the ordinary case, which is a program
pushing a row and running it *in the same process* — every CLI, every server
whose handler queues a job for its own workers.

The first CLI on nilo felt it. fdm, a download manager, queues a download and
waits for the first byte; with the default it waited half a second on
average. It set `poll_ms = 100`, which is sixteen workers × ten
`UPDATE … RETURNING` a second against one SQLite file while there is nothing
to do, and still left 60 ms between it and `curl` on a 100 KB file — all of
it the poll. A program that never noticed `poll_ms` exists gets a queue that
feels broken, and a program that did notice pays for it in idle queries.

`std.Io` has the primitive: `futexWaitTimeout` and `futexWake`, implemented
by `std.Io.Threaded` and by zio alike, so a wake reaches a worker on either
without the Fitting naming an Engine
([ADR 0070](./0070-a-fitting-borrows-the-loop.md)).

## Decision

**A `push` wakes one worker, and `poll_ms` is what finds a row nobody
woke anybody for.**

A `Jobs` carries a counter, `wakes`. A worker reads it *before* it asks the
store, and when the store answers "nothing" it sleeps on the futex with the
value it read and `poll_ms` as the timeout. `push` bumps the counter after
the store has the row and wakes one waiter. The order is what makes the
wake lossless: a push that lands between the empty claim and the sleep has
already changed the word the worker is about to sleep on, so the wait
returns at once.

**One worker per push, not all of them.** A row is one unit of work; waking
sixteen workers for it is fifteen empty claims against the store. `wake()`,
the public one, wakes every worker — it is for a row nilo did not see
arrive: pushed by another process, or by `pushIn` under a transaction that
has since committed, where a wake before the commit would find nothing.

**A row due later does not wake anybody.** `push` with `.after_ms` or `.at`
in the future leaves the poll to find it; waking a worker for it is one
empty claim now and the same wait after.

`serveOn` with no `nilo_start` before it — the worker process with no server
— takes the `Io` it runs on as the one a wake goes through, so the shape
every CLI has works without a line.

## Alternatives rejected

**A single claimer handing rows to workers over a channel.** It would also
take fifteen writers off the SQLite lock. fdm did not measure that lock as
a cost, and the wake is one atomic and one syscall against a redesign of the
loop. If the lock ever shows up in a number, this is the next step and the
counter is not in its way.

**Idle backoff — double the sleep when a claim comes back empty, to a cap.**
With a wake in place the poll is already the fallback for another process,
and doubling it would make that process's rows slower to start on a quiet
queue for no saving the default does not already give. `poll_ms` stays one
number that means one thing.

**`std.Io.Event`.** A boolean with a `reset`, which is a race between two
workers: the second to wake finds it already reset, or resets it under the
first. A counter has no reset.

**Waking inside `pushIn`.** The row is not visible until the caller's
transaction commits, so the woken worker claims nothing and goes back to
sleep — and the real wake then never comes. Saying "call `wake` after
`commit`" is one line in the doc comment and true.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | 0 — the counter is 4 bytes on the `Jobs`, not on a connection |
| Throughput and p99 | one `fetchAdd` and one `futexWake` per `push` |
| Binary size | not measured separately; two functions of four lines |

What it saves is the whole of `poll_ms` off the latency of an in-process
push. The test is the number: two workers on a poll of a minute, a row
pushed from the test thread, and the row run within the 2 s bound — 60 s if
the wake were not there.
