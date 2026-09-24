# A deadline belongs to an operation, not to a request

**Status:** accepted
**Topic:** [deadlines](../design/deadlines.md)

## Context

nilo 0.1.0 had no deadlines of any kind. `nc host 8080`, then say nothing, and a fiber is parked until TCP gives up on it, which on Linux is minutes. Repeat from one laptop and the server is full. No tool, no bandwidth, no cleverness: this was the largest hole in the project, and [ADR 019](./019-a-request-that-lasts-is-still-one-request.md) named it and declined to fix it, on the grounds that read, header and write timeouts want one decision rather than a knob bolted onto each feature.

The question that decides the shape is not "where do the timeouts go", it is **what is a deadline attached to?** The obvious answer is the request: give it 30 seconds, and cut it if it is not done. That is wrong here for reasons that are not about performance. It is wrong about streams: a server-sent event stream that runs for an hour is a request, so is a WebSocket, so is a 4 GB upload on a domestic line, and under a request deadline each of those is either killed for working correctly or the deadline is set so high it protects nothing. It cannot be implemented without cancellation: cutting a request halfway through a handler means unwinding a fiber that is not asking to be unwound, and Zig has no way to make that safe, the same fact that makes a `recover` middleware impossible ([ADR 007](./007-no-recover-middleware.md)). And it answers the wrong question: a handler taking 30 seconds is a slow handler, and slow handlers are the author's business, while a *client* taking 30 seconds to send a header is nobody's business but the server's, because it is the server's fiber being held.

## Decision

**A deadline is a limit on one wait for the network, not on a request.** Several limits, each on a different wait, and none of them can interrupt a handler that is doing work. Nothing in nilo can be cut off mid-computation, so nothing had to be made interruptible, so this adds no new way for a handler to fail: every failure it introduces is a read or a write that returns an error, a shape every call site already handles because a client can always disconnect.

### The limits

| `Options` | Default | The wait it bounds |
|---|---|---|
| `header_timeout_ms` | 10,000 | From the first byte of a request head to the blank line that ends it |
| `idle_timeout_ms` | 75,000 | A connection between one request and the next |
| `body_timeout_ms` | 30,000 | Any single read of a request body |
| `write_timeout_ms` | 30,000 | Any single write to the client |

Zero turns one off; all four zero is 0.1.0's behaviour, kept reachable so that "put it behind a proxy that has them" stays a real option rather than a thing the docs say while the code disagrees.

**The header limit is absolute and the others are per operation.** A client sending one byte a second satisfies a per-read limit of any size, forever, and never finishes a head, so the head gets one deadline, computed when its first byte arrives and shared by every read after that. `readHead` arms it exactly once; re-arming per read would move the finish line every time a byte turned up, which is the attack rather than the defence, and a test counts the arming rather than trusting the comment. The other three are per operation because "how long is reasonable" is a function of size and line speed a server cannot know in advance: a 4 GB body over a slow link is not an attack, a body that stops arriving is, and a per-read limit catches that without anybody guessing how big a legitimate upload is. Idle and header are separated on purpose: a browser holding a keep-alive connection open has done nothing wrong and may do it for a minute, a client halfway through a head has, and they run out to different answers (below).

### A buffered body also has to arrive at a rate

A per-read limit alone leaves a hole: **a client sending one byte every twenty-nine seconds is inside a thirty-second per-read limit forever**, and each byte is delivered on time. It holds a fiber, the 16 KiB step `c.body()` has committed ([ADR 083](./083-a-body-is-taken-as-it-arrives.md)), and a slot against `max_connections`, for as long as it cares to, the slowloris shape one phase later, at the body rather than the head.

**A run of reads that assembles a buffered body carries a deadline of `body_grace_ms + bytes / body_min_rate`**, in addition to the per-read limit above. Two `Options`, `body_min_rate` (default 8 KiB/s) and `body_grace_ms` (default 10,000), armed per read run rather than once. What makes this different from a request deadline is that the body of a `Content-Length` request is the one wait in HTTP where the client has said, in advance and in the request itself, exactly how much work is coming: the deadline is not a guess about the client, it is a statement about the rate the server is prepared to sit at, applied to a length the client chose.

Three shapes, and the rule has to be right about each. **A sized body** gets `grace + announced / rate`: `readSizedBody` takes its 16 KiB step before committing the rest, so a client that announces a megabyte and goes quiet is refused in ten seconds rather than in the megabyte's worth of time it never earned. **A chunked body** announces nothing, so it is sized from `max_body`, the most it is allowed to be; a flat number was rejected because it would make chunked either the cheap way to hold a connection or the framing that cannot upload anything large, and sizing it this way gives it exactly the worst case of a body that announced `max_body`, so neither framing is the better attack. **Everything that is not a buffered body** (`bodyStream`, a WebSocket, a held-open stream, the connection's own reads) keeps the per-read limit only: those are [ADR 019](./019-a-request-that-lasts-is-still-one-request.md)'s "a request that lasts is still one request", and none of them is the framework holding memory on the client's behalf.

**A client that misses it is told 408, not 500.** Both arrive at `c.body()` as `error.ReadFailed`, one interface with one error and no room for a reason, so `Ctx.slowBody` asks `deadlines.timedOut()` and turns the timeout into `error.BodyTooSlow`, which maps to 408. A 500 would blame the server for something the client did.

**This is an admission policy, and it says so.** `body_min_rate` is not a safety limit that only touches attackers: 8 KiB/s is the slowest upload this server will sit through, and a client below it is refused however honest it is. A server whose clients are on genuinely bad links should lower the rate, not raise the timeout; `body_min_rate = 0` turns the rate deadline off and leaves the per-read limit exactly as it was, and `body_timeout_ms = 0` still means no clock on a body at all. The attacker's remaining freedom is the announcement, `Content-Length` up to `max_body`, so the largest deadline they can buy is bounded, `grace + max_body / rate`, 138 seconds at the defaults (10s + 1 MiB / 8 KiB/s). It was unbounded before.

### What runs out, and what the client is told

- **Halfway through a head → 408, then close.** The client asked for something, so it gets an answer.
- **Idle, having asked for nothing → close, no answer.** There is nothing to answer.
- **A body that stops → the connection goes**, with whatever the response already was. If the handler was reading it gets a read error like any other; if nobody read it, `App` was discarding it to reuse the connection, and now it will not be reused.
- **A write that stops → the response is abandoned and the connection closed.** The head has gone out already.

The distinction between "timed out" and "the connection broke" needs asking for, because both arrive as the same error through a `std.Io.Reader`, so the reason is kept on the side and `Deadlines.timedOut()` asks for it right after the failed operation. A 408 is conditional on there being buffered bytes: a client that vanished mid-head gets nothing written into a socket nobody is holding. And a failed write now logs what happened rather than "WriteFailed": a client that stopped reading is not a bug in the handler.

### A WebSocket has no read limit, and that is not an oversight

After the handshake, reads go back to no limit at all: a chat tab with nobody typing is working correctly, and any read limit closes it. What is worth catching there is a client that has gone away without saying so, and the answer is a ping it fails to answer, which needs a frame to send, a reply to wait for and a decision about several missed in a row. That is a WebSocket feature with its own design, not a number in `Options`. Writes keep their limit, which is what makes this safe rather than a hole: a WebSocket whose client has stopped reading is caught by the write limit, and that is also the case that matters for a server pushing to a client that walked away.

### Where it lives

The Engine already has to wait with a limit, it cannot implement `accept` with a stop flag otherwise, so this asks nothing new of it: zio keeps a timeout on its reader and its writer and applies it to every operation, so putting a limit on the next read is a field store. The Bulkhead splits mechanism from policy: `engine.Clocks` can put a limit on a read or a write and has no idea why, `bulkhead.Deadlines` knows why (it holds the numbers and the `arm*` calls that work out which limit applies) and has no idea how. `Ctx` carries the connection's limits because the paths that read from a connection are on `Ctx`. `Ctx.aboutToRead` arms the body limit: it already existed as the choke point every read passes through, so arming the clock there makes "every read has a limit" structurally true rather than remembered. `handleRequest` takes a `Deadlines` as a Bulkhead type rather than an Engine one; every test that drives it directly passes `.off`, a complete working instance that does nothing.

That split is also the test seam: `Deadlines` reaches its target through a vtable, so a test can hand `App` one that writes down what it was asked for, and "the header deadline is armed once, however many reads the head takes" is a counting assertion that runs in a millisecond rather than a socket test waiting out a real deadline. What zio does with a limit once it has one is checked by hand against a real server:

Against the real server on a real socket, with the limits turned down to 1000ms (2000ms idle) so a check takes seconds instead of a minute:

| | |
|---|---|
| A healthy request | 200, 10ms, untouched |
| Two requests down one keep-alive connection | both 200 |
| A head that stops halfway | **408 at 1001ms** |
| A head at one byte every 300ms, the slowloris shape | **408 at 1201ms** |
| An idle keep-alive connection | **closed at 2000ms**, nothing written |
| A body that stops halfway | **connection released at 1002ms** |
| 80,000 answers asked for and none read | **closed at 1116ms** |

The last row is the one that matters for streaming: before this, that client parked a fiber in a blocked write for as long as the kernel would allow.

## What was rejected

**A deadline attached to the request rather than to one wait.** The shape most frameworks ship, and wrong here for three separate reasons: it kills a stream that is working correctly or is set too high to protect anything, it needs cancellation Zig cannot give safely, and it answers a question that is the handler author's business rather than the server's.

**A combined body limit: each read gets `body_timeout_ms`, and no read may pass an absolute instant.** The exact semantics of the rate deadline, and it needs the Engine to express both a duration and a deadline in one wait, which zio's `Timeout` cannot today. Not needed: a deadline per read run, sized from the run's own bytes, catches the same client, and the only cost of the difference is that a client can spend a whole run's budget on one slow read rather than being cut at the first one. Both end at the same instant.

**A flat `body_deadline_ms`.** A number nobody can choose: large enough for a legitimate upload on a slow line, it is large enough to hold a connection open; small enough to be a limit, it refuses uploads that are working.

**Re-arming the rate deadline per chunk on a chunked body.** Reads as the tighter option and is the looser one: a client sending 1-byte chunks would get a fresh grace on each, the per-read hole again with more steps.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. Arming a limit is a field store on the reader. |
| Memory per idle connection | None added by this ADR. `idle_timeout_ms` is the one knob here whose real units are memory: an idle connection holds 4,669 bytes ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), so a server with many visitors and few of them active wants the number lower. Two `u32`s on `Options` and on `Deadlines` are per *server*, copied by value into a connection that already carries the other limits. |
| Throughput and p99 | One `clock_gettime` per head and, on requests that have a buffered body, one per read run (the same vDSO call `armHeader` already makes once per head). A GET with no body does not reach it. |
| Binary size | Not separately measured; the arming logic is a handful of comparisons behind code every request already runs. |

A default changed behaviour rather than adding to it: a server upgraded to this whose clients are on genuinely bad links, or below 8 KiB/s, may see 408s it did not see before. That is the point, the numbers are generous, and it is a pre-1.0 release.
