# Responses

**A response is a value a handler's return type settles, held by the framework rather than pointed at, and put on the wire only when the connection would otherwise wait.** How to write one is the guide ([`guide/responses.md`](../guide/responses.md), [`guide/streaming.md`](../guide/streaming.md)); every wrapper and field is the reference ([`reference/handlers.md#handler-returns`](../reference/handlers.md#handler-returns)). The code is `http/headers.zig`, `http/redirect.zig`, `http/versioned.zig`, `http/bytebody.zig`, `http/stream.zig`, `http/date.zig` and `http/http1.zig` (`writeHead`, `settle`).

## How the pieces fit

```
  handler's return type ──► sendResult / sendValue ──► writeHead
    void, Str, T                200, empty/text/JSON      Date (always, unless the
    ?T                          200 or 404                handler set one)
    Status(code, T)             that status               Connection (only if it
    Response(T)                 status chosen at runtime  carries information)
    Redirect(code)              that status, Location      Content-Length, or
    FileBody / Bytes            a file, or bytes in hand    chunked framing
    Versioned(T)                200+ETag, or 304, no body
    T with nilo_write           200, T's own bytes                │
                                                                    ▼
                                                          out through settle():
                                                          flushed before the
                                                          connection next waits
                                                          for a read, not before
                                                          send() returns
```

A stream (`Ctx.stream`, `streamWith`) sits beside the table on the left: the handler holds it, writes pieces through one buffer taken once from the request arena, and `finish` says where the body ends.

## The rule in force

1. **`Response`, `Redirect` and `Versioned` hold their headers by value, not by slice.** `Headers.of(&.{…})` copies a list written at the call site into a fixed array of `room = 8`; a ninth is a compile error, and past eight there is `c.setHeader`, uncapped, which copies into the request arena immediately. [ADR 018](../adr/018-a-response-owns-its-headers.md)
2. **A long-lived response allocates nothing per piece.** A stream takes one buffer from the request arena when it opens and writes every piece through it; the request cost is 2 allocations whether it sends one piece or two hundred. A request body read with `bodyStream` allocates nothing at all, using a buffer the handler already owns. [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md)
3. **A stream is told to stop, not cut off.** `stream.live()` goes false when a shutdown starts, and a handler's loop is expected to check it; nothing is closed mid-frame, and a handler that never checks delays the drain for as long as it runs. [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md)
4. **A redirect's status is in the type.** `Redirect(303)` writes only 301, 302, 303, 307 or 308; anything else refuses to compile, naming what each is for. It carries `headers` the way `Response` does, and no body. [ADR 031](../adr/031-a-redirect-puts-its-status-in-the-type.md)
5. **A stream that knows its length says so.** `streamWith(status, ct, .{ .length = n })` sends `Content-Length` and no `Transfer-Encoding`; writing past the promise is refused before the overrun goes out, and finishing short closes the connection and logs both numbers rather than padding the body. [ADR 101](../adr/101-a-stream-that-knows-its-length-says-so.md)
6. **A type can write its own answer.** A type carrying both `nilo_content_type` and `nilo_write(self, *std.Io.Writer)` is dispatched after every wrapper is taken apart, so `?T`, `Status(code, T)` and `Response(T)` all work over it the way they do over JSON; nilo parses none of what it writes. [ADR 157](../adr/157-a-type-can-write-its-own-answer.md)
7. **Bytes already in hand are an answer of their own.** `Bytes { body, content_type, headers }` is `FileBody`'s shape with the file already in memory, for a proxy that hands on somebody else's download; the label is a runtime field, so the document says `application/octet-stream` with `format: binary`. [ADR 173](../adr/173-bytes-handed-on-are-an-answer.md)
8. **A version a handler names is a weak `ETag`.** `Versioned(T)` sends `T`'s version as `W/"<hex>"`; a request whose `If-None-Match` carries it gets 304 with no body, and `c.clientHas(version)` lets the handler skip building the value at all. `.unchanged` to a client that never sent the version is a 500 naming the route. [ADR 189](../adr/189-a-version-a-handler-names-is-an-etag.md)
9. **Every response head carries a `Date`, second after the status line**, on every path that writes one, unless the handler set its own. Formatted once a second per thread from a threadlocal cache, never from a task. [ADR 197](../adr/197-a-response-says-when-it-was-sent.md)
10. **`Connection` is written only when it says something**: HTTP/1.1 defaults to persistent, so `implied` writes nothing, and the line appears only for an HTTP/1.0 client being kept or a connection that is closing. [ADR 197](../adr/197-a-response-says-when-it-was-sent.md)
11. **A response is flushed before the connection next waits for a read, not before `send` returns.** If the client's next request (or WebSocket frame) is already in the read buffer, the response stays in the write buffer and leaves with the next one; a close frame and a connection that is ending always flush. The guarantee lives in the Engine's read path, not in the callers that skip. [ADR 201](../adr/201-a-response-is-flushed-before-the-connection-waits.md)
12. **A non-pipelining client is measured exactly as before.** With one request in the buffer, the buffer empties on parse and `send` flushes as it always did; a middleware's "after" half still cannot rewrite a response once `Ctx.send` has marked the request answered. [ADR 201](../adr/201-a-response-is-flushed-before-the-connection-waits.md)
13. **An event stream whose every event comes from Rooms is handed to the connection, not held by its handler.** `return c.eventsFrom(rooms, .{})` takes a seat in each room before the head (a full one is a 503), and the connection loop writes each post as an event, a comment every `keepalive_ms`, until the client sends anything or hangs up, or the server stops. It costs what an idle connection does, 5,184 bytes against 21,566 for a stream a handler holds. [ADR 227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)
14. **A client that comes back is caught up by a Room that keeps history.** `Room.Options.history` keeps the latest text posts, bounded by count and by `history_bytes`, and `c.eventsFrom` writes the ones after the client's `Last-Event-ID` before anything new, seated and copied under one lock; an id the Room does not have replays nothing. [ADR 229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md)

## Decisions

| ADR | What it decides |
|---|---|
| [018](../adr/018-a-response-owns-its-headers.md) | Headers are copied into the response by value, capped at 8, because a slice pointed at a handler's stack frame is a use-after-return |
| [019](../adr/019-a-request-that-lasts-is-still-one-request.md) | What a `Ctx` still means across a stream, an SSE feed, a large body or a WebSocket: memory, shutdown, the log line, HTTP/1.0 and HEAD |
| [031](../adr/031-a-redirect-puts-its-status-in-the-type.md) | `Redirect(code)` as a typed wrapper instead of a header a handler spells by hand |
| [101](../adr/101-a-stream-that-knows-its-length-says-so.md) | A stream that already knows its length sends `Content-Length` instead of chunked framing |
| [157](../adr/157-a-type-can-write-its-own-answer.md) | A type may declare its own content type and write its own bytes, for a consumer JSON cannot serve |
| [173](../adr/173-bytes-handed-on-are-an-answer.md) | `Bytes`, for content already in the handler's hand whose label is decided at run time |
| [189](../adr/189-a-version-a-handler-names-is-an-etag.md) | `Versioned(T)`: a handler-named `u64` becomes a weak `ETag`, and a match is a 304 with the body never built |
| [197](../adr/197-a-response-says-when-it-was-sent.md) | Every head carries a `Date`; `Connection` is written only when it carries information |
| [201](../adr/201-a-response-is-flushed-before-the-connection-waits.md) | A response flushes before the connection next waits for a read, not on every `send` |
| [227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md) | `c.eventsFrom`: a feed sits in Rooms and waits from the connection loop's frame; a client that speaks has gone; a binary post is counted, not sent |
| [229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md) | `Room.Options.history` and `Last-Event-ID`: what a Room said while a stream was away, written before anything new |

Beside this topic: the return-type family a `Redirect` and a `Versioned` join is [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md); a static file's own `ETag` and the `If-None-Match` comparison `Versioned` reuses is [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md); an idempotent route keeping a written, XML or `Bytes` answer for a replay is [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md); a WebSocket frame is a response held to the same length and flush rules, decided in [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md) and [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md); why a `*Ctx` handler returning `void` is the one shape the document cannot describe is [ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md); the fiber-bound failure slot a fail function reaches from anywhere is [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md); a deadline bounding one write rather than a response is [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md); the four axes every one of these ADRs prices against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md).

## Open

- **A typed shape for streaming**, so a handler that streams could return something that reads like `Response(T)` rather than asking for a `*Ctx`. Left open in [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md).
- **No read or header timeout.** A client that opens a stream and stops reading parks a fiber; [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md) bounds a write, not this. Named in [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md).
- **Backpressure beyond the socket's**, for a program that wants a queue with a drop or disconnect policy rather than a fiber that blocks on a full write buffer; a `Room` is the one answer built so far, in [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md).
