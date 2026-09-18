# nilo_fetch

One page of [the reference](./README.md): calling somebody else's HTTP API.

## `nilo_fetch`

An HTTP client for calling somebody else's API from inside a request. A
**Fitting**: it borrows the event loop and owns no destination
([ADR 0070](../adr/0070-a-fitting-borrows-the-loop.md)).

`std.http.Client` is the client — pool, HTTP/1.1, TLS. What this adds is the
policy a server needs and a script does not, in about sixty lines.

```zig
const fetch = @import("nilo_fetch");

var api: fetch.Client = .init(gpa, .{});
try app.provide(&api);

fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.post(c, "https://api.example.com/v1/charges", "amount=500", .{});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

| Call | |
|---|---|
| `client.get(c, url, .{})` | `Response` |
| `client.post(c, url, body, .{})` | `Response` |
| `client.put(c, url, body, .{})` | `Response` |
| `client.delete(c, url, .{})` | `Response` |
| `client.patch(c, url, body_or_null, .{})` | `Response` — `null` for the verb endpoint whose whole request is its path |
| `client.send(c, method, url, body_or_null, .{})` | for a method the five above do not name. **The body decides the framing, not the method** ([ADR 0213](../adr/0213-the-body-decides-not-the-method.md)): a DELETE with a body sends it under its `content-length`, a POST with `null` sends `content-length: 0`. `error.HeadTooLong` is a body on a method std frames none for whose head did not fit the connection's buffer |
| `res.ok()` | `bool` — 2xx |
| `res.status` | `std.http.Status` |
| `res.body` | `Str`, in the Scope you passed. Goes when the request does |
| `res.json(T, c)` | `T`, parsed into the same Scope |

`c` is a Scope — the `*Ctx` a handler was given, or a `nilo.Run` where there is
no request. Handing over something that is neither is a Refusal naming the call.

**`Client.Settings`**, given to `init`:

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past it a caller waits for a permit rather than opening another connection — an HTTPS one holds 59,151 bytes |
| `timeout_ms` | 30,000 | how long one whole call may take. `0` is no limit. It fires with or without an Engine: under `listen()` the Engine cancels the fiber; on a client started with `nilo_start(io, .none)` each step of the call runs as a task of that `Io` and the task is cancelled — one thread hop per step, paid only there ([ADR 0230](../adr/0230-a-deadline-with-no-engine-cancels-a-task.md)) |
| `max_body` | 8 MiB | a longer body is `error.BodyTooLarge`, enforced while reading |
| `max_drain` | 64 KiB | how much of an unread body is worth reading to keep a pooled connection. Past it the connection is dropped |
| `forward_request_id` | true | a call made under a `*Ctx` sends the request's id as `X-Request-Id`, so the other side's log lines up with this one. A `Run` has no id and sends none; a call naming its own `X-Request-Id` in `headers` keeps it ([ADR 0196](../adr/0196-a-request-id-goes-out-with-the-call.md)) |

**`Client.Call`**, given per call: `headers`, and `timeout_ms` / `max_body` to
override the settings above for one call. A header in `headers` that std has
a slot for — `host`, `authorization`, `user-agent`, `content-type`,
`connection`, `accept-encoding` — is sent **once**, the caller's copy, rather
than beside std's ([ADR 0231](../adr/0231-a-header-std-owns-goes-out-once.md)).

**An answer with no body by rule ends at its head.** A HEAD's answer, a 1xx,
a 204 and a 304 are complete at the blank line whatever `content-length` or
`transfer-encoding` say, so `send` returns an empty body at once and the
connection is kept ([ADR 0215](../adr/0215-an-answer-with-no-body-ends-at-its-head.md)).

**Errors worth naming.** `error.TimedOut` is this call's own deadline;
`error.Canceled` is the server shutting down underneath it, and the two are
told apart rather than guessed at. `error.NotStarted` is a call made before
`listen()` — the client is finished at startup like any other service.

**A 4xx or a 5xx is a `Response`, not an error.** The call worked and the
service said no; only the caller knows which of those matters.

**The body is asked for uncompressed.** `send` sends
`Accept-Encoding: identity`, so `res.body` is the body rather than a gzip
stream. This differs from `std.http.Client`'s default, which advertises gzip
and then returns the compressed bytes from `Response.reader` — decompressing is
a separate call there, and a caller who does not make it gets unreadable bytes
and no error. Decompressing here would cost a 32 KiB flate window on the
handler's stack, which is per *connection*
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)), so identity is
the trade taken. A server that ignores the header and gzips anyway is an error
rather than a `Str` full of noise.

`examples/outbound/` is the whole of this against a real API, and
[`bench/result/fetch.md`](../../bench/result/fetch.md) is what it costs on each of
ADR 0018's four axes.

**What it is not**: a retry policy, a circuit breaker or a rate limiter. Those
are decisions about somebody else's service and belong to whoever knows what
that service promises.

### `fetch.Exchange`

The four calls above hold the whole body in the Scope, which is right for an
API answering JSON and wrong for anything measured in megabytes. An `Exchange`
is the same policy with the body left on the socket: **read the response head,
decide, then move the bytes somewhere that is not memory.**

```zig
var ex: fetch.Exchange = .idle;
defer ex.end();

const head = try ex.begin(client, .{ .method = .GET, .url = url });
if (head.content_length) |n| if (n > ceiling) return error.TooLarge;
_ = try ex.pipe(&body.writer);   // straight out, allocating nothing
```

| | |
|---|---|
| `ex.begin(client, .{…})` | `Head` — status, `content_length`, `content_type`, `header(name)` (case-insensitive), `ok()`, and `redirected` / `location(&buf)`: the `std.Uri` a followed redirect ended at, or null, and the same as one string. Its text lives in the `redirect_buffer` the call was given ([ADR 0232](../adr/0232-a-followed-redirect-says-where-it-ended.md)) |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing over `max` |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest into a `*std.Io.Writer`, and how many bytes |
| `ex.discard()` | "I will not read this body; close the connection" — for the probe that got the whole file. `max_drain` stays a policy rather than a lever ([ADR 0235](../adr/0235-a-caller-that-knows-says-discard.md)) |
| `ex.end()` | required, and safe twice |

`Begin` takes `headers`, `host`, `authorization`, `content_type`, `user_agent`, `timeout_ms`,
a `body` of `.none` / `.slice` / `.stream`, and the two buffers — an empty
`redirect_buffer` means redirects are not followed, which is what a signed
request wants. A name in `headers` that std has a slot for tells std to leave
the slot out, so the line goes once; the explicit fields are the form for a
caller who has the value and not a line, and a field *and* the line is two
lines ([ADR 0231](../adr/0231-a-header-std-owns-goes-out-once.md)). **The buffers are the caller's because their cost is the
caller's stack**, and by
[ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md) that is per
connection.

**It must not be copied once begun**: it holds a `std.http.Client.Request`.
Declare it, fill it where it stands, leave it there.
