# 0267 — a deadline every request starts with

**Status:** accepted
**Amends:** [ADR 0133](./0133-a-route-can-say-how-long-it-has.md), which
rejected "a `request_timeout_ms` in `listen()`" under *What was rejected*.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0023](./0023-a-deadline-belongs-to-an-operation-not-to-a-request.md),
[ADR 0104](./0104-a-cleanup-path-is-not-cancellable.md),
[ADR 0126](./0126-a-route-can-say-what-covers-it.md).
**Found by:** reading [dusty](https://github.com/lalinsky/dusty)'s
`ServerConfig.timeout.request` — one number, 30 seconds, on by default —
against nilo's `nilo.deadline(ms)`, which is per route and off unless asked.

## Context

ADR 0133 built `nilo.deadline(ms)`: a route says how long it has, every wait
nilo owns is cut down to it, and a handler doing its own work asks
`c.overdue()`. It rejected a number in `listen()` with this:

> One number for every route is the wrong shape: an upload and a health
> check do not have the same budget, and a number loose enough for the
> slowest route bounds none of the others.

That is true and it is not the whole picture. It answers "what is the right
budget for this route", and the question a deployment actually has is
**"which routes have no budget at all"** — and the answer is every route
whose author did not think about it, which in an application of forty
routes is most of them. `nilo.deadline` is a statement a route makes on
purpose; a route with none is not a route that chose "unbounded", it is a
route nobody looked at. The bound that is missing is the floor, not the
right number.

dusty ships one number, on by default, and gives a handler `setTimeout` to
re-arm it — which is the shape that fits a `(*Request, *Response)` API where
every route is the same function type. nilo has something better than a
re-arm: a route that knows its budget says so with `with(nilo.deadline(ms))`,
and the middleware is the one place that number lives.

## Decision

**`listen()` takes `request_deadline_ms`, and it is the deadline every
request starts with.** It is applied before the chain runs, through the same
`until_ns` ADR 0133 built, so a route's own `nilo.deadline` replaces it — the
route's number is set later and wins — and everything ADR 0133 says still
holds: every wait is clamped to it, `c.overdue()` and `c.timeLeftMs()` read
it, and a handler that is running rather than waiting is not interrupted.
Nothing is cancelled; ADR 0104 stands.

**A request that takes the connection over lets go of it.** `c.stream()`,
`c.events()`, `c.upgrade()` and `c.bodyStream()` are the four ways a request
stops being one that answers and goes, and they are the four where "an
upload and a health check do not have the same budget" is exactly right —
a default chosen for the health check cuts the event stream off at the same
second every time. So a **default** deadline is dropped at the takeover, and a
deadline the route asked for **by name** is kept, because that route knew it
was going to stream and said thirty seconds anyway. The distinction is one
flag on `Ctx`, `_deadline_default`, set by `giveDefaultDeadline` and cleared
by `giveDeadline`.

**Zero, off, is the default.** dusty's thirty seconds is a reasonable number
for an API and the wrong number for a report, and nilo's four operation
deadlines already answer the case ADR 0023 was written for — a client that
stalls. What is left is a policy about the handlers behind the server, which
their author is the one to set. The option's doc comment says thirty seconds
is where to start.

## What it costs

- **Allocations per request:** none.
- **Memory per idle connection:** none; the flag is a byte on a `Ctx` that
  lives on a frame the connection unwinds before it waits (ADR 0071).
- **Throughput:** one `monotonicNanos()` per request when the option is set,
  which is the read `block_warning_ms` already makes; none when it is zero,
  because `giveDefaultDeadline` returns before the clock on `ms == 0`.
- **Binary:** two small functions.

## Alternatives

**Leave it rejected.** The argument above: the rejection answered the wrong
question. The number of routes with no deadline in the stress application
is the whole of it, and nobody chose that.

**Thirty seconds on by default.** What dusty, Go's `ReadTimeout` users and
most reverse proxies do. Refused for the reason the option's doc gives — a
total is a policy about the handlers, and a default that cuts a first user's
report route off at thirty seconds with a 408 they did not configure is a
worse first day than one where nothing is bounded and `block_warning_ms`
says so. The four deadlines already hold the line against a hostile client.

**Keep the default through a takeover, and let the route re-arm.** dusty's
shape, `req.setTimeout(...)` before each WebSocket message. Puts the rule in
every streaming handler instead of in one place; a handler that forgets is a
WebSocket cut off at thirty seconds. Dropping the default at the takeover
puts the decision where the takeover is.

**A separate `stream_deadline_ms`.** A second number for the routes the first
one is dropped from. A route that wants one has `nilo.deadline`, which is
kept, and that is one number in one place rather than two in `listen()`.

## Consequences

- `http/bulkhead.zig`: `Options.request_deadline_ms`.
- `http/ctx.zig`: `Limits.request_deadline_ms`, `Ctx._deadline_default`,
  `giveDefaultDeadline`, `tookOver` — the three `_took_over = true` sites
  now go through one function, so the rule cannot be forgotten at a fourth.
- `http/serve.zig`: applied once, before the chain, after `Ctx` is built.
- `http/deadline.zig`: two tests at the bottom hold that the default reaches a
  route, that a route's own replaces it, and that a takeover drops the
  default and keeps the route's own.
- `docs/reference/app.md` and the deploying guide's two tables carry the
  option; ADR 0133's rejection is superseded by this one and left in place,
  because the argument it makes is still the reason the default is zero.
