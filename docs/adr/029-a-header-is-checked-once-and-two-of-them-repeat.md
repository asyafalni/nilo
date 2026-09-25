# A header is checked once, and two of them repeat

**Status:** accepted
**Topic:** [cookies-sessions](../design/cookies-sessions.md)

## Context

nilo had no cookies at all until 0.1.0 was nearly done. Nothing had been decided about them; they were simply missing, and `docs/guide/middleware.md` had been quietly writing "behind a cookie" in an example for weeks. Somebody coming from Express or Gin reaches for `c.cookie("session")` inside the first ten minutes, finds `c.header("Cookie")`, and has to split `a=1; b=2` themselves.

Building that mechanism surfaced a rule bigger than cookies. `Ctx.setHeader` had always replaced: setting a header twice is somebody changing their mind, and the second call wins. Applied to `Set-Cookie`, that rule is a bug with no symptom, a handler that sets a session and a preference cookie delivers only the second, and nothing anywhere says so. And the rule turned out to be wrong a second way, one this repository had already stated twice without generalising it: `cookie.check` refused a `;` in a cookie value because there is no escaping in that grammar, and `Ctx.requestId` refused a client-supplied id with a newline in it, because a newline forges a line of its own and in a response header splits the response. What neither covered was the general case. `putHeader`, the one function every response header goes through, checked only `isReservedHeader`, and `Ctx.setHeader`, `setStaticHeader`, a `Response(T)`'s `.headers`, a `Redirect(status)`'s `.headers` and every built-in middleware wrote whatever bytes they were handed. The framework's own documented redirect example fed it untrusted text (`.to(try db.target(code.view()))`), and `Set-Cookie` written as a plain header, exactly what a sign-in answer does, reached `putHeader` directly and never saw `cookie.check` at all.

`Vary` turned out to be the same shape as `Set-Cookie`, from the opposite direction. Two places in the framework set it independently, unaware of each other: CORS sets `Vary: Origin` when the origin is named, and `serveHeldFile` sets `Vary: Accept-Encoding` when a file has a gzipped copy. Middleware runs before the handler, always, so on any app with a named-origin CORS in front of gzipped static files, which is an ordinary way to deploy, the first `Vary` was set and then silently overwritten by the second. "Last one wins" is right when one author sets a header twice; it is a fact being lost when two layers that do not know about each other each state something independently true about the same response.

## Decision

### Reading a cookie allocates nothing, and decodes nothing

`c.cookie(name)` walks the `Cookie` header where it lies and hands back a `Str` pointing into the request head, the same thing `c.header` does and for the same reason ([ADR 017](017-the-trade-budget-has-four-axes.md)'s per-request allocation invariant). A map built on the way in would be an allocation on every request that carries cookies, to save a scan on the few that read more than one; a request with four cookies through a route that reads one allocates zero times.

**Decoding does not happen.** RFC 6265 §4.1.1 makes a cookie value opaque octets, and every framework layers its own encoding on top, percent, base64, signed-then-base64; there is no way to tell which one a value used, so guessing corrupts the ones that guessed otherwise. What went out is what comes back, minus the quotes if the writer used them. Stated in the guide rather than left to be discovered, because it is the one place a Node person's habits do not transfer: `cookie-parser` decodes, this does not.

### Every response header goes through one choke point, and it checks the name and the value

`putHeader` is that choke point, for the same reason `Ctx.aboutToRead` is one for a body read ([ADR 022](022-a-deadline-belongs-to-an-operation-not-to-a-request.md)): one place every path already goes through, so a new way to set a header gets the check without anybody remembering to give it one. Three refusals, one shape:

| | Refused | Because |
|---|---|---|
| reserved name | `Content-Type`, `Content-Length`, `Transfer-Encoding`, `Connection` | two of any is malformed, and two `Content-Length` is smuggling |
| the name | anything that is not RFC 9110 §5.1 `token` | a space or a colon ends the name early and starts a field nobody wrote |
| the value | anything below `0x21` that is not SP or HTAB, and `0x7F` | CR and LF start a second header; NUL and DEL mean the value came from somewhere it should not have |

`obs-text`, everything from `0x80`, is allowed: deprecated, and also what a UTF-8 filename in a `Content-Disposition` is made of, and it cannot terminate a line, which is the only thing being defended.

The content type is the one header value that never passes through `putHeader`, because it is chosen through `send`, `streamWith` or a file body rather than set, and until a review found `c.send(200, "text/plain\r\nX-Injected: 1", …)` sending the injected header it had no check at all. `Ctx.contentTypeOk` is the value check above, applied where each of the three takes its type and before the response is marked answered, so the refusal can still go out.

All three refusals are `fail.internal`, matching `setCookie`: a malformed header is a mistake in the server, not in the request, so the 500 names the header and which rule it broke rather than reaching the client as a bare "internal server error". **The value is never quoted back**, since it is the half most likely to have come from a request, and echoing it would hand the sender a way to read what the check caught.

### Two headers repeat, for opposite reasons

`http1.repeats(name)` lists the response headers `putHeader` does not fold into a replace, and `Set-Cookie` and `Vary` are on it for opposite reasons. RFC 6265 §3 forbids folding a cookie into a comma-separated value (an `Expires` attribute contains a comma, which is how that ended up being true), so a server sending two cookies sends two `Set-Cookie` lines and `putHeader` skips its replace loop for it, appending instead. `Vary` is a list field (RFC 9110 §12.5.5) where folding is *allowed*, so joining "Origin" and "Accept-Encoding" would be correct on the wire, and it is not done anyway: both inputs are borrowed constants set through `setStaticHeader` precisely so nothing is copied, and building a joined string would put an arena allocation on the static-file path, the path ADR 017's hard invariant is about. Two entries in a list that already exists cost nothing. An exact duplicate, same name and same value, is dropped, since it is not a second fact and is what two middlewares that both depend on the origin would otherwise produce.

`inline_headers` is 7, not 6, because the shape above (CORS setting `Vary: Origin`, the static file setting five headers including `Vary: Accept-Encoding`) sets seven, and with six held inline the seventh spilled to the arena, an allocation on exactly the path this was meant to fix. The test that set six aside was written to fail first (`expected 0, found 1`) before the constant moved. A CORS with `credentials` or `expose` set still spills, at nine.

### The cookie defaults are the careful ones

`.{ .name = "session", .value = token }` is `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`. The argument for permissive defaults is that they always work, which is the argument against them: forgetting `HttpOnly` reads exactly like not needing it, and the failure shows up in somebody else's XSS report rather than in a diff. Turning a protection off is now a visible line. `Secure` by default was the one worth checking rather than assuming: browsers have treated `http://localhost` as a secure context since 2020, so a development server sets and receives these normally, and the default costs nothing where people meet it first.

### A cookie value cannot carry its own delimiter

`.value = "abc; Path=/admin"` does not produce a broken cookie, it produces a cookie **with a path nobody wrote**, because `;` is the attribute separator and the grammar has no escaping to defend with. There is nothing to encode it as, so it is refused: `cookie.check` runs before anything is allocated, and a value carrying a character RFC 6265's `cookie-octet` does not allow is a 500 naming the character. The path, the domain and the expiry get the same refusal, against RFC 6265's `av-octet` (a printable character that is not `;`): a path built from the request's own turns `/x;Domain=example.com` into a cookie every subdomain is sent, and only the name and the value were checked until a review found it. `SameSite=None` without `Secure` is refused on the same footing, since every current browser drops that combination and the symptom is a cookie that silently never arrives.

### Consequences

`Ctx.cookie`, `Ctx.setCookie`, `Ctx.clearCookie`, `nilo.Cookie` and `nilo.SameSite` are the surface, nothing new on `App`. One arena allocation per cookie set, sized from `cookie.lengthOf` before it is written, held next to a test that checks the length and the writer agree. `clearCookie` takes a `Clearing` and not a name, because a browser matches a deletion on name, path *and* domain: a cookie set under `/admin` is not cleared by a deletion at `/`, and the signature puts the other two fields where they can be seen. Sessions are still not here: a cookie is the mechanism, what goes in it, where it is stored and how it is signed is policy ([ADR 033](033-a-session-is-sealed-into-the-cookie.md)). Reading a cookie is not a handler argument; a type carrying `nilo_resolve` already reads what it likes from the request and appears in an argument list by name, which is the mechanism a signed-in user goes through, and a second way in would have been a second thing to keep in step.

## What was rejected

**Escaping instead of refusing**, for both the cookie value and the general header check. There is nothing to escape *to*: RFC 9110 retired `obs-fold`, so a value cannot legally span two lines at all, and inventing an encoding would mean the client has to know about it.

**Stripping the bad bytes and carrying on.** A `Location` with the newline deleted is a *different URL*, sent silently. Refusing is louder, and the loudness is the point: the handler is passing text it did not check.

**Checking in `http1.writeHead` instead of `putHeader`.** One layer lower, catching the same bytes, but by the time it runs the status line has already gone out and there is nothing left to answer with. `putHeader` runs before anything is sent, which is what makes a 500 possible.

**A `Debug`-only check**, the way `Str`'s lifetime trap is. That trap catches a bug in *your* code, which a test run will reach; this one catches bytes that arrive from outside at three in the morning, and a check that is off in the mode people deploy in is not a check ([ADR 032](032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)).

**Refusing only the six bytes with a consequence, rather than the whole `token` and value grammar.** Built once, on the branch this shipped from, and the argument for it is real: a byte outside the strict grammar that still goes out as one header line and is read back as one cannot do harm on its own. Dropped for two reasons: a header name is written by the programmer and never by a request, so refusing more than the narrow reason costs nobody anything at runtime, while the narrow rule has to be re-argued every time somebody asks why *this* byte and not that one, and the RFC's grammar answers that question once and is what a downstream proxy with its own parser reads.

**Joining `Vary` values with a comma.** Correct and tidier on the wire, and it spends the one axis ADR 017 does not allow spending, an allocation on the static-file path.

**Leaving `Vary` alone because the CORS origin was a compile-time constant.** True the day it was written, and an argument about that day's CORS rather than about `Vary`; it would have had to be rediscovered once CORS learned more than one origin ([ADR 078](078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)), by which point the bug is silent and in a cache.

**Making the static file check whether CORS already set a `Vary`.** Couples two layers that have no business knowing about each other, in the direction that breaks first.

**Raising `inline_headers` to nine to cover CORS with credentials.** That case was already spilling and still is; paying 64 more bytes on every request to fix an allocation on a response already carrying nine headers is the wrong way round.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | Unchanged at zero on every path these checks touch: reading a cookie, checking a header name or value, and repeating `Set-Cookie` or `Vary` are all loops or list appends over memory already there. Setting a cookie costs one arena allocation, sized in advance. |
| Memory per idle connection | Unchanged. `inline_headers` moved from 6 to 7, 32 bytes on `serveRequest`'s frame, which is unwound before an idle connection waits ([ADR 062](062-where-a-connection-waits-is-what-it-costs.md)). Measured on Linux at 10,000 connections against a `v0.2.0` baseline: **4,810 bytes both sides**, a one-byte spread across four interleaved runs, confirming the frame reasoning held ([`bench/result/http.md`](../../bench/result/http.md)). |
| Throughput and p99 | The header check costs **3 to 8ns on a request `zig build profile` puts at 192ns**, so 2 to 4%, quoted as a range because the run-to-run spread is close to the effect's size; per `setHeader` call, so a response that sets none pays nothing. In process rather than over a socket, so a larger fraction here than served over a network. Repeating a header costs one extra comparison over a list of at most seven entries already in L1. `scan.positionsOf` was tried and cost 9ns instead of 3: it is built for whole 32-byte blocks and falls back to a scalar tail below one, which header names and values almost always are; a straight per-byte loop is the right tool here ([`bench/result/http.md`](../../bench/result/http.md)). |
| Binary size | Byte-identical, measured across four examples in a stripped `ReleaseFast` build ([`bench/result/http.md`](../../bench/result/http.md)). |

The one behaviour change visible to a user: a handler writing a header with a control byte in it now gets a 500 instead of a response somebody else could forge.
