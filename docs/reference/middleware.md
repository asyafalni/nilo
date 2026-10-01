# Middleware

**nilo's built-in middleware (logging, CORS, CSRF, rate limits, per-route deadlines and body limits), and `nilo.accept` for reading an `Accept` header.**

**Guide:** [Middleware and resolved values](../guide/middleware.md) · **Design:** [Middleware](../design/middleware.md), [CORS and the proxy in front](../design/cors-proxy.md), [Rate limiting](../design/rate-limiting.md), [Deadlines](../design/deadlines.md)

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

### `nilo.cors`

**`origins` is a list, and the one entry that matched is what gets sent**, because `Access-Control-Allow-Origin` carries a single value: the request's `Origin` is compared against each entry. Entries must be lowercase, and anything else is refused at build time. `&.{"*"}` allows anyone and reads no header at all; any other list also sends `Vary: Origin`, whether or not it matched.

**`cors.reading` is the same middleware with the list read at run time**, for the deployment detail `with` cannot express: the front end at one address in staging and another in production ([ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)). Everything except the list is still fixed at compile time.

| | |
|---|---|
| `nilo.cors.Origins` | where the list lives. Start with `.empty`; a `var` that outlives the App |
| `o.set(&.{ … })` | takes a list you assembled. `error.OriginNotLowercase`, `.OriginEmpty`, `.OriginIsWildcard`, `.OriginNotAnOrigin` (`null`, a path, no scheme) |
| `o.setSplit(&buf, text)` | splits `"https://a.com,https://b.com"` into `buf`, which you own. `error.TooManyOrigins` if it does not fit |
| `nilo.cors.reading(&o, .{ … })` | the middleware. Passing `.origins` in the options is a compile error, because the list is `o`'s |

**The text is borrowed and has to outlive the server.** The environment block and a `.env` file's text both do. Borrowing is what lets the matched origin be sent without copying, so a cross-origin request still allocates nothing. `"*"` is refused, because that is `cors.permissive`. A list nobody filled rejects every cross-origin request and logs it once.

### `nilo.csrf`

**Accepts a request that changes something only from a page this server serves.** `GET`, `HEAD` and `OPTIONS` pass without being checked. Anything else is checked in this order ([ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)):

| the request carries | result |
|---|---|
| `Sec-Fetch-Site: same-origin` or `none` | allowed |
| any other `Sec-Fetch-Site`, `same-site` included | allowed if `Origin` is listed, else 403 |
| `Origin` and no `Sec-Fetch-Site` | allowed if listed, or if it matches the `Host` header's authority (ignoring the scheme), else 403 |
| neither | allowed: not a browser |

| | |
|---|---|
| `nilo.csrf.sameOrigin` | lists nobody: only this server's own pages |
| `nilo.csrf.with(.{ .origins })` | the pages on other origins that are allowed. Scheme, host and port, nothing after; compared case-insensitively. `"*"`, `""` and an entry with a path or no `://` are compile errors |
| `nilo.csrf.reading(&o)` | the same, with `o` a `nilo.cors.Origins`, so one list can feed both `cors.reading` and this |

The 403 names the origin and `csrf .origins`. There is no allocation on any path, and no per-connection cost. A route opts out with `without(nilo.csrf.sameOrigin)`, which is what a callback that another site posts to from a browser needs; a server-to-server webhook sends neither header and needs nothing.

### `nilo.allowance`

**How many requests one address may make within a time window.** Past that, the request gets a 429 with `Retry-After`, and the handler is never reached.

<!-- compiles: body -->
```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
```

| | |
|---|---|
| `.per_window` | how many requests, 1 to 1023 |
| `.window_s` | the window length in seconds. Also the value of `Retry-After` |
| `.slots` | how many addresses are remembered at once. A power of two, at least 64. Eight bytes each |
| `.ipv6_prefix` | how much of an IPv6 address counts as one client. 64 is one customer's allocation |
| `.name` | tells this allowance apart from another with the same numbers |

**The table is sized while compiling and lives in `.bss`**: no allocation per request and none at startup, 131,072 bytes at the default, and nothing at all in a program that does not use it. The window **slides**: the previous window is weighted by how far into the current one the request arrived, so a hundred requests at 11:59:59 and a hundred at 12:00:00 do not add up to two hundred allowed.

Two behaviours are deliberate ([ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)): a full bucket **forgets its stalest address** instead of letting two addresses share one allowance, and a slot under contention **lets the request through**. Both make the same trade: being loose for one window is better than refusing somebody who has made no requests at all.

Two `with()` calls with the same options share one table. Give one a `.name` to count a sign-in route separately from a search route.

**Behind a proxy, set `.trusted_hops`** on `listen`, or every request looks like it came from the proxy and the whole table becomes one slot. A refusal that sees an `X-Forwarded-For` on a request counted against the socket's own address logs this once.

It is not a defence against a flood: a refused request is still read, parsed, matched and answered. That is what `max_connections` is for.

#### `allowance.keyed`

**`with` counts per address, which is right for a scraper and wrong for anything the application knows about.** Ten accounts behind one office NAT would share one allowance, and one account on ten machines would get ten. `keyed` counts against a key your application provides:

<!-- compiles -->
```zig
fn account(c: *nilo.Ctx) ?[]const u8 {
    const session = c.resolve(nilo.Session(Signed)) catch return null;
    const who = session.get() orelse return null;
    return std.fmt.allocPrint(c.arena(), "{d}", .{who.user}) catch null;
}
```

```zig
try app.useOn("/api", nilo.allowance.keyed(account, .{
    .per_window = 1000,
    .on_null = .reject,
}));
```

The first argument is a function of one `*Ctx` returning `?[]const u8` or `?nilo.Str`. **Its bytes are not kept**, since they live in the request arena; the table stores a 64-bit tag from a keyed hash, in its own word beside the counters ([ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)).

| | |
|---|---|
| `.per_window` | how many requests, 1 to 65,535: the whole range, unlike `with` |
| `.window_s` | as `with` |
| `.slots` | how many keys are remembered at once. A power of two, at least 64. **Sixteen** bytes each; 4,096 by default |
| `.on_null` | **required.** `.skip`: not counted, and allowed. `.reject`: a 403 |
| `.name` | as `with` |

**`on_null` has no default on purpose.** `keyed(signedInAccount, …)` on a sign-in route with a silent skip would leave every *failed* sign-in uncounted, which is exactly the attack the limit exists to stop. For that route, key on the *claimed* username with `.on_null = .reject`, and add an address-keyed `allowance.with` underneath it, which means calling `use` twice.

`.reject` answers 403, not 429: nothing was rated and nothing was exceeded, and a `Retry-After` on it would be false.

### `nilo.deadline`

**How long a route gets, as a middleware:**

```zig
try app.with(nilo.deadline(2000)).get("/report", buildReport);
```

`listen()`'s four deadlines each bound one wait for the network, and none of them bounds the whole request. This clamps every wait nilo owns (reading the body, writing, a stream's pieces, a WebSocket's silence) to whichever limit comes first.

**A running handler is not interrupted, on purpose**: a cancel firing in the middle of a handler is a cancel that every handler, every `nilo.Mutex` and every Service would have to survive ([ADR 082](../adr/082-a-cleanup-path-is-not-cancellable.md)). A loop doing its own work checks `c.overdue()`:

```zig
while (try rows.next()) |row| {
    if (c.overdue()) return nilo.fail.status(503, "too many rows to do in time", .{});
    try out.json(row);
}
```

**The write is clamped too, in one case**: a deadline with less left than `write_timeout_ms` bounds the answer's writes, so a two-second route does not wait thirty seconds on a client that reads nothing. A deadline further off leaves each write on `write_timeout_ms`, which stops a client that has stopped reading but not one that takes a little every few seconds.

A handler that fails while overdue, with nothing sent yet, gets a 503 naming the budget. One that finishes late still answers, because the work is done and correct, and the lateness is logged ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)). `deadline(0)` is a compile error.

### `nilo.maxBody`

**How much body a route accepts, as a middleware:**

```zig
try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
try app.with(nilo.maxBody(1024)).post("/sign-in", signIn);
```

`listen()`'s `max_body` is one number for every route, but an import and a sign-in need different limits. This is the same argument `nilo.deadline` makes about time, with the same answer: the route decides. It bounds every read into the request arena (`c.body()`, a JSON body, a `Form(T)`, a `Bound(…)` of either), and a `Content-Length` over the limit is a 413 before any byte is read. Lowering the limit works the same way as raising it.

**It does not affect `c.bodyStream()`**, which holds nothing in the arena and has its own `max_bytes` ([ADR 156](../adr/156-a-route-can-say-how-much-body-it-takes.md)). `maxBody(0)` is a compile error.

## `nilo.accept`

**What the request's `Accept` header says about one media type.** One call, no allocation. It is what the single-page fallback uses to decide ([ADR 087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)).

```zig
switch (nilo.accept.asks(c.header("Accept"), "text/html")) {
    .named => …,      // the client asked for it, or for `text/*`
    .anything => …,   // it said `*/*` and nothing more specific
    .unsaid => …,     // there is no Accept header at all
    .refused => …,    // it named other types, or named this one with q=0
}
```

`asks(header, kind)` takes a `?[]const u8`. `c.header(…)` gives a `?Str`, so pass `if (c.header("Accept")) |h| h.view() else null`. The type is known at compile time and must be a full media type: `"text/*"` is a compile error, because the answer is about one type, not a family.

The most specific entry decides, which is RFC 9110's rule: `text/html;q=0, */*` is `.refused` for HTML and `.anything` for everything else. There is no negotiation across several offers: this answers one question, and a handler with two things to serve asks it twice.
