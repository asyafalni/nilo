# nilo_fetch

One page of [the reference](./README.md): calling somebody else's HTTP API.

## `nilo_fetch`

An HTTP client for calling somebody else's API from inside a request. A
**Fitting**: it borrows the event loop and owns no destination
([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

`std.http.Client` is the client — pool, HTTP/1.1, TLS. What this adds is the
policy a server needs and a script does not, in about sixty lines.

```zig
const fetch = @import("nilo_fetch");

var api: fetch.Client = .init(gpa, .{});
try app.provide(&api);

fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.postJson(c, "https://api.example.com/v1/charges", .{ .amount = 500 }, .{});
    if (res.status == .too_many_requests) return nilo.fail.status(503, "retry after {s}", .{res.header("retry-after") orelse "a while"});
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
| `client.send(c, method, url, body_or_null, .{})` | for a method the five above do not name. **The body decides the framing, not the method** ([ADR 174](../adr/174-the-body-decides-not-the-method.md)): a DELETE with a body sends it under its `content-length`, a POST with `null` sends `content-length: 0`. `error.HeadTooLong` is a body on a method std frames none for whose head did not fit the connection's buffer |
| `client.postJson(c, url, value, .{})` | `Response` — `value` written out with `std.json` into the Scope and sent under `content-type: application/json`, unless `headers` names one. `putJson`, `patchJson` and `sendJson(c, method, url, value, .{})` beside it. Text handed here is a Refusal: it would go out as one JSON string ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `fetch.withQuery(c, base, .{ .page = 2, .q = "a b" })` | `[]const u8` — `base?page=2&q=a%20b`, in the Scope, one allocation sized exactly. A field is an int, a bool, text or an optional of one (null left out); anything else is a Refusal naming the field. `&` after a base that has a `?` already ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `res.ok()` | `bool` — 2xx |
| `res.status` | `std.http.Status` |
| `res.body` | `Str`, in the Scope you passed. Goes when the request does |
| `res.headers` | `[]const u8`, the header block the answer arrived with, kept into the Scope ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)) |
| `res.header(name)` | `?[]const u8` — case-insensitively; null when the answer did not carry it. `Retry-After` off a 429, `ETag` for the next conditional GET, `Location` on a 201 |
| `res.json(T, c)` | `T`, parsed into the same Scope |

`c` is a Scope — the `*Ctx` a handler was given, or a `nilo.Run` where there is
no request. Handing over something that is neither is a Refusal naming the call.

**`Client.Settings`**, given to `init`:

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past it a caller waits for a permit rather than opening another connection — an HTTPS one holds 59,151 bytes |
| `timeout_ms` | 30,000 | how long one whole call may take. `0` is no limit. It fires with or without an Engine: under `listen()` the Engine cancels the fiber; on a client started with `nilo_start(io, .none)` each step of the call runs as a task of that `Io` and the task is cancelled — one thread hop per step, paid only there ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)) |
| `stall_ms` | 0 | how long the far end may say **nothing** before the call is `error.Stalled`: time since the last byte, not since the call began. `0` is no such bound. Composes with `timeout_ms`; the Engine's timer re-armed on every chunk, or the engineless wait re-read from the last byte ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)) |
| `max_body` | 8 MiB | a longer body is `error.BodyTooLarge`, enforced while reading |
| `max_drain` | 64 KiB | how much of an unread body is worth reading to keep a pooled connection. Past it the connection is dropped |
| `read_buffer_size` | 8 KiB | each connection's socket read buffer, and so how much one read brings in. std's default, passed through ([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)) |
| `forward_request_id` | true | a call made under a `*Ctx` sends the request's id as `X-Request-Id`, so the other side's log lines up with this one. A `Run` has no id and sends none; a call naming its own `X-Request-Id` in `headers` keeps it ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)) |

**`Client.Call`**, given per call: `headers`, and `timeout_ms` / `stall_ms` /
`max_body` to override the settings above for one call. A header in `headers` that std has
a slot for — `host`, `authorization`, `user-agent`, `content-type`,
`connection`, `accept-encoding` — is sent **once**, the caller's copy, rather
than beside std's ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)).

**An answer with no body by rule ends at its head.** A HEAD's answer, a 1xx,
a 204 and a 304 are complete at the blank line whatever `content-length` or
`transfer-encoding` say, so `send` returns an empty body at once and the
connection is kept ([ADR 176](../adr/176-an-answer-with-no-body-ends-at-its-head.md)).

**Errors worth naming.** `error.TimedOut` is this call's own deadline;
`error.Stalled` is `stall_ms` of nothing arriving while the peer holds the
socket; `error.Canceled` is the server shutting down underneath it, and the
three are told apart rather than guessed at. `error.RedirectRefused` is a 3xx
with a `Location` under an `Exchange` that made no decision about redirects
(`Client.get` and its siblings follow). `error.NotStarted` is a call made
before `listen()`; the client is finished at startup like any other service.

**A 4xx or a 5xx is a `Response`, not an error.** The call worked and the
service said no; only the caller knows which of those matters.

**The body is asked for uncompressed.** `send` sends
`Accept-Encoding: identity`, so `res.body` is the body rather than a gzip
stream. This differs from `std.http.Client`'s default, which advertises gzip
and then returns the compressed bytes from `Response.reader` — decompressing is
a separate call there, and a caller who does not make it gets unreadable bytes
and no error. Decompressing here would cost a 32 KiB flate window on the
handler's stack, which is per *connection*
([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), so identity is
the trade taken. A server that ignores the header and gzips anyway is an error
rather than a `Str` full of noise.

`examples/outbound/` is the whole of this against a real API, and
[`bench/result/fetch.md`](../../bench/result/fetch.md) is what it costs on each of
ADR 017's four axes.

**What it is not**: a retry policy, a circuit breaker or a rate limiter. Those
are decisions about somebody else's service and belong to whoever knows what
that service promises.

### `fetch.Target`

A service's base URL, standing headers and ceilings as a type of its own,
opened once on the client and asked for by type. Two services are two types
([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Stripe = fetch.Target("stripe", .{ .timeout_ms = 5_000, .max_in_flight = 8 });

fn charge(stripe: *Stripe, c: *nilo.Ctx, charge_id: nilo.Str) !fetch.Response {
    return stripe.get(c, "/v1/charges/{}", .{charge_id}, .{});
}
```

| | |
|---|---|
| `fetch.Target(name, .{…})` | a type. `name` tells two targets with the same options apart and is what the health route calls it; empty is a Refusal |
| `Stripe.open(&client, .{ .base, .authorization, .user_agent, .headers })` | `error.BaseNotAbsolute` for a base with no scheme or host, `error.BaseHasQuery` for one with a `?` or `#`; a trailing `/` is dropped. Every value is held, not copied |
| `app.provide(&stripe)` | starts the client under it at `listen()`; the client itself is provided only if a handler asks for it by that type |
| `stripe.get(c, path, args, .{})` | `Response` — and `post(c, path, args, body, .{})`, `put`, `delete`, `patch(c, path, args, body_or_null, .{})`, `send(c, method, path, args, body_or_null, .{})`, `postJson(c, path, args, value, .{})`, `putJson`, `patchJson`, `sendJson`: every call the client has, with a path in place of the URL and the same `Call` last |
| `stripe.url(c, path, args)` | `[]const u8`, the URL alone, in the Scope, one allocation sized exactly — for an `Exchange` begun on the client |
| `stripe.nilo_ready(scope)` | started is ready, unless the type names a `ready` path, which is then GET on every probe with anything but a 2xx reported |

**`fetch.target.Options`**, on the type: `max_in_flight` (0, no gate of its
own; otherwise this service's own semaphore, taken before the client's and
given back after), `timeout_ms`, `stall_ms`, `max_body` (each null for the
client's, and a `Call` still overrides for one call), `ready` (null, or a
path beginning with `/`).

**`path` is a comptime template.** `{}` is filled by position from a tuple
— `"/repos/{}/{}", .{ owner, name }` — with the count checked. `{name}` is
filled from a struct's field of that name, and **every field the template
does not name is a query param** under `withQuery`'s rules — `"/v1/charges/{id}/refunds",
.{ .id = id, .limit = 10, .cursor = cursor }` with a null cursor left out.
A segment is an int, a bool or text, encoded with `/` as data. A count that
disagrees, a name with no field, a tuple for a named segment, a struct for a
positional one, a template mixing the two, a segment of another type, and a
path not beginning with `/` are each a Refusal.

**Standing headers, and the call's over them.** `authorization` and
`user_agent` go through std's slot; a line in `Call.headers` naming either
goes instead ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)).
A line naming any other standing header shadows it. No allocation unless a
call with headers of its own meets a target with some, and then one.

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
| `ex.begin(client, .{…})` | `Head`: status, `content_length`, `content_type`, `header(name)` (case-insensitive), `ok()`, and `redirected` / `location(&buf)`: the `std.Uri` a followed redirect ended at, or null, and the same as one string. Its text lives in the `.follow` buffer the call was given ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)) |
| `head.keep(c)` | the same `Head` copied into the Scope, good after the body: one arena allocation the size of the header block ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)) |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing over `max` |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest into a `*std.Io.Writer`, and how many bytes |
| `ex.stream(w, limit)` | one chunk into `w`, at most `limit`, and how many bytes; `0` is the end. What one socket read handed over; inside both clocks, where the same call on `ex.reader` is not |
| `ex.discard()` | "I will not read this body; close the connection" — for the probe that got the whole file. `max_drain` stays a policy rather than a lever ([ADR 184](../adr/184-a-caller-that-knows-says-discard.md)) |
| `ex.end()` | required, and safe twice |

`Begin` takes `headers`, `host`, `authorization`, `content_type`, `user_agent`,
`timeout_ms`, `stall_ms`, a `body` of `.none` / `.slice` / `.stream`, and
`redirects`: `.refuse` (the default; a 3xx with a `Location` is
`error.RedirectRefused`), `.follow = &buf` (walked, three deep, resolved in
the buffer) or `.expose` (the 3xx as itself, which is what a signed request
and an S3 client want) ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)).
A name in `headers` that std has a slot for tells std to leave
the slot out, so the line goes once; the explicit fields are the form for a
caller who has the value and not a line, and a field *and* the line is two
lines ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)).
`transfer_buffer` is for a caller who reads buffered off `ex.reader` and for
nothing else: `take`, `readInto`, `pipe` and `stream` never fill it, and the
empty default is the ordinary call ([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)).

**It must not be copied once begun**: it holds a `std.http.Client.Request`.
Declare it, fill it where it stands, leave it there.

### `fetch.testing`

A canned server for a suite of your own: one real exchange over a loopback
socket on `std.Io.Threaded`, with no Engine anywhere. What the module's own
tests drive, exported ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn oneExchange(io: std.Io, gpa: std.mem.Allocator) !void {
    var canned = try fetch.testing.Canned.open(io);
    defer canned.close();
    canned.reply("429 Too Many Requests", "Retry-After: 30\r\n", "slow down");
    var served = try io.concurrent(fetch.testing.Canned.serveOne, .{&canned});
    defer served.cancel(io) catch {};

    var api: fetch.Client = .init(gpa, .{});
    defer api.deinit();
    try api.nilo_start(io, .none);

    var run: nilo.Run = .init(gpa);
    defer run.deinit();
    var buf: [64]u8 = undefined;
    const res = try api.get(&run, try canned.url(&buf), .{});
    try std.testing.expectEqualStrings("30", res.header("retry-after").?);
}
```

| | |
|---|---|
| `Canned.open(io)` | bound to port 0 on loopback, the kernel's answer read back; no port range to keep apart from anybody's |
| `canned.reply(status, headers, body)` | what `serveOne` answers: the status line after `HTTP/1.1 `, headers each ending in `\r\n` (`Content-Length` is written for you), the body as it is |
| `canned.url(&buf)` | `http://127.0.0.1:<port>/` |
| `canned.serveOne()` | accept one connection, read the request whole, answer, close. **Start it with `io.concurrent`**, never `io.async`, which may run it on your own thread and wait there for the connection you were about to make |
| `canned.request()` | the request head that arrived, one line per header, `\n` between |
| `canned.requestBody()` | the request body that arrived, up to a kilobyte |
| `canned.close()` | |

The client is finished with `nilo_start(io, .none)`, as `listen()` would
have done it; `.none` is "no Engine to arm a deadline on", and the client
then bounds the call itself ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)).
