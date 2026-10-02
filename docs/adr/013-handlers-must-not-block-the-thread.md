# Handlers must not block the thread, and holding it is watched at run time

**Status:** accepted
**Topic:** [engine](../design/engine.md)

## Context

nilo runs each connection in a fiber and many fibers on one OS thread. A handler that waits on the operating system directly, a database driver, `std.fs`, `std.http.Client`, stops every other request sharing that thread, not just its own. Measured on a two-executor server with one handler sitting in `nanosleep` for two seconds: a second request for a route that does nothing at all took 1.7s, and four concurrent two-second handlers took 6.0s where fibers should have taken 2s.

nilo is aimed at people coming from Go and Node. In Go every blocking call is safe because the runtime moves the goroutine; in Node the driver is async because there is no other option. Both groups arrive with "call the database from the handler" as a habit that has always worked, and here it compiles, passes every test, works under curl, and only shows up as a latency tail under load, the worst possible failure schedule. The Bulkhead carried a Mutex and a clock and nothing that let a handler wait or hand a blocking call somewhere it could block harmlessly, so a correct handler could not be written without naming zio directly, which ADR 001 forbids.

Once the way out existed, a second problem remained: nothing forced its use. A handler calling a driver directly still compiled and still passed its tests, and the bug is invisible in development precisely because there is no load. One `curl` against it returns the right answer at the right speed. It only exists in the presence of a second request, which arrives for the first time in production. Zig has no effect system and no way to mark a function as blocking, so there is no proving at compile time that a function blocks, but that is the wrong question. The one that matters is whether the server can notice that one just did, and it can, cheaply, with a stopwatch.

The first shape of that stopwatch summed elapsed time minus parked time over the whole request, and had to excuse a Stream, a Body reader and a WebSocket entirely: a WebSocket answering a thousand messages a second accumulates seconds of correct handler time in a minute, and a total measured against a quarter-second limit would report it. That was the wrong gap to leave open, because a stalled fiber inside a WebSocket loop holds its executor against every other socket that executor is serving for the life of the connection, which is where the mistake costs the most and the one place nothing was watching.

## Decision

### The way out: `nilo.blocking` and `nilo.sleep`

The Bulkhead carries two items:

```zig
fn getUser(db: *Db, id: u32) !User {
    return nilo.blocking(Db.query, .{ db, id });
}
```

`nilo.blocking` runs the call on the Engine's thread pool and parks the fiber until it returns; the arguments and the result stay on the calling fiber's stack, so nothing is allocated. `nilo.sleep` waits without occupying anything at all. Both fall back to running inline when there is no fiber, `blocking` calls the function directly and `sleep` really does sleep, so a handler using either is still an ordinary function a unit test calls with no server running. `sleep` fails the way `Mutex.lock` already does: `error.Canceled` if the request went away while waiting, mapped to a 503. Long computation is covered by the same tool: `nilo.blocking` around a CPU-bound call moves it off the executor thread just as well as it moves a syscall. The blocking pool is finite, so `blocking` converts "the thread stalls" into "the pool is the queue" rather than into unlimited concurrency, the correct trade for a database, which has a connection limit of its own.

### How the pool grows

**A call that finds no idle worker starts one, up to the pool's ceiling.** `serve` passes zio's pool `scale_threshold = 0` (`blocking_pool` in `http/engine/zio.zig`); the ceiling is zio's default of twice the logical CPUs, and a worker idle for 60 s exits, as before. Past the ceiling a call queues, so the pool is still the queue, just one that fills its workers before it lines anybody up. `blockingReserved` keeps its own rule, a thread past the ceiling if it has to, for a caller holding a connection or a lock ([ADR 064](./064-a-file-has-no-socket-to-wait-on.md#a-statement-under-hop-gets-a-thread-of-its-own)).

zio's default threshold of 2 starts a worker only once twice as many calls wait as run, which suits many short calls and strands a short one behind a long one: with one call running for seconds, a second is `1 < 2` and waits for it however many workers the ceiling allows. The photon port met it as a 2 ms write waiting up to 1.9 s behind a compaction pass. Measured on a cold pool, a 2 ms call behind a 500 ms one took 501 ms every time at the default and 2.1 ms at 0; a burst of 512 callers fills the pool to its ceiling either way and reads the same; 16 callers in a steady loop take 16 workers instead of 7, for 6% more CPU, 2.2 MB more RSS and a wall time 38% shorter ([`bench/result/http.md`](../../bench/result/http.md#a-short-blocking-call-behind-a-long-one-and-what-starting-a-worker-for-it-costs)).

### What is watched: one unparked stretch

`http/watchdog.zig` measures **the longest stretch a fiber ran without parking**, not a sum over the request. A stretch ends wherever the request waits on something that is not the handler's own code, and every one of those says so through a `waiting`/`waited` pair:

| what waits | where it says so |
|---|---|
| `nilo.blocking` | `bulkhead.blocking` |
| `nilo.sleep` | `bulkhead.sleep` |
| `nilo.Mutex.lock` | `bulkhead.Mutex` |
| asking the OS for entropy | `bulkhead.randomSecure` |
| reading the request body | `Ctx.body` |
| writing the response | `Ctx.send`, `App.sendDirect` |
| a stream's writes | `stream.zig`'s `drain` |
| a body reader's reads | `body.zig`'s `streamFn` and `discardFn` |
| a WebSocket's park | `websocket.zig`'s `park` |
| a service waiting on its own socket | [ADR 210](./210-a-services-wait-on-its-own-socket-is-a-park.md) |

`waiting` closes the current stretch and reports it if it was too long; `waited` opens a fresh one. Whatever is left over is the handler running: a handler that ran for a quarter of a second without yielding once is either blocking or doing CPU work it should have handed to `nilo.blocking`, and since that is the same advice either way, both are worth saying:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 013).
```

One stretch means the same thing on a request that lasts a millisecond and on a connection that lasts a day, so nothing needs to be excused. **A WebSocket's stretch is exactly one message**: `park` is where the loop waits, so what lies between two of them is what the handler did with the message it was handed, including the framework's own reassembly. Nested pairs are safe: `nilo.sleep` inside `Ctx.body` is that shape, and the inner `waiting` finds the watch already parked, returns a zero token, and its `waited` does nothing, so the stretch is reopened by the outermost pair and by that one only.

A handler that yields between short stretches is no longer reported as one long one: ten 30ms stretches with a `nilo.blocking` between each pair used to sum to 300ms and be caught, and measured one at a time they are 30ms and are not, which is the right answer since the advice is already followed. A handler that blocks twice is now reported twice, where the sum reported once; the rate limit below is what keeps that readable.

The clock starts before the middleware chain and stops after it, rather than around the terminal handler: a middleware that writes an audit row to a file after `next.run` stops the thread exactly as dead as a handler that does.

### A park nobody announced: the loop's turn

The brackets above are the waits nilo was told about. A handler can also wait through the server's `Io` ([ADR 244](./244-a-handler-is-given-the-loop-it-runs-on.md)): a `std.Io.Event`, a `std.Io.Queue`, a service parked on its own socket. That parks the fiber and frees the thread, and says nothing to the watchdog, so a wait past `block_warning_ms` was reported as a handler holding its thread, with advice to hand it to `nilo.blocking`, which would have made it worse. A false report teaches people to ignore the real one.

**The run loop already knows.** zio writes `Executor.tick_started_at`, a `CLOCK_MONOTONIC` stamp, once per turn of its run loop, after the poll and before the batch of ready fibers. A fiber cannot be running while a turn ends, so **a turn newer than a stretch's start means the fiber parked at some point, whatever it waited on**. `engine/zio.zig` reads it as `loopTurnNanos()` (re-exported by `bulkhead.zig`; zio does not export `Executor`, so the field is reached through the type of `Runtime.executors`, and ADR 001 still holds: only that file names zio).

The check runs only for a stretch that is already past the limit, in `watchdog.reportIfTooLong`, after the early exit every request takes:

1. Ask the loop for its last turn. With no loop (`testing.Client`, in-memory, a pool thread) there is none, and the stretch is what the brackets said.
2. If the turn is newer than the stretch's start by more than 12 ms, the fiber parked, and the stretch that counts is the one **since that turn**: a park of 400 ms is not a hold, and a park followed by a 300 ms spin is a hold of 300 ms. The 12 ms is the slack between the stretch's start, a `CLOCK_MONOTONIC_COARSE` reading that trails the real clock by up to a kernel tick, and the exact stamp; a park shorter than that is charged from the start of the stretch, which overstates a hold by under 12 ms against a quarter of a second.
3. A threadlocal `charged_turn` records the turn a report was made in. One turn runs a whole batch of fibers and they share its stamp, so a fiber that blocks for 300 ms would make every fiber after it in the batch look 300 ms into its stretch. Once a turn is charged to one holder, nobody else is charged for it; the next turn tells the truth.

The brackets stay. With no executor they are the only signal, and they give exact ends: a `nilo.sleep` reopens the stretch at the moment the fiber resumed, where the turn only says it was some time since. `Watch` is unchanged and nothing is stored per connection or per request.

**What it still cannot tell.** The turn says the fiber parked, not that the thread was free. A fiber that parks and then blocks in the kernel is a hold from the turn that resumed it, and is reported. A fiber with no request that blocks (an `app.spawn` writer) is never reported by itself, and can be blamed on the next request that ends a stretch in the same turn after an unannounced park: the executor keeps `current_task` for the fiber running now, and no record of the one before it, so there is nothing cheap to tell them apart. The advice in the report is right for the thread either way.

### What it does not see

**A request that took the connection over** is watched by the message or the chunk, not excused: see the WebSocket row above. **A handler that blocks for less than the threshold, every time**, is a real ceiling on throughput that goes unmentioned; the threshold is a knob, not a claim. **Fibers as a whole**: this reports one request holding its thread, not a thread that is oversubscribed or a pool that is saturated. **A fiber that is not on zio's loop** has no turn to ask, so a wait through an `Io` of another kind is timed as the handler running.

**A service that waits through its own `Io`**, pg.zig on a socket, `nilo_fetch`'s client, a pool a caller queues on, used to be reported too. [ADR 210](./210-a-services-wait-on-its-own-socket-is-a-park.md) closed it for the services that say so through `core.Limits.VTable`'s `waiting`/`waited` pair, and the turn closes it for the rest on a real loop, including `nilo_fetch`, which does not call the pair.

## What was rejected

**Wrap handlers automatically**, running every one on the blocking pool. Makes the slow path safe by making the fast path slow: every request would pay a thread hand-off, including the overwhelming majority that only touch memory, and throws away the reason for choosing a fiber Engine.

**zio's default growth rule** (`scale_threshold = 2`), which `serve` ran until the photon port. It saves workers on a steady load of short calls, and the price is a short call waiting out a long one whenever no worker happens to be idle, which no caller can see coming or bound. The measurement under "How the pool grows" is what moved it.

**`min_threads` instead of a growth rule.** Workers kept alive for the life of the process, and still a short call queued once that many are busy.

**Detect blocking calls at compile time.** Zig has no effect system and no way to mark a function as blocking; there is nothing to detect with. The question that has an answer is not whether the compiler can prove a function blocks, but whether the server can notice that one just did.

**Provide async drivers.** The real fix and far outside v1: an async Postgres client, an async file API, an async HTTP client. `nilo.blocking` is what makes the ecosystem that exists today usable in the meantime, and it is what Go's own `syscall` boundary does underneath.

**Say nothing and let people find out.** The status quo, and the option this decision exists to reject: the symptom is a p99 nobody can explain, on a metric nilo has declared primary.

**A message-scoped watch of its own**, started and stopped by `websocket.receive`. Answers the WebSocket and leaves the stream and the body reader where they were, and needs a decision about where a Room's drain belongs. Bracketing `park` needs no such decision: the drain is on the handler's side of it, which is correct, because draining a Room is work that does not wait.

**Keeping the sum and adding a ceiling to it**, resetting the total every N seconds on a long-lived connection. A second number to explain, and it still cannot say whether the handler ever held the thread or merely used it.

**Reading the request's method and path through the fiber slot in the report.** `fail.inFlight()` has them, but a `Watch` living outside an `InFlight` is a thing a test is allowed to build, and `@fieldParentPtr` from one of those would print a garbage slice in a log line. `Watch` carries its own two strings instead.

**Measure the fiber's CPU time instead of wall time between parks** (ADR 210's question). The operating system accounts CPU per thread, not per fiber, and a thread serves many; there is no clock to read.

**Have the Engine record every suspend** (ADR 210's question). zio knows when a fiber parks, and an Engine hook would catch every service at once. zio has no switch hook and counts none, so this meant patching the runtime. What it does keep, a stamp per run-loop turn, is enough to answer the question that matters (did the fiber park since the stretch began), and is read with no change to zio.

**Exempt `db.*` calls by name** (ADR 210's question). The watchdog has no view of what a handler called, only of whether it parked, and a driver that truly blocks a thread, one that does not go through `Io`, should still be caught.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none. A handler that computes rather than waits never calls `blocking` or `sleep`, and pays nothing for their existence. |
| Memory per idle connection | unchanged by the loop's turn: no field was added, and `bench/mem.py` reads 5,816 bytes at 100 connections and 5,247 at 1,000 before and after. `Watch` carries two slices (32 bytes) on `fail.InFlight`, which every connection already holds; the strings are arena slices pointed at, not copied. Against the 4,669-byte framework floor ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), 32 bytes. |
| Throughput and p99 | on, by default, in every optimize mode, because the bug lives in production. The mechanism is one subtraction and one comparison per wait, on top of a clock read, and nothing on the path between `begin` and `finish` with no wait in between; `block_warning_ms = 0` turns it off and every call becomes a null check. **The loop's turn adds nothing to it**: it is read only for a stretch already past the limit, so a request that does not wait long executes the same instructions as before (one register move more in `reportIfTooLong` before its early exit, read from the disassembly). Interleaved ReleaseFast runs of the benchmark server show no difference outside the noise ([`bench/result/http.md`](../../bench/result/http.md)). |
| Binary size | not separately tracked; the detector is part of the request path rather than a module a program opts out of linking. The loop's turn is 272 bytes of the stripped `ReleaseFast` benchmark server. |

**A coarse clock is what keeps the per-request cost low.** `bulkhead.coarseNanos` reads `CLOCK_MONOTONIC_COARSE`, which only moves once a millisecond, against a quarter-second threshold where that resolution is not a compromise. Re-measured on Zig 0.16 ([ADR 041](./041-core-knows-what-time-it-is.md)): the coarse read costs about 2ns against about 15ns for the exact monotonic clock read the same way, through `std.posix.system` on both the libc and non-libc build, an earlier reading that had the non-libc path far slower did not survive Zig 0.16's own vDSO handling and is corrected there. `Watch` holds a pointer on `Ctx` rather than looking one up through the fiber slot on the response-write path; code with no `Ctx` to hand, `nilo.blocking` and friends, still pays the lookup and does not care, because a request reaching one of those is about to park anyway.

Every failure in this ADR is a log line rather than a Refusal, since it is a runtime condition and not something the compiler can decide; `watchdog.caught` counts what was detected before the one-a-second rate limit throws any away, because a detector nobody can watch fail is a detector nobody should trust.
