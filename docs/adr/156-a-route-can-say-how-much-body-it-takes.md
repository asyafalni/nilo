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

**For a route that reads its number**: one load from a global, a compare and the same store. No allocation, no bytes per idle connection, and the once-only warning is `noinline` and cold, so its format machinery is not on the frame of a request that does not reach it ([ADR 062](062-where-a-connection-waits-is-what-it-costs.md)). A program that never hands it a pointer links none of it.

**A refusal**: `nilo.maxBody(0)` stops compilation. Zero is what somebody
writes for "no limit", and the answer to that is to leave the middleware off.
**A second refusal**: `nilo.maxBody(&n)` with `n` anything but a `usize`. Taking a `u32` would mean a conversion per request for a number whose type is already `listen()`'s `max_body`.

## What was rejected

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
