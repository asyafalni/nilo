# Streaming

**The types for answering in pieces and holding connections open: a directory, a stream, server-sent events, a request body read in pieces, a WebSocket, and rooms that broadcast to them.**

**Guide:** [Streaming](../guide/streaming.md), [WebSocket](../guide/websocket.md), [Static files](../guide/static-files.md) · **Design:** [WebSockets](../design/websocket.md), [Responses](../design/responses.md), [Static files](../design/static-files.md)

## `Dir`

**A directory, opened once and kept open**: what a service gives a `FileBody`.

| | |
|---|---|
| `Dir.open(path)` | `!Dir`, relative to the server's working directory. Do this at startup |
| `d.close()` | |
| `d.openFile(name)` | `!File`: a name inside it, resolved by the kernel against the directory descriptor |
| `d.writeFileAtomic(name, bytes)` | `!void`: replaces `name` with `bytes`, all of it or none of it |

**Nothing here resolves a path, so a name is only a name.** `openFile` passes it to the kernel together with the directory, so there is no normalisation step to get wrong. A symlink inside the directory is followed. `error.FileNotFound` is the one open failure with a better answer than a 500, and a `FileBody` turns it into a 404.

## `Stream`

| | |
|---|---|
| `s.writeAll(bytes)` / `s.print(fmt, args)` / `s.json(value)` | append |
| `s.flush()` | send what is buffered |
| `s.live()` | false once the server is stopping |
| `s.finish()` | ends the body. **Required** |
| `s.writer` | a plain `std.Io.Writer` |

## `Events`

| | |
|---|---|
| `e.send(.{ .name = …, .id = …, .data = … })` | one event |
| `e.data(text)` | a `data:` field alone |
| `e.json(name, value)` | data as JSON |
| `e.comment(text)` | a line the client ignores |
| `e.retry(millis)` | the browser's reconnect delay |
| `e.live()` | false once the server is stopping |
| `e.close()` | |

**Multi-line text is split where the browser would split it**: at LF, CRLF **and a lone CR**. So `data` and `comment` are sent as one field per line, and a value cannot start an event of its own. `name` and `id` are single lines by definition: a CR or LF in either, or in `json`'s name, returns `error.EventFieldBreaksLine`, and nothing is written.

### An event stream fed by Rooms

**A feed where every event is something said into a [`Room`](#room) does not need its handler to stay running.** `c.eventsFrom` seats the stream in the rooms, writes the head and returns, and the connection waits on the rooms from its own frame, the same way it waits on a Socket. That costs 5,184 bytes a stream, instead of the 21,566 of a stream a handler holds ([ADR 227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)).

<!-- compiles -->
```zig
const Feeds = struct { lobby: nilo.Room, news: nilo.Room };

fn feed(c: *nilo.Ctx, feeds: *Feeds) !void {
    return c.eventsFrom(.{ &feeds.lobby, &feeds.news }, .{ .retry_ms = 5_000 });
}
```

| | |
|---|---|
| `c.eventsFrom(rooms, options)` | `rooms` is one `*nilo.Room` or a tuple of them; anything else, or an empty tuple, does not compile. A request already answered is `error.AlreadyAnswered` |
| `.keepalive_ms` | sends a comment this often while nothing is said. 30,000 by default, `0` for none |
| `.retry_ms` | `retry:`, sent once before anything else. Null leaves the browser's default |

A text post (`say`, `sayText`, `print`, `json`) is sent as one event's `data`, and `room.event` adds `event:` and `id:`. A binary post is not an event: it is counted in the room's missed posts and not sent. If all of a room's seats are taken, the request gets a 503 before the head is sent. The stream ends when the client sends anything or disconnects (an `EventSource` never sends anything after its request), or when the server stops, after sending what was already queued. The same room can hold WebSockets and event streams together.

`rooms` can also name a key in a [`Rooms`](#rooms) pool, alone or in the tuple: `c.eventsFrom(.{ lobby, rooms.named(key) }, .{})`. A pool with no Room left for a new key also answers 503.

What it cannot do is run any of the handler's own code between events. For that, use `c.events()` above, which keeps the handler running.

## `Body`

| | |
|---|---|
| `b.read(&buf)` | `!?[]u8`: the next piece, `null` at the end |
| `b.writeTo(w)` | `!u64`: copies all of it into a `std.Io.Writer` |
| `b.discardRest()` | |
| `b.seen()` | bytes read so far |
| `b.size()` | `?u64`: what the request announced; `null` if chunked |
| `b.reader` | a plain `std.Io.Reader` |

**`read`, `writeTo` and `discardRest` fail with `error.BodyTruncated`, a 400, when the connection ends while bytes are still owed**, so an upload cut short is never stored as a whole one. `null` from `read` is always the real end ([ADR 083](../adr/083-a-body-is-taken-as-it-arrives.md)).

## `Socket`

| | |
|---|---|
| `s.receive()` | `!?Message`. The buffer belongs to the executor and is lent for one message |
| `s.send(kind, data)` | `.text` or `.binary`. Posts waiting from a room this socket sits in leave first, so what you said into a room and then sent arrives in that order |
| `s.sendText(text)` / `s.sendBinary(bytes)` | |
| `s.print(fmt, args)` | one text message, formatted, with no buffer of your own |
| `s.json(value)` | one text message, serialised |
| `s.ping(data)` | `data` is cut to 125 bytes, the most a control frame holds |
| `s.close(code, reason)` | safe to call twice |
| `s.closedCleanly()` | whether the other side closed properly; a malformed close frame is not a goodbye |
| `s.live()` | false once the server is stopping |

**`receive` returns `null` when the server is stopping**, after telling the client with a 1001, so a message loop needs no shutdown branch of its own ([ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)). `live()` is for a handler doing its own work between messages. Sending on a socket that has already closed writes nothing instead of failing.

`Close`: `.normal`, `.going_away`, `.protocol_error`, `.unsupported`, `.invalid_payload`, `.policy`, `.too_big`, `.internal`, or a number.

### `c.upgradeWith` options

**`.idle_ms` is how long this connection may send nothing before nilo pings it**: `c.upgradeWith(loop, state, .{ .idle_ms = 30_000 })`. No answer by the end of the next interval closes it with 1001. It is not a deadline: a quiet WebSocket is a working one, so silence triggers a check, not a close. `0` waits forever. `.max_message` is the limit on one message, 16 KiB by default; a frame announcing more is refused with a 1009 before any of it is read.

**`.origins` is which pages may open this socket, and by default it is only yours.** A browser applies no CORS to a WebSocket (no preflight, and it ignores `Access-Control-Allow-Origin`), so the handshake is an ordinary GET that arrives with the session cookie, and only the server can refuse it ([ADR 080](../adr/080-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)). An `Origin` that does not match the authority in the request's `Host` gets a 403. The scheme is not compared, because TLS is terminated in front. A request with no `Origin` at all (`curl`, a native client) is allowed, because the cookie this protects is a browser's.

```zig
// the page is on another host to the socket
return c.upgradeWith(chatLoop, room, .{ .origins = &.{"https://app.example.com"} });
// a public socket carrying nothing worth stealing
return c.upgradeWith(feedLoop, {}, .{ .origins = &.{"*"} });
```

## `Room`

**Sends to sockets a handler does not hold** ([ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)). It is a service like any other: provide one, and take it by type.

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
| `nilo.Room.init(gpa)` | `!Room`: 1,024 seats, backlog of 4 |
| `nilo.Room.initWith(gpa, .{ .seats = …, .backlog = … })` | `!Room` |
| `.history = n`, `.history_bytes = b` | keeps the latest `n` text posts, at most `b` bytes (64 KiB by default), for an event stream reconnecting with `Last-Event-ID`. `0`, the default, keeps none ([below](#a-client-that-comes-back)) |
| `room.deinit()` | |
| `room.join(&socket)` | `!void`: `error.RoomFull` when every seat is taken |
| `room.leave(&socket)` | safe to call twice, and safe without joining. Pair it with `defer` |
| `room.say(kind, data)` | to everybody in the room, sender included |
| `room.sayText(text)` / `room.sayBinary(bytes)` | |
| `room.print(fmt, args)` | one text message, formatted into the post itself. If the two formatting passes disagree nothing is posted and the call is `error.WriteFailed` |
| `room.json(value)` | one text message, serialised |
| `room.event(.{ .name = …, .id = …, .data = … })` | one event: an event stream gets all three fields, a WebSocket gets `data` as text. `error.EventFieldBreaksLine` for a line break in `name` or `id` |
| `room.count()` | how many connections are in it |
| `room.missed(&socket)` | posts this connection was too slow to take |
| `room.full = .drop_oldest` | or `.drop_newest`: what happens when a connection's backlog fills |

**The loop is the one an echo server writes.** Nothing in it mentions the other connections, and nothing handles an incoming broadcast: `receive` writes those out as it goes, from the fiber that owns the socket. That is why one client that stops reading costs only that client.

`defer room.leave(&socket)` gives up the seat as soon as the handler is done with the room. When the loop returns, nilo gives up any seat still taken, so a forgotten `leave` holds the seat until then and no longer.

### Several rooms

**A socket can sit in as many rooms as it joins, and one `receive` drains all of them**, for example a lobby everybody hears and a room of one user's tabs. Joining a room it is already in does nothing, and leaving one keeps the rest. The list of rooms lives in the seats, not on the connection, so a second room costs a seat in that room and nothing on the socket ([ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md)).

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

**Sizing a room generously only costs memory**: `join` and `say` both cost what the room *holds*, not what it was sized for, and a `say` into an empty room allocates nothing at all ([ADR 046](../adr/046-a-message-is-copied-once-and-framed-once.md)).

### A client that comes back

**A Room made with `.history` lets a reconnecting event stream catch up.** A browser that loses an event stream reconnects by itself and sends `Last-Event-ID`, the `id` of the last event it read. A Room with `.history` keeps its latest text posts, including those said while nobody was in it, and `c.eventsFrom` writes the ones after that id before anything new ([ADR 229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md)). Taking the seat and copying the history happen under one lock, so nothing is written twice and nothing said in between is missed.

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

- A post is found by its `id`, so give every post in a room that keeps history an id. A `say` has none, and a browser that read it still reports the id before it, so it would be sent again.
- An id the room no longer has, or never had, replays nothing. Guessing would send somebody events twice.
- A stream in several rooms reports the id from whichever room spoke last, so only that room catches it up.
- Only text posts are kept, and a single post bigger than `history_bytes` is not kept.
- A WebSocket sends no `Last-Event-ID`; history is for event streams.

## `Rooms`

**Rooms by name, lent from a pool made up front**, for keys the application invents: every tab a user has open joins `"user:42"`, and anything that wants to reach that user says into that key ([ADR 228](../adr/228-a-room-for-a-key-is-lent-from-a-pool.md)).

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
| `nilo.Rooms.initWith(gpa, .{ .rooms, .seats, .backlog, .history, .history_bytes, .full })` | `!Rooms`, with every Room made here |
| `rooms.deinit()` | |
| `rooms.join(key, socket)` | `!void`: `error.NoRoomFree` when every Room is lent, `error.RoomFull` when the key's seats are taken, `error.KeyTooLong` past `nilo.rooms.max_key` (64) |
| `rooms.leave(key, socket)` | safe to call twice, and safe without joining; the socket's other rooms keep their seats |
| `rooms.say(key, kind, data)`, `sayText`, `sayBinary`, `print`, `json`, `event` | as on a Room. For a key nobody is under, they do nothing and allocate nothing |
| `rooms.count(key)` | connections under the key, `0` for a key with no Room |
| `rooms.missed(key, socket)` | as on a Room |
| `rooms.named(key)` | the key in the form `c.eventsFrom` takes |

**A key has a Room only while somebody is under it.** When the last connection leaves, by `leave` or by nilo cleaning up what a loop left behind, the Room goes back to the pool. A pool made with `.history` is the exception: a Room that keeps history keeps its key after it empties, which is exactly when a returning user needs it. It is lent to another key only when the pool has no never-used Room left, starting with the one that went quiet first, and what it kept is forgotten at that point.

**Nothing is allocated for a key after `init`**, so the pool costs what it was sized for (a seat's worth of bytes, times `rooms`, times `seats`) whether anybody connects or not. A Room is never lent under a new key while anything could still say into it under the old one.
