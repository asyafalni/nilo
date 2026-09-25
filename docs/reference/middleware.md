# Middleware

One page of [the reference](./README.md): the built-in middleware, and `nilo.accept`.

## Built-in middleware

```zig
nilo.logger.standard                                    // one info line per request
nilo.logger.with(.{ .level = .info, .slow_micros = 0,   // slower than this → .warn
                     .format = .text,                    // or .json, one object per line
                     .request_id = false })              // X-Request-Id out, and on the line

nilo.cors.permissive                                    // origins &.{"*"}, no credentials
nilo.cors.with(.{ .origins = &.{…}, .methods = …, .headers = …,
                   .expose = …, .credentials = false, .max_age = 0 })

nilo.cors.reading(&origins, .{ … })                     // the list read at run time

nilo.csrf.sameOrigin                                    // 403 a cross-site POST, PUT, PATCH, DELETE
nilo.csrf.with(.{ .origins = &.{…} })                   // …unless it came from one of these
nilo.csrf.reading(&origins)                             // the list, from a cors.Origins

nilo.allowance.with(.{ .per_window = 100, .window_s = 60,   // 429 past this
                        .slots = 16 * 1024,                  // addresses remembered
                        .ipv6_prefix = 64, .name = "" })

nilo.allowance.keyed(account, .{ .per_window = 1000,        // …counted against
                        .window_s = 60, .slots = 4 * 1024,   //   what `account`
                        .on_null = .reject, .name = "" })    //   returns

nilo.deadline(2000)                                         // how long a route gets
nilo.maxBody(50 << 20)                                      // how much body it takes
```

`origins` is a list because `Access-Control-Allow-Origin` carries one value:
the request's `Origin` is compared against each entry and the one that matched
is what goes out. Lowercase, and refused at build time otherwise. `&.{"*"}`
answers anyone and reads no header at all; anything else also sends
`Vary: Origin`, whether or not it matched.

**`cors.reading` is the same middleware with the list read at run time**, for
the deployment fact `with` cannot express — the front end at one address in
staging and another in production
([ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)).
Everything but the list stays comptime.

| | |
|---|---|
| `nilo.cors.Origins` | where the list lives. `.empty` to start; a `var` that outlives the App |
| `o.set(&.{ … })` | take a list you assembled. `error.OriginNotLowercase`, `.OriginEmpty`, `.OriginIsWildcard` |
| `o.setSplit(&buf, text)` | split `"https://a.com,https://b.com"` into `buf`, which is yours. `error.TooManyOrigins` past its length |
| `nilo.cors.reading(&o, .{ … })` | the middleware. `.origins` in the options is a compile error — the list is `o`'s |

**The text is borrowed and has to outlive the server** — the environment block
and a `.env`'s text both do — which is what lets the matched origin go out
without being copied, so a cross-origin request still allocates nothing. `"*"`
is refused: that is `cors.permissive`. A list nobody filled refuses every
cross-origin request and says so in the log once.

### `nilo.csrf`

**A request that changes something, taken only from a page this server serves.** `GET`, `HEAD` and `OPTIONS` pass unread. Anything else is asked, in order ([ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)):

| the request carries | answer |
|---|---|
| `Sec-Fetch-Site: same-origin` or `none` | through |
| any other `Sec-Fetch-Site`, `same-site` included | through if `Origin` is named, else 403 |
| `Origin` and no `Sec-Fetch-Site` | through if named, or if it names the `Host` header's authority (scheme aside), else 403 |
| neither | through: not a browser |

| | |
|---|---|
| `nilo.csrf.sameOrigin` | names nobody: only this server's own pages |
| `nilo.csrf.with(.{ .origins })` | the pages on other origins that may. Scheme, host and port, nothing after; compared case-insensitively. `"*"`, `""` and an entry with a path or no `://` are compile errors |
| `nilo.csrf.reading(&o)` | the same, with `o` a `nilo.cors.Origins`, so one list can feed `cors.reading` and this |

The 403 names the origin and `csrf .origins`. No allocation on any path, and nothing per connection. A route leaves it with `without(nilo.csrf.sameOrigin)`, which is the shape for a callback another site posts to from a browser; a server-to-server webhook sends neither header and needs nothing.

### `nilo.allowance`

**How many requests one address may make inside a window.** Past it the request
is a 429 carrying `Retry-After`, and the handler is never reached.

<!-- compiles: body -->
```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
```

| | |
|---|---|
| `.per_window` | how many requests, 1 to 1023 |
| `.window_s` | how long the window is, in seconds. Also what `Retry-After` says |
| `.slots` | how many addresses are remembered at once. A power of two, ≥ 64. Eight bytes each |
| `.ipv6_prefix` | how much of an IPv6 address is one client. 64 is one customer's allocation |
| `.name` | tells this allowance apart from another with the same numbers |

The table is sized while compiling and lives in `.bss`: **no allocation per
request and none at startup**, 131,072 bytes at the default, and nothing at all
in a program that does not use it. The window **slides** — the previous one is
weighed by how far into the current one the request arrived — so a hundred at
11:59:59 and a hundred at 12:00:00 is not two hundred through.

Two things it does on purpose
([ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)):
a bucket with no room **forgets its stalest address** rather than letting two
share one allowance, and a slot under contention **lets the request through**.
Both are the same trade — being loose for one window beats refusing somebody who
has made no requests at all.

Two `with()` calls carrying the same options are one table. Give one a `.name`
to count a sign-in route apart from a search route.

**Behind a proxy, set `.trusted_hops`** on `listen`, or every request looks like
it came from the proxy and the whole table is one slot. A refusal that finds an
`X-Forwarded-For` on a request counted against the socket's own address says so
in the log once.

It is not a defence against a flood — a refused request is still read, parsed,
matched and answered. That is `max_connections`.

#### `allowance.keyed` — counted against something the application knows

**`with` counts against the address**, which is right for a scraper and wrong
for everything the application knows: ten accounts behind one office NAT share
an allowance they should not, and one account on ten machines gets ten.

```zig
fn account(c: *nilo.Ctx) ?nilo.Str {
    const who = c.session(Account) orelse return null;
    return who.id;
}

try app.useOn("/api", nilo.allowance.keyed(account, .{
    .per_window = 1000,
    .on_null = .reject,
}));
```

The first argument is a function of one `*Ctx` returning `?[]const u8` or
`?nilo.Str`. **Its bytes are not kept** — they live in the request arena — so
what goes in the table is a 64-bit tag from a keyed hash, in a word of its own
beside the counters ([ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)).

| | |
|---|---|
| `.per_window` | how many requests, 1 to 65,535 — the whole range, unlike `with` |
| `.window_s` | as `with` |
| `.slots` | how many keys are remembered at once. A power of two, ≥ 64. **Sixteen** bytes each; 4,096 by default |
| `.on_null` | **required.** `.skip` — not counted, and through. `.reject` — a 403 |
| `.name` | as `with` |

**`on_null` has no default on purpose.** `keyed(signedInAccount, …)` on a
sign-in route with a silent skip leaves every *failed* sign-in uncounted, which
is the attack the route exists to stop. The right shape for that route is the
*claimed* username with `.on_null = .reject`, composed with an address-keyed
`allowance.with` underneath it — which is `use` twice.

`.reject` answers 403 rather than 429: nothing was rated and nothing exceeded,
and a `Retry-After` on it would be a lie.

### `nilo.deadline`

**How long a route gets**, as a middleware:

```zig
try app.with(nilo.deadline(2000)).get("/report", buildReport);
```

`listen()`'s four deadlines bound one wait for the network each and none of them
bounds the request. This clamps every wait nilo owns — the body, the write, a
stream's pieces, a WebSocket's silence — to whichever comes first.

**A running handler is not interrupted**, and deliberately is not: a cancel
firing mid-handler is a cancel every handler, every `nilo.Mutex` and every
Service has to survive
([ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md)). A loop doing its
own work asks `c.overdue()`:

```zig
while (try rows.next()) |row| {
    if (c.overdue()) return nilo.fail.status(503, "too many rows to do in time", .{});
    try out.json(row);
}
```

A handler that fails while overdue with nothing sent gets a 503 naming the
budget. One that finishes late still answers — the work is done and correct —
and the lateness is a log line
([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)). `deadline(0)` is a
compile error.

### `nilo.maxBody`

**How much body a route takes**, as a middleware:

```zig
try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
try app.with(nilo.maxBody(1024)).post("/sign-in", signIn);
```

`listen()`'s `max_body` is one number for every route, and an import and a
sign-in do not have the same budget. This is the same argument `nilo.deadline`
makes about time, with the same answer: the route says. It bounds every read
into the request arena — `c.body()`, a JSON body, a `Form(T)`, a `Bound(…)`
of either — and a `Content-Length` past it is a 413 before a byte is read.
Lowering is as ordinary as raising.

**It does not touch `c.bodyStream()`**, which holds nothing in the arena and
takes a `max_bytes` of its own
([ADR 156](../adr/156-a-route-can-say-how-much-body-it-takes.md)).
`maxBody(0)` is a compile error.

## `nilo.accept`

What the request's `Accept` header says about one media type. One call, no
allocation, and the reader the single-page fallback decides with
([ADR 087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)).

```zig
switch (nilo.accept.asks(c.header("Accept"), "text/html")) {
    .named => …,      // the client asked for it, or for `text/*`
    .anything => …,   // it said `*/*` and nothing more specific
    .unsaid => …,     // there is no Accept header at all
    .refused => …,    // it named other types, or named this one with q=0
}
```

`asks(header, kind)` takes `?[]const u8` — `c.header(…)` gives a `?Str`, so
pass `if (c.header("Accept")) |h| h.view() else null`. The type is comptime and
has to be a full media type: `"text/*"` is a compile error, because the answer
is about one type rather than a family.

The most specific entry decides, which is RFC 9110's rule: `text/html;q=0, */*`
is `.refused` for HTML and `.anything` for everything else. There is no
`Format`-shaped negotiation over several offers — this answers one question and
a handler with two things to serve asks it twice.
