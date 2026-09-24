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

### What it does not see

**A request that took the connection over** is watched by the message or the chunk, not excused: see the WebSocket row above. **A handler that blocks for less than the threshold, every time**, is a real ceiling on throughput that goes unmentioned; the threshold is a knob, not a claim. **Fibers as a whole**: this reports one request holding its thread, not a thread that is oversubscribed or a pool that is saturated.

**A service that waits through its own `Io`**, pg.zig on a socket, `nilo_fetch`'s client, a pool a caller queues on, is a park the fiber makes without going through any of the rows above, and used to be reported as a handler holding its thread with advice to hand it to `nilo.blocking`, which would have made it worse. [ADR 210](./210-a-services-wait-on-its-own-socket-is-a-park.md) closed that: `core.Limits.VTable` carries the same `waiting`/`waited` pair, and a service that parks on its own `Io` reports through it. `nilo_fetch` does not yet call it and still draws the false report on a slow outbound call.

## What was rejected

**Wrap handlers automatically**, running every one on the blocking pool. Makes the slow path safe by making the fast path slow: every request would pay a thread hand-off, including the overwhelming majority that only touch memory, and throws away the reason for choosing a fiber Engine.

**Detect blocking calls at compile time.** Zig has no effect system and no way to mark a function as blocking; there is nothing to detect with. The question that has an answer is not whether the compiler can prove a function blocks, but whether the server can notice that one just did.

**Provide async drivers.** The real fix and far outside v1: an async Postgres client, an async file API, an async HTTP client. `nilo.blocking` is what makes the ecosystem that exists today usable in the meantime, and it is what Go's own `syscall` boundary does underneath.

**Say nothing and let people find out.** The status quo, and the option this decision exists to reject: the symptom is a p99 nobody can explain, on a metric nilo has declared primary.

**A message-scoped watch of its own**, started and stopped by `websocket.receive`. Answers the WebSocket and leaves the stream and the body reader where they were, and needs a decision about where a Room's drain belongs. Bracketing `park` needs no such decision: the drain is on the handler's side of it, which is correct, because draining a Room is work that does not wait.

**Keeping the sum and adding a ceiling to it**, resetting the total every N seconds on a long-lived connection. A second number to explain, and it still cannot say whether the handler ever held the thread or merely used it.

**Reading the request's method and path through the fiber slot in the report.** `fail.inFlight()` has them, but a `Watch` living outside an `InFlight` is a thing a test is allowed to build, and `@fieldParentPtr` from one of those would print a garbage slice in a log line. `Watch` carries its own two strings instead.

**Measure the fiber's CPU time instead of wall time between parks** (ADR 210's question). The operating system accounts CPU per thread, not per fiber, and a thread serves many; there is no clock to read.

**Have the Engine record every suspend** (ADR 210's question). zio knows when a fiber parks, and an Engine hook would catch every service at once. The right long-term shape and the wrong first change: it reaches into the runtime's scheduler for something two vtable entries already say from the outside.

**Exempt `db.*` calls by name** (ADR 210's question). The watchdog has no view of what a handler called, only of whether it parked, and a driver that truly blocks a thread, one that does not go through `Io`, should still be caught.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none. A handler that computes rather than waits never calls `blocking` or `sleep`, and pays nothing for their existence. |
| Memory per idle connection | `Watch` carries two slices (32 bytes) on `fail.InFlight`, which every connection already holds; the strings are arena slices pointed at, not copied. Against the 4,669-byte framework floor ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), 32 bytes. |
| Throughput and p99 | on, by default, in every optimize mode, because the bug lives in production. The mechanism is one subtraction and one comparison per wait, on top of a clock read, and nothing on the path between `begin` and `finish` with no wait in between; `block_warning_ms = 0` turns it off and every call becomes a null check. |
| Binary size | not separately tracked; the detector is part of the request path rather than a module a program opts out of linking. |

**A coarse clock is what keeps the per-request cost low.** `bulkhead.coarseNanos` reads `CLOCK_MONOTONIC_COARSE`, which only moves once a millisecond, against a quarter-second threshold where that resolution is not a compromise. Re-measured on Zig 0.16 ([ADR 041](./041-core-knows-what-time-it-is.md)): the coarse read costs about 2ns against about 15ns for the exact monotonic clock read the same way, through `std.posix.system` on both the libc and non-libc build, an earlier reading that had the non-libc path far slower did not survive Zig 0.16's own vDSO handling and is corrected there. `Watch` holds a pointer on `Ctx` rather than looking one up through the fiber slot on the response-write path; code with no `Ctx` to hand, `nilo.blocking` and friends, still pays the lookup and does not care, because a request reaching one of those is about to park anyway.

Every failure in this ADR is a log line rather than a Refusal, since it is a runtime condition and not something the compiler can decide; `watchdog.caught` counts what was detected before the one-a-second rate limit throws any away, because a detector nobody can watch fail is a detector nobody should trust.
