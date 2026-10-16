# nilo_fetch

**`nilo_fetch` is an HTTP client for calling somebody else's API from inside a request, with the limits a server needs.**

**Guide:** [Calling somebody else's API](../guide/fetch.md) · **Design:** [Outbound calls](../design/fetch.md)

## `nilo_fetch`

An HTTP client for calling somebody else's API from inside a request. It is a **Fitting**: it borrows the event loop and owns no destination ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

The client underneath is `std.http.Client` (connection pool, HTTP/1.1, TLS). This module adds the policy a server needs and a script does not, in about sixty lines.

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

### `fetch.Client` calls

| Call | |
|---|---|
| `client.get(c, url, .{})` | `Response` |
| `client.post(c, url, body, .{})` | `Response` |
| `client.put(c, url, body, .{})` | `Response` |
| `client.delete(c, url, .{})` | `Response` |
| `client.patch(c, url, body_or_null, .{})` | `Response`. `null` for an endpoint whose whole request is its path |
| `client.send(c, method, url, body_or_null, .{})` | for a method the five above do not cover. **The body decides the framing, not the method** ([ADR 174](../adr/174-the-body-decides-not-the-method.md)): a DELETE with a body sends it with its `content-length`, and a POST with `null` sends `content-length: 0`. `error.HeadTooLong` means a body on a method std sends none for, whose head did not fit the connection's buffer |
| `client.postJson(c, url, value, .{})` | `Response`: `value` written with `std.json` into the Scope and sent as `content-type: application/json`, unless `headers` names a content type. `putJson`, `patchJson` and `sendJson(c, method, url, value, .{})` work the same way. Passing text here is a Refusal, because it would be sent as one JSON string ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `client.postForm(c, url, fields, .{})` | `Response`: `fields` written as an `application/x-www-form-urlencoded` body and sent with that `content-type`, unless `headers` names one. The field types, the null that leaves a field out and the Refusals are `withQuery`'s, naming a form field. A space is `+` and a literal `+` is `%2B`, where a query string says `%20`. `putForm` and `sendForm(c, method, url, fields, .{})` work the same way. Text here is a Refusal ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `fetch.formBody(c, .{ .grant_type = "client_credentials" })` | `[]const u8`: the form body alone, in the Scope, one allocation of exactly the right size, for `post` with a `content-type` of your own |
| `fetch.basicAuth(c, id, secret)` | `[]const u8`: the `authorization` value `Basic …` the OAuth way, with the id and the secret form-encoded before they are joined with `:` and base64-encoded (RFC 6749 §2.3.1), so a secret with a `+`, a `:` or a space reaches the provider as it was written. Pass it as `.headers = &.{.{ .name = "authorization", .value = value }}` |
| `fetch.withQuery(c, base, .{ .page = 2, .q = "a b" })` | `[]const u8`: `base?page=2&q=a%20b`, in the Scope, one allocation of exactly the right size. A field may be an int, a bool, text, or an optional of one (null is left out); anything else is a Refusal naming the field. Uses `&` after a base that already has a `?` ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)) |
| `res.ok()` | `bool`: a 2xx status |
| `res.status` | `std.http.Status` |
| `res.body` | `Str`, in the Scope you passed. Freed when the request ends |
| `res.headers` | `[]const u8`: the header block the response arrived with, kept in the Scope ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)) |
| `res.header(name)` | `?[]const u8`, case-insensitive; null when the response did not have it. For example `Retry-After` on a 429, `ETag` for the next conditional GET, `Location` on a 201 |
| `res.json(T, c)` | `T`, parsed into the same Scope |

`c` is a Scope: the `*Ctx` a handler was given, or a `nilo.Run` where there is no request. Passing anything else is a Refusal naming the call.

### `Client.Settings`

Given to `init`:

| Field | Default | |
|---|---|---|
| `max_in_flight` | 32 | calls at once, across every host. Past this, a caller waits for a permit instead of opening another connection. An HTTPS connection allocates up to 59,151 bytes, of which 12 KB are resident after a small answer and 45 KB after a large one |
| `timeout_ms` | 30,000 | how long one whole call may take. `0` means no limit. **The shorter of this and the time the Scope's route has left**, if it has a [deadline](./middleware.md#nilodeadline): the call is `error.TimedOut` when either runs out, and a request whose time has already passed (including time spent queued for a permit) fails without dialling ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)). A `nilo.Run` has no deadline. It works with or without an Engine: under `listen()` the Engine cancels the fiber; on a client started with `nilo_start(io, .none)`, each step of the call runs as a task of that `Io` and the task is cancelled, which costs one thread hop per step, only in that case ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)) |
| `stall_ms` | 0 | how long the other side may send **nothing** before the call fails with `error.Stalled`: time since the last byte, not since the call began. `0` means no such limit. While a `.stream` body goes out, every step of it that reaches the socket counts as a byte (the source is read 16 KiB at a time and each step flushed before the clock moves), since nothing arrives from the peer meanwhile; a peer that already stopped reading ends the call when its socket gives up, not `stall_ms` after. Works together with `timeout_ms`; the Engine's timer is re-armed on every chunk, or without an Engine the wait is measured from the last byte ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)) |
| `max_body` | 8 MiB | a longer body fails with `error.BodyTooLarge`, checked while reading |
| `max_drain` | 64 KiB | how much of an unread body to read in order to keep a pooled connection. Past this the connection is dropped |
| `read_buffer_size` | 8 KiB | each connection's socket read buffer, and therefore how much one read brings in. std's default, passed through ([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)) |
| `forward_request_id` | true | a call made under a `*Ctx` sends the request's id as `X-Request-Id`, so the other side's logs line up with yours. A `Run` has no id and sends none; a call that sets its own `X-Request-Id` in `headers` keeps it ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)) |
| `proxy` | null | an egress proxy for `http://` calls: `.{ .url = "http://user:password@host:3128", .bypass = &.{ "corp.example", "127.0.0.1" } }`. Never read from the environment. See [A proxy and a private authority](#a-proxy-and-a-private-authority) ([ADR 267](../adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)) |
| `roots` | null | the certificate authorities an `https://` call trusts, as a `*const std.crypto.Certificate.Bundle` you loaded. Null is the system's, scanned on the first `https://` call. The bundle is yours: it must outlive the client and not change while it lives |

### `Client.Call`

Given per call: `headers`, `timeout_ms` / `stall_ms` / `max_body` to override the settings above for one call, `unix_socket` to send the call over a unix domain socket ([below](#a-call-over-a-unix-socket)), and `tls` to skip the certificate check for this call ([below](#a-call-that-does-not-verify-the-certificate)). **A header std has its own slot for** (`host`, `authorization`, `user-agent`, `content-type`, `connection`, `accept-encoding`) **is sent once**: your copy replaces std's instead of being sent beside it ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)).

### A call over a unix socket

**`Call.unix_socket = "/var/run/docker.sock"` sends the call over that socket instead of dialling the URL's host.** The URL is still the request: its host is the `Host` header and its path and query the request line, so one socket serves any number of paths ([ADR 272](../adr/272-a-call-names-the-socket-it-goes-over.md)).

```zig
const res = try client.get(c, "http://docker/containers/json?all=1", .{ .unix_socket = "/var/run/docker.sock" });
```

- **The path is absolute, at most 107 bytes, with no NUL**, else `error.InvalidSocket`; the URL is `http://`, an `https://` one is `error.TlsOverSocket`, any other scheme `error.UnsupportedUriScheme`. All three come before anything is dialled. A socket nobody listens on is the dial's own error (`error.FileNotFound`, `error.ConnectionRefused`).
- **Connections are pooled by the path**, so two sockets never share one. Deadlines, `stall_ms`, the stale-connection replay and a `Target`'s retry apply as for any call.
- **`Settings.proxy` does not apply**: a socket never leaves the host, so the call goes straight to it in origin form. One `Client` can proxy Stripe and talk to Docker.
- **A followed redirect inside the origin stays on the socket; one that leaves it is `error.RedirectLeavesSocket`**, not dialled over TCP on a `Location`'s word.
- **`Exchange.begin` takes the same field**, `Begin.unix_socket`.
- A `Target` holds the path once: `Docker.open(&client, .{ .base = "http://docker/v1.43", .unix_socket = "/var/run/docker.sock" })`. `open` returns the same three errors, and a call's own `unix_socket` goes instead of the target's.

### A call under a traced request

**On an App that calls `app.trace`, a call made under a `*Ctx` is a client span, and it sends `traceparent`** naming that span, plus the `tracestate` the request arrived with. The span has the method, `server.address`, `server.port`, the status, and the error's name when the call failed. A call that sets its own `traceparent` in `headers` keeps it, and no span id is sent for it. A `Run` declares no trace and sends none. An `Exchange` sends only the headers it is given, as it does for the request id ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)), so a signed `nilo_s3` request is not traced. A Scope of your own joins by declaring `traceBegin(self) ?core.trace.Outbound` and `traceEnd(self, core.trace.Outbound, core.trace.Ended) void` ([ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md), [Tracing](../guide/tracing.md)).

### A proxy and a private authority

**`Settings.proxy` sends every `http://` call to a forward proxy, and `Settings.roots` replaces the authorities an `https://` call trusts.** Both are applied to both of the client's std clients, the pooled one and the one a `.stream` body takes ([ADR 267](../adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)).

```zig
var roots: std.crypto.Certificate.Bundle = .empty;
defer roots.deinit(gpa);
try roots.rescan(gpa, io, now); // the system's, then one more
try roots.addCertsFromFilePathAbsolute(gpa, io, now, "/etc/corp/ca.pem");

var api: fetch.Client = .init(gpa, .{
    .roots = &roots,
    .proxy = .{ .url = "http://user:secret@proxy.corp:3128", .bypass = &.{ "corp.example", "127.0.0.1" } },
});
```

- **The proxy URL is `http://` or `https://` with an optional `user:password@`**, which becomes `Proxy-Authorization: Basic` and is sent to the proxy and nowhere else. A bad one is `error.InvalidProxy` from `nilo_start`, before the program serves. Nothing is read from `HTTP_PROXY` or `NO_PROXY`; pass what your configuration says.
- **`bypass` lists hosts dialled directly.** An entry matches the host it names and every host under it, ignoring case (`corp.example` skips `api.corp.example`); a leading `.` or `*.` is the same, `*` is every host. No CIDR range, no port. **`localhost` and loopback are not skipped unless listed.**
- **An `https://` call goes through the proxy in a `CONNECT` tunnel `nilo_fetch` opens**, with TLS run inside it and the certificate checked against the URL's host name, never the proxy's (std 0.17's own tunnel would send the request in the clear). The proxy's credential rides the `CONNECT` and nothing else. A proxy that does not answer 2xx is `error.TunnelRefused`, before a byte of the call is sent; a proxy that is itself an `https://` URL is `error.TlsThroughProxy`, before anything is dialled. A client certificate is not supported ([`docs/todo.md`](../todo.md)).
- **The proxy's credential never follows a redirect.** A followed redirect to a bypassed host goes direct without it; a `Proxy-Authorization` line you wrote yourself is dropped past a change of origin as before.
- **`roots` is shared, not copied.** An empty bundle trusts nobody; "the system's plus one file" is the recipe above. `deinit` hands the bundle back untouched.

### A call that does not verify the certificate

**`Call.tls = .unverified` makes one `https://` call without checking the certificate, and nothing else can.** For the call that asks "does it answer" and not "is its certificate good": an uptime check of an appliance on its factory certificate, `curl -k` for a program ([ADR 290](../adr/290-a-call-can-skip-the-certificate-check-and-only-that-call.md)). `.verified` is the default and checks the chain and the name; a certificate the client does not trust is `error.TlsInitializationFailed` (std's name for a handshake that did not complete, and what it makes of an unknown authority, a wrong name and an expired certificate alike, direct or through a proxy), and `.unverified` is the way to ask the question that refuses.

```zig
const res = try client.get(c, "https://nas.lan:5001/", .{ .tls = .unverified, .timeout_ms = 2_000 });
```

- **It is a field of `Call` and `Begin`, and of no `Target` or `Settings`**, so it cannot become a default by accident: a service that is called unverified on every call says so on every call. A private authority's service wants `Settings.roots`.
- **`Exchange.begin` takes the same field**, `Begin.tls`.
- **No server name is sent in the handshake**, because `std.crypto.tls.Client` takes the name for the handshake and for the check from one option. A host that picks its certificate by name answers with its default one.
- **An IPv6 literal cannot be called unverified**: std's TLS client takes the name for the handshake from the option that switches the check off, so there is no name to give it, and the call is `error.UnverifiedNeedsHostName` rather than quietly verified and failing. An IPv4 literal is a valid host name and is answered.
- **An unverified connection is pooled apart.** It is kept for the next unverified call to the same host and port, and a verified call is never handed it.
- **A followed redirect to another origin is verified again.** Inside the origin it stays unverified, as the credentials stay ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)).
- **A proxy carries it as it carries any `https://` call**, in the same `CONNECT` tunnel; the certificate is the one thing not checked. A WebSocket opened with `fetch.WebSocket.open` has no such option.

### Redirects

**`Client.get` and the calls beside it follow up to ten redirects (a longer chain or a loop is `error.TooManyHttpRedirects`), and what they send does not follow the call to another origin.** A change of scheme, host or port is another origin ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)). Past one, the `authorization`, `cookie`, `proxy-authorization` and `www-authenticate` lines, the `host` the call named, and every standing header of a `Target` are not sent; a hop from `https` to `http` is `error.InsecureRedirect`. Inside one origin everything goes along. A 303, and a 301 or 302 on a POST, become a GET without a body; any other redirect of a call that has a body is `error.RedirectRequiresResend`. `Response.redirected` is the URL the call ended at (without userinfo or fragment), in the Scope, or null when it was not redirected.

### Responses with no body

**A response that has no body by definition ends at its head.** A response to HEAD, a 1xx, a 204 and a 304 are complete at the blank line whatever `content-length` or `transfer-encoding` say, so `send` returns an empty body immediately and the connection is kept ([ADR 176](../adr/176-an-answer-with-no-body-ends-at-its-head.md)).

### Errors

**Each error means one thing.** `error.TimedOut` is this call's own deadline. `error.Stalled` is `stall_ms` passing with nothing arriving while the other side keeps the socket open. `error.Canceled` is the server shutting down underneath the call. The three are kept distinct instead of guessed at. `error.RedirectRefused` is a 3xx with a `Location` under an `Exchange` that did not choose a redirect policy (`Client.get` and the other calls above do follow redirects). `error.InsecureRedirect` is a followed redirect that led from `https` to `http`: it is not followed. `error.NotStarted` is a call made before `listen()`; the client is finished at startup like any other service. `error.TlsThroughProxy` is an `https://` call through a proxy that is itself `https://`, `error.TunnelRefused` is a proxy that answered the `CONNECT` with anything but a 2xx, and `error.InvalidProxy` is a proxy URL the start refused. `error.TlsOverSocket`, `error.InvalidSocket` and `error.RedirectLeavesSocket` are the three refusals of a call over a unix socket ([above](#a-call-over-a-unix-socket)). `error.BodyEncodingInvalid` is a gzip answer that does not decode, in a `-Dfetch_gzip` build ([below](#compression)); without the flag a gzip answer is `error.HttpContentEncodingUnsupported`. A WebSocket adds its own ([below](#fetchwebsocket)).

**A 4xx or 5xx is a `Response`, not an error.** The call worked and the service said no; only the caller knows which of those matters.

### Compression

**The body is requested uncompressed, unless the build reads gzip or zstd.** `send` sends `Accept-Encoding: identity`, so `res.body` is the body and not a gzip stream. This differs from `std.http.Client`'s default, which advertises gzip and then returns the compressed bytes from `Response.reader`: decompressing is a separate call there, and a caller who forgets it gets unreadable bytes and no error. Decompressing here would cost a 32 KiB flate window on the handler's stack, which is held per *connection* ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)), and link flate into every program that dials out, so a build does it only when it asks. A server that ignores the header and sends gzip anyway causes `error.HttpContentEncodingUnsupported`, not a `Str` full of noise, and a Debug build logs the line to write.

**`-Dfetch_gzip` reads a gzip answer** ([ADR 292](../adr/292-a-fetch-build-can-read-a-gzip-answer.md)). Pass `.fetch_gzip = true` to `b.dependency("nilo", …)` (or to `nilo.app`), and `fetch.reads_gzip` is `true`. Then:

- Every call made through `Client` (`get`, `post`, `send` and the rest, so a `Target`, a `Retry` and the trace exporter too) sends `Accept-Encoding: gzip, identity`, and an answer under `Content-Encoding: gzip` is decoded. **It is decoded whatever was advertised**: a server that gzips regardless of `identity`, or a caller's own `accept-encoding` line, gets the body and not the error.
- **`max_body` counts the decoded bytes**, so a few kilobytes of gzip that inflate past it are `error.BodyTooLarge`, and the exact-size read of an announced length does not apply (the length announced is the wire's: `head.content_length` is the length of the gzip stream, not of the body).
- **The footer is checked.** A body that is not gzip, a block that does not decode, a CRC-32 or length that disagrees with the footer, and a stream that ends early are `error.BodyEncodingInvalid` (only in this build). A connection that dies under the decoder is `TimedOut`, `Stalled` or `ReadFailed` as ever.
- **Any other coding is still `error.HttpContentEncodingUnsupported`**: `deflate` and `br` are not read, and `zstd` is read only with `-Dfetch_zstd` (below).
- **The decoder is one heap allocation of 73,136 bytes** from the client's allocator, made when an answer announces gzip and freed by `end`; an answer that is not gzip allocates nothing, and the stack of a call grows by one pointer. A program without the flag links no flate and pays 16 bytes; one with it pays 23 KB. Decoding 4 KiB of JSON is about 114,000 instructions and 1 MiB is 2.3 ms ([`bench/result/fetch.md`](../../bench/result/fetch.md#reading-a-gzip-answer-what-it-costs-adr-292)).
- **Which reads decode.** On an `Exchange`, `take`, `readInto`, `pipe`, `stream` and `reader` all read the decoded body, when `Begin.gzip` is set; `Client`'s calls set it, and an `Exchange` begun by hand does not unless asked, so `nilo_s3` still gets an object as it was stored. `Redirects.follow` decodes the answer it ends at (a 3xx body is not read). A WebSocket upgrade has no body to decode. A drain at `end` reads the wire, never the decoder.

**`-Dfetch_zstd` reads a zstd answer beside gzip** ([ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)). Pass `.fetch_zstd = true` (it implies `.zstd = true`, libzstd) and `fetch.reads_zstd` is `true`; the two flags are independent, so a build can read either or both, and `fetch.accepted_encodings` is what its calls send: `identity`, `gzip, identity`, `zstd, identity` or `zstd, gzip, identity`, best first (a server that reads both picks zstd, which is smaller and decodes faster). Everything above holds for zstd as for gzip: decoded whatever was advertised, `max_body` counted on the decoded bytes (8 MiB of one letter is a few hundred bytes of zstd and `error.BodyTooLarge` at the ceiling), `error.BodyEncodingInvalid` for a body that is not a frame, does not decode, fails the frame's checksum, ends early or asks for a window over 8 MB (the size RFC 9659 requires every HTTP decoder to give, and the most a peer can make a call hold). The differences:

- **The decoder is two heap allocations from the client's allocator, and the second is made at the first read**, once the first bytes say what the frame needs: a 16 KB header with its input buffer when the answer announces zstd, then the context, **112,416 bytes for a frame that announces its length (a small body), 1.5 MB for one that announces a megabyte, 2.6 MB for a stream that announces nothing at level 3's window (2^21), and 8.9 MB at the 8 MB window**. Both are freed by `end`; the stack of a call grows by nothing more than gzip's pointer, and an answer that is not zstd allocates nothing. A body of no bytes under the header is an empty answer.
- **A program without the flag pays nothing**: the stripped `ReleaseFast` program of `bench/release/fetch.zig` is the same byte count with and without `-Dzstd` (953,760), and `-Dfetch_zstd` adds 92,128 bytes (gzip's decoder adds 23,888; both 115,232). Decoding 4 KiB of JSON is about 59,000 instructions (gzip 124,000) and 1 MiB is 7.9 million (gzip 18.2 million), 406 us against 2,145 us ([`bench/result/fetch.md`](../../bench/result/fetch.md#sending-and-reading-zstd-what-it-costs-adr-295)).
- **`Begin.decode`** is the switch on an `Exchange`, for either coding (it was `Begin.gzip`).

`examples/outbound/` shows all of this against a real API, and [`bench/result/fetch.md`](../../bench/result/fetch.md) has the cost on each of ADR 017's four axes.

### Sending a body compressed

**`Call.encoding = fetch.gzip` or `fetch.zstd` sends the body compressed, and a program that never writes either links no compressor.** The body is compressed into the Scope, `Content-Length` is the compressed size and `Content-Encoding` names the coding; `fetch.gzip.with(.{ .level = .fastest, .min_bytes = 512 })` changes the level and the threshold under which a body goes out as it is (1 KB by default). **`Level` is `.fastest`, `.default`, `.best` or `.{ .exact = n }`**: gzip maps the three to zlib's 1, 6 and 9 (`exact` is clamped to them), zstd to 1, 3 and 6 and takes `exact` as libzstd's own number (1 to 22, and negative for faster and larger). Zstd's memory grows with the level, which is why `.best` stops at 6: a 1 MB body needs a 583 KB context at level 1, 1.3 MB at 3, 3.7 MB at 6, 13 MB at 12 and 18 MB at 19. **`fetch.zstd` needs `.zstd = true`** (a build without it refuses to compile the line, with the line to write), and no `-Dfetch_zstd`: that flag is for reading. A frame announces its own length, so a receiver can decode it in one call. A zstd body of 4 KB JSON costs about 99,900 instructions against gzip's 285,300; a megabyte 13.5 million against 81.2 million (about 0.5 ms against 5.4 ms of CPU). A body that does not shrink, and one whose `headers` already carry a `content-encoding`, go out as they are, and `Response.sent_encoding` is the coding the body finally went under, or null ([ADR 293](../adr/293-a-request-body-can-be-sent-gzipped.md)).

**A server that does not read the coding answers 415, and the call sends the body once more, plain.** The answer is not remembered between calls: a caller that asked and reads `sent_encoding == null` knows this server does not read the coding and stops asking. A 415 whose `Accept-Encoding` lists the coding is about something else and is the answer. A `Body.stream` is never compressed and never sent again. **A zstd body refused by a server that reads gzip goes out plain and not gzipped**: falling back to the other coding would link the other compressor into every program that sends zstd; a caller who wants it reads `sent_encoding == null` and sends `fetch.gzip` itself.

The gzip compressor is `~288 KB`, on the heap, started in place by `core.deflate` (never `Compress.init`, whose 99 KB temporary would sit on the fiber's stack), and kept on the `Client` between calls. Zstd's is libzstd's static context in heap memory sized by `nilo_zstd`'s estimate for the body (73,744 to 1.3 MB at levels 1 to 3 and a megabyte, 90,128 bytes for 4 KB at level 3), grown to a power of two and kept in the same one-compressor stash; **a context over 4 MiB is freed with the call that needed it**, so a client that once posted a large body at a high level holds nothing for ever. The stash holds one compressor of one coding: a client that alternates codings makes a new one each time. A coding is a value (`fetch.Coding`: `name`, `level`, `min_bytes`, a vtable), so another is a second constant and not a new API.

### `fetch.Exchange.Upload`

**A chunked body the caller writes is `Exchange.beginUpload`, because an unknown length is something to ask for by name.** `Body.stream` keeps its mandatory length (S3 and its kind answer `411` to a chunked body); this is for the server that reads chunked and the caller whose lines are not known in advance.

```zig
var ex: fetch.Exchange = .idle;
defer ex.end();
var up: fetch.Exchange.Upload = .{};
defer up.deinit();
try ex.beginUpload(client, c, &up, .{ .method = .POST, .url = url, .timeout_ms = 0 }, fetch.gzip);
try up.writer().writeAll("{\"t\":1}\n");
try up.writer().flush();        // that line is on the wire, whole
const head = try up.end();      // the head of the answer; ex.take(c, max) reads the rest
```

| | |
|---|---|
| `ex.beginUpload(client, c, &up, opts, coding)` | sends the head with `transfer-encoding: chunked` and, under a coding (`?fetch.Coding`), `content-encoding`. `opts.body` is `.none` and the method POST, PUT or PATCH; anything else is `error.InvalidUpload`. On a connection no pool held, like a `.stream` |
| `up.writer()` | a `*std.Io.Writer`. **`flush()` on it is the unit**: under a coding it is deflate's sync flush (zstd: `ZSTD_e_flush`), so the server can decode everything written so far, then the chunk is ended and on the socket. A zstd upload holds a stream context for its length: 1.1 MB at level 1 and 1.8 MB at level 3 with the window held to 256 KB (2^18), 4.2 MB at `.best`; the frame does not announce its length, so a receiver decodes it as a stream |
| `up.end()` | finishes the coding, ends the body and reads the head of the answer. A server that answered early and closed makes the writes fail; `end` still returns what it said |
| `up.deinit()` | gives back the compressor and the 16 KB chunk buffer; safe after `end`, after a failure, and on an `Upload` never begun |

`timeout_ms` bounds the whole upload, so an open-ended one says `0`; `stall_ms` counts from the last flush. A redirect is handed back, never followed. Do not copy an `Upload` once begun.

### What it does not do

**An answer sent before the body was finished is the answer.** When writing a large body fails because the server refused it on the head and closed, `begin` returns that refusal (a 4xx or 5xx) rather than `WriteFailed`, and the connection is not reused. A 2xx in that position is not taken, since the server never received the whole upload.

**No circuit breaker or rate limiter, and no retry unless a `Target` declares one.** How many times and what counts as failure are decisions about somebody else's service, and belong to whoever knows what that service promises; the mechanism of trying again is `Target`'s `.retry` ([below](#fetchretry)).

### `fetch.Target`

**A service's base URL, standing headers and limits, as a type of its own**, opened once on the client and asked for by type. Two services are two types ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

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
| `fetch.Target(name, .{…})` | a type. `name` tells two targets with the same options apart, and is what the health route calls it; an empty name is a Refusal |
| `Stripe.open(&client, .{ .base, .authorization, .user_agent, .headers, .unix_socket })` | `error.BaseNotAbsolute` for a base with no scheme or host, `error.BaseHasQuery` for one with a `?` or `#`, `error.TlsOverSocket` / `error.InvalidSocket` for a bad `unix_socket` ([ADR 272](../adr/272-a-call-names-the-socket-it-goes-over.md)); a trailing `/` is dropped. Every value is held, not copied |
| `app.provide(&stripe)` | starts the client under it at `listen()`; the client itself is provided only if a handler asks for it by that type |
| `stripe.get(c, path, args, .{})` | `Response`. Also `post(c, path, args, body, .{})`, `put`, `delete`, `patch(c, path, args, body_or_null, .{})`, `send(c, method, path, args, body_or_null, .{})`, `postJson(c, path, args, value, .{})`, `putJson`, `patchJson`, `sendJson`, `postForm(c, path, args, fields, .{})`, `putForm`, `sendForm`: every call the client has, with a path instead of the URL and the same `Call` last |
| `stripe.url(c, path, args)` | `[]const u8`: the URL alone, in the Scope, one allocation of exactly the right size, for an `Exchange` begun on the client |
| `stripe.nilo_ready(scope)` | ready once started, unless the type names a `ready` path, which is then fetched with GET on every probe, and anything but a 2xx is reported |

**`fetch.target.Options`**, on the type: `max_in_flight` (0 means no limit of its own; otherwise this service's own semaphore, taken before the client's and released after, per try), `timeout_ms`, `stall_ms`, `max_body` (each null to use the client's, and a `Call` can still override them for one call), `ready` (null, or a path starting with `/`) and `retry` (null, or a [`fetch.Retry`](#fetchretry)).

**`path` is a template known at compile time.** `{}` is filled by position from a tuple (`"/repos/{}/{}", .{ owner, name }`), and the count is checked. `{name}` is filled from the struct field of that name, and **every field the template does not name becomes a query param** under `withQuery`'s rules: `"/v1/charges/{id}/refunds", .{ .id = id, .limit = 10, .cursor = cursor }`, with a null cursor left out. A segment may be an int, a bool or text, and `/` inside it is encoded as data. Each of these is a Refusal: a count that does not match, a name with no field, a tuple for a named segment, a struct for a positional one, a template mixing the two, a segment of another type, and a path that does not start with `/`.

**Standing headers, and a call's headers over them.** `authorization` and `user_agent` use std's slot; a line in `Call.headers` naming either replaces it ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)). A line naming any other standing header overrides it. There is no allocation unless a call with its own headers meets a target that also has some, and then there is one.

### `fetch.Retry`

**What a `Target` does when the service has a bad minute**: `fetch.Target("stripe", .{ .retry = .{ .times = 3, .mint_key = "Idempotency-Key" } })`. The numbers are the caller's, the mechanism is nilo's, and a target that declares nothing holds and runs none of it ([ADR 271](../adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md), the [guide](../guide/fetch.md#retrying)).

| Field | Default | |
|---|---|---|
| `times` | 2 | tries after the first; 0 is a Refusal |
| `backoff` | exponential 100 ms to 2 s, `.jitter = .full` | a `nilo_core.Backoff` ([core](./core.md#nilo_corebackoff)); `from_ms = 0` and `to_ms < from_ms` are Refusals |
| `statuses` | `&.{ 429, 502, 503, 504 }` | answers worth another try; each must be 400 to 599 |
| `retry_after_max_ms` | 5,000 | `Retry-After`, in seconds or as an HTTP date, is a floor on the wait, capped here |
| `budget` | `.{ .percent = 20, .min_per_sec = 10, .window_s = 10 }` | retries allowed up to `percent` of the calls made in the last `window_s` seconds (1 to 16), plus `min_per_sec` a second. Both 0 is a Refusal; there is no way to turn it off |
| `mint_key` | null | the header name a POST or PATCH with no `Idempotency-Key` of its own is given a minted key under (32 hex digits, the same on every try). A Refusal for an empty name or one with a space or colon |

**What is retried.** GET, HEAD, PUT, DELETE, OPTIONS, TRACE and QUERY always; POST and PATCH only with an `Idempotency-Key` in `Call.headers` or the target's standing headers, or with `mint_key`. A status in `statuses`, and a failure before an answer: `ConnectionRefused`, `ConnectionResetByPeer`, `ConnectionTimedOut`, `NetworkUnreachable`, `HttpConnectionClosing`, `UnknownHostName`, `TemporaryNameServerFailure`, `ReadFailed`, `WriteFailed`, `TimedOut` and `Stalled`. Never `Canceled`. When the tries run out the last `Response` is returned as itself, or the last error.

**The wait** is the backoff's jittered delay, or the capped `Retry-After` if that is longer, slept on the fiber with no permit held. A wait not shorter than the route's time left (`core.timeLeftOf`) is not taken, and the answer in hand is returned; each try runs under the time left at that moment, so the whole sequence ends by the route's deadline.

| | |
|---|---|
| `fetch.retry.Retry.problem()` | `?[]const u8`: what is wrong with the numbers, which is the text of the Refusal and of `s3.Store`'s `error.BadRetry` log line |
| `fetch.retry.Ledger` | the budget's counts, 264 bytes, one per target that declares `.retry` and one per `s3.Store`; `fetch.retry.Tries` is one call's progress, on the stack, for a module that retries a round trip of its own (`nilo_s3` does) |
| `fetch.retry.retryAfterMs(value, now_s)` | `?u64`, the header's wait in milliseconds, or null |
| `fetch.testing.Canned.serveScript(script, count)` | answers `count` requests from `[]const fetch.testing.Reply`, one connection each and `Connection: close`; `canned.tried` has how many arrived, when, and `headOfTry(n)` the head of each |
| `canned.requestEncoding()` / `canned.requestBodyDecoded(gpa)` | the request's `content-encoding`, and the request body with a `gzip` or `zstd` coding undone (the first kilobyte is kept, so `error.BodyTruncated` for a larger one); `requestBody()` stays the bytes as they arrived |
| `fetch.testing.Canned.serveUpload()` | reads a **chunked** request body chunk by chunk and answers when it ends; `canned.uploadSeen()` is the payload so far and `canned.chunks_seen` counts the chunks, each updated the moment it arrives, so a test can see a line was there before the caller finished |
| `fetch.testing.Canned.serveWebSocket(steps)` | accepts one connection, answers its WebSocket handshake with a `101`, then plays `[]const fetch.testing.WsStep` at it: `.send` a `WsFrame` (opcode, payload, `fin`, a `declared_len` that lies), `.read` one frame, `.hold_until_closed`, `.sleep_ms`. `canned.ws_seen` has the frames it read, each with its mask bit and payload; `ws_protocol`, `ws_accept` and `headers` bend the handshake; `wsUrl(&buf)` is the URL |

### `fetch.Exchange`

**An `Exchange` is for a body too large to hold in memory.** The calls above hold the whole body in the Scope, which is right for an API that answers with JSON and wrong for anything measured in megabytes. An `Exchange` applies the same policy but leaves the body on the socket: **read the response head, decide, then move the bytes somewhere that is not memory.**

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
| `head.keep(c)` | the same `Head` copied into the Scope, valid after the body is read: one arena allocation the size of the header block ([ADR 187](../adr/187-a-head-that-outlives-its-body.md)) |
| `ex.take(c, max)` | the rest of the body as a `Str` in the Scope, refusing anything over `max`. A body that announced its length (and within `max`) is read into exactly that many bytes, and `error.BodyTooShort` if it ends short; a chunked one grows |
| `ex.readInto(buf)` | exactly `buf.len` bytes, or `error.BodyTooShort` |
| `ex.pipe(w)` | the rest of the body into a `*std.Io.Writer`, and how many bytes |
| `ex.stream(w, limit)` | one chunk into `w`, at most `limit`, and how many bytes; `0` means the end. It is what one socket read delivered, and it runs inside both timeouts, which the same call on `ex.reader` does not |
| `ex.discard()` | "I will not read this body; close the connection", for example after a probe that got the whole file. `max_drain` stays a policy, not a switch ([ADR 184](../adr/184-a-caller-that-knows-says-discard.md)) |
| `ex.end()` | required, and safe to call twice |

**`Begin.decode`** reads a gzip or zstd answer through this `Exchange` in a build that reads either, and does nothing in one that reads neither ([Compression](#compression)). **`Begin` options.** `Begin` takes `headers`, `host`, `authorization`, `content_type`, `user_agent`, `timeout_ms`, `route_left_ms` (the Scope's time left from `core.timeLeftOf`, which `Client.send` and the other calls fill in themselves; a caller of `Exchange.begin` with a Scope passes it to get the same narrowing), `stall_ms`, a `body` of `.none` / `.slice` / `.stream` (an `.upload` is only what `beginUpload` sets, and `begin` refuses it), and `origin_only` (header names that never leave the origin the call was made to, in addition to the credentials above), and `redirects`: `.refuse` (the default; a 3xx with a `Location` fails with `error.RedirectRefused`), `.follow = &buf` (followed up to ten deep, resolved in the buffer, which bounds one URL plus one Location and not the chain, and held to the origin rule in [Redirects](#redirects)) or `.expose` (the 3xx returned as it is, which is what a signed request and an S3 client want) ([ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)). A name in `headers` that std has a slot for tells std to leave its slot out, so the line is sent once. The explicit fields are for a caller who has the value but not a whole header line; setting both a field *and* the line sends two lines ([ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)). `transfer_buffer` is only for a caller who reads buffered data from `ex.reader`: `take`, `readInto`, `pipe` and `stream` never fill it, and the empty default is the normal case ([ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)).

**A `.stream` body is sent on a connection no pool held.** It is a reader that cannot be read twice, so it cannot be replayed onto a second connection when the first turns out to be one the server closed while it idled, the case that protects a `.slice` body. Instead it never meets one: the call uses a second std client whose pool keeps nothing, so every streamed body opens a connection (one TCP handshake, plus TLS over `https://`) and closes it after. Calls with a slice, no body or `get` are unchanged, and the second client costs nothing until the first streamed body, when an `https://` call scans the system's root certificates once, as the first call on the main client does.

**Do not copy an `Exchange` once it has begun**, because it holds a `std.http.Client.Request`. Declare it, fill it in place, and leave it there.

### `fetch.WebSocket`

**A WebSocket opened from a URL, to consume a feed or hold a platform's gateway.** It is an `Exchange` that was upgraded: the open is a GET asking for `Upgrade: websocket`, so the client's gate, `timeout_ms` and the route's deadline, TLS and the roots from `Settings.roots`, `Call.unix_socket`, the request id and the trace all apply to it unchanged, and the permit goes back as soon as the `101` is in ([ADR 281](../adr/281-nilo-fetch-opens-a-websocket-and-the-framing-is-core.md)).

<!-- compiles: body -->
```zig
var ws: fetch.WebSocket = .idle;
defer ws.deinit();
try ws.open(&client, c, "wss://stream.example.com/prices", .{ .idle_ms = 30_000 });
try ws.sendJson(.{ .op = "subscribe", .channels = [_][]const u8{"BTC-USD"} });
while (try ws.receive()) |message| {
    // message.data is borrowed: copy what must outlive the next receive
    _ = message.kind; // .text or .binary
}
if (!ws.closedCleanly()) {} // the connection stopped without a close frame
_ = ws.close(.normal, "done");
```

| | |
|---|---|
| `ws.open(client, c, url, call)` | dial and ask to become a WebSocket. `ws://`, `wss://`, and `http://` and `https://` for the same two; anything else is `error.UnsupportedUriScheme`. `c` is a Scope. A refusal leaves the socket as it was, so one variable can be opened again |
| `ws.receive()` | `?Message`: `.kind` (`.text` or `.binary`) and `.data`, **borrowed until the next `receive`, `send` or `close`**. Null when the conversation is over, by a close frame or by the connection stopping. Pings are answered inside it and pongs and close frames are not the caller's |
| `ws.send(kind, data)`, `sendText`, `sendBinary` | one message in one frame, masked. `error.Closed` on a socket that is closed or closing |
| `ws.sendJson(value)` | `value` written as JSON and sent as one text message, on the client's allocator, freed before it returns. Text is refused while compiling |
| `ws.ping(data)` | a ping, cut to 125 bytes; its pong is swallowed by `receive` |
| `ws.close(code, reason)` | the close frame out, then the other side's awaited for at most `close_timeout_ms`. `.acknowledged`, `.timed_out` or `.dropped`; the connection is destroyed whichever |
| `ws.deinit()` | lets the socket go **without waiting**: an open one gets a close frame with 1000 written and is destroyed. Safe twice, after `close`, and on one that never opened |
| `ws.status` | the status the upgrade was answered with, readable after `error.UpgradeRefused` |
| `ws.subprotocol` | the subprotocol the server chose: one of the caller's `protocols`, or null |
| `ws.closedCleanly()`, `ws.closeCode()`, `ws.closeReason()` | whether the other side closed with a close frame, and the code and reason it gave |
| `ws.isOpen()` | whether `receive` and `send` can still be called |

**`fetch.websocket.Call`.**

| Field | |
|---|---|
| `headers` | sent with the handshake, in order. A name the handshake writes (`upgrade`, `connection`, `sec-websocket-key`, `-version`, `-extensions`, `-protocol`) is `error.ReservedHeader` |
| `protocols` | the subprotocols offered, in order of preference. A name that is not an HTTP token is `error.InvalidProtocol` |
| `timeout_ms` | how long the **open** may take, overriding `Settings.timeout_ms`; the route's deadline narrows it as for any call. It bounds nothing after the `101` |
| `max_message` | the biggest message `receive` assembles, **in decoded bytes, all the pieces of a message together**. Default `fetch.websocket.default_max_message`, 1 MiB. A frame announcing more than is left of it is refused on its header and closes the socket with 1009 (`error.MessageTooBig`) |
| `idle_ms` | how long `receive` may wait with nothing at all arriving before it is `error.Stalled`. Default 0, never: a quiet socket is working |
| `close_timeout_ms` | how long `close` waits for the other side's close frame. Default 5,000 |
| `unix_socket` | open over the unix socket at this absolute path, as `Client.Call.unix_socket` does; `wss://` is `error.TlsOverSocket` |

**Errors.** Beside the client's own (`TimedOut`, `Stalled`, `NotStarted`, `TlsOverSocket`, the transport's): `error.UpgradeRefused` (the answer was not `101`; the status is `ws.status`), `error.BadHandshake` (a `101` that is not the answer to this request: no `Upgrade: websocket`, no `Connection: Upgrade`, an accept key that is not the hash of ours, an extension or a subprotocol nobody offered), `error.ReservedHeader`, `error.InvalidProtocol`, `error.ProtocolError` (the other end broke the framing; closed with 1002), `error.MessageTooBig` (1009), `error.InvalidPayload` (text that is not UTF-8; 1007) and `error.Closed`. After any error from `receive`, it returns null.

**Every frame the client sends is masked with four fresh bytes from `std.Io`** (RFC 6455 §5.3), applied as the payload is copied into the write buffer; the caller's slice is never written to. **There is no permessage-deflate**: the client offers no extension and refuses an answer that names one.

**A proxy.** `Settings.proxy` carries a `ws://` open the way it carries an `http://` call, as a forward proxy request, and most forward proxies do not pass an upgrade: name the host in `Proxy.bypass` to open it directly. A `wss://` open is `error.TlsThroughProxy` for the reason an `https://` call is ([ADR 267](../adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)).

**One fiber at a time.** `receive` writes the pongs, so `send` from a second fiber while the first is in `receive` would interleave two frames. A feed read in one place and written from another is two sockets or a queue between them.

**Do not copy a `WebSocket` once it has opened**, for the reason an `Exchange` must not: it holds one. A `WebSocket` is 1,200 bytes, on the frame of the fiber that holds it.

**Nothing is allocated for a message that arrived whole in the connection's read buffer**, which is every message a feed sends and nearly every one under 8 KiB: a server never masks, so it is handed over where it lies. A larger or fragmented one is collected in one buffer the socket holds, grown to the largest message seen and never past `max_message`, and freed at `deinit`.

### `fetch.testing`

**A canned server for your own test suite**: one real exchange over a loopback socket on `std.Io.Threaded`, with no Engine anywhere. It is what the module's own tests use, exported ([ADR 061](../adr/061-a-fitting-borrows-the-loop.md)).

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
| `Canned.open(io)` | bound to port 0 on loopback, with the port the kernel chose read back, so there is no port range to keep separate from anybody else's |
| `Canned.openUnix(io, path)` | the same server on a unix socket at `path` (absolute, at most 107 bytes), for a test of `Call.unix_socket`. `port` is 0 and `url` means nothing: send your own URL, whose host is only the `Host` header. The socket file is yours to remove ([ADR 272](../adr/272-a-call-names-the-socket-it-goes-over.md)) |
| `canned.reply(status, headers, body)` | what `serveOne` answers: the status line after `HTTP/1.1 `, headers each ending in `\r\n` (`Content-Length` is written for you), and the body as given |
| `canned.replyGzip(out, status, headers, plain)` | `reply`, with `plain` gzipped into `out` (which must outlive the exchange) and `Content-Encoding: gzip` added, so a caller's decode path is testable in a `-Dfetch_gzip` build ([ADR 292](../adr/292-a-fetch-build-can-read-a-gzip-answer.md)). The stream is in `canned.body`, where a test can damage it. `error.NoSpaceLeft` when `out` is too small |
| `canned.replyZstd(out, status, headers, plain)` | `replyGzip`'s counterpart: `plain` as one zstd frame under `Content-Encoding: zstd`, so a decode path is testable in a `-Dfetch_zstd` build ([ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)); needs `.zstd = true`, which this repository's tests have. `fetch.testing.inflateZstd(gpa, frame)` is the decode a test applies to a frame it holds |
| `canned.url(&buf)` | `http://127.0.0.1:<port>/` |
| `canned.serveOne()` | accepts one connection, reads the whole request, answers, and closes. **Start it with `io.concurrent`**, never `io.async`, which may run it on your own thread and wait there for the connection you were about to make |
| `canned.request()` | the request head that arrived, one line per header, `\n` between them |
| `canned.requestBody()` | the request body that arrived, up to a kilobyte |
| `canned.close()` | |

The client is finished with `nilo_start(io, .none)`, as `listen()` would have done. `.none` means "no Engine to arm a deadline on", and the client then enforces the timeout itself ([ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)).
