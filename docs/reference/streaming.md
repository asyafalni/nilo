# Streaming

One page of [the reference](./README.md): a directory, a stream, events, a body read in pieces, a socket and a room.

## `Dir`

A directory, opened once and held open — what a service hands a `FileBody`.

| | |
|---|---|
| `Dir.open(path)` | `!Dir` — relative to the working directory the server runs in. Startup work |
| `d.close()` | |
| `d.openFile(name)` | `!File` — a name inside it, resolved by the kernel against the descriptor |
| `d.writeFileAtomic(name, bytes)` | `!void` — replace `name` with `bytes`, all of it or none of it |

Nothing here resolves a path, which is why a name is a name: `openFile` hands it
to the kernel with the directory, so there is no normalisation step to get
wrong. A symlink inside the directory is followed. `error.FileNotFound` is the
one open failure with a better answer than a 500, and a `FileBody` turns it into
the 404 a file that was never there gets.

## `Stream`

| | |
|---|---|
| `s.writeAll(bytes)` / `s.print(fmt, args)` / `s.json(value)` | append |
| `s.flush()` | push what's buffered |
| `s.live()` | false once the server is stopping |
| `s.finish()` | end the body — **required** |
| `s.writer` | a plain `std.Io.Writer` |

## `Events`

| | |
|---|---|
| `e.send(.{ .name = …, .id = …, .data = … })` | one event |
| `e.data(text)` | `data:` alone |
| `e.json(name, value)` | data as JSON |
| `e.comment(text)` | a line the client ignores |
| `e.retry(millis)` | the browser's reconnect delay |
| `e.live()` | false once the server is stopping |
| `e.close()` | |

## `Body`

| | |
|---|---|
| `b.read(&buf)` | `!?[]u8` — the next piece, `null` at the end |
| `b.writeTo(w)` | `!u64` — pump it all into a `std.Io.Writer` |
| `b.discardRest()` | |
| `b.seen()` | bytes read so far |
| `b.size()` | `?u64` — what the request announced; `null` if chunked |
| `b.reader` | a plain `std.Io.Reader` |

## `Socket`

| | |
|---|---|
| `s.receive()` | `!?Message` — the buffer is the executor's, lent for one message |
| `s.send(kind, data)` | `.text` or `.binary` |
| `s.sendText(text)` / `s.sendBinary(bytes)` | |
| `s.print(fmt, args)` | one text message, formatted — no buffer of your own |
| `s.json(value)` | one text message, serialised |
| `s.ping(data)` | |
| `s.close(code, reason)` | safe to call twice |
| `s.closedCleanly()` | whether the other end said goodbye |
| `s.live()` | false once the server is stopping |

`receive` returns `null` when the server is stopping, after telling the client
so with a 1001 — a message loop needs no shutdown branch of its own
([ADR 0052](../adr/0052-a-message-is-copied-once-and-framed-once.md)). `live()` is
for a handler doing work of its own between messages. Sending on a socket that
has already closed writes nothing rather than failing.

`c.upgradeWith(loop, state, .{ .idle_ms = 30_000 })` — how long this connection
may say nothing before nilo pings it. No answer by the end of the next stretch
closes it with 1001. Not a deadline: a quiet WebSocket is a working one, so
silence asks a question rather than ending anything. `0` waits forever.
`.max_message` is the ceiling on one message, 16 KiB by default; a frame
announcing more is refused with a 1009 before a byte of it is read.

`.origins` is **which pages may open this socket, and it defaults to yours
alone.** A browser applies no CORS to a WebSocket — no preflight, and it ignores
`Access-Control-Allow-Origin` — so the handshake is an ordinary GET that arrives
carrying the session cookie, and nothing but the server can refuse it
([ADR 0102](../adr/0102-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)).
An `Origin` that does not name the authority the request's `Host` named is a
403. The scheme is not compared, because TLS is terminated in front. A request
with no `Origin` at all — `curl`, a native client — is allowed, because the
ambient cookie this guards is a browser's.

```zig
// the page is on another host to the socket
return c.upgradeWith(chatLoop, room, .{ .origins = &.{"https://app.example.com"} });
// a public socket carrying nothing worth stealing
return c.upgradeWith(feedLoop, {}, .{ .origins = &.{"*"} });
```

`Close`: `.normal`, `.going_away`, `.protocol_error`, `.unsupported`,
`.invalid_payload`, `.policy`, `.too_big`, `.internal`, or a number.

## `Room`

Saying something to sockets a handler does not hold
([ADR 0038](../adr/0038-a-broadcast-rings-a-bell-it-does-not-write.md)). A
service like any other: provide one, take it by type.

```zig
var room = try nilo.Room.init(gpa);
defer room.deinit();
try app.provide(&room);

fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    return c.upgrade(chatLoop, room);
}

fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
    try room.join(socket);
    defer room.leave(socket);

    while (try socket.receive()) |message| {
        try room.say(message.kind, message.data);
    }
}
```

| | |
|---|---|
| `nilo.Room.init(gpa)` | `!Room` — 1,024 seats, backlog of 4 |
| `nilo.Room.initWith(gpa, .{ .seats = …, .backlog = … })` | `!Room` |
| `room.deinit()` | |
| `room.join(&socket)` | `!void` — `error.RoomFull` when every seat is taken |
| `room.leave(&socket)` | safe twice, safe without joining — pair it with `defer` |
| `room.say(kind, data)` | to everybody in the room, sender included |
| `room.sayText(text)` / `room.sayBinary(bytes)` | |
| `room.print(fmt, args)` | one text message, formatted into the post itself |
| `room.json(value)` | one text message, serialised |
| `room.count()` | how many connections are in it |
| `room.missed(&socket)` | posts this connection was too slow to take |
| `room.full = .drop_oldest` | or `.drop_newest`, when a connection's backlog fills |

The loop is the one an echo server writes: nothing in it mentions the other
connections, and nothing handles an incoming broadcast. `receive` writes those
out on the way past, from the fiber that owns the socket — which is why one
client that stops reading costs that client and nobody else.

`defer room.leave(&socket)` is not optional. Zig has no destructor, and a seat
nobody gives up is one the next connection cannot have.

Sizing a room generously is a memory decision and nothing else: `join` and
`say` both cost what the room *holds*, not what it was sized for, and a `say`
into an empty room allocates nothing at all
([ADR 0052](../adr/0052-a-message-is-copied-once-and-framed-once.md)).
