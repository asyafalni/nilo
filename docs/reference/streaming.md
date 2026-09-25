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

Text that runs over lines is split where the browser would split it, at LF, CRLF **and a lone CR**, so `data` and `comment` go out as one field per line and a value cannot start an event of its own. `name` and `id` are one line by definition: a CR or LF in either, or in `json`'s name, is `error.EventFieldBreaksLine`, and nothing is written.

### An event stream fed by Rooms

A feed, where every event is something said into a [`Room`](#room), does not need its handler to stay. `c.eventsFrom` seats the stream in the rooms, writes the head and returns, and the connection waits on the rooms from its own frame, the way it waits on a Socket: 5,184 bytes a stream rather than the 21,566 of a stream a handler holds ([ADR 227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)).

<!-- compiles -->
```zig
const Feeds = struct { lobby: nilo.Room, news: nilo.Room };

fn feed(c: *nilo.Ctx, feeds: *Feeds) !void {
    return c.eventsFrom(.{ &feeds.lobby, &feeds.news }, .{ .retry_ms = 5_000 });
}
```

| | |
|---|---|
| `c.eventsFrom(rooms, options)` | `rooms` is one `*nilo.Room` or a tuple of them; anything else, or an empty tuple, does not compile |
| `.keepalive_ms` | a comment this often while nothing is said; 30,000 by default, `0` for none |
| `.retry_ms` | `retry:`, sent once before anything else; null leaves the browser's own |

A text post (`say`, `sayText`, `print`, `json`) goes out as one event's `data`, and `room.event` adds `event:` and `id:`. A binary post is not an event: it is counted in the room's missed posts and not sent. A room whose seats are all taken is a 503 before the head. The stream ends when the client sends anything or hangs up, because an `EventSource` never speaks after its request, or when the server stops, after what was already queued. The same room can hold WebSockets and event streams together.

`rooms` can also name a key in a [`Rooms`](#rooms) pool, alone or in the tuple: `c.eventsFrom(.{ lobby, rooms.named(key) }, .{})`. A pool with no Room left for a new key is a 503 as well.

What it does not do is anything of the handler's own between events; that is `c.events()` above, which keeps the handler.

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
([ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)). `live()` is
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
([ADR 080](../adr/080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)).
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
([ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)). A
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
| `.history = n`, `.history_bytes = b` | keep the latest `n` text posts, `b` bytes at most (64 KiB by default), for an event stream coming back with `Last-Event-ID`; `0`, the default, keeps none ([below](#a-client-that-comes-back)) |
| `room.deinit()` | |
| `room.join(&socket)` | `!void` — `error.RoomFull` when every seat is taken |
| `room.leave(&socket)` | safe twice, safe without joining — pair it with `defer` |
| `room.say(kind, data)` | to everybody in the room, sender included |
| `room.sayText(text)` / `room.sayBinary(bytes)` | |
| `room.print(fmt, args)` | one text message, formatted into the post itself |
| `room.json(value)` | one text message, serialised |
| `room.event(.{ .name = …, .id = …, .data = … })` | one event: an event stream sends all three, a WebSocket gets `data` as text. `error.EventFieldBreaksLine` for a line break in `name` or `id` |
| `room.count()` | how many connections are in it |
| `room.missed(&socket)` | posts this connection was too slow to take |
| `room.full = .drop_oldest` | or `.drop_newest`, when a connection's backlog fills |

The loop is the one an echo server writes: nothing in it mentions the other
connections, and nothing handles an incoming broadcast. `receive` writes those
out on the way past, from the fiber that owns the socket — which is why one
client that stops reading costs that client and nobody else.

`defer room.leave(&socket)` gives the seat up as soon as the handler is done
with the room. When the loop returns, nilo gives up any seat still taken, so a
forgotten `leave` costs the seat until then and nothing after.

A socket can sit in as many rooms as it joins, and the one `receive` drains all of them: a lobby everybody hears and a room of one user's tabs, say. Joining a room it is already in does nothing, and leaving one keeps the rest. The chain of rooms lives in the seats rather than on the connection, so a second room costs a seat in that room and nothing on the socket ([ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)).

```zig
fn loop(socket: *nilo.Socket, rooms: Rooms) !void {
    try rooms.lobby.join(socket);
    defer rooms.lobby.leave(socket);
    try rooms.mine.join(socket);
    defer rooms.mine.leave(socket);

    while (try socket.receive()) |message| {
        try rooms.lobby.say(message.kind, message.data);
    }
}
```

Sizing a room generously is a memory decision and nothing else: `join` and
`say` both cost what the room *holds*, not what it was sized for, and a `say`
into an empty room allocates nothing at all
([ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)).

### A client that comes back

A browser that loses an event stream reconnects by itself and sends `Last-Event-ID`, the `id` of the last event it read. A Room made with `.history` keeps its latest text posts, including those said while nobody was in it, and `c.eventsFrom` writes the ones that followed that id before anything new ([ADR 229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md)). The seat and the copy are taken under one lock, so nothing is written twice and nothing said in between is missed.

<!-- compiles -->
```zig
fn ticker(c: *nilo.Ctx, prices: *nilo.Room) !void {
    return c.eventsFrom(prices, .{});
}

fn publish(prices: *nilo.Room, seq: u64, quote: []const u8) !void {
    var digits: [20]u8 = undefined;
    try prices.event(.{ .id = try std.fmt.bufPrint(&digits, "{d}", .{seq}), .data = quote });
}
```

- A post is found by its `id`, so give every post in a room that keeps history one. A `say` carries none, and a browser that read it still reports the id before it, so it would be written again.
- An id the room no longer has, or never had, replays nothing. Guessing would send somebody events twice.
- A stream in several rooms reports the id of whichever spoke last, so only that room catches it up.
- Only text posts are kept, and a post bigger than `history_bytes` on its own is not.
- A WebSocket sends no `Last-Event-ID`; history is for event streams.

## `Rooms`

Rooms by name, lent from a pool made up front, for a key the application makes up: every tab a user has open joins `"user:42"`, and anything that wants to reach that user says into the key ([ADR 228](../adr/228-a-room-for-a-key-is-lent-from-a-pool.md)).

<!-- compiles -->
```zig
fn notifications(c: *nilo.Ctx, rooms: *nilo.Rooms, me: *const Me) !void {
    var key: [32]u8 = undefined;
    return c.eventsFrom(rooms.named(try std.fmt.bufPrint(&key, "user:{d}", .{me.id})), .{});
}

fn notify(rooms: *nilo.Rooms, user: u64, unread: u32) !void {
    var key: [32]u8 = undefined;
    try rooms.json(try std.fmt.bufPrint(&key, "user:{d}", .{user}), .{ .unread = unread });
}

const Me = struct { id: u64 };
```

| | |
|---|---|
| `nilo.Rooms.init(gpa)` | `!Rooms`: 1,024 Rooms of 8 seats, backlog of 4 |
| `nilo.Rooms.initWith(gpa, .{ .rooms, .seats, .backlog, .history, .history_bytes, .full })` | `!Rooms`, every Room made here |
| `rooms.deinit()` | |
| `rooms.join(key, socket)` | `!void`: `error.NoRoomFree` when every Room is lent, `error.RoomFull` when the key's seats are taken, `error.KeyTooLong` past `nilo.rooms.max_key` (64) |
| `rooms.leave(key, socket)` | safe twice, safe without joining; the socket's other rooms keep their seats |
| `rooms.say(key, kind, data)`, `sayText`, `sayBinary`, `print`, `json`, `event` | as on a Room; nothing, and no allocation, for a key nobody is under |
| `rooms.count(key)` | connections under it, `0` for a key with no Room |
| `rooms.missed(key, socket)` | as on a Room |
| `rooms.named(key)` | the key as something `c.eventsFrom` sits a stream in |

A key has a Room only while somebody is under it. The last one out gives the Room back, whether by `leave` or by nilo giving up what a loop left behind. A pool made with `.history` is the exception: a Room that keeps history keeps its key once it empties, which is when a user who is coming back needs it, and is lent to another key only when the pool has no Room that was never lent, the one that went quiet first going first. What it kept is forgotten before then.

Nothing is allocated for a key after `init`, so the pool costs what it was sized for, a seat's worth of bytes times `rooms` times `seats`, whether anybody connects or not. A Room is never lent under a new key while anything could still say into it under the old one.
