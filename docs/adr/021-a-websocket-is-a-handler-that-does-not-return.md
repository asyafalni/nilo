# A WebSocket is a handler that does not return yet

**Status:** accepted
**Topic:** [websocket](../design/websocket.md)

Everything else in nilo answers a request. A WebSocket stops being a request: after the 101 the connection carries frames in both directions until somebody closes it, and none of HTTP applies any more.

The temptation is a shape of its own — a registration API, a set of callbacks, an object with `onMessage` and `onClose`. That is what most frameworks do, and it means a WebSocket handler is not a handler, cannot take a service, cannot take a resolved value, and cannot be read next to the routes around it.

So it is a handler:

```zig
fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(echoLoop, {});
}

fn echoLoop(socket: *nilo.Socket) !void {
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}
```

> **The handler hands its loop back rather than running it** ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)). It is still a handler: it takes services and resolved values, and middleware runs in front of it. What moved is where the loop runs, from inside the request to the connection's own frame, because that is where an idle socket is cheap to keep.

`app.get("/ws", chat)` registers it, `room` arrives by type like any service, a `CurrentUser` would arrive the same way, and the middleware in front of it runs exactly as it does for anything else. What is different is only that it does not return for a while — which ADR 019 already had to have an answer for.

## There is one message ceiling, and it is `Options.max_message`

> **`Options.max_message` (16 KiB by default) is the message ceiling, and it is also the size of the buffer a message is collected into.** There is no second number.

A frame whose header announces more than is left under the ceiling is refused with `1009` before a byte of its payload is read, so a client announcing four gigabytes costs four bytes to refuse. Fragments are reassembled into one buffer and the total is checked as they arrive. The buffer is not the connection's: it is taken from the executor's free list when a message starts arriving and given back when the socket goes quiet (`http/scratch.zig`), and a message that arrived whole in the read buffer takes none ([ADR 216](./216-a-message-that-arrived-whole-is-handed-over-where-it-lies.md)).

### What was rejected

**An option beside a buffer the handler declared.** The first version had `Options.max_message` alongside the buffer passed to `receive`, and a test client found it: it sent 70 KB, the option said a megabyte was fine, the buffer was 4 KB, and the connection closed with `1009` for no reason visible anywhere in the handler. An option that can quietly contradict the code beside it is worse than no option.

**The handler's buffer as the only ceiling**, which is what replaced it. It had one number, and it cost that number per open socket for as long as the socket stayed open: the buffer was a local in a frame that lives for the whole connection, and a suspended fiber keeps its stack at the high-water mark. A socket that had received one 60 KiB message held 74,809 bytes idle against 13,375 for one that had not (`http/scratch.zig` has the measurement, [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) the reason). Moving the buffer onto the executor's free list made it one buffer per message in flight rather than one per connection, and a buffer nobody declares needs a size before anybody asks. So the option came back, this time as the only number rather than a second one.

## The protocol keeps itself alive, invisibly

Ping, pong and close are answered inside `receive`. A handler never sees them, because they are not messages — they are the protocol's own housekeeping, and every handler would write the same three branches.

That includes the closing handshake: a close frame is echoed before `receive` returns null, which is what stops a browser reporting an ordinary goodbye as an error. A control frame arriving in the middle of a fragmented message is handled without disturbing what has been collected, which is legal, happens, and is the kind of thing that only shows up under a real client.

## A client that vanishes is not an error

`receive` returns null both for a close frame and for a connection that simply stopped — a tab closed, a laptop lid shut, a network gone.

Making the second one an error would be more precise and worse: it is the *most common* way a WebSocket ends, and every handler in the world would open with a `catch` that treats it as normal. The loop shape should be the same for both, because what the handler does next is the same for both. `closedCleanly()` tells them apart afterwards, for the one handler in twenty that cares.

> **There is a third way now, and it is the same `null`** ([ADR 046](./046-a-message-is-copied-once-and-framed-once.md)). A server that has been asked to stop ends the conversation itself, with a 1001 to the client first. The argument is this section's, read once more: ADR 019 says a handler that ignores the stopping flag holds the deploy open, and leaving that to `if (!socket.live()) break;` in every loop is a rule stated somewhere it cannot be enforced. The same reading runs the other way too — **sending on a socket that has already closed writes nothing rather than failing**, because the other end closing between two of a handler's sends is exactly as unpreventable as a client vanishing.

## What is refused, and why it is refused properly

Every refusal sends a close frame with the right code before returning the error, because a connection that is dropped without one looks to the other end like a crash:

| | |
|---|---|
| An unmasked frame from a client | `1002` — either a broken client or something that is not a client |
| A reserved bit set | `1002` — an extension nobody negotiated |
| A continuation with nothing to continue | `1002` |
| Text that is not valid UTF-8 | `1007`, not `1002` — the framing was fine, the payload was not |
| A message bigger than `max_message` | `1009` |

> **One row was missing and its absence was worse than pedantry** ([ADR 046](./046-a-message-is-copied-once-and-framed-once.md)). A close frame carrying one byte, a code nobody assigned, or a reason that is not UTF-8 was *echoed* — so a server whose whole discipline here is "say goodbye properly" answered a broken goodbye by putting the same broken bytes back on the wire. It is a `1002` now, like every other framing error, and the reason nilo sends with a close of its own is cut on a character boundary rather than at the 123rd byte.

The UTF-8 check is the one that looks like pedantry and is not. Text frames are *defined* to be UTF-8; a handler that gets invalid bytes will pass them to something that breaks further away, where the cause is no longer visible.

## The thing this does not do: talking to a socket you do not hold

The chat example echoes. It does not broadcast, and that is the honest limit of what is here.

Sending to *other* connections needs a registry of live sockets and a way to write to one from a different fiber — and a connection's write buffer belongs to the fiber serving it, so a second fiber writing into it interleaves frames and corrupts the stream. Doing it properly means a per-socket outbox with its own lock, or a mailbox the owning fiber drains. That is Phoenix Channels, which ADR 014 named as the shape to borrow, and it is a project rather than a function.

It is recorded here rather than half-built, because a broadcast that works in a test and interleaves under load is worse than one that does not exist.

> **This is no longer true, and [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md) is how it stopped being.** A `nilo.Room` says things to sockets a handler does not hold, and the loop above is unchanged — `receive` writes out anything posted to this connection on its way past, so a handler still never sees a broadcast and never writes a branch for one. The registry is the Room's seats; the way to write to a socket from a different fiber is not to, which was the whole finding.
>
> **Both of the guesses below were wrong, and ADR 028 has the measurements.** The interleaving is real and a lock per socket does fix it — and fixes nothing else, because the writing is done by the *speaker's* fiber, which then blocks on the first connection that has stopped reading. That is not a locking problem and no lock granularity touches it. The second guess, a mailbox the owning fiber drains, is the right shape and is not reachable: it needs a wait that ends on either the socket becoming readable or a post arriving, and zio exports no way to park a fiber on a completion. What did come out of that work is `nilo.spawn`.

Also not here: `permessage-deflate` (negotiated in the handshake, and a compressor per connection is memory nilo has not budgeted), and any deadline at all — a client that opens a socket and never speaks holds a fiber until TCP gives up. That last one is the same hole ADR 019 recorded, and WebSocket makes it cheaper to exploit.

> **The hole is closed, by the answer this ADR already named.** `Options.idle_ms`, 30 seconds by default: silence sends a ping, and silence after an unanswered ping closes with 1001. Still not a deadline, for the reason given above — a quiet WebSocket is a working one, so the framework asks rather than assumes. What made it buildable was [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md), which gave the connection a wait that can carry a limit; before that there was no way to time a WebSocket read without also breaking the quiet-is-fine promise. Set it to `0` for the old behaviour.
>
> **Quiet between frames, not inside one.** The silence is waited on by the Socket's park, which asks the socket for readiness and reads nothing, and a ping goes out only with nothing buffered. So a client that stopped half way through a frame was never pinged and held its fiber for ever. Every read is of a frame already begun, so each read carries a limit of twice `idle_ms`, what a silent client gets between frames before it is closed: the ping's stretch and the one after it. `0` still waits forever. `test "a WebSocket is allowed to sit quiet between frames, and not inside one"` holds it.

## Consequences

- The connection cannot carry another HTTP request, which nilo arranges: `upgrade()` sets the same flag an unframed HTTP/1.0 stream sets, and `keepAlive()` is false from then on. A handler only has to return.
- A handshake that is missing something is a 400 naming the missing part — `Upgrade`, `Connection`, `Sec-WebSocket-Version`, `Sec-WebSocket-Key` — rather than framing nobody can read. Getting this wrong by hand is the normal way to meet WebSocket for the first time.
- **The logger was reporting a status nobody sent.** A handler failing after its 101 was logged as `500`, because the logger asked the error what status it mapped to without asking whether an answer had already gone out. It now uses the sent status when there is one, which fixes the same wrongness for a stream that fails mid-body.
- 5 of the 8 statuses `Close` names are ones nilo sends itself. The enum is left open (`_`) because a handler is entitled to send a code of its own.
