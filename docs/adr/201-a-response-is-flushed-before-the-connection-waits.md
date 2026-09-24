# A response is flushed before the connection waits, not before `send` returns

**Status:** accepted
**Topic:** [responses](../design/responses.md)
**Extends:** [ADR 008](./008-middleware-is-an-onion-of-ctx-functions.md)
(when a finished response is flushed; ADR 008 says so).
**Applies:** [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 021](./021-a-websocket-is-a-handler-that-does-not-return.md),
[ADR 200](./200-every-executor-accepts.md).
**Found by:** [HttpArena](https://github.com/MDA2AV/HttpArena)'s `pipelined`
and `echo-ws-pipeline` profiles, sixteen requests or frames a write, against
which nilo answered each one with a `send(2)` of its own; and by this box,
where the same shape reads 3.0M req/s pipelined against 2.6M keep-alive, an
18% gain from a client doing sixteen times less work per request.

## Context

Since ADR 008 every `Ctx.send` has ended in `flush()`, and every WebSocket
`send` the same. The reason given there was honesty: a response that is
flushed the moment it is finished is one whose latency the client measures
truthfully, and one that a middleware's "after" half cannot rewrite, because
the bytes are gone. Both of those are still wanted, and this ADR keeps both.

What it costs is a syscall a response whatever the client is doing. A client
that pipelines, sending request N+1 before it has read response N, is not
waiting on response N, and nothing about it is measured more honestly by a
`send(2)` of its own. On this box that syscall was **the** cost of a
pipelined request: `bench/main.zig`'s `/health` through
[gcannon](https://github.com/MDA2AV/gcannon) at `-p 16` read 3.04–3.06M
req/s at 1.78 µs of server CPU a request, against 0.57 µs once the sixteen
responses left as one write. On the WebSocket echo the difference is larger
still, 1.38 µs a message against 0.16, because an echo is a memcpy and the
syscall was nearly all of it.

The shape rewards a server that writes when it would otherwise wait, which
is what an event loop that flushes before it blocks does without being
asked; actix's dispatcher, read for [`input_from_actix.md`](../input_from_actix.md),
decodes what it has, answers it into one write buffer and flushes once it
has nothing more to decode, and a server that answers sixteen buffered
requests with sixteen `send(2)`s spends most of a pipelined request in the
kernel. The property worth keeping is not "flushed on `send`" but the one
it was standing in for: **a response is on the wire before the connection
next waits for its client.** Per-response flushing is one way to guarantee
that, and the most expensive.

## Decision

**A response is flushed on `send` unless the client's next request is
already in the read buffer.** In that case it stays in the write buffer and
leaves with the next response, or the one after, until either the buffer
fills (a plain drain, the way any write past the buffer goes) or the
connection runs out of buffered input and would have to wait. The same for
a WebSocket frame: `send`, `print`, `json` and a room's `deliver` hold the
frame while the peer's next frame is already buffered, and let it go
otherwise. A close frame is flushed whatever the buffer holds, because that
connection is not going to read again.

The guarantee that makes the skip safe belongs to the Engine, not to the
layers that skip. In `Conn.run` the reader's vtable is swapped for one that
flushes the connection's writer before every read that reaches the socket,
then hands the read to zio's own. No code above the Bulkhead can park a
connection in a read with a response still in memory, whether it knew about
this ADR or not; the Bulkhead's header lists it as part of the contract. The
one wait that is not a read, the WebSocket's `park` on socket readiness,
flushes before it waits, in the WebSocket layer, which owns both halves.
And a connection that is ending flushes in `handleConnection` before its
FIN or its close, because it never reads again either.

What ADR 008 wanted survives untouched. A client that does not pipeline,
which is every browser and every HTTP client by default, has exactly one
request in the buffer, so once it is parsed the buffer is empty and the
response is flushed on `send` as before; its latency is measured as it
was. A middleware's after half still cannot rewrite a response: the bytes
may still be in the write buffer, but nothing above the Bulkhead has a
handle to them, and `Ctx.send` has already marked the request answered.

Same box, `ReleaseFast`, server on CPUs 0–7 and gcannon on 8–15,
interleaved pairs, before (`0efa4c0`) → after:

| shape | before | after |
|---|---|---|
| HTTP `/health`, 256 conns, `-p 16` | 3.04–3.06M req/s, p99 1.8 ms, 43.5 core-s | **12.3–13.6M**, p99 365–384 µs, 59 core-s |
| HTTP `/health`, 4,096 conns, `-p 16` | 2.05M, p99 107 ms, p99.9 338 ms | **10.4–11.0M**, p99 39 ms, p99.9 82 ms |
| WS `/ws/small` echo, 256 conns, `-p 16` | 3.59–3.61M msg/s, p99 1.3–1.5 ms, 39.7 core-s | **37.1–37.4M**, p99 200–223 µs, 48.6 core-s |
| WS `/ws/small` echo, 4,096 conns, `-p 16` | 2.9M, p99 81.5 ms | **30.8–31.1M**, p99 33 ms |
| HTTP `/health`, 256 conns, keep-alive | 2.61 / 2.61 / 2.61M, 46.3 core-s | 2.59 / 2.60 / 2.60M, 46.3 core-s |
| WS `/ws/small` echo, 256 conns, one at a time | 2.75 / 2.75 / 2.74M | 2.75 / 2.75 / 2.75M |

Four times on pipelined HTTP and ten on pipelined WebSocket, with the tails
down by the same factor; on the HTTP row the server is at 7.4 of its 8
cores after, where before it sat at 5.4 with the rest in `send(2)`'s wait.
The two shapes that
do not pipeline are the check that nothing else moved: the WebSocket row is
unchanged to the third digit, and the HTTP row is 0.4% down with the sign
the same in all three pairs, which is the compare of the reader's fill on
every response and the load of the writer's fill on every read, and inside
ADR 017's budget by a factor of twenty. Memory per idle connection reads
the same on both binaries at 2,000, 5,000 and 10,000 connections.

## What it costs

**Latency, for a client that pipelines behind a slow handler.** Response N
is not on the wire until the connection next waits or the write buffer
fills, and between the two sits the handling of request N+1. For the
handlers pipelining clients are pointed at this is microseconds, and the
client by definition was not waiting; but a client that pipelines a fast
request behind a slow one now sees the fast answer arrive with the slow
one. That is the trade a write-when-you-would-wait loop makes, and
`write_buffer` (4 KiB by default) bounds how much can be held.

**A WebSocket handler that stops reading.** A `send` while the peer has a
frame buffered that the handler has not received is held until the handler
next receives, parks, or fills the write buffer. A handler that reads what
it is sent, which is every handler `receive` was designed for, never sees
this; one that sends in a loop without receiving, while the peer is also
sending, gets its frames out in 4 KiB batches. `Socket.settle`'s comment
says so.

**Per request:** one compare of two fields of the reader on `send`, and one
load of the writer's `end` on each read that reaches the socket. A read
answered from the buffer pays nothing. **Per connection:** one pointer in
the fiber's frame, zio's vtable, which the swap needs to delegate to.
Nothing on the binary the linker could not already see; the tests that
count writes do so through a writer of their own.

## Alternatives

**Flush per response, as before.** Correct and simple, and on a pipelined
request the syscall is most of the request. Rejected on the numbers above.

**Flush when the handler returns rather than in `send`.** Moves the flush
later by a few instructions and still pays it once a response.

**Skip the flush only when a complete next request is buffered.** Tighter
than "any bytes buffered" and would need the parser to look ahead on every
`send`. The looser check is safe either way, because a partial head leads
to a read, and the read flushes.

**Do it in the HTTP layer alone, with no Engine guarantee.** `waitForRequest`
could flush before it fills, the way the WebSocket's `park` has to anyway.
Rejected because it makes the safety of every skip depend on every read
site remembering, including body reads inside handlers and the WebSocket's
frame fills. A guarantee at the one place all reads pass is forty lines and
cannot be forgotten by the next read site.

**Ask zio for a flush-before-read hook.** The vtable swap is that hook,
done from outside, and costs zio nothing; an upstream option would only
save nilo the `@fieldParentPtr`.

## Consequences

- `http1.writeResponse` and `writeResponseHeadOnly` no longer flush;
  `http1.settle(out, in)` is the flush, and `Ctx.send`, `sendDirect` and
  `sendfile`'s HEAD path call it. `handleConnection` flushes before a
  connection ends. `websocket.Socket.settle` is the WebSocket half, `park`
  flushes before it waits, and `close` flushes always.
- `http/engine/zio.zig`: `Link` joins a connection's reader and writer and
  carries the swapped vtable. The Bulkhead's contract gains the line.
- Tests: `http1.zig` counts writes across a pipelined pair;
  `websocket.zig` counts them across sixteen buffered echoes, a lone one,
  and a close with a frame unread; `live.zig` sends two requests in one
  write over a real socket and reads both answers back with a receive
  timeout, which is the only test that reaches the Engine's half.
- the entry's `meta.json` can now carry `echo-ws-pipeline` (and
  `echo-ws-limited`, which ADR 200 made worth entering); the arena's
  `pipelined` column is reference-only and moves regardless.
- [`http.md`](../../bench/result/http.md#what-a-flush-per-response-costs-a-client-that-pipelines)
  carries the runs.
