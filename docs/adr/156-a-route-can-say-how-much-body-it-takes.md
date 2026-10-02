# A route can say how much body it takes

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

`listen(.{ .max_body = … })` is one number for every route, and one number is
the wrong shape. A CSV import takes fifty megabytes; the sign-in beside it takes
two hundred bytes. A `max_body` loose enough for the first is no bound on the
second, and a server that raised it for the import has told every other route
to hold fifty megabytes in the arena for anybody who sends them.

This is the argument [ADR 105](105-a-route-can-say-how-long-it-has.md) made
about time, one axis over, and it gets the same answer: a route that wants its
own limit says so, through `with`.

```zig
try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
try app.with(nilo.maxBody(1024)).post("/sign-in", signIn);
```

actix-web is where the shape was checked: its `JsonConfig::limit()` is set per
scope for exactly this reason, and axum's `DefaultBodyLimit` is a layer applied
per route. Neither has a single server-wide number and nothing else.

## It is one field, written before the body is read

`Ctx` already carries `_limits`, a copy of `listen()`'s `Limits` made per
request (`serve.zig`), and `body()` reads `_limits.max_body` at the moment it
decides how much to take. So the middleware writes that field and calls
`next`:

```zig
fn run(c: *Ctx, next: mw.Next) anyerror!void {
    c.giveBodyLimit(bytes);
    return next.run(c);
}
```

`giveBodyLimit` is public on `Ctx` for the same reason `giveDeadline` is: a
middleware of the caller's own may want to decide the number from the request
— a plan, a role — rather than from the route.

The body is read lazily, from inside the handler or the typed layer, so every
middleware has run by then; nothing had to move. That is also why lowering is
as ordinary as raising: a `Content-Length` past the route's number is a 413
before a byte is read, exactly as it is past `listen()`'s.

## The number can come from configuration

A cap is sometimes a fact about the deployment and not the program: an ingest route whose limit is an environment setting, one number in staging and another in production. That is the argument [ADR 088](088-an-origin-is-a-fact-about-the-deployment.md) made about an origin, and it gets the same answer: the middleware reads the number from somewhere the program fills before `listen()`.

```zig
var ingest_limit: usize = 16 << 20;

pub fn main() !void {
    ingest_limit = settings.ingest_max_body;
    try app.with(nilo.maxBody(&ingest_limit)).post("/v1/logs", ingest);
    try app.listen(.{});
}
```

**What `maxBody` is handed decides when the number is read.** A number is settled while compiling, as above; the address of a `usize` is read on every request that reaches the route, and written to the same field. Anything else (a `*u32`, a slice, a string) stops compilation with a message naming both forms. The pointer is comptime, so it is a container-level `var` that outlives the App, which is what `cors.reading` asks of its `Origins`. It is read with no lock, under the same rule: written before there is a request, and reloading configuration is a separate feature that does not exist.

**Zero read at run time leaves `listen()`'s `max_body` in force** and logs once at `warn`. The compile-time form refuses zero because it is a route that refuses every body, and a number that arrives later cannot be refused while compiling. A setting left at zero most often means "no limit"; of the three readings (every body refused, no bound, the server's own bound) only the last fails closed without failing every request.

## On a gRPC call it means the same thing

**A route's `maxBody` is the limit its gRPC call is collected under**, the raised one as much as the lowered. A call's message is collected, and a gzip message's inflated size is checked, before any middleware runs ([ADR 220](220-grpc-is-served-over-h2c-behind-a-flag.md)), so the middleware cannot be what says the limit there. The route is known from `:path` as soon as the headers are in, and the collector asks the App what that route's limit is: the last `maxBody` in the route's chain, the one that has the last word on HTTP/1, or `listen()`'s `max_body` where the chain has none. Over it is `RESOURCE_EXHAUSTED` (8) without the route running, as over `max_body` always was. The `maxBody` middleware still runs, and still sets the limit the route's reads go by.

**What makes that possible is that `maxBody` hands back more than a function.** A middleware is a function pointer, and nothing can ask a function pointer what number it carries without calling it, which is the one thing the collector may not do. So `nilo.maxBody` returns an `mw.Limited`: the middleware and the limit it gives, a number or the `usize` it reads. `use`, `useOn`, `with` and `without` take it wherever they take a middleware, and keep the pair, one per function, in `App.body_limits`, which is empty unless `maxBody` is used. `nilo.maxBody(n)` and `nilo.maxBody(&limit)` are spelled as they were; what stops compiling is a program that stored the result in a `nilo.Middleware` variable, which has to use the `.run` field. `maxBody(&limit)` is read when the call's headers arrive, so it is read once a call, where HTTP/1 reads it once a request.

**The connection's budget follows the largest limit a call can be given.** The budget that protects memory is `max(ceiling + 5, 65,535)`, where `ceiling` is `max_body`, or the largest limit any `POST` route's chain gives where one raises it ([ADR 220](220-grpc-is-served-over-h2c-behind-a-flag.md)). So a raised route does not make one connection hold more than the largest raise, and a connection that never calls it is held to what it was. The worst a connection can hold is therefore the largest limit the program wrote, once, plus the first window of each call, which is the bound a listener's `max_body` set to that number gave before, now paid only by the connection that uses it. **What it does not bound:** a limit is a limit before the middleware in front of the route has run. A client that has no session can collect a message up to the route's limit on a route a session guards, as it could up to `max_body` before, and the budget is what keeps that to one such message per connection.

## What it bounds, and what it leaves alone

**Every read into the request arena.** `c.body()`, a JSON body, `Form(T)`,
`Bound(…)` of either, an `Idempotent` route's replay — they all go through
`body()`, so one field covers them. A chunked body is counted against the same
field as it arrives.

**Not `c.bodyStream()`.** It holds nothing in the arena — memory is bounded by
the buffer the handler passes in — and it carries a `max_bytes` of its own
([ADR 019](019-a-request-that-lasts-is-still-one-request.md)) because the question it
answers is a different one: not "how much may sit in memory" but "how much may
the client send at all". A route that streams a body sets that number on the
stream, where it always has.

## What it costs

**Nothing for a route without one.** `_limits.max_body` is what `listen()`
said, as before.

**For a route with one**: a single store into a field already on the `Ctx`,
which is on the fiber's frame. No allocation, no bytes per idle connection,
nothing on the hot path that was not there. `bytes` is `comptime`, so
`maxBody.with` is generic on it and a program that never calls it links none
of it.

**On a gRPC call**, an App that never used `maxBody` pays nothing: `body_limits` is empty, the lookup returns `max_body` before it matches anything, and no allocation is added. One that did pays one more route match when a call's headers arrive (no allocation), and a route whose chain depends on the path (`useOn` with a `:param` in the prefix) pays one chain built and freed. A stream holds one `usize` more, 8 bytes of a call and not of an idle connection, and the retained spare streams hold it too. **Binary size: +144 B on `hello` and +176 B on `rest`**, stripped `ReleaseFast` against `689b034`, though neither uses gRPC or `maxBody`: the registration that notes a `Limited` and the gRPC host's two fields are linked whatever the program registers (ADR 017's running total).

**For a route that reads its number**: one load from a global, a compare and the same store. No allocation, no bytes per idle connection, and the once-only warning is `noinline` and cold, so its format machinery is not on the frame of a request that does not reach it ([ADR 062](062-where-a-connection-waits-is-what-it-costs.md)). A program that never hands it a pointer links none of it.

**A refusal**: `nilo.maxBody(0)` stops compilation. Zero is what somebody
writes for "no limit", and the answer to that is to leave the middleware off.
**A second refusal**: `nilo.maxBody(&n)` with `n` anything but a `usize`. Taking a `u32` would mean a conversion per request for a number whose type is already `listen()`'s `max_body`.

## What was rejected

**Collecting a gRPC message under `max_body` and checking the route's limit afterwards**, which is what shipped first. It made `maxBody` mean two things: on HTTP/1 a limit that raises or lowers, on a gRPC route one that lowers only, since the message had already been refused at `max_body`. A program raising a gRPC route past `max_body` had to raise it for the whole listener, which makes it every route's ceiling (photon's feedback found it).

**Finding the limit by running the chain's `maxBody` early**, against a stand-in request. Middleware is arbitrary code: a session check or a rate limit run for its side effects on a request that is not one is worse than the asymmetry it removes. **Recognising a `maxBody` by its address**, with no change to what it returns, was looked for and has no way in: a function pointer carries nothing, `with(comptime m)` is evaluated while compiling and cannot register anything at run time, and a section of the binary with its bounds is a linker feature that is not the same everywhere.

**A limit per listener**, `.also` entries with a `max_body` each. It answers the whole-listener case and none of the route one: the OTLP route and the rest of the API share a listener.

**`nilo.maxBody.reading(&limit)`**, the shape photon's feedback suggested, beside `cors.reading`. `cors` is a namespace and `nilo.maxBody` is a function, and Zig hangs no declaration off a function, so `.reading` would mean renaming every `nilo.maxBody(n)` to `nilo.maxBody.with(n)`: a breaking change to every route that has one, to buy a name. **A separate `nilo.maxBodyReading`** was the other way to get a name, and it is a second entry for one middleware whose argument already says which form it is. Reading the argument's type is the project's idiom anyway: a pointer is a service and a value is request data in a typed handler, and here a pointer is where the number lives and a value is the number.

**Writing it in the caller's own middleware**, with `c.giveBodyLimit(limit)`. It is three lines and it was always possible, which is why `giveBodyLimit` is public. It is also the fourth time a dependent writes the same three lines, and the zero case is the one each of them would get differently.

**A per-route field in `listen()`** — `.max_body = .{ .default = 1 << 20,
.routes = … }`. A table keyed by pattern is a second registry beside the route
table, and ADR 079 already decided the route table is the registry. `with` is
where a route says what covers it ([ADR 099](099-a-route-can-say-what-covers-it.md)).

**A typed argument** — `nilo.Body(50 << 20, T)`. It reads well and it puts the
limit somewhere only a typed handler can reach. A `*Ctx` handler calling
`c.body()` wants the same limit and has no argument list to say it in.

**Making `bodyStream()` honour it too.** One number for two different
questions. A route streaming a gigabyte to disk under a 50 MB arena limit is a
sensible route, and the stream's own `max_bytes` is where its answer goes.
