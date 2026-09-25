# Streaming

When the length of a response isn't known when the head goes out — a report being
generated, a file being assembled, tokens from a model — the handler writes it
instead of returning it.

## A response in pieces

```zig
fn report(c: *nilo.Ctx, db: *Db) !void {
    var body = try c.stream(200, "text/csv");
    for (db.rows()) |row| try body.print("{d},{s}\n", .{ row.id, row.name });
    try body.finish();
}
```

`Transfer-Encoding: chunked` is handled for you, the connection survives to carry
another request, and an HTTP/1.0 client — which has no chunked encoding — gets
the body unframed with `Connection: close`, because there the end of the body is
the end of the connection.

| | |
|---|---|
| `body.writeAll(bytes)` | append |
| `body.print(fmt, args)` | append, formatted |
| `body.json(value)` | serialise straight into the response |
| `body.flush()` | push what's buffered out now |
| `body.live()` | false once the server has been asked to stop |
| `body.finish()` | say where the body ends — **required** |
| `body.writer` | a plain `std.Io.Writer`, for anything that takes one |

**Nothing is allocated per piece** — one buffer when the stream opens, and that
is all, however long it runs. A streamed request costs two allocations whether it
writes 1 piece or 200
([ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md)).

`finish()` is required: it writes the marker saying where the body ends. Forget
it and nilo writes one so the connection stays usable, and logs that it had to.

`c.streamWith(200, "text/csv", .{ .buffer = 16 * 1024 })` for a different
buffer size; the default is 4 KB.

## Server-sent events

```zig
fn tokens(c: *nilo.Ctx, llm: *Llm) !void {
    var events = try c.events();
    while (events.live()) {
        const token = llm.next() orelse break;
        try events.send(.{ .name = "token", .data = token });
    }
    try events.json("done", .{ .finished = true });
    try events.close();
}
```

Every send flushes, so an event doesn't sit waiting for the one after it.
`Cache-Control: no-cache` and `X-Accel-Buffering: no` go out with the head — the
second is what stops an nginx in front holding the events back until a buffer
fills.

| | |
|---|---|
| `events.send(.{ .name = …, .id = …, .data = … })` | one event; a `data` spanning lines becomes one `data:` per line |
| `events.data(text)` | `data:` and nothing else |
| `events.json(name, value)` | an event whose data is `value` as JSON |
| `events.comment(text)` | a line the client ignores — for proxies that close a quiet connection |
| `events.retry(millis)` | how long the browser waits before reconnecting |
| `events.live()` | false once the server is stopping |
| `events.close()` | end the stream |

The browser side is `EventSource`, which needs nothing from you:

```js
const source = new EventSource("/tokens");
source.addEventListener("token", (e) => output.append(e.data));
```

A browser reconnecting sends `Last-Event-ID`, which is an ordinary request
header: `c.header("Last-Event-ID")`.

## A feed, where every event is somebody else's

Most event streams have nothing of their own to say: a browser opens one, and every event it will see is something another request said. For that, the handler does not need to stay. Put the streams in a [`Room`](../reference/streaming.md#room), say things into the room, and hand the stream over:

<!-- compiles -->
```zig
fn feed(c: *nilo.Ctx, news: *nilo.Room) !void {
    return c.eventsFrom(news, .{ .retry_ms = 5_000 });
}

fn publish(news: *nilo.Room, headline: nilo.Str) !void {
    try news.event(.{ .name = "headline", .data = headline.view() });
}
```

`eventsFrom` takes a seat in the room, writes the head and returns. From there the connection waits on the room the way an idle connection waits for its next request, and every `say`, `print`, `json` or `event` into the room goes out as an event, one chunk each. A comment goes out every 30 seconds while nothing is said, so a proxy that closes quiet connections sees this one speak (`.keepalive_ms`, `0` for none). The stream ends when the browser goes away or the server stops.

Pass a tuple for more than one room, `c.eventsFrom(.{ lobby, mine }, .{})`, and a stream hears all of them. A room can hold WebSockets and event streams together, so the chat room a socket speaks into can be the one a read-only page listens to. A binary message said into it reaches the sockets and is counted as missed for the streams, because an event is text.

**A browser that reconnects can be caught up.** It sends `Last-Event-ID`, the id of the last event it read, and a room made with `.history` keeps its latest text posts, including those said while nobody was listening. `eventsFrom` writes the ones after that id before anything new, and nothing is written twice:

```zig
var news = try nilo.Room.initWith(gpa, .{ .history = 256 });
```

Give every post in such a room an id, with `room.event(.{ .id = … })`: a post without one does not move the browser's last id, so it would be written again on the next reconnect. An id the room no longer has replays nothing ([ADR 229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md)).

**One user rather than everybody** is a key in a [`nilo.Rooms`](../reference/streaming.md#rooms) pool: `c.eventsFrom(.{ news, rooms.named(key) }, .{})` with the user's key, and `rooms.json(key, value)` from wherever the notification starts. The [WebSocket guide](./websocket.md#one-user-on-every-tab) has the rest.

When the handler does have something of its own to do between events, the tokens of a model as they arrive, say, that is `c.events()` above, and it costs what [holding one open](#what-it-costs-to-hold-one-open) costs.

## When you already know how long it is

A handler moving bytes out of something that has already counted them — an S3
object, an upstream response — should say so:

```zig
var body = try c.streamWith(200, object.content_type, .{ .length = object.len });
```

The head then carries `Content-Length` and no `Transfer-Encoding`, and the
pieces go out unframed. What that buys is not framing overhead: a browser
downloading a chunked response has nothing to draw a progress bar against, and
a `Range` against it cannot be answered at all — which is exactly the request a
large download makes when it resumes.

**A stream with a length is held to it.** Writing past the promise fails with
`error.WriteFailed` before a byte of the overrun goes out, because a client
reading a `Content-Length` stops there and everything after it is read as the
beginning of the next response. Finishing short cannot be refused — the head
has already gone — so the connection closes and the log names both numbers
([ADR 101](../adr/101-a-stream-that-knows-its-length-says-so.md)).

## Ending, on purpose and otherwise

`live()` is the one to know about. It goes false when the server has been asked
to stop, so a loop that checks it lets a deploy finish: measured with a client
mid-stream, `Ctrl-C` to process exit took **204 ms**, and the client got the
closing event rather than a dropped connection. A stream that ignores it holds
the shutdown open for as long as it runs — up to `shutdown_grace_ms`, after which
it is cut off.

The other way a stream ends needs no check: when the client goes away the next
write fails, and the error unwinds the handler.

## What it costs to hold one open

One fiber each, and **it is not the 4,669 bytes an idle connection costs.** A
stream is a handler that has not returned, so it holds its buffers — an idle
connection gives those back, a streaming one is using them — and it holds its
stack at the high-water mark of everything the handler has touched
([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). Turning
`read_buffer` and `write_buffer` down in `listen()` comes straight off it, which
it does not for an idle connection.

**A held stream measures 21,058 bytes**, against 4,674 for an idle keep-alive
connection on the same server and the same run
([`bench/result/http.md`](../../bench/result/http.md)). Ten thousand of them is
about 210 MB, and that is the floor rather than the total.

**Your handler's stack is added to it, one byte for one.** The same table has a
handler that touches 32 KiB before its first wait, and it measures 53,825 —
32,767 bytes more, which is the 32 KiB, held for as long as the stream is
because the frame holding it never unwinds. So measure your own handler with
`python3 bench/mem.py --port … --path … --hold` before planning ten thousand,
and keep what a streaming handler puts on its stack small.

**A feed handed to a room does not pay any of this.** `c.eventsFrom` returns from the handler before the stream waits, so it costs what an idle connection does, 5,184 bytes against 21,566 for a held stream measured on the same host the same afternoon, and whatever stack the handler touched first is given back ([ADR 227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)). If your events all come from somewhere else, that is the shape to plan ten thousand of.

A client that opens a stream and then stops reading is cut off by
`write_timeout_ms`, which bounds one write rather than the whole response — so a
stream sending an event a minute is inside the limit however long it runs. See
[Deploying](./deploying.md#deadlines).

## Testing one

A handler that writes its answer can't be tested by calling it — there's nowhere
for it to write. That's what the [test client](./testing.md#handlers-that-write-their-answer)
is for.

`zig build run-stream` is a working example: a streamed CSV report, an event
stream, and a chunked upload, browser page included.
