# The request

One page of [the reference](./README.md): one request in flight: reading it, answering it, its cookie, session and uploads, and failing it.

## `Ctx`

### Reading

| | |
|---|---|
| `c.method` | `.GET`, `.POST`, … |
| `c.path()` | `Str` — the path, without the query string |
| `c.param(name)` | `?Str`, percent-decoded. `"*"` for a catch-all |
| `c.routeName()` | `?[]const u8` — the `operationId` of the route that matched, as the API description prints it: what `app.named` gave it, or the derived `getUsersId`. Null when nothing matched — a 404, a 405, a static file. For a middleware holding one authorisation table over every route ([ADR 0201](../adr/0201-a-middleware-can-learn-which-route-it-is-in-front-of.md)) |
| `c.query(name)` | `?Str`, percent-decoded, `+` as space |
| `c.queries()` | an iterator over every query parameter, in arrival order — `while (it.next()) \|q\|`, `q.name` and `q.value` are `Str`. A name sent twice appears twice |
| `c.queryString()` | `Str` — the query as it arrived, still encoded, no `?` on the front. `""` when there was none |
| `c.host()` | `Str` — the host this request was addressed to. `X-Forwarded-Host` under `trusted_hops`, else the authority of an absolute-form target, else the `Host` header |
| `c.scheme()` | `Str` — `"https"` or `"http"`, what the **client** used. `X-Forwarded-Proto` under `trusted_hops`, else always `"http"` |
| `c.header(name)` | `?Str`, name matched case-insensitively. The **first** of that name |
| `c.authorization(.bearer)` | `!Authorization(.bearer)` — the header as one scheme, or the 401 with the challenge on it. For a resolver; a handler asks in its argument list |
| `c.headers()` | an iterator over every header, in arrival order — `while (it.next()) \|h\|`, `h.name` and `h.value` are `Str` |
| `c.cookie(name)` | `?Str` — as the client sent it, nothing decoded. Allocates nothing |
| `c.body()` | `!Str` — the whole body, up to `max_body` (1 MB) |
| `c.json(T)` | `!T` — the body parsed as JSON |
| `c.form(T)` | `!T` — the body parsed as a form, urlencoded or multipart |
| `c.jsonCollecting(T, &outcomes)` | `!T` — as `json`, recording why each field failed |
| `c.formCollecting(T, &outcomes)` | `!T` — as `form`, recording why each field failed |
| `c.requestId()` | `Str` — this request's id, from `X-Request-Id` or generated |
| `c.entropy(n)` | `![n]u8` — unguessable bytes from the OS, off the event loop. `n` is comptime |
| `c.entropyInto(buf)` | `!void` — the same, at a width nobody said while compiling |
| `c.hashPassword(gpa, text)` | `!pw.Hash` — argon2id, salted, off the loop and behind the Gate |
| `c.hashPasswordWith(cost, gpa, text)` | the same, at a `pw.Cost` of your own |
| `c.verifyPassword(gpa, stored, text)` | `!bool` — `stored` is `?[]const u8`; null means no such account |
| `c.verifyPasswordWith(cost, gpa, stored, text)` | the same, told what a hash of yours costs |
| `nilo.verifyPassword(gpa, stored, text)` | the same check with no request in hand — a CLI, a job, a test. Same Gate; see [`nilo_pw`](./pw.md) |
| `c.bodyStream()` | `!Body` — the body in pieces |
| `c.bodyStreamWith(.{ .max_bytes = … })` | the same, with a ceiling. Default 64 MB |
| `c.peer()` | the address the connection came from — the proxy's, if there is one |
| `c.clientIp()` | `Str` — the client, looking through `trusted_proxies` or `trusted_hops`. Empty on a unix socket with neither set |
| `c.stopping()` | `bool` — the server has been told to stop and is draining. What the health page answers `stopping` on |
| `c.overdue()` | whether the deadline `nilo.deadline(ms)` gave this route has passed. Always false without one |
| `c.timeLeftMs()` | `?u32` — milliseconds left, `null` without a deadline, `0` once it has gone |
| `c.giveDeadline(ms)` | set one by hand. `nilo.deadline(ms)` is what normally calls this |
| `c.giveBodyLimit(bytes)` | how much body this request may read into the arena, over `listen()`'s `max_body`. `nilo.maxBody(bytes)` is what normally calls this; a body already read keeps the limit it was read under |
| `c.service(*Db)` | `?*Db` |
| `c.resolve(V)` | `!V` — a resolved value, worked out once per request |
| `c.keepAlive()` | whether the connection will carry another request |
| `c.arena()` | `std.mem.Allocator` — memory that lasts exactly this request. Never freed by hand |
| `c.str(bytes)` | `Str` — text you allocated from `c.arena()`, stamped with this request's lifetime |

### Answering

| | |
|---|---|
| `c.setHeader(name, value)` | copied into the request arena |
| `c.setStaticHeader(name, value)` | not copied — for text that already outlives the request |
| `c.setCookie(cookie)` | a `Set-Cookie`. Calling it twice sets two, not one |
| `c.clearCookie(.{ .name = …, .path = …, .domain = … })` | delete one. Path and domain have to match |
| `c.redirect(status, location)` | a `Location` and no body |
| `c.send(status, content_type, bytes)` | |
| `c.sendText(status, text)` | `text/plain` |
| `c.sendJson(status, value)` | `application/json` |
| `c.sendEmpty(status)` | no body and no `Content-Type` — a 204, usually |
| `c.sendFile(.{ .file = f, .content_type = … })` | an open file. **Closed here**, on every way out |
| `c.stream(status, content_type)` | `!Stream` |
| `c.streamWith(status, content_type, .{ .buffer = … })` | the same, buffer of your own. Default 4 KB |
| `c.streamWith(…, .{ .length = n })` | a stream whose length is already known: `Content-Length` and no chunk framing ([ADR 0128](../adr/0128-a-stream-that-knows-its-length-says-so.md)) |
| `c.url(pattern, args)` | `!Str` — a URL for a route, every value percent-encoded and every mistake a compile error ([ADR 0127](../adr/0127-a-route-pattern-is-the-name-of-its-url.md)) |
| `c.events()` | `!Events` |
| `c.upgrade(loop, state)` | `!void` — the connection becomes a WebSocket and `loop` reads it. `{}` when there is no state |
| `c.upgradeWith(loop, state, .{ .protocol = "chat.v1" })` | the same, naming a subprotocol |

`Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` are
refused by `setHeader`. So is a name that is not a token, and a value holding a
control byte — a newline in one would start a second header, and two would start
a second response ([ADR 0087](../adr/0087-a-header-value-cannot-end-its-own-line.md)).
All three are a 500 naming the header. Set headers before sending. Setting the
same header twice replaces it — except `Set-Cookie` and `Vary`, which a response
may carry more than one of. `Set-Cookie` because two cookies cannot be folded
into one line; `Vary` because two layers each name their own axis, and replacing
threw one away ([ADR 0089](../adr/0089-two-layers-can-each-name-a-vary-axis.md)).
Setting either with a name and value already present adds nothing.

**`host()` and `scheme()` are how a handler writes a URL to its own service** —
a password-reset link, an OAuth `redirect_uri`, an absolute `Location`. nilo
does not speak TLS, so with no `trusted_hops` set `scheme()` is always
`"http"`; behind a proxy set it and the two headers that proxy writes are
believed, exactly as `X-Forwarded-For` is
([ADR 0112](../adr/0112-a-request-can-be-read-past-the-parts-a-handler-names.md)).
A forwarded host that is not host-shaped is dropped rather than used, because
this ends up in a link somebody clicks.

**A target that arrived in absolute form answers `host()` before the header
does.** `GET http://example.com/users/7` is what a client sends to what it
believes is a proxy, and RFC 9112 §3.2 gives an origin server no choice: the
authority on the request line is the host, and a `Host` header beside it is
ignored ([ADR 0120](../adr/0120-a-target-is-read-in-the-form-it-arrived-in.md)).
The router still matches on the path, so nothing about writing routes changes.
A trusted `X-Forwarded-Host` outranks both.

**A body arriving under `Content-Encoding: gzip` is inflated into the arena
before anything reads it** — `body`, `json`, a struct argument, a form — bounded
by `max_body` on both sides of the inflating, and a 400 naming the coding when
it does not decode
([ADR 0251](../adr/0251-a-gzipped-body-is-inflated-into-the-buffer-that-holds-it.md)).
`bodyStream` does not decode and answers a gzipped body with a 415. **Any other
coding is a 415** naming the header, before any handler runs
([ADR 0111](../adr/0111-a-body-under-an-encoding-nilo-cannot-read-is-refused.md)).
The header on a request with no body is ignored.

**A stream with a `.length` is held to it.** Writing past the promise is
refused before a byte of the overrun goes out, because a client reading a
`Content-Length` stops there and everything after it is read as the next
response. Finishing short cannot be refused — the head has gone — so the
connection closes and the log names both numbers.

**`c.url` is checked while compiling.** A param with no value, a value with no
param, a value a path segment cannot carry and a `*` catch-all are all compile
errors naming the field. Values are matched by name, so `.{ .slug = t, .id = 42 }`
and `.{ .id = 42, .slug = t }` are the same URL. `nilo.url.into(buf, pattern, args)`
is the same call with a buffer of your own and no allocation, for code with no
request in flight.

`sendFile` also takes `size` (null asks the file), `etag` and `cache_control`,
and answers a `Range`, an `If-Range`, an `If-None-Match` and a `HEAD` from them.
A handler that knows it is answering with a file before it runs returns
[`FileBody`](./handlers.md#handler-returns) instead, which the API description can see.

## `Cookie`

What `c.setCookie` takes. Only `name` and `value` have no default.

| | Default |
|---|---|
| `name`, `value` | — |
| `path` | `"/"` |
| `domain` | `""` — this host, no subdomains |
| `max_age` | `null` — a session cookie |
| `expires` | `""` — an HTTP-date, if you have one |
| `secure` | `true` |
| `http_only` | `true` |
| `same_site` | `.lax` — or `.strict`, `.none`, `.unset` |

A value holding a space, comma, semicolon, quote, backslash or control byte is
refused with a 500: a `;` would start an attribute nobody wrote. `.none`
without `.secure` is refused for the same kind of reason — browsers drop it.

## `Session(T)`

The session, sealed into one cookie. `T` is a struct of yours of a size known
while compiling — numbers, bools, enums, `[N]u8`, optionals and structs of
those. Not slices. See [Sessions](../guide/sessions.md).

| | |
|---|---|
| `s.get()` | `?T` — what the client sent, or null if it sent nothing readable |
| `s.set(value)` | replace it; one `Set-Cookie` on this response |
| `s.setWith(value, options)` | the same, with the cookie's attributes your own |
| `s.clear()` | sign out — deletes the cookie |
| `s.clearWith(.{ .path = …, .domain = … })` | the same, matching a cookie set elsewhere |

`setWith` options: `path` (`"/"`), `domain` (`""`), `max_age` (`null` — a
session cookie), `secure` (`true`), `same_site` (`.lax`). No `http_only`: it
is always on.

`max_age` sets the cookie attribute **and** an expiry sealed inside the cookie,
where the client cannot reach it — `Max-Age` alone is advice a copied cookie
does not take. Null seals `nilo.session.default_max_age`, 24 hours
([ADR 0088](../adr/0088-an-expiry-a-client-can-ignore-is-not-one.md)).
`nilo.session.openAt(T, cookie, key, when)` opens one against a time you name,
for a test that wants the boundary without a wall clock.

Every way a cookie can be unreadable — tampered, truncated, expired, sealed
under another secret, written by a build with a different shape of `T` — is the
same answer, `null`. The secret comes from
`listen(.{ .session_secret = … })` and must be exactly 32 bytes; a handler
asking for a session with none set answers 500.

## `Upload`

One file out of a multipart form, as a `Form(T)` field type.

| | |
|---|---|
| `u.filename` | `Str` — **what the client said**, never a path to write to |
| `u.content_type` | `Str` — the client's claim, unverified |
| `u.bytes` | `Str` — the file itself |
| `u.len()` | how big it is |
| `u.saveTo(dir, name)` | `!void` — write it into a [`Dir`](./streaming.md#dir) under **a name of yours** |

`saveTo` replaces the file at `name` or leaves it untouched: the bytes go to a
temporary name beside it and one rename puts them in place, so a request
serving that same name out of the same `Dir` never reads it half-written
([ADR 0123](../adr/0123-a-file-is-written-by-the-engine.md)). Handing `u.filename`
in as the name is `error.NameNotAllowed`, not a path resolved against the
directory.

## Failing

| | |
|---|---|
| `fail.badRequest(fmt, args)` | 400 |
| `fail.unauthorized(…)` | 401 |
| `fail.forbidden(…)` | 403 |
| `fail.notFound(…)` | 404 |
| `fail.conflict(…)` | 409 |
| `fail.tooLarge(…)` | 413 |
| `fail.unprocessable(…)` | 422 |
| `fail.tooManyRequests(…)` | 429 |
| `fail.internal(…)` | 500 — logged, not sent |
| `fail.status(code, fmt, args)` | any |

All return `error.Failed`. The message goes into a 240-byte slot, no allocation,
and goes out as `{"error": "…", "status": 404}` — the same shape for every
failure, whatever the endpoint returns when it works.
