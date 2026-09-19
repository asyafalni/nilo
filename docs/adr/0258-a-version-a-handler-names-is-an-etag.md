# 0258 — a version a handler names is an ETag

**Status:** accepted
**Extends:** [ADR 0024](./0024-a-failure-mode-belongs-in-the-return-type.md),
whose family of return wrappers gains one that answers 304, and
[ADR 0010](./0010-static-files-are-held-in-memory.md), whose
`If-None-Match` comparison now serves a body a handler built.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0032](./0032-a-redirect-puts-its-status-in-the-type.md),
[ADR 0195](./0195-a-type-can-write-its-own-answer.md),
[ADR 0247](./0247-a-route-can-say-cache-this-answer-for-a-minute.md).

## Context

An `ETag` was a thing only a file had. `static.zig` makes one over a held
file's bytes or a descriptor's mtime and size, `sendfile.zig` compares it
against `If-None-Match`, and those were the only paths there were. A JSON
endpoint polled every five seconds — a dashboard, a job's status, a list a
mobile app refreshes on every foreground — sent the whole body every time,
and a handler that wanted to do better got no help: it read the header,
worked something out, and called `c.sendEmpty(304)` from a `*Ctx`, which the
document could not see.

The roadmap held the entry at *waiting on a design* for one question: what
the handler hands over, given that nothing here hashes a body per request.
Hashing was refused up front by ADR 0018: it means the body exists before the
head is written, which the streaming paths do not do, and a buffer to hash
over on every response whether or not any client would ever send the tag
back.

## Decision

**`nilo.Versioned(T)` is `T` with a `u64` version on it. The version goes
out as a weak `ETag`; a request whose `If-None-Match` names it is answered
304 with no body; and `c.clientHas(version)` lets the handler skip building
the body at all.**

```zig
fn listOrders(c: *nilo.Ctx, db: *Db) !nilo.Versioned([]Order) {
    const revision = try db.rawOne(i64, c, "select coalesce(max(revision), 0) from orders", .{}) orelse 0;
    const version: u64 = @intCast(revision);
    if (c.clientHas(version)) return .unchanged(version);
    return .{ .version = version, .value = try db.select(Order, c, .{ .order = .{ .id = .asc } }) };
}
```

**The handler names the version, because the handler is the only thing
that knows what it is.** A revision column, a `max(updated_at)`, a counter
the writer bumps: each is one cheap query, and each is known *before* the
body is built, which is the property a hash can never have. The 304 that
matters is the one that saves the query, not the one that saves the bytes,
and only a version known first can save the query. That is what
`c.clientHas` is for, and why the type has an `unchanged` constructor: a
handler that asks first returns `.unchanged(version)` and runs nothing else.
A handler that never asks still answers 304 — nilo compares on the way out
whatever the handler did — and pays for the body it built.

**The tag is weak.** `W/"<hex>"`. A version the handler names says the
representation is the same and says nothing about the bytes: the same value
goes out gzipped to one client and plain to another, and a strong tag would
promise byte equality across the two. Weak is also all `If-None-Match` ever
compares by, and it is the one comparison this path makes — `If-Range` needs
a strong tag, and it is a file's. `static.etagMatches` is the comparison,
unchanged, so the wildcard, a list of tags and a strong tag sent for a weak
one all match the way they do for a file.

**A version is a `u64`, and not a tag the handler wrote.** A tag as text
would have to be checked per request for the quotes and the control
characters a header cannot carry, and its comparison would have to know
which half was the handler's. A number has neither problem. Text — an
`updated_at` kept as a string, a row's own hash — is one
`std.hash.Wyhash.hash(0, text)` away, which the guide shows.

**`.unchanged` to a client that did not send the version is a 500.** The
handler skipped the work without asking, and an empty 200 would be the
silent form of that bug. The message names the route and says which.

**The headers go on both answers.** A `Versioned` carries `headers` the way
a `Response` does, and they are sent on the 304 too, because RFC 9110 has
the 304 carry what the 200 would have — a `Cache-Control` above all — and a
304 without them is a client that revalidates every time.
`.unchangedWith(version, headers)` is the 304 with them on, since a handler
that skipped the body has not filled a `headers` field either.

**Three shapes are refused while compiling**, each because the alternative
is a silent wrong answer:

- `Versioned(?T)` — `null` would have to mean a 404 and "you already hold
  it" both. A thing that is not there has no version; `fail.notFound` is
  the answer for it, in the sentence the `?T` path would have said.
- `Status(code, Versioned(T))` and `Response(Versioned(T))` — the status is
  already decided, 200 or 304, and the headers are a field the versioned
  type carries itself.
- `Versioned(T)` under a `Cached` or an `Idempotent` — a kept answer is
  replayed as it was kept, so a 304 decided once would go to every client
  after, whether they hold the version or not. Refused at the route, by
  reading the arguments beside the return type.

And `Versioned(void)`, which has no body for a client to hold, and a
`Versioned` in the argument list, which is the mistake `Bytes` in the
argument list is.

**The document says so.** The 200 carries an `ETag` header in the response
object, and a `304` sits beside it with the header and no content — not
through `writeFailure`, because it is not a failure and carries no body.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** none on a route that is not versioned. On
  one that is, the `ETag` header is copied into the arena by `setHeader`,
  which is inside the budget a response carrying any header already
  spends; the tag itself is twenty bytes in `sendResult`'s frame. `test
  "the request path stays inside its allocation budget"` is unmoved.
- **Memory per idle connection:** unchanged. Nothing is held between
  requests.
- **Throughput:** a 304 is one header scan, one comparison and a head. A
  200 is what the bare `T` cost plus the header.
- **Binary size:** one function per `T` a program versions; nothing for a
  program that names none.

## Alternatives

**Hashing the body**, as a middleware would. Refused by the roadmap entry
itself: the body has to exist before the head is written, which the
streaming paths do not do; it costs a buffer and a hash per response on the
chance a client sends the tag back; and it saves the bytes and never the
query, which is the expensive half.

**A tag the handler writes**, `etag: []const u8`. Rejected above: a check
for quotes and control characters per request, and a comparison that has to
know which half was the caller's. The `u64` is the same information with
nothing to validate.

**`c.notModified(version)` from a `*Ctx` handler.** Answers the 304 but not
the 200: the `ETag` on the success path would be a second call the handler
has to remember, and the document would see neither. The return type is
where both halves are visible.

**Honouring `If-Modified-Since` too.** A date needs a clock the handler's
version is not, and `If-None-Match` takes precedence over it whenever both
are sent. A client that has an `ETag` sends it.

## Consequences

- `http/versioned.zig`: `nilo.Versioned(T)` with `version`, `headers`,
  `value`, `.unchanged(version)`, `.unchangedWith(version, headers)`;
  `Ctx.clientHas(version)`. The file names nothing in `http_core` — it
  compares a header's value, not a `Ctx` — so the core's list is unmoved.
- `typed.sendResult` sets the tag and answers the 304 before the
  `Response` branch; `answerOf` marks the document; `checkAnswer` refuses
  the three shapes and the argument-list case.
- `openapi.Answer.versioned`; the 200 carries the header and a `304` is
  written beside it.
- Five refusals under `refusals/versioned_*`; `refusals` is 146.
- The roadmap loses "A response a handler wrote can never answer 304".
