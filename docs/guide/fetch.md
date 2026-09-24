# Calling somebody else's API

`nilo_fetch` is an HTTP client for the inside of a handler: a payment
provider, a geocoder, a webhook, somebody's JSON API. It is
`std.http.Client` — the pool, HTTP/1.1, TLS — with the policy a server needs
and a script does not put in front of it, in about sixty lines
([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

It is a **Fitting**: it borrows the event loop and owns no destination. A
`sql.Db` holds a pool to one database named in its URL; a `fetch.Client` is
handed an address on every call and holds no connection to any named system,
which is what lets one client serve every API a program talks to.

```zig
const fetch = @import("nilo_fetch");
```

and in `build.zig`, beside `nilo_http`:

```zig
.{ .name = "nilo_fetch", .module = nilo.module("nilo_fetch") },
```

## One call

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Receipt = struct { id: []const u8, amount: u64 };

fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.post(c, "https://api.example.com/v1/charges", "amount=500", .{});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

and in `main`, once:

```zig
var api: fetch.Client = .init(gpa, .{});
defer api.deinit();
try app.provide(&api);
```

The client is a [service](./services.md): registered once, asked for by type.
**One is enough for the whole program** — the pool inside it is keyed by
host, so calls to three different APIs share it without knowing about each
other, and a second client would load the certificate bundle a second time.

`c` is a Scope: the `*Ctx` a handler holds, or a [`nilo.Run`](../reference/core.md#run)
where there is no request — a startup path, a ticker, a test. The body comes
back as a `Str` in that Scope's arena, so it lives exactly as long as the
request does and nothing is freed by hand.

| Call | |
|---|---|
| `api.get(c, url, .{})` | `Response` |
| `api.post(c, url, body, .{})` | `Response` |
| `api.put(c, url, body, .{})` | `Response` |
| `api.delete(c, url, .{})` | `Response` |
| `api.patch(c, url, body_or_null, .{})` | `Response` |
| `api.send(c, method, url, body_or_null, .{})` | for a method the five above do not name |
| `api.postJson(c, url, value, .{})` | `Response` — `value` written out as JSON, `content-type` said for you. `putJson`, `patchJson`, `sendJson` beside it |

**Most APIs take JSON, so the value goes as itself.** `postJson` writes it
out with `std.json` into the Scope's arena — the one allocation every caller
was already paying to `std.json.Stringify.valueAlloc` by hand — and says
`content-type: application/json`, unless your `headers` name one, which then
goes instead. What `res.json(T, c)` is for the way in, this is for the way
out ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn chargeJson(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.postJson(c, "https://api.example.com/v1/charges", .{
        .amount = 500,
        .currency = "idr",
    }, .{});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

A body you already have as text is refused here while compiling — `std.json`
would write it out as *one JSON string*, quotes and escapes and all, and the
far end would answer 400 to a body that looked right in your editor. That one
goes through `post`.

**A query string is a struct, and the encoding is done for you.**
`fetch.withQuery(c, base, params)` answers the URL with the params on the
end of it, percent-encoded, in the Scope's memory — one allocation, sized
exactly. A field is an int, a bool, text (a `[]const u8`, a string literal,
a `Str`) or an optional of one, where null is the param left out; anything
else is a Refusal naming the field. A base that already has a `?` gets `&`.

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn search(api: *fetch.Client, c: *nilo.Ctx, q: nilo.Str, page: u32) !fetch.Response {
    const url = try fetch.withQuery(c, "https://api.example.com/search", .{
        .q = q, // "a b" goes as a%20b, "a/b" as a%2Fb
        .page = page,
        .cursor = @as(?[]const u8, null), // left out
    });
    return api.get(c, url, .{});
}
```

The URL is what every call takes, `Exchange.begin` included, which is why
this is a function and not a field on the call. A path segment —
`/v1/charges/{id}` with the id encoded on the way in — needs a base for the
path to hang off, and that is a [target](#a-service-as-a-type): the same
struct is then the query, and the segments come out of it by name.

The last argument is a `Call` — per-call overrides, every field null, so
`.{}` is the ordinary case:

| Field | |
|---|---|
| `headers` | `[]const std.http.Header`, written to the wire in this order. One that std has a slot for — `host`, `authorization`, `user-agent`, `content-type`, `connection`, `accept-encoding` — is sent once, this copy, rather than beside std's own ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)) |
| `timeout_ms` | this call's own deadline, over the client's |
| `stall_ms` | this call's own ceiling on silence, over the client's |
| `max_body` | this call's own body ceiling, over the client's |

**Headers you did not choose.** A `headers` taken off a pasted `curl` line
carries `user-agent`, `host` and `authorization` as strings, and std writes
each of those for itself. Hand them over as they are: nilo tells std to leave
its own copy out, and the list of what std owns is nilo's to know rather
than yours. The one to know about is `accept-encoding` — the line goes as
written, but the client still decodes nothing, so a server that obliges a
`gzip` gets `error.HttpContentEncodingUnsupported` rather than handing you
a `Str` full of gzip. Leave it out and the client asks for identity itself.

## Reading the answer

| | |
|---|---|
| `res.status` | `std.http.Status` |
| `res.ok()` | `bool` — 2xx |
| `res.body` | `Str`, in the Scope's arena. Goes when the request does |
| `res.header(name)` | `?[]const u8`, case-insensitively; null when the answer did not carry it |
| `res.headers` | the whole header block, kept into the Scope beside the body |
| `res.json(T, c)` | `T`, parsed into the same Scope. Unknown fields are ignored |

**The answer's headers came back with it.** `Retry-After` on a 429, `ETag`
for the next conditional GET, `Location` on a 201, `Link` on an API that
pages by header, `X-RateLimit-Remaining` before deciding whether to make the
next call: `res.header("retry-after")` reads any of them after the call,
because the block was kept into the Scope before the body read over it. It
is the same copy `head.keep(c)` makes on an `Exchange`, made for you here
because a whole-body call has no other moment to make it — one arena
allocation the size of the block, beside the body's own
([ADR 187](../adr/187-a-head-that-outlives-its-body.md)).

**A 4xx or a 5xx is a `Response`, not an error.** The call worked and the
service said no; only the caller knows which of those matters and what to
say about it. The distinction is worth a `switch`, because the far end's
status is not yours to forward:

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Repo = struct {
    full_name: []const u8,
    stargazers_count: u64,
};

const GitHub = fetch.Target("github", .{ .timeout_ms = 2_000 });

fn stars(github: *GitHub, c: *nilo.Ctx, owner: nilo.Str, name: nilo.Str) !u64 {
    const res = github.get(c, "/repos/{}/{}", .{ owner, name }, .{}) catch |err| switch (err) {
        error.TimedOut => return nilo.fail.status(504, "github took longer than 2s", .{}),
        else => return err,
    };

    if (!res.ok()) return switch (@intFromEnum(res.status)) {
        404 => nilo.fail.notFound("no repository {s}/{s}", .{ owner.view(), name.view() }),
        403, 429 => nilo.fail.status(502, "github is rate-limiting this address; retry after {s}", .{
            res.header("retry-after") orelse res.header("x-ratelimit-reset") orelse "a while",
        }),
        else => nilo.fail.status(502, "github answered {d}", .{@intFromEnum(res.status)}),
    };

    const repo = res.json(Repo, c) catch
        return nilo.fail.status(502, "github sent something this program cannot read", .{});
    return repo.stargazers_count;
}
```

Four things in there are the habits worth keeping. **Text from a request
going into a URL is percent-encoded**, never pasted — `%2e%2e%2f` in a path
param is how a caller reaches an endpoint you never meant to offer, and each
`{}` in a target's path is encoded on the way in with `/` as data, by the
same `nilo.percent` a query goes through
([ADR 057](../adr/057-percent-is-needed-by-two-layers.md)). **`error.TimedOut`
gets its own arm**, because it is the one failure every caller of anything
has to have an answer for, and 504 says *the thing I asked is slow* where 500
would say *I am broken*. **A refusal says when to come back**, because the
header that carries that is on the answer and one call away. And **the
struct you parse into is what your program depends on**, not a
transcription of the far end's schema: `Repo` names two of GitHub's hundred
fields, and the parse ignores the rest.

[`examples/outbound`](../../examples/outbound/main.zig) is that handler with
a `main` around it, against GitHub's public API.

## A service as a type

A program that calls Stripe from six handlers writes Stripe's host, its
`authorization` and the seconds it gets six times, and there is nowhere on
the client to write them once — the client is one for the whole program,
because the pool is in it. **A target is that sentence as a type**: two
services are two types, opened once on the client, and a handler asks for
the one it wants the way it asks for a database
([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

const Stripe = fetch.Target("stripe", .{ .timeout_ms = 5_000, .max_in_flight = 8 });

const Refund = struct { id: []const u8, amount: u64 };

fn refund(stripe: *Stripe, c: *nilo.Ctx, charge_id: nilo.Str) !Refund {
    const res = try stripe.postJson(c, "/v1/charges/{}/refunds", .{charge_id}, .{ .amount = 500 }, .{});
    if (!res.ok()) return nilo.fail.status(502, "stripe said no", .{});
    return res.json(Refund, c);
}
```

and in `main`, once, beside the client:

```zig
var stripe = try Stripe.open(&api, .{
    .base = cfg.stripe_base, // https://api.stripe.com
    .authorization = cfg.stripe_key,
});
try app.provide(&stripe);
```

**What is on the type is what is true of the service wherever the program
runs**; what is given to `open` is the deployment's. The split is
[the one a bucket makes](./s3.md): the name, the clocks and the ceilings are
Stripe's, and the base URL and the key come from a `Config`, because a
sandbox host with a test key in development and the real pair in production
is one binary rather than two.

| On the type | Default | |
|---|---|---|
| `max_in_flight` | 0 | calls to this service at once, under the client's own ceiling. `0` is no gate of its own. Set it for the slow third party, so its calls queue at its own gate rather than holding the permits every other service shares |
| `timeout_ms` | the client's | this service's own deadline; a `Call` still overrides it for one call |
| `stall_ms` | the client's | likewise, for silence |
| `max_body` | the client's | likewise, for the body |
| `ready` | null | a path the [health route](./deploying.md#knowing-whether-it-is-ready) GETs on every probe, with a 2xx as ready. Null is started-is-ready, because a balancer asks every second and a call to somebody else's API at that rate is a bill and a rate limit rather than a check |

| Given to `open` | |
|---|---|
| `base` | `https://api.stripe.com`, or `https://api.sandbox.example.com/v2` — scheme, host, and a path prefix if there is one. No query, no fragment; a trailing `/` is dropped. `error.BaseNotAbsolute` and `error.BaseHasQuery` otherwise |
| `authorization` | sent on every call, unless the call's own `headers` name one |
| `user_agent` | likewise |
| `headers` | anything else the service always wants — `accept`, an API version, a tenant. A call's own line of the same name goes instead of it |

Every call the client has, the target has with a **path** in place of the
URL: `get`, `post`, `put`, `delete`, `patch`, `send`, `postJson`,
`putJson`, `patchJson`, `sendJson`, and `url(c, path, args)` for the URL
alone — an `Exchange` begun on the client, a link written into a response.

**The path is a template, read while compiling.** `{}` is a segment filled
by position from a tuple, and the count is checked: two `{}` and one
argument is a compile error rather than a 404 from the far end. A segment is
an int, a bool or text, and text is percent-encoded with `/` as data, so an
id off a request that says `../admin` is one segment rather than a walk.

**Name the segments and the same struct is the query.** `{id}` is filled
from the field `id`, and every field the template does not name goes on the
end as a query param under `withQuery`'s rules — an optional that is null is
left out:

<!-- compiles -->
```zig
fn refunds(stripe: *Stripe, c: *nilo.Ctx, charge_id: nilo.Str, cursor: ?nilo.Str) !fetch.Response {
    // GET /v1/charges/<charge_id>/refunds?limit=20, and &starting_after=… when there is one
    return stripe.get(c, "/v1/charges/{id}/refunds", .{
        .id = charge_id,
        .limit = 20,
        .starting_after = cursor,
    }, .{});
}
```

A name with no field, a tuple for a named segment, a struct for a
positional one, and a template that mixes the two are each refused while
compiling, in a sentence that says what to write instead.

**The call's own headers win.** A `Call` on a target is the same `Call`,
and a line in its `headers` naming `authorization` or `user-agent` goes
instead of the standing value — one line on the wire, yours, the rule
[ADR 182](../adr/182-a-header-std-owns-goes-out-once.md) already sets for
std's own slot. A line naming any other standing header shadows it, so a
target that says `accept: application/json` can be asked for `text/csv` on
one call. The ordinary call has no standing headers and costs nothing here;
a call that passes headers of its own under a target that has some spends
one arena allocation on the merge.

**One target's gate is taken before the client's.** With `max_in_flight` on
the type, a call to a slow service waits at that service's own gate holding
no permit the others share; the client's ceiling on live connections still
holds over all of them. The target starts the client under it, so a program
that provides three targets and never the client is fine, and one that
provides all four starts the client four times, which sets the same `Io`
four times.

## The client's settings

Given to `init`, once:

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past it a caller waits for a permit rather than opening another connection |
| `timeout_ms` | 30,000 | how long one whole call may take — connect, send, head and body. `0` is no limit |
| `stall_ms` | 0 | how long the far end may say **nothing**: time since the last byte, not since the call began. `0` is no such bound. The other shape of clock, for the call whose whole point is the transfer ([below](#a-bound-on-silence-not-on-the-call)) |
| `max_body` | 8 MiB | a longer body is `error.BodyTooLarge`, enforced while reading, so a `content-length` that lies cannot get past it |
| `max_drain` | 64 KiB | how much of an unread body is worth reading to keep a pooled connection. Past it the connection is dropped instead |
| `read_buffer_size` | 8 KiB | the buffer each connection reads the socket through, and so how much one read brings in. std's own default, passed through; per connection, on the heap beside it |
| `forward_request_id` | true | a call made under a `*Ctx` carries the request's id as `X-Request-Id`, so the service you called can log the same id you did. Under a `nilo.Run` there is no request and nothing is sent; a call that names its own `X-Request-Id` keeps it ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)) |

**`max_in_flight` is the one that is not a nicety.** `std.http.Client`'s pool
bounds *idle* connections and does not bound in-use ones at all, so without
it the ceiling on live connections is however many handlers happen to be
running — and an HTTPS connection holds 59,151 bytes of TLS and socket
buffers. Five hundred concurrent handlers would be 29.6 MB nobody asked for
and five hundred handshakes. Thirty-two times that is the most the client
will ever hold.

**`timeout_ms` bounds the whole call rather than each read**, because a
server sending one byte a second satisfies any per-read limit you care to
name and never finishes. It is the same reasoning the server's own
[deadlines](./deploying.md#deadlines) follow from the other side.

**And it fires with or without an Engine.** Under a server the deadline is
armed on the fiber
([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)), and
`app.provide` is what hands the client the Engine's `Limits`. A client
started with `nilo_start(io, .none)` — a test, a CLI, a worker with no server
around it — has no fiber to arm, so each step of the call runs as a task of
that `Io` and the task is what gets cancelled when the clock runs out
([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)). The
cost is one thread hop per step, paid only there. Until 0.5 that client had
`timeout_ms` written down and nothing to fire it, and the first CLI on nilo
wrote its own watchdog to cover for it; `.off`, the older name for `.none`,
is kept so that program still compiles.

### A bound on silence, not on the call

A download may honestly take an hour, so the only honest `timeout_ms` for a
call whose whole point is the transfer is `0`, and that leaves a peer that
went quiet with the socket open (a CDN edge that lost its origin, a NAT that
dropped the mapping, a Wi-Fi handover) with nothing to end it. **`stall_ms`
is the ceiling on silence inside a call**: nothing arriving for that long is
`error.Stalled`, counted from the last byte that reached you rather than
from the start. The two compose (`timeout_ms` on the whole, `stall_ms` on
the gaps) and a caller sets either or both
([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn pull(api: *fetch.Client, c: *nilo.Ctx) !void {
    var out = try c.stream(200, "application/octet-stream");
    var ex: fetch.Exchange = .idle;
    defer ex.end();
    _ = try ex.begin(api, .{
        .method = .GET,
        .url = "https://mirror.example.com/large.iso",
        .timeout_ms = 0, // however long it takes
        .stall_ms = 10_000, // but never ten seconds of nothing
    });
    _ = ex.pipe(&out.writer) catch |err| switch (err) {
        error.Stalled => return nilo.fail.status(504, "the mirror went quiet", .{}),
        else => return err,
    };
    try out.finish();
}
```

It is not a per-read timeout, which ADR 056 refused and still refuses: a
server sending one byte a second is *slow*, satisfies this bound, and
whether slow is acceptable is yours to judge against your other connections.
What this catches is a server sending nothing. `Stalled` is told apart from
`TimedOut` because a caller does different things with them: a stalled
transfer is restarted on a fresh connection, a call that blew its whole
budget is given up on.

Under a server it is the Engine's timer, re-armed on every chunk; on a
client with no Engine it is the same task-and-cancel ADR 056 built, with
the wait re-read from the last byte. Either way a transfer that keeps moving
never fires it.

## What it answers instead

| Error | |
|---|---|
| `error.TimedOut` | this call's own deadline ran out |
| `error.Stalled` | nothing arrived for `stall_ms`; the peer still holds the socket |
| `error.Canceled` | the server is shutting down underneath the call. Told apart from `TimedOut` rather than guessed at |
| `error.RedirectRefused` | the answer was a 3xx with a `Location`, and the call made no decision about redirects. `Client.get` and its siblings follow; an `Exchange` says `.redirects = .follow` or `.expose` ([below](#a-body-too-big-to-hold)) |
| `error.BodyTooLarge` | the body passed `max_body`, and reading stopped there |
| `error.BodyTooShort` | the body ended before the length its own head announced |
| `error.NotStarted` | a call made before `listen()` — the client is finished at startup like any other service |
| the rest | `std.Uri.ParseError`, `std.http.Client`'s connect and receive errors, and the reader and writer errors, unchanged |

`NotStarted` is the one a unit test meets: a handler called directly, with no
App around it, has a client nobody started. The fix is the same one the
[testing page](./testing.md#two-things-listen-does-that-the-client-does-not)
gives for a database — `app.start(io)`, in a test that never listens — or a
fake in the handler's argument list, which is what the signature rules are for.

## The body is asked for uncompressed

`send` puts `Accept-Encoding: identity` on every call, so `res.body` is the
body rather than a gzip stream. `std.http.Client` on its own advertises gzip
and then hands back the compressed bytes — decompressing is a separate call
there, and a caller who does not make it gets unreadable bytes and no error.
Decompressing here would cost a 32 KiB flate window on the handler's stack,
which is held per *connection*
([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), so identity
is the trade taken. A server that ignores the header and gzips anyway is an
error rather than a `Str` full of noise.

## A body too big to hold

The four calls above take the whole body into the Scope, which is right for
an API answering JSON and wrong for anything measured in megabytes. An
`Exchange` is the same policy with the body left on the socket: **read the
response head, decide, then move the bytes somewhere that is not memory.**
What a [body reader](./requests.md#bodies-too-big-to-hold) is for a request
coming in, this is for an answer going the other way.

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn mirror(api: *fetch.Client, c: *nilo.Ctx) !void {
    var ex: fetch.Exchange = .idle;
    defer ex.end();

    const head = try ex.begin(api, .{
        .method = .GET,
        .url = "https://example.com/report.csv",
    });
    if (!head.ok()) return nilo.fail.status(502, "upstream answered {d}", .{@intFromEnum(head.status)});
    if (head.content_length) |n| if (n > 64 << 20) return nilo.fail.status(502, "report too large", .{});

    var body = try c.streamWith(200, head.content_type orelse "text/csv", .{ .length = head.content_length });
    _ = try ex.pipe(&body.writer);
    try body.finish();
}
```

| | |
|---|---|
| `ex.begin(api, .{…})` | `Head` — `status`, `content_length`, `content_type`, `header(name)` case-insensitively, `ok()`; and `redirected`, the `std.Uri` a followed redirect ended at or null, with `location(&buf)` to write it out as one string |
| `head.keep(c)` | the same head copied into the Scope, so it reads the same after the body has been through |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing over `max` |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest into a `*std.Io.Writer`, and how many bytes |
| `ex.stream(w, limit)` | one chunk into `w`, at most `limit`, and how many bytes; `0` is the end. For a body moved in pieces of your own choosing |
| `ex.discard()` | "I will not read this body; close the connection." For the probe that asked for one byte and got the file |
| `ex.end()` | required, and safe twice |

`Begin` takes what a `Call` does and more: `headers`, `host`, `authorization`,
`content_type` and `user_agent` — four headers std would otherwise write for
itself, which a signed request has to control; `timeout_ms`, `stall_ms`, a
`body` of `.none`, `.slice` or `.stream` with a length, and `redirects`. The
explicit fields are for a caller who has the value; the same name in
`headers` is the other way to say it, and both at once is two lines on the
wire.

**A redirect is a decision, and the call says which.** `redirects` is
`.refuse` by default, and under it a 3xx with a `Location` is
`error.RedirectRefused`: a caller who never thought about redirects finds
out from the error rather than from a status 301 read as a broken server.
`.follow = &buf` walks the chain, three deep at most, and the answer comes
back with `head.redirected` set to the URL it actually came from, so the
connections after a probe can go straight there rather than walking the
chain again; the text lives in your buffer, which is why
`head.location(&buf)` takes one to write into rather than handing back a
slice ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)).
`.expose` is handed the 3xx as itself, which is what a signed request wants
(a signature is computed over one host and one path, and following would
send the `authorization` header somewhere it was never meant to go) and
what a client that reads the body of a 301 wants, which is where S3 puts
its reason ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)).

**Everything in `Head` points into the connection's read buffer, and the
first byte of body read overwrites it.** Read what you need before `take` or
`pipe`, or `head.keep(c)` for a copy in the Scope that reads the same
afterwards: the `etag` the next run compares against, taken before the body
and needed after it
([ADR 187](../adr/187-a-head-that-outlives-its-body.md)). That is the
bargain a [borrowed row](./sql/raw.md) makes, for the same reason: the
alternative is an allocation per call for text most callers glance at once,
so the borrowed head is the default and the copy is one line where it is
wanted.

**There is no buffer to declare.** `take`, `readInto`, `pipe` and `stream`
go from the connection's own read buffer straight to the destination, on
every framing; the `transfer_buffer` field is for a caller who reads
*buffered* off `ex.reader` (`take`, `peek`, a delimiter) and for nothing
else. It does not change how much one socket read brings in, which is
`read_buffer_size` on the client. Until 0.5 the guide said bigger was fewer
trips, a download manager gave sixteen segments 64 KiB each on the strength
of it, and the syscall count did not move
([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)).

**An `Exchange` must not be copied once begun** — it holds a live
`std.http.Client.Request`. Declare it, fill it where it stands, leave it
there. `defer ex.end()` is the line that is not optional: it gives the permit
back and returns the connection to the pool, or drops it if what was left
unread is past `max_drain`. When you already know the body is not wanted —
a `Range` probe that was answered with the whole object — `ex.discard()`
before the `end` says so, and the connection goes with the body whatever
`max_drain` would have decided. That keeps `max_drain` a policy for every
call rather than a lever pulled for one
([ADR 184](../adr/184-a-caller-that-knows-says-discard.md)).

**A body with no length cannot be sent streamed.** `.stream` takes the
length because HTTP can frame an unknown length only as chunked, and the
services this exists for — S3 among them — answer `411` to that. Not knowing
the length is therefore a compile error here rather than somebody else's
status code.

## What it costs

On the request path, nothing that was not already there: one call is one
permit, two arena allocations — the header block, then the body
([ADR 187](../adr/187-a-head-that-outlives-its-body.md)) — the JSON
written out or the URL assembled if you asked for either, and the parse if
you asked for that. **What it costs is per idle connection**, and it is stack: a handler
that has made one call holds 4,139 bytes more than one that has not, for the
life of the connection, at the depth `std.http.Client` drives the fiber to
([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). That is
still the largest per-connection figure in the toolkit, and the levers left
are small: taking the 4 KiB transfer buffer out of `send` moved it by 14
bytes, because a buffer no byte ever touched was never a resident page.

Everything measured is `http://`;
[`bench/result/fetch.md`](../../bench/result/fetch.md) has the numbers on all
four of [ADR 017](../adr/017-the-trade-budget-has-four-axes.md)'s axes and
says plainly that nothing has been put on a scale through TLS yet.

## What it is not

A retry policy, a circuit breaker or a rate limiter. How many times, how long
between, and what counts as failure are facts about somebody else's service,
and a default that guessed them would turn one outage into a thundering herd.
A caller who knows them writes three lines — a loop, a
[`nilo.sleep`](./services.md#what-needs-wrapping) between attempts, and a
`switch` on which errors are worth another go. What is here is the part that
is the same for everybody: do not hold a connection forever, do not hold more
than you meant to, and do not read more than you asked for.

## Testing

A handler that takes a `*fetch.Client` is an ordinary function, and the
usual answer is not to give it one: shape the far end's response into a
struct, and test the function that turns that struct into yours, which is
what `examples/outbound` does with its `card`. For the call itself, the
module's own tests stand a real socket up on `std.Io.Threaded` with no
Engine anywhere — which is the entry condition for its layer — and the
server they drive is yours to use.

**`fetch.testing.Canned` is one real exchange, for a suite of your own.**
Open it, say what it answers, start it with `io.concurrent` beside the
call, and finish the client with `nilo_start(io, .none)` as `listen()` would
have done. It binds port 0 and reads the kernel's answer back, so there is
no port range to keep apart from anybody's; `serveOne` reads the request
whole and `request()` and `requestBody()` show what reached it, which is
what a test about a POST wants
([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

<!-- compiles -->
```zig
const fetch = @import("nilo_fetch");

fn retryAfterIsRead(io: std.Io, gpa: std.mem.Allocator) !void {
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
    try std.testing.expect(std.mem.startsWith(u8, canned.request(), "GET / "));
}
```

`io` is a `std.Io.Threaded` the test owns — `var threaded: std.Io.Threaded =
.init(std.testing.allocator, .{}); defer threaded.deinit();` and
`threaded.io()`. `concurrent` rather than `async`, because `async` may run
the server on your own thread and sit in `accept` waiting for the connection
that thread was about to make; the module's tests found that at zero CPU
([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)).

## See also

- [The reference](../reference/fetch.md#nilo_fetch) — the surface as a list.
- [Object storage](./s3.md) — `nilo_s3` is this module with SigV4 in front of
  it, and the only module that imports a Fitting.
- [Checking somebody else's token](./jwt.md) — the fetch that gets a JWKS
  document.
- [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md) — why the
  deadline is on the fiber rather than in std.
