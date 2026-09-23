# 0290 — A job says how urgent it is, and the claim takes the most urgent due row

## Status

Accepted.

## Context

`job.Table`'s claim ordered by `run_at` and nothing else, so a queue was
strictly first-come. The roadmap held the open question and said what would
settle it: *a queue where the emails wait behind the reports*.

Here is one. An engine queues two things through the same `Jobs`: a model
backfill that runs for minutes, and a cache revalidation a person is waiting
on, pushed while a dashboard shows them a stale answer. Two workers. The
backfill is pushed first, so it is due first, so it is claimed first — and
every revalidation behind it waits for the backfill, not because the machine
is busy but because the backfill is *in front*.

Raising the worker count does not fix it; it buys one more backfill's worth
of room and moves the queue. Splitting into two `Jobs` over two tables fixes
it and costs a second table, a second set of workers sized by guess, and a
second thing to watch.

## Decision

A kind says how urgent it is, beside its `timeout_ms`, and the claim takes
the most urgent due row:

```zig
pub const priority: job.Priority = .high;
```

`Priority` is `.high`, `.normal` (the default, and what every existing kind
gets) and `.low`. Both stores order the same way: urgency first, and among
equals the row that has been due longest, so a kind that says nothing keeps
exactly the order it had.

Three things follow from choosing the shape this way:

**It belongs to the kind, not the call site.** How urgent a revalidation is
is a fact about revalidations. A per-push override would make the same kind
mean different things in different places, which is the sort of thing that is
true for a week and then nobody knows.

**Three levels, not a number.** `2` says nothing about whether it beats `1`,
and the answer differs between queues. A kind that writes a number is a
compile error naming the three levels.

**`high` is 0.** The numbers run backwards on purpose so the claim can
`ORDER BY priority, run_at`, both ascending. Nobody writes the number.

**The index stays `(state, run_at)`.** Widening it to
`(state, priority, run_at)` was the obvious move and it is the wrong one:
`run_at <= $1` is then no longer a range bound, only a filter inside each
priority, so the claim walks every *future-dated* queued row — the scheduled
next ticks, the `after_ms` pushes, the backoff retries — before it reaches a
due one. Measured on 200 000 future rows with one row due: 988 buffers and
7.9 ms against 7 buffers and 0.065 ms. It does not even pay in the regime it
was meant for: with 50 000 rows actually due, the wide index takes 20.2 ms
and the narrow one 12.4 ms, because the narrow one finds the due set first
and top-N sorts it. The numbers are in `bench/result/job.md`.

The column is the integer behind the enum rather than the enum, which cost a
test to learn: an enum column is stored as its *name*, and `ORDER BY` on text
puts 'high' before 'low' before 'normal' — not the order asked for, and not
an order at all. A state has no order and is stored as a word; a priority is
only an order.

## What this costs

| axis | cost |
|---|---|
| Throughput and p99 | one more term in the claim's `ORDER BY`, over a due set the `(state, run_at)` index finds first and a top-N heapsort orders. Not measurable against the round trip the claim already is |
| Allocations per request | none. A job is not a request, and the priority is a comptime constant read at push |
| Memory per idle connection | unchanged |
| Binary size | an enum and one field |

**And a migration, which is the real cost.** `nilo_jobs` gains
`priority smallint NOT NULL`. `job.Table` creates nothing, so a caller adds
the column beside their own rows. A queue that has not is not subtly wrong:
the claim names the column, so it fails loudly on the first claim.

## Rejected

**A per-push option** (`.{ .priority = .high }`). More general, and the
generality is the problem: the same kind claiming different urgency in
different places is a thing that is true once and then drifts. Nothing stops
this being added later on top of the per-kind default if a caller turns up
who needs it; the reverse is not true.

**A number.** See above.

**A second queue for the urgent kinds.** It works, and it is what a caller
does today. It costs a table, a worker count sized by guess, and a second
queue to watch — for something that is one column and one `ORDER BY` term.

**Leaving it out.** The roadmap's own position until now, and the right one
until a case turned up. It has.

## Consequences

A kind that says nothing is `.normal` and behaves exactly as before. A caller
migrating adds one column. The claim is one term longer.

Not addressed here, and still open on the roadmap: whether a job may say how
many of it run at once. That is a different question — a ceiling on
concurrency rather than an order — and it wants its own case.
