# 0246 — a tick knows which one it is, and a test says when it is

**Status:** accepted
**Amends:** [ADR 0198](./0198-a-queue-is-a-table-in-the-database-you-already-have.md),
what a `run` may take and what `drain` reads the clock from.

## Context

Two entries on the roadmap were about the same thing from two sides: what
a tick is allowed to know.

**A `run` did not know which tick it was.** The store hands the worker a
`Claimed` — the row's `id`, its `attempts`, its `run_at` — and `run` saw
none of it. "On the last attempt, use the fallback provider", a log line
that names the row, and a progress figure a route can poll all need one
of those three, and the first two are what every retrying job wants
eventually. The `status` Space already existed, keyed by the id, and
nothing inside a `run` could name the id to write into it.

**A test could not move the clock.** `drain` ran what was due *now*, and
`core.nowMicros()` was read straight in `push`, `claim` and `execute`. So a
test could assert that a row pushed with `after_ms = 60_000` did not run,
and nothing more: not that it ran after a minute, not that an exponential
backoff's third attempt waited the doubled time, not that `job.cron("0 3 *
* *")` fired at three. The module's own tests got by on `.fixed_ms = 0`
and a real two-millisecond sleep against `every(1)`.

## Decision

### The tick

**`job.Tick` is a value a `run` may ask for beside its deps:**

```zig
pub fn run(self: Export, scope: *nilo.Run, tick: job.Tick, db: *Db, jobs: *Jobs) !void {
    const provider = if (tick.last) fallback else primary;
    …
    jobs.progress(tick.id, rows_done);
}
```

Four fields — `id`, `attempts`, `run_at`, and `last`, which is `attempts
== retry.times + 1` — all of them in the worker's hand from the claim, so
asking costs nothing. `checkRun` recognises the parameter by its type, the
way `http/typed.zig` reads a handler's argument list: after the job and
the Run, **a pointer is a service and a value is the tick**. A `*job.Tick`
is refused naming the rule, because left to the deps lookup it would be
told `.deps` has no `*job.Tick`, which is true and points the wrong way.

`last` is about the count and says so on the field: a failure in `final`
is dead on any attempt (ADR 0218), and the tick does not know which error
is coming.

**Progress goes into the `status` Space that already holds the state.**
`job.Status` gains `progress: u32`, `jobs.progress(id, n)` writes it
beside the `state` and `attempts` already there, and a route polling
`jobs.status(id)` reads it. The number means what the kind says it means
— rows, a percentage, a step — and it is reset by every change of state
except `done`, which keeps the last figure the run gave, so "done, 4,000
rows" survives the finish. A queue with no Space does nothing, as
`status` does.

### The clock

**`drainAt(&run, now)` and `runOneAt(&run, now)`**, with `drain` and
`runOne` as the same calls at `core.nowMicros()`. Inside a tick every read
of the clock reads that one number: whether a row is due, whether a
schedule's tick is later than its own successor, when a failed run is
tried again, when the next tick is. A test moves time by calling `drainAt`
with a later number and sleeps nothing:

```zig
const t = core.nowMicros();
_ = try jobs.push(&run, Nudge{ .user = 7 }, .{ .after_ms = 60_000 });
try testing.expectEqual(0, try jobs.drainAt(&run, t));
try testing.expectEqual(1, try jobs.drainAt(&run, t + 61 * std.time.us_per_s));
```

`seed(&run)` and `seedAt(&run, now)` are the seeding `serve` does at start,
made callable, because a test of a schedule has to put the first tick in
the table before it can move the clock to it.

The mechanism is a private `Clock` — `.wall` under a worker, `.fixed`
under `drainAt` — passed down `execute`. The worker reads the wall clock
*again* after a run for the next tick, which is what `.skip` promises: the
next tick counts from when this one ended. Under `drainAt` the same read
answers the same number.

**`drain` reads the clock once, and that changes it slightly.** It used to
read the clock per row, so a schedule of `every(1)` under a tick that took
longer than a millisecond was due again by the time the next claim looked,
and a drain could run for as long as the ticks did. Against one reading,
what is due is due at that moment, and a drain finishes.

## What was rejected

**A `Settings` clock** — `fn () i64` on `Settings`, read everywhere
`nowMicros` was. The general shape, and the one the roadmap named beside
the small one. It reaches `push` too, which `drainAt` does not; but a push
in a test can already say `.at`, the worker's reads would go through a
function pointer for the sake of a test, and a clock on the queue is a
clock the *store* does not share — `Table.done` writes `finished_at` from
the wall regardless. A parameter on the two calls a test makes is the
whole of what the tests wanted, and nothing on the worker changes.

**A `Tick` handed to every `run`**, as a third fixed parameter after the
Run. Every existing `run` would change, for a value most of them never
read, and the argument-list rule this module borrowed from the server
already says how a run asks for what it wants.

**Progress on the row.** A column written per call to `progress` is a
`UPDATE` per call, and a run reporting every hundred rows would be writing
the table as fast as it reads its input. The Space is a cache and may
forget, which for a progress bar is the right promise (the guide already
says so of `status`).

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | 0 |
| Throughput and p99 | per row, not per request: one `Tick` — three words and a bool — built on the worker's stack whether or not the `run` asks for it, and one tag test on the `Clock` per read of it, three or four a tick. `progress` is a `get` and a `put` on the Space, per call, only when called |
| Binary size | unchanged for a queue with no Space; `progress` and the wider `note` are the linker's to drop |

## What proves it

In `job/job.zig`: `test "a run that asks for a job.Tick sees attempts == 3
on the third attempt, and that it is the last"`; `test "progress from
inside a run reaches the status Space, and a finished row keeps it"`, over
a fake Space because `job/` names no `nilo_cache`; `test "a row due in a
minute does not run at t and runs at t plus a minute"`; `test "an
exponential backoff's third attempt waits the doubled time, on a moved
clock"`, which walks 100, 200 and 400 milliseconds without sleeping; and
`test "a cron schedule fires when the clock is moved to three in the
morning"`, seeded on a fixed day and drained at `03:00` and at `02:59:59`.
One Refusal, `job_run_takes_the_tick_by_pointer`, holds the rule's wording.
