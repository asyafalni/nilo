# Responses

**A handler's return type decides its response; nilo holds the response by value rather than by pointer, and sends it only when the connection would otherwise start waiting.**

**Guide:** [Responses](../guide/responses.md), [Streaming](../guide/streaming.md) · **Reference:** [Handler returns](../reference/handlers.md#handler-returns)

The code is `http/headers.zig`, `http/redirect.zig`, `http/versioned.zig`, `http/bytebody.zig`, `http/stream.zig`, `http/date.zig` and `http/http1.zig` (`writeHead`, `settle`).

## Overview

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

A stream (`Ctx.stream`, `streamWith`) works alongside the table on the left: the handler holds it, writes pieces through one buffer taken once from the request arena, and `finish` marks the end of the body.

## Rules

1. **`Response`, `Redirect` and `Versioned` hold their headers by value, not as a slice.** `Headers.of(&.{…})` copies a list written at the call site into a fixed array with `room = 8`; a ninth header is a compile error. For more than eight there is `c.setHeader`, which has no limit and copies into the request arena immediately. [ADR 018](../adr/018-a-response-owns-its-headers.md)
2. **A long-running response allocates nothing per piece.** A stream takes one buffer from the request arena when it opens and writes every piece through it; the request costs 2 allocations whether it sends one piece or two hundred. A request body read with `bodyStream` allocates nothing, because it uses a buffer the handler already owns. [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md)
3. **A stream is asked to stop, not cut off.** `stream.live()` becomes false when shutdown starts, and the handler's loop is expected to check it. Nothing is closed in the middle of a frame; a handler that never checks delays shutdown for as long as it keeps running. [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md)
4. **A redirect's status is part of its type.** `Redirect(303)` only accepts 301, 302, 303, 307 or 308; anything else fails to compile with a message explaining what each is for. It carries `headers` like `Response`, and has no body. [ADR 031](../adr/031-a-redirect-puts-its-status-in-the-type.md)
5. **A stream that knows its length says so.** `streamWith(status, ct, .{ .length = n })` sends `Content-Length` and no `Transfer-Encoding`. Writing more than promised is rejected before the extra bytes go out; finishing short closes the connection and logs both numbers, instead of padding the body. [ADR 101](../adr/101-a-stream-that-knows-its-length-says-so.md)
6. **A type can write its own response.** A type with both `nilo_content_type` and `nilo_write(self, *std.Io.Writer)` is handled after every wrapper is unwrapped, so `?T`, `Status(code, T)` and `Response(T)` all work with it as they do with JSON. nilo does not parse anything it writes. [ADR 157](../adr/157-a-type-can-write-its-own-answer.md)
7. **Bytes you already have are a response type of their own.** `Bytes { body, content_type, headers }` is like `FileBody`, but with the content already in memory, for a proxy passing on someone else's download. The content type is a run-time field, so the document says `application/octet-stream` with `format: binary`. [ADR 173](../adr/173-bytes-handed-on-are-an-answer.md)
8. **A version number the handler provides becomes a weak `ETag`.** `Versioned(T)` sends `T`'s version as `W/"<hex>"`. A request whose `If-None-Match` contains it gets a 304 with no body, and `c.clientHas(version)` lets the handler skip building the value altogether. Returning `.unchanged` to a client that never sent the version is a 500 naming the route. [ADR 189](../adr/189-a-version-a-handler-names-is-an-etag.md)
9. **Every response head has a `Date` header, right after the status line**, on every path that writes a head, unless the handler set its own. It is formatted once a second per thread from a threadlocal cache, never by a separate task. [ADR 197](../adr/197-a-response-says-when-it-was-sent.md)
10. **`Connection` is written only when it adds information.** HTTP/1.1 connections are persistent by default, so `implied` writes nothing; the header appears only when an HTTP/1.0 client is kept alive or the connection is closing. [ADR 197](../adr/197-a-response-says-when-it-was-sent.md)
11. **A response is flushed before the connection next waits to read, not before `send` returns.** If the client's next request (or WebSocket frame) is already in the read buffer, the response stays in the write buffer and goes out together with the next one. A close frame and an ending connection always flush. This guarantee lives in the Engine's read path, not in each caller that skips a flush. [ADR 201](../adr/201-a-response-is-flushed-before-the-connection-waits.md)
12. **A client that does not pipeline sees exactly the same behaviour as before.** With one request in the buffer, the buffer empties on parse and `send` flushes as it always did. A middleware's "after" half still cannot rewrite a response once `Ctx.send` has marked the request answered. [ADR 201](../adr/201-a-response-is-flushed-before-the-connection-waits.md)
13. **An event stream fed entirely by Rooms is handed to the connection, not held by its handler.** `return c.eventsFrom(rooms, .{})` takes a seat in each room before the head is sent (a full room is a 503). The connection loop then writes each post as an event, and a comment every `keepalive_ms`, until the client sends anything or disconnects, or the server stops. It costs the same as an idle connection: 5,184 bytes, against 21,566 for a stream a handler holds. [ADR 227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)
14. **A Room that keeps history can catch up a client that reconnects.** `Room.Options.history` keeps the latest text posts, limited by count and by `history_bytes`, and `c.eventsFrom` writes those after the client's `Last-Event-ID` before anything new; seating and copying happen under one lock. An id the Room does not have replays nothing. [ADR 229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md)

## Decisions

| ADR | What it decides |
|---|---|
| [018](../adr/018-a-response-owns-its-headers.md) | Headers are copied into the response by value, up to 8, because a slice pointing at a handler's stack frame is a use-after-return |
| [019](../adr/019-a-request-that-lasts-is-still-one-request.md) | What a `Ctx` still means for a stream, an SSE feed, a large body or a WebSocket: memory, shutdown, the log line, HTTP/1.0 and HEAD |
| [031](../adr/031-a-redirect-puts-its-status-in-the-type.md) | `Redirect(code)` as a typed wrapper instead of a header written by hand |
| [101](../adr/101-a-stream-that-knows-its-length-says-so.md) | A stream that already knows its length sends `Content-Length` instead of chunked framing |
| [157](../adr/157-a-type-can-write-its-own-answer.md) | A type can declare its own content type and write its own bytes, for a client JSON cannot serve |
| [173](../adr/173-bytes-handed-on-are-an-answer.md) | `Bytes`, for content already in the handler's hands whose content type is decided at run time |
| [189](../adr/189-a-version-a-handler-names-is-an-etag.md) | `Versioned(T)`: a handler-provided `u64` becomes a weak `ETag`, and a match is a 304 without building the body |
| [197](../adr/197-a-response-says-when-it-was-sent.md) | Every head has a `Date`; `Connection` is written only when it carries information |
| [201](../adr/201-a-response-is-flushed-before-the-connection-waits.md) | A response flushes before the connection next waits to read, not on every `send` |
| [227](../adr/227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md) | `c.eventsFrom`: a feed sits in Rooms and waits in the connection loop's frame; a client that sends anything has left; a binary post is counted, not sent |
| [229](../adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md) | `Room.Options.history` and `Last-Event-ID`: what a Room posted while a stream was away is written before anything new |

Related topics: the return-type family that `Redirect` and `Versioned` belong to is [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md); a static file's own `ETag` and the `If-None-Match` comparison `Versioned` reuses are [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md); an idempotent route storing a written, XML or `Bytes` answer for replay is [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md); a WebSocket frame follows the same length and flush rules, decided in [ADR 021](../adr/021-a-websocket-is-a-handler-that-does-not-return.md) and [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md); why a `*Ctx` handler returning `void` is the one case the document cannot describe is [ADR 120](../adr/120-a-ctx-handler-that-returns-nothing-may-have-written-it.md); the fiber-bound failure slot that fail functions reach from anywhere is [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md); a deadline limiting one write rather than a whole response is [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md); the four axes every one of these ADRs is measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md).

## Open questions

- **A typed return for streaming**, so a streaming handler could return something like `Response(T)` instead of asking for a `*Ctx`. Left open in [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md).
- **No read or header timeout for streams.** A client that opens a stream and stops reading keeps a fiber parked; [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md) limits a write, not this. Named in [ADR 019](../adr/019-a-request-that-lasts-is-still-one-request.md).
- **Backpressure beyond the socket's own**, for a program that wants a queue with a drop or disconnect policy instead of a fiber that blocks on a full write buffer. A `Room` is the only answer built so far, in [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md).
