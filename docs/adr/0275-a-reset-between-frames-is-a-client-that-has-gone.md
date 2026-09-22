# 0275 — a reset between frames is a client that has gone

**Status:** accepted
**Applies:** [ADR 0022](./0022-a-websocket-is-a-handler-that-does-not-return.md)
(a client that vanished is not an error the handler writes a branch for),
[ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md)
(a `std.log` call on a connection path costs what it costs every connection),
[ADR 0273](./0273-every-executor-accepts.md).
**Found by:** running HttpArena's `echo-ws-limited` shape on this box
before subscribing to it: 512 connections, each closed after ten frames,
through [gcannon](https://github.com/MDA2AV/gcannon), which closes every
connection under `-r` with `SO_LINGER` at zero. The server after ADR 0273
read **461K frames a second against 874K before it**, with 10,000
descriptors open for 512 clients and a warning in the log for every
connection.

## Context

`Socket.receive` returns `null` when the client has gone. ADR 0022 made
that the rule: a tab closed and a network dropped are the same thing to a
handler's loop, so neither is an error to branch on, and the loop ends the
way it ends for a close frame. What "gone" meant in the code was a FIN,
`EndOfStream` from the reader between two frames. A **reset** between two
frames took the other path, `ReadFailed`, up through the handler's `try`
and out to `warnSocketFailed`: "the WebSocket loop on /ws failed:
ReadFailed", once per connection.

A reset is how a great many clients leave. A load generator closes with
`SO_LINGER {1, 0}` so that its ports do not sit in `TIME_WAIT`, and
gcannon does exactly that on every connection of the two `limited`
profiles, which means the arena's `echo-ws-limited` column is a reset per
connection by construction. A browser tab killed rather than closed, a
phone that lost its signal, a proxy that gave up: none of them sends a FIN
either. The handler cannot do anything with the news, and the log line
says "failed" about a loop that did nothing wrong, which is the same
misreport ADR 0023 removed from the write side.

What made it worse than noise is where the line was written. `std.log`
takes the process's one stderr lock and holds it for the format and the
`write(2)`; under zio the lock parks the fiber rather than the thread, so
the executors keep running, and what they keep running is `accept`. Every
connection's way out now queued on one lock, one line at a time, and a
fiber waiting for its turn to write holds the socket it is about to
close. Measured, the shape looked like this:

| server | stderr | frames/s, 512 conns | descriptors open mid-run | connections made, of which upgraded |
|---|---|---|---|---|
| `7e084ce`, one acceptor, warning per reset | a file | 878K | 10,014 | 542K, 445K |
| | `/dev/null` | 1.18M | 323 | 590K, 600K |
| `0efa4c0`, every executor accepts, warning per reset | a file | **454K** | **10,025** | **2.6M, 233K** |
| | `/dev/null` | 708K | 10,021 | 2.4M, 360K |
| every executor accepts, no warning on a reset | a file | **1.70M** | 560 | 851K, 863K |

The one acceptor had been throttling intake to about what the lock could
pass, and even so the descriptors piled up once the line went to a file.
With eight acceptors, connections arrived faster than their predecessors
could get through the lock whatever stderr was, the reset sockets piled up
to `max_connections`, the server started refusing at accept, and
gcannon's instant retry of a refused connection turned the refusals into
2.4M connection attempts in five seconds for 233K that got as far as a
handshake, most of them work for the server and none of them frames.
`/dev/null` says it was not the disk: the lock and the format were enough.
ADR 0273 alone made this column worse by half, and that was found by
running the shape before entering it rather than after.

## Decision

**A read that fails on an empty buffer, between two frames, ends the
conversation the way `EndOfStream` does.** `receive` returns `null`,
`closedCleanly` answers false, nothing is written to a peer that cannot
hear it, and nothing is logged. `fillHeader` is the one place a read can
fail with nothing half-read, and it checks `bufferedLen() == 0` before
the read; a failure with bytes already in hand is still a truncated
frame and still `ReadFailed`, by the rule that stood.

The distinction the WebSocket layer cannot make, and does not need to, is
*why* the read failed. A WebSocket has no read deadline (`readForever`,
set at the upgrade); silence is the `park`'s to measure, with its own
ping. So between frames, a read that fails is a connection that broke,
whichever error the kernel put on it.

Same box, `ReleaseFast`, server on CPUs 0–7 and gcannon on 8–15,
interleaved pairs, `0efa4c0` → after (this and ADR 0274):

| shape | before | after |
|---|---|---|
| WS echo, 512 conns × 10 frames | 461K / 469K frames/s, p50 340 µs, p99 640–670 µs | **1.67M / 1.69M**, p50 69–86 µs, p99 380 µs |
| WS echo, 4,096 conns × 10 frames | 286K / 283K, p50 5.4 ms, p99 6.8 ms | **1.58M / 1.58M**, p50 270 µs, p99 1.1–1.2 ms |

3.6× and 5.5×, and 1.9× over the one-acceptor server the column would
have been entered with. No warnings in the log across 1.7M connections
but one, below.

## What it costs

Nothing per frame: one `bufferedLen` compare on the path that was already
about to read from the socket. A handler that wanted to know a client
left by reset rather than by FIN cannot; `closedCleanly` says "not by a
close frame" for both, which is what it said before for a FIN, and
nothing in the guide ever promised the difference.

**What it does not change:** a reset in the *middle* of a frame is still
`ReadFailed` and still logged, because the layer cannot tell a client
that died mid-send from one that sent half a frame and stopped, and the
second is a broken peer worth a line. If that line ever shows at rate,
the same argument applies to it.

## Alternatives

**Log it at `debug` instead of `warn`.** Still formats under the lock on
every connection at any level that is on, and the line was never
actionable at any level.

**Rate-limit the warning.** Hides the symptom and keeps the lock; and the
first line would still say a loop "failed" that did not.

**Ask the Engine which error it was and treat only `ConnectionResetByPeer`
as gone.** Needs a new Bulkhead call for a distinction nothing above the
Bulkhead would act on differently; a read with no deadline that fails is
a broken connection whatever the errno.

**Keep the one acceptor for WebSocket servers.** It was hiding this by
throttling, at 874K frames a second against 1.68M.

## Consequences

- `http/websocket.zig`: `fillHeader` checks `between` before the read.
  Two tests, one for a reset between frames and one for a reset inside
  one, on a `Reset` reader that fails the way a reset socket fails.
- the entry's `meta.json` subscribes `echo-ws-limited` and
  `echo-ws-pipeline`; the README beside it says what each waited on.
- The rule to carry forward is ADR 0071's, sharpened: **a `std.log` call
  on a per-connection path is one lock every connection queues on**, and
  a client-caused event on that path is never a line in the log.
- One line remains, at 0.05–0.1% of short-lived connections on both HTTP
  and WebSocket: "handler … failed after answering: WriteFailed", a
  response written to a client already reset. It is older than this ADR
  and the roadmap carries the measurement.
- [`http.md`](../../bench/result/http.md#a-reset-between-frames-is-a-client-that-has-gone)
  carries the runs.
