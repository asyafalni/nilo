# 0243 — the ordinary call sends JSON and a query

**Status:** accepted
**Extends:** [ADR 0070](./0070-a-fitting-borrows-the-loop.md), which shipped
the policy half of the module; [ADR 0066](./0066-percent-is-needed-by-two-layers.md),
whose encoder this is the third caller of.

## Context

Two rounds of a real program made the policy half of `nilo_fetch` the strong
half: a gate, two clocks, a bounded drain, a body ceiling, a head that can be
kept. The ordinary call was the thin half, and `examples/outbound/main.zig`
was the evidence — `std.json.Stringify.valueAlloc` and a `content-type` line
by hand on every POST, and a search endpoint assembled through an
`Allocating` writer and `percent.encodeWrite` one param at a time. Both are
the first thing a handler calling somebody's JSON API writes, and both were
written the same way in every caller because the module offered nothing.

A third thing sat beside them: the guide's testing section told a suite of
somebody's own to *copy the shape of* `fetch/live.zig`'s `Canned`, because
the type was private to that file. Every such suite wrote a loopback server
again, and `s3/canned.zig` was already the second copy inside this
repository.

## Decision

Three things, and the shape of each is decided by one fact about Zig:
**a value of a type the caller chose cannot sit in a field of a struct nilo
declared.** `Client.Call` is a plain struct, and it has to stay one — the
moment the last argument is `anytype`, a `.headers = &.{.{ .name = …, .value
= … }}` literal loses its result type and stops coercing to
`[]const std.http.Header`, which is every existing call site. A union arm
cannot carry an `anytype` either. So the two things that take a value of the
caller's own are **functions**, where `anytype` is at home, and the thing
that takes none is a field.

- **`client.postJson(c, url, value, .{})`**, with `putJson`, `patchJson`
  and `sendJson(c, method, url, value, .{})` beside it. The value is written
  out with `std.json.Stringify.valueAlloc` into the Scope's arena and sent
  under `content-type: application/json` — unless `call.headers` carries a
  `content-type` of its own, which then goes once, the way ADR 0231 sends
  every header std has a slot for. **Text is refused while compiling**: a
  `[]const u8` handed here would go out as one JSON *string*, quotes and
  escapes and all, and the far end would answer 400 to a body that looked
  right in the editor. A body already encoded goes through `post`.

- **`fetch.withQuery(c, base, .{ .page = 2, .q = "a b" })`** answers
  `base?page=2&q=a%20b` in the Scope's memory. A field is an int, a bool,
  text (`[]const u8`, a string literal, a `Str`) or an optional of one, and
  a null optional is the param left out; any other type is a Refusal naming
  the field. A base that already has a `?` gets `&`, and one ending in `?`
  or `&` gets the first param straight after it. The space is `%20` and the
  hex is upper-case, for the reason `core/percent.zig` gives: both are the
  difference between a signed request that verifies and one that does not.
  A function that answers a URL rather than a `.query` field on `Call`, for
  the reason above — and a URL is what every call takes, `Exchange.begin`
  included, so one function serves all of them. **The path half is not
  built.** `"/v1/charges/{}"` with the segment encoded on the way in needs
  somewhere for the base to live, and that is a target, which is the
  roadmap's `nilo_fetch` Next 1.

- **`fetch.testing.Canned`** is `fetch/live.zig`'s server, moved to
  `fetch/testing.zig` and exported. `open(io)`, `reply(status, headers,
  body)`, `url(&buf)`, `serveOne`, `request()`, `requestBody()`, `close()`
  are the whole of what a caller's suite needs; `serveOne` now reads the
  request body its head announced, so a test about a POST sees what went
  out. The other `serve*` are the shapes the module's own tests drive, public
  because `live.zig` is another file now. Port 0 and the kernel's answer
  read back, so a suite needs no port range of its own. `s3/canned.zig`
  still carries its own copy — it checks signatures, which this one does
  not — and could adopt this one underneath later.

## What was rejected

**`.body = .{ .json = value }` on `Call`, and `.query = .{ … }` beside it.**
The roadmap's first spelling, and the one that reads best. A union arm and a
struct field both need a type nilo can name, and the value's type is the
caller's. Making the last argument `anytype` and reading the fields off it
was tried on paper and breaks the `headers` literal at every existing call.

**A type-erased `Query` — a pointer and a write function — so the field
could exist.** `.query = fetch.query(&.{ .page = 2 })` takes the address of
a temporary, and what the language promises about that temporary's lifetime
is not something a caller should have to know to write a GET.

**`query: []const Param` at run time.** No struct, no Refusal, and every int
turned to text by hand at the call site, which is the five lines the entry
was written to remove.

**A growing writer for the URL.** The params are measured and then written,
into one allocation of exactly that size, the way every caller of
`core.percent` already does; an `Allocating` writer would be one to three
allocations for the same bytes.

**Refusing a non-struct JSON body.** `std.json` writes an int, an array or
an enum as itself, and each of those is a body some API takes. The one shape
that is silently wrong is text, and that is the one refused.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | `postJson`: one, the stringified body — the one every caller was already paying by hand. `withQuery`: one, the URL, sized exactly — the one the example was already paying to an `Allocating` writer. `Canned`: none on any request path; it is a test type |
| Memory per idle connection | unchanged. Neither call adds a frame under the one `std.http.Client` waits in |
| Throughput and p99 | unchanged on `get`, `post` and the rest, which are one private `sendAs` away from where they were |
| Binary size | +0 for a program that calls none of the three. `withQuery` is generic over its params and `fetch.testing` is reached only by name, so a program that never names them links nothing |

Three Refusals, in `fetch/refusals/`, and the module's first table in
`build.zig`: `fetch_refusals`, on `zig build refusals-fetch`, which
`test-fetch` and so `test` and `test-all` run.

## What proves it

`fetch/fetch.zig`: a query struct of every allowed type becomes the string
the encoder promises, in one allocation whose measured length is the written
length; a null is left out; a base with a query gets `&`. `fetch/live.zig`:
a `postJson` body arrives written out under `content-type:
application/json`, once, and a caller's own `content-type` wins; a suite
written on nothing but `fetch.testing.Canned` sees the request head, the
request body and the reply it asked for.
