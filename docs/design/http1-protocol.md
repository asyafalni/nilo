# The HTTP/1.1 wire protocol

**Nothing crosses the wire two ways: a request the front end and nilo could read differently is refused, and a header nilo says it answers gets the exact answer RFC 9112 defines and nothing adjacent.** How a request is read is the guide ([`guide/requests.md`](../guide/requests.md), [`guide/forms.md`](../guide/forms.md)); the fields it produces are the reference ([`reference/ctx.md#reading`](../reference/ctx.md#reading), [`reference/app.md#listen-options`](../reference/app.md#listen-options)). The code is `http/http1.zig` (`parseHead`, `parseRequestLine`, `finish`, `Encoding`), `http/ctx.zig` (`aboutToReadBody`, the gzip inflate inside `body`), `http/static.zig` (`etagMatchesStrong`) and `http/bulkhead.zig` (`read_buffer`).

## How the pieces fit

```
  bytes off the socket
        │
        ▼
  parseRequestLine ──► absolute-form? split authority, route the rest
        │
        ▼
  applyHeaderAt, one header at a time ──► Expect, If-Range, filename*
        │                                  answered as asked, or refused
        ▼
  finish (the blank line)
        │
        ├─► Content-Length / Transfer-Encoding disagree, repeat, or          } error.BadHeader,
        │   frame both ways ─────────────────────────────────────────────── } already a 400
        ├─► HTTP/1.1 with no Host, or two of them ────────────────────────── }
        └─► Content-Encoding other than identity or gzip on a body ──────── 415
        │
        ▼
  Ctx.body() ──► gzip? inflate once into the arena, bounded by max_body
```

Every one of these checks lives at the point that first knows the answer rather than in the header arm that read the value, because whether there is a body to refuse, or which host answered, depends on more than one header read in whatever order the client sent them.

## The rule in force

1. **A request nobody else on the chain would answer is refused rather than resolved.** `Content-Length` that is not `1*DIGIT`, a repeated `Content-Length` that disagrees, `Content-Length` beside chunked framing, and a `Transfer-Encoding` whose final coding is not `chunked` are all `error.BadHeader`, because guessing which reading a front end already committed to is how one request becomes two. [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md)
2. **An HTTP/1.1 request needs exactly one `Host`.** None, or two, is a 400; a repeat is refused even when both copies agree. HTTP/1.0 is left alone, because `Host` was never required before 1.1. [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md)
3. **An absolute-form target supplies its own authority, and that authority is the Host, full stop.** RFC 9112 says a server receiving `GET http://example.com/x HTTP/1.1` must ignore a `Host` header and use the target's authority instead; a request in this form with no `Host` line is not the 400 that rule 2 otherwise is, because the first line already said which host it wanted. [ADR 095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md)
4. **A target is read in the form it arrived in.** Origin-form is routed as the path it always was; absolute-form is split into an authority and an origin-form path before routing; asterisk-form (`*`) and authority-form (`CONNECT`) pass through unchanged, because neither names a route here and refusing them outright would refuse a request somebody else answers. [ADR 095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md)
5. **Userinfo in an absolute-form target is refused**, because `http://real.example.com@evil.example.net/` names `evil.example.net` and every human reading the line sees the first name. An empty path carrying a query (`http://example.com?a=1`) is refused too, since serving it would mean an allocation to insert the missing `/` or dropping the query silently; a target with no path and no query is served as `/`. [ADR 095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md)
6. **`Expect: 100-continue` is answered at the moment nilo commits to reading the body, not when the header is parsed.** A request refused before that point (an oversized body, a 404, a 405, a handler that never asks) gets its final status and the body is never sent at all. HTTP/1.0, an already-answered request, and `Content-Length: 0` send nothing. [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)
7. **`If-Range` is a strong comparison and never the `If-None-Match` one.** `etagMatchesStrong` refuses a `W/` tag, refuses `*`, and treats an empty ETag as matching nothing, because a resumed download staples bytes onto a prefix it already holds and "close enough" is the one answer that corrupts it. [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)
8. **A multipart part naming its file only with `filename*` is a 400 naming the part, not a text field with the wrong value.** nilo still does not decode RFC 6266's encoded form; it stops silently mis-binding the part instead. [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)
9. **A body under `Content-Encoding: gzip` is inflated once into the request arena; every other coding but `identity` is a 415 naming the header.** The trailer's declared length sizes one exact allocation, checked against `max_body` before a byte is inflated, so a small compressed body cannot inflate past the same ceiling an uncompressed one is held to. [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)
10. **`Content-Encoding` on a request with no body is left alone.** Refusing it would turn a GET everybody answers into a 415 over a header with no effect, the opposite of what rule 1 is for. [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)
11. **`c.bodyStream()` decodes nothing and refuses every coding with its own 415.** A stream hands bytes out as they arrive with nothing to hold the decoder's history against. [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)
12. **`read_buffer` defaults to 16 KiB, and it is still the ceiling on a request head as well as the connection's read buffer.** A head that does not fit is a 431; a server that wants the old number passes `.read_buffer = 8 * 1024`. [ADR 196](../adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)

## Decisions

| ADR | What it decides |
|---|---|
| [070](../adr/070-a-request-nobody-else-would-answer-is-refused.md) | Which framing ambiguities (`Content-Length`, `Transfer-Encoding`, `Host`) are refused rather than guessed at |
| [073](../adr/073-a-header-is-answered-as-asked-or-refused.md) | `Expect: 100-continue`, `If-Range`, and `filename*` each get the answer RFC 9110 defines |
| [089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md) | Which `Content-Encoding` nilo decodes, and how gzip is inflated with no pool |
| [095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md) | The four request-target forms, and which one supplies the Host |
| [196](../adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md) | The default size of `read_buffer`, and the head ceiling that follows from it |

Beside this topic: TLS is terminated in front rather than by nilo, which is the whole reason a second parser reading the same bytes is a smuggling risk at all, is [ADR 027](../adr/027-tls-is-terminated-in-front.md); the head being parsed in place, which is why the buffer is the ceiling rather than a number configured on its own, is [ADR 085](../adr/085-every-header-without-handing-out-the-head.md); a fiber's stack held at its high-water mark, which is what turns a struct field on `Request` into a per-connection cost, is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md); reading a trusted `X-Forwarded-Host` ahead of the authority is [ADR 090](../adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md); the arena bound a compressed body is already held to before it is inflated is [ADR 083](../adr/083-a-body-is-taken-as-it-arrives.md).

## Open

- **What a connection holds mid-request under the 16 KiB `read_buffer`** is arithmetic (two more pages than before) rather than a measured reading; `docs/roadmap.md`'s Measurements outstanding table names the run, `bench/mem.py --hold` against `bench-stream-server` at 8 and at 16.
- **RFC 6266's `filename*` stays refused rather than decoded**, on the record in [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md): `core/percent.zig` could decode it, and it waits on a caller who sends the encoded form alone rather than beside a plain `filename`.
