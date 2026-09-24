# A route can say "cache this answer for a minute"

**Status:** accepted
**Topic:** [idempotency](../design/idempotency.md)
**Extends:** [ADR 155](./155-a-request-answered-once-is-answered-the-same-way-again.md), whose record, marker and Space shape this reuses.

## Context

The most ordinary use of a cache in a web app had no shape here. A front
page that costs four queries and changes once a minute was either four
queries per request or twenty lines of `Carts.get` and `Carts.put` in the
handler — and the twenty lines get the one thing wrong that matters: when
the entry expires, every request that arrives in the same hundred
milliseconds finds nothing and runs the four queries, which is the moment
the cache was for.

The parts were already built. `http/idempotent.zig` encodes whatever a
handler returned — status, its own headers, the body, a label — into a
bytes Space and replays it byte for byte, with an `in_flight` marker for
the request still being answered. What it keys on is a header the client
sent, and what it does with a second request that finds the marker is a
409, because for a payment a retry too soon is a client bug.

## Decision

**`nilo.Cached(Pages, .{ .ttl_s = 60 })` is a route argument, and it is
`Idempotent` with three things changed.**

```zig
const Pages = cache.Space("pages", []const u8, .{ .max_bytes = 32 << 10 });

fn frontPage(page: nilo.Cached(Pages, .{ .ttl_s = 60 }), db: *sql.Db, c: *nilo.Ctx) !Front
```

**The key is the request line.** `.by` says what of it: `.path_and_query`
(the default), `.path`, or `.{ .header = "Accept-Language" }` for the path,
the query and one header's value — the shape `Vary` names. The query is
taken as it arrived and nothing is normalised, so `?a=1&b=2` and `?b=2&a=1`
are two entries; the guide says so in one sentence rather than this module
carrying a canonicaliser. The key goes into the Space's ring with the entry,
so a path alone costs no allocation and a query costs one join in the
arena.

**The second request waits.** A request that finds the marker reads again
every 10 ms, for at most 2,000 ms — or **half of what `nilo.deadline(ms)`
left the route**, whichever is less, so a request that waited and then had
to make the answer itself is not late for having waited. Past the bound it
runs the handler and overwrites the marker with what it made; nothing is
refused for the server's own tardiness. The wait is `nilo.sleep`, so it
parks the fiber and the watchdog knows. This lives in `http/` because
`http/` is the layer with an `Io` to wait on: `nilo_cache`'s lock spins and
nothing that waits may go inside it ([ADR 109](./109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)),
so the stampede answer was never the cache's to give.

**GET and HEAD only.** A kept answer is served to whoever asks next, and the
request the second client sent was not the one the first client sent — the
body, the account, the order placed. `app.post` and the other write verbs
refuse it while compiling, at the call that named the verb; `app.route(.POST,
…)`, whose verb is a runtime value, refuses it at registration the way a
duplicate route is refused, with `error.CachedWrite` from `tryRoute`.

Everything else is ADR 155's. The record is `idempotent.zig`'s, used and
not copied — the rendering of a handler's answer into one is now
`typed.renderAnswer`, which both `idempotentFinish` and `cached.finish`
call. What the handler returned is kept whatever its status; what it failed
with is not, and the marker goes with the failure. The Space is a shape
rather than an import: any type with `getInto`, `putIfAbsent`, `putFor`,
`del`, `max_bytes` and `Held`. `putFor` rather than `put` because the TTL
is the route's and not the Space's — one Space may hold a page kept a
minute beside one kept an hour. A replay carries `Cache-Status: nilo; hit`
and a fresh answer `Cache-Status: nilo; fwd=miss`, in RFC 9211's words,
because a test and a browser's network tab both want to tell the two apart.

The Space is a service the route needs, so `listen()` names it when it is
missing rather than the first request finding out — the requirement is
read off the argument the way a `*Db` is.

## What it costs

Put against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four
axes, and all of it on the route that asks:

- **Allocations per request.** What `Idempotent` costs: a fresh answer is
  one arena allocation to encode the record, plus the JSON buffer the
  answer was taking anyway; a replay is one arena allocation of
  `max_bytes` to read into. One more, on either, to join the path and the
  query when there is a query or a header in the key. **A route with no
  `Cached` on it runs the code it ran before**, and `test "the request path
  stays inside its allocation budget"` in `http/app.zig` is untouched.
- **Memory per idle connection.** None. Nothing is on the stack — the
  record is read into the arena, which is why the cache has `getInto`
  ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)). A request
  waiting on another's answer is a parked fiber holding the frame it was
  already holding.
- **Throughput.** Per fresh answer one cache claim and one write; per hit
  one claim that fails and one read. Per waiter, a claim and a read every
  10 ms for as long as it waits.
- **Binary size.** One file, one role in the engine, one more arm in
  `wrap`. Not measured separately; it is the `Idempotent` shape a second
  time.

## What was rejected

**A middleware — `app.with(nilo.cache(Pages, 60)).get(…)`.** It is the
shape every other framework ships, and it has to intercept the response on
the way out. nilo's typed handler *returns* its answer, so the engine has
the value in hand before a byte is written and can render, keep and send
it in that order — which is the argument ADR 155 made and it holds here
unchanged. The argument is also where the Refusals live: a handler that
streams has no answer to keep, and that is said at the route.

**A 409 for the second request, as `Idempotent` gives.** Correct for a
retry with somebody's payment key; wrong for twenty browsers asking for one
page. The wait is the whole of why this is a second argument rather than an
option on the first.

**Waking the waiters rather than polling.** A condition per key would need
a table of keys being made, which is a second cache inside `http/` — the
thing [ADR 038](./038-a-module-sits-where-the-loop-puts-it.md) exists
to refuse. Ten milliseconds of poll on the route that asked is the price,
and a page that takes longer than the bound to render is a page that
needed the deadline anyway.

**A TTL on the Space rather than on the argument.** A Space's `ttl_s` is
the default for every `put` into it; a route's is the route's. Reading the
route's from the Space would mean one Space per TTL, and the marker —
which goes in through `putIfAbsent` under the Space's default — would then
share the answer's lifetime, which for a marker is wrong in both
directions.

**Normalising the query.** Sorting parameters and decoding percent-escapes
would make `?b=2&a=1` hit `?a=1&b=2`'s entry, and would also make the key a
second parse of the query on every request. A handler that wants one entry
for every ordering keys on `.path`.

**A `.by` that takes a function, as `Idempotent`'s does.** A function of
one `*Ctx` answering `?Str` can build any key, including one that holds
the caller's credential — and a cache keyed on a credential is a session
store with a stranger's answers in it. The three variants cover the pages
this is for, and the header variant refuses `Cookie`, `Authorization` and
`Proxy-Authorization` by name.

## What proves it

`http/cached.zig`: a fresh answer is served and kept and the next request
inside the TTL is the same bytes without the handler running; a different
query is a different entry and the bare path a third; after the TTL the
handler runs again and its new answer is the one kept; a failure is not
kept and the marker is released; a request that finds the answer being
made waits and gets it, landed from a second thread; one that waits the
bound out — half a 200 ms deadline — runs the handler itself and its
answer replaces the marker; a header key varies by that header and an
absent one is an entry of its own; a path key answers every query string
with one entry; the requirement `listen()` reads names the Space.

The TTL there is a fake Space's clock, moved by hand, because `nilo_cache`'s
is the kernel's monotonic clock and `http/` may not import the module to
reach `opened_s` anyway. The cache's own suite holds the real expiry.

Eight Refusals: not a bytes Space, `ttl_s` of 0, a header key naming no
header, a header key naming a credential, a `Cached` on a POST, a handler
that returns nothing, a handler that asks twice, a handler that asks for
both `Idempotent` and `Cached`.

## Consequences

- `http/cached.zig`: the type, its options, the key, the wait, the finish,
  and the tests. `typed.zig` gains a `.cached` role, `renderAnswer`,
  `sendRendered`, `isCached` and `checkVerb`; `checkKeepable` takes the
  argument's name. `app.zig` calls `checkVerb` from the five write verbs on
  `App` and `Group`, and `tryRouteNamed` refuses a runtime write verb.
- The roadmap's `nilo_http` list loses its fourth entry.
- Not built, and not blocked: an `Age` or `ttl=` on `Cache-Status`, which
  wants the entry's remaining life and the Space does not say it; a
  `Cache-Control` on the answer, which is the handler's to set and is kept
  with the record when it does.
