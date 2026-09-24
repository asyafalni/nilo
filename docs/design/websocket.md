# WebSockets

**A WebSocket is a handler that stops returning for a while, not a shape of its own.** How to write one is the guide ([`guide/websocket.md`](../guide/websocket.md)); every method and option is the reference ([`reference/streaming.md`](../reference/streaming.md#socket) for `Socket`, [`#room`](../reference/streaming.md#room) for `Room`). The code is `http/websocket.zig` (the handshake, the frame reader, `Socket`), `http/room.zig` (broadcast), and `http/testing.zig` (`Conversation`, for driving one from a test).

## How the pieces fit

```
  app.get("/chat", chat) ──► c.upgrade(loop, state)
                                  │  101, keepAlive() = false from here
                                  ▼
                             loop(socket, state)         an ordinary function, never returns
                                  │
                    ┌─────────────┴──────────────┐
                    ▼                             ▼
            socket.receive()               room.say(kind, data)
            one message, or null            one alloc, refcounted, framed
            (close, EOF, reset,              once, posted to every seat's ring
             or the server stopping)
                    │                             │
                    └───────────────┬─────────────┘
                                     ▼
                a post for THIS seat is written out by THIS
                fiber, inside receive(), on its way past
```

A message that is whole and already sitting in the connection's read buffer is unmasked and handed over from there; nothing else takes a buffer from `scratch.zig`'s free list until it must (fragmented, split across reads, or bigger than the read buffer).

## The rule in force

1. **A WebSocket handler is a plain function**, taking services by type like any route, registered with `app.get` like any route; `c.upgrade(loop, state)` is what makes it not return until the conversation ends. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
2. **The buffer `receive` fills is the one message ceiling.** `Options.max_message` (16 KiB by default) closes a frame that lies about being bigger with a 1009 before a byte of its payload is read. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
3. **Ping, pong and the closing handshake are answered inside `receive`**, never handed to the handler; a handler asks `closedCleanly()` to learn whether the other end said goodbye. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
4. **A client that is simply gone is not an error.** `receive` returns `null` for a close frame, a FIN, a reset between two frames, or the server stopping (which sends a 1001 first); a reset or a broken read in the *middle* of a frame is still `error.ReadFailed`. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md), [ADR 202](../adr/202-a-reset-between-frames-is-a-client-that-has-gone.md)
5. **Sending on a socket that has already closed writes nothing rather than failing**, the same reading applied the other way round. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md)
6. **A goodbye that is not a valid one is a framing error (1002), never echoed**: a close payload of one byte, an unassigned code, or a reason that is not UTF-8. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md), [ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)
7. **A handshake carrying `Origin` is refused with a 403 unless that origin is the request's own `Host`, or one the route listed in `Options.origins`.** A browser applies no CORS to a WebSocket, so this check is the server's or there is none; a request with no `Origin` at all is allowed. [ADR 080](../adr/080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)
8. **`Options.idle_ms` (30 s by default) is a question, not a deadline**: silence sends a ping, silence after an unanswered one closes with 1001; `0` waits forever. [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md), [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)
9. **A `Room` is a service like any other**: `join`, `say`, `leave`, taken by type. The speaker never writes to another socket; `say` copies a pointer into each seat and rings a bell, and the fiber that already owns a connection writes that connection's post out on its way past inside `receive`. [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)
10. **A post is one allocation, refcounted**, freed by whichever seat drains it last, framed once by the room rather than once per recipient; a broadcast costs what the room *holds* (via `roll`), never what it was sized for. [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md), [ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)
11. **A full backlog drops rather than disconnects**: `Full.drop_oldest` (the default) or `.drop_newest`; `room.missed(&socket)` reports the count, because a server never closes a connection for being slow. [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)
12. **`defer room.leave(&socket)` is always correct**: safe twice, safe on a socket that never joined, and its two locks are taken with `lockUncancelable` so a cancellation mid-broadcast cannot skip releasing the seat. [ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md)
13. **A `print` or `json` on a live socket is checked against what it actually wrote**: while the payload fits the write buffer, `Writer.end` gives an exact count, and a disagreement closes with 1011 instead of desynchronising every frame after it. [ADR 076](../adr/076-a-frame-that-lies-about-its-length-is-not-sent.md)
14. **A route can be driven from a test without a real socket**: `testing.Conversation` queues frames, runs the handshake and the loop, and hands back what the server said, decoded independently of the encoder; it is scripted, not interactive, so a conversation between two live sockets still needs `http/live.zig`. [ADR 091](../adr/091-a-websocket-route-can-be-driven-from-a-test.md)

## Decisions

| ADR | What it decides |
|---|---|
| [021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md) | A WebSocket is a handler; the buffer is the one ceiling; a vanished client is `null`, not an error |
| [035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md) | `Room`: the speaker never writes to another socket, a post is refcounted, the backlog policy |
| [046](../adr/046-a-message-is-copied-once-and-framed-once.md) | The copy and the unmask are one pass; a post is framed once by the room; a goodbye that lies is a framing error |
| [076](../adr/076-a-frame-that-lies-about-its-length-is-not-sent.md) | `print`/`json` check the second format pass against `Writer.end` and close rather than desync |
| [080](../adr/080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md) | `Origin` is checked against `Host` or `Options.origins`; no browser CORS applies here |
| [082](../adr/082-a-cleanup-path-is-not-cancellable.md) | `Room.leave` takes its locks with `lockUncancelable`, added to the Bulkhead |
| [091](../adr/091-a-websocket-route-can-be-driven-from-a-test.md) | `testing.Conversation`: scripted frames, decoded independently, against the public API |
| [202](../adr/202-a-reset-between-frames-is-a-client-that-has-gone.md) | A reset between frames is `null`, not a logged `ReadFailed`; a reset mid-frame still is |
| [216](../adr/216-a-message-that-arrived-whole-is-handed-over-where-it-lies.md) | A whole message already in the read buffer is unmasked and handed over there, taking no free-list buffer |

Beside this topic: a handler that ignores the server's stopping flag holds the deploy open, which is [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md); why a `std.log` call on a per-connection path is a lock every connection queues on is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md); why an assert cannot be the check in ADR 076 is [ADR 007](../adr/007-no-recover-middleware.md) (Zig cannot recover from a panic) and [ADR 032](../adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md) (a guard has to have been watched failing); TLS being terminated in front, which is why `Origin`'s scheme is not compared, is [ADR 027](../adr/027-tls-is-terminated-in-front.md).

## Open

- **The Autobahn suite (`wstest`) does not run against nilo yet.** The close-code and UTF-8 rules were written from RFC 6455 directly rather than from a failing report; wiring it up is on [the roadmap](../roadmap.md) as a known gap.
- **`permessage-deflate` is not implemented.** Negotiating it needs a compressor per connection, which is memory nilo has not budgeted, per [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md).
- **`Room.leave`'s narrow cancellation window has no test.** Reproducing it needs a broadcast in flight and a cancellation landing between two instructions, which the suite has no way to drive today, per [ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md).
- **A short-lived socket that sends large messages still pays an `mmap` a connection.** [ADR 216](../adr/216-a-message-that-arrived-whole-is-handed-over-where-it-lies.md) narrowed the free-list cost to that shape and says nothing has asked about it since.
