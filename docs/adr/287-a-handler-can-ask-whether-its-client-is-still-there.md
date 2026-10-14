# A handler can ask whether its client is still there

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Extends:** [ADR 105](./105-a-route-can-say-how-long-it-has.md), whose `overdue()` is a question a running handler asks and is not interrupted by, and [ADR 227](./227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md), whose reason a hang-up can be read on a stream that never ends is generalised here.
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md),
[ADR 082](./082-a-cleanup-path-is-not-cancellable.md),
[ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md).
**Found by:** the photon port: a live tail that wakes on a timer held a connection slot for fifteen seconds after its tab closed, and a search kernel on a blocking worker ran for seconds for a client that had aborted its `fetch` (`docs/zig-rewrite/feedback-for-nilo.md` there, entries 21 and "A blocking call cannot learn that its request went away").

## Context

`error.Canceled` comes from a shutdown or a deadline. A client closing its connection in the middle of a handler produced neither, so the work ran to the end and its answer was written into a socket nobody read. Go's `r.Context().Done()` is what people arrive expecting.

The todo entry this closes said the obvious implementation is wrong, and it is: **a read-side EOF is not a client leaving.** A client that sent `Connection: close` and then `shutdown(SHUT_WR)` produces the same FIN a closed tab does, and is still waiting for its answer. TCP cannot tell them apart: a peer that called `close()` and one that called `shutdown(SHUT_WR)` both arrive as a FIN, and differ only once the server writes, when the closed one answers with a reset (measured over loopback with `poll(2)`: the first write to a closed peer succeeds, the second fails with `EPIPE`, and a half-closed peer reads what was written). So the answer is two signals and a rule for the first, and a question to ask again rather than a fact to keep.

Go's `net/http` starts a goroutine and a one-byte read for every request once its body is read (`connReader.startBackgroundRead`, `server.go`), and **any read error, EOF included, cancels the request's context**; a byte read is a pipelined request, which it deliberately does not treat as a departure, which also hides the hang-up behind it. HTTP/2 cancels a stream's context on `RST_STREAM` and when the stream is closed. That is a per-request cost on every route, whether or not the handler ever looks at the context, and it takes the half-close as a departure for everyone.

## Decision

**A handler asks. The answer comes from the kernel when it is asked, on HTTP/1.1 and from the connection's own state on HTTP/2, and a route that does not ask pays nothing.**

```zig
fn tail(c: *nilo.Ctx, feed: *Feed) !void {
    var events = try c.events();
    while (events.live()) {
        try events.sleep(1000);               // returns early when the tab closes
        if (feed.take()) |row| try events.send(.{ .data = row });
    }
}

fn search(c: *nilo.Ctx) !void {
    const hits = nilo.blocking(scan, .{});     // scan polls nilo.gone() between units of work
    …
}
```

1. **`nilo.Presence` is `here`, `half_closed` or `gone`.** `c.presence()` answers it, `c.gone()` is `presence() == .gone`. `half_closed` is a FIN from a client that said it had finished sending (`Connection: close`, or HTTP/1.0), or an HTTP/2 connection whose input ended with the call still running: it may be waiting for its answer. `gone` is a reset or an error, a FIN from a client that did not say it was finished (a closed tab, an aborted `fetch`), or an HTTP/2 `RST_STREAM` or lost connection.
2. **The rule for a FIN is the request's own words**, and it is stated as a weakness: a keep-alive client that half-closes to say "that was my request" is `gone`, and its work is abandoned; a client that sent `Connection: close` and then aborts is `half_closed` for ever, and its work is wasted but correct. The alternative, a FIN is always `half_closed`, leaves a tab close, which is a FIN, unanswered on HTTP/1.1. A per-route setting for it is not built; the three-valued answer is there for a handler that wants the other rule. **For an event stream a FIN is `gone` whatever the request said**, ADR 227's argument: a response that never ends has nothing for a half-closed client to wait for.
3. **HTTP/1.1 asks `poll(2)` with `POLLRDHUP` and nothing else, on the connection's socket** (`Wake.hangup` in `http/engine/zio.zig`, `Waker.hangup` in the Bulkhead). Not a peek: a FIN is reported while the bytes the peer sent before it are still unread, so a client that pipelined, or a TLS client whose `close_notify` is unread, does not hide its hang-up behind them (`MSG_PEEK` returns the bytes and says nothing of the FIN; measured, and a test holds it). `POLLERR` and `POLLHUP` are a reset. It reads nothing and is thread-safe, which is what lets a **blocking worker** ask from its own thread, through `nilo.gone()`, while the fiber that owns the socket is parked on it: the fiber cannot return, and so cannot close the descriptor, before the worker does. Nothing has to set a flag while the fiber is parked.
4. **`c.sleepUnlessGone(ms)` and `events.sleep(ms)` are the waits.** `nilo.sleep` that ends the moment the client is `gone`, returning `.elapsed` or `.gone`; `error.Canceled` stays the server's stop and the request's deadline, a different thing. A client that is `half_closed` does not end a `sleepUnlessGone`. `events.sleep` ends on either (any FIN or reset, since the stream never ends), and leaves `events.live()` false. On HTTP/1.1 the readable poll the connection already uses is armed for the length of the call, raced against the timer in the `CompletionQueue` `Wake.wait` uses, and cancelled on every way out, so a quiet client costs no wakeup before the timer. zio's `NetPoll` watches `POLLIN` only, which is complete at once while bytes are unread, and fires on bytes as well as a FIN: when bytes are pending, or the client speaks during the sleep, **the rest is slept in slices of one second, asking `hangup` between them**, so the hang-up is still found, at most a slice late. A `NetPoll` event for the hang-up is the upstream change that removes the slice (`docs/todo.md`).
5. **HTTP/2 already separated the two signals and this only reads them.** `Stream.departed` is stored by the connection's fiber before it wakes the call, at a `RST_STREAM` and when the connection is lost (`abortInbound(true)`, and a reset on the socket when the input ends); the connection's input ending without a reset sets `Shared.input_ended`, which is `half_closed`. It is its own atomic and not `Inbox.failure` (the first reason stands there) nor `Stream.reset` (a plain `bool`, the call's own). A client's `GOAWAY` is not a signal: it stops the sender's streams from being opened, and `streams up to the last identifier are still processed` ([RFC 9113 §6.8](https://www.rfc-editor.org/rfc/rfc9113#section-6.8): "allows an endpoint to gracefully stop accepting new streams while still finishing processing of previously established streams"). The sleep parks on the call's own `Inbox.wake`, which a reset already wakes. A gRPC unary call is such a stream, and `RST_STREAM(CANCEL)` is its client's cancel; a streaming call, when it comes, asks the same question of the same flag.
6. **`error.ClientGone` answers 499**, nginx's number, and the response is written into a socket that is not read, or read by a half-closed client that can still be told. It is a value a handler returns; nothing swallows it, and nothing is interrupted.
7. **TLS is the same question of the same socket.** What is watched is TCP under the record layer. A `close_notify` followed by a FIN is a FIN; a `close_notify` with no FIN after it (a TLS half-close) is not seen, and stays `here`. Which of a FIN, a reset, and an alert and a FIN a browser sends on a tab close over HTTP/1.1 and TLS is not known; a browser speaks HTTP/2 over TLS, where the signal is a `RST_STREAM`. WebSocket is out of scope: its loop already parks on the socket and sees a hang-up as a read.

The answer is **asked again, not kept**: a FIN is `half_closed` or `gone` by the request's words, and a write to a closed peer turns it into a reset, so a long wait asks again after it has written (an event stream's keep-alive comment is such a write).

## What was rejected

- **A background read for every request, as Go does.** One armed read per request on every route, whether it asks or not; a pending receive pins its buffer, which is ADR 062's axis (ADR 284); EOF as cancel for everybody; a byte read hides the hang-up behind it.
- **`MSG_PEEK`.** Returns the bytes, not the FIN behind them, so a pipelining client or an unread TLS alert hides a hang-up. Kept as nothing.
- **A flag set from a callback on the loop** (zio runs a completion's own `callback` before its queue's, so a poll with a callback and a pointer into the frame would write one). It would need a standing submission for every blocking call of a request that asked, fires uselessly on pipelined bytes, cannot see a FIN behind them, and adds a callback on the loop thread, to save a worker one `poll(2)`.
- **A second fiber per request watching the socket.** The figure in `Wake`'s comment from ADR 028, 8,673 bytes a connection, against a 4,669 byte floor.
- **Cancelling the fiber when the client goes.** ADR 105 and ADR 082: every wait in every handler, `Mutex`, Service and cleanup would have to survive a new cancel source, and a cancel does not reach a compute-bound worker (`blockInPlace` waits `.no_cancel` for the worker after one). It stays later work, with a Scope that carries `gone()` as `core.within` carries the deadline, so `nilo_sql` and `nilo_fetch` calls end when the client has (`docs/todo.md`).
- **A write probe**, a zero-length write or a 1xx interim response, to tell `close()` from `shutdown(SHUT_WR)` before the answer. A zero-length write elicits nothing, and a 1xx before the final response is legal and unknown to some clients and proxies.
- **`SO_KEEPALIVE` and `TCP_USER_TIMEOUT`.** They detect a dead path in minutes to hours, not a closed tab, which is a FIN that arrived.
- **Doing nothing and documenting a ping.** It stays right for a handler that does not want to change, and it keeps a slot until the next write and does nothing for a worker with no write to make.
- **`c.peer()`'s name.** It is already the address of the other end; the new answer is `presence()`.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0, for every route; `test "the request path stays inside its allocation budget"` unchanged. |
| Memory per idle connection | **0.** No field was added to `Wake` (528 bytes) or `InFlight` (328), asserted in `http/gone_live.zig`; `park-check` holds one page ([the run](../../bench/result/http.md#what-asking-whether-the-client-is-there-costs)). |
| Throughput and p99 | 0 for a route that does not ask: no branch, field, syscall or submission was added to the request path. A route that asks pays **75 to 77 ns** a `c.presence()` (one `poll(2)`, pinned, ReleaseFast, interleaved against a control); `sleepUnlessGone(1)` against `nilo.sleep(1)` is inside the timer's own spread. |
| Binary size | **+112 bytes** stripped `ReleaseFast` on `hello` and `rest`, +176 on `example-stream`. The two entries sit in a second vtable that only `Ctx.presence`, `Ctx.sleepUnlessGone` and `events.sleep` name (`Waker.watching`); in the one every connection names they cost +1,712. The stream holds its `Waker` and calls `watching` from `sleep` and nowhere else: a function pointer to the wait was 2,664 on `example-stream`. |

## What it breaks

Nothing. `nilo.Presence`, `c.presence()`, `c.gone()`, `c.sleepUnlessGone`, `events.sleep` and `nilo.gone()` are new; `Events.live()` also reads what `events.sleep` found, and a handler that never calls it sees the same value as before. A 499 is a status a handler's own `error.ClientGone` returns, which no handler returned before.
