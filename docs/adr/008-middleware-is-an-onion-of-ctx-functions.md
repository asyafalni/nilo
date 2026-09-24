# Middleware is an onion of Ctx functions, resolved at listen()

**Status:** accepted
**Topic:** [middleware](../design/middleware.md)

## Context

Middleware works at the `Ctx` layer, never the typed layer ([ADR 002](./002-typed-handlers-are-a-thin-layer-over-ctx.md)). What had to be decided was its shape, how a chain is assembled, where it attaches, and how a route removes itself from one.

Every API with accounts has the same shape: one prefix, almost all of it behind a session, and two routes inside it that cannot be, because you cannot require a session to create one. An application built with `app.use(mw)`, `app.useOn(prefix, mw)` and a group's own `use` had no way to say "except this route", so `g.use(requireOperator)` on a group mounted at `/v1` guarded `/v1/sign-up` too, and sign-up answered 401 on the first run, in ten tests at once. **Registering the open routes first did not help, and that is the expensive part: it looks like it should.** Chains are resolved at `listen()` (below), so mount order carries no meaning at all, and the failure is silent, immediate and un-Googleable.

## Decision

```zig
fn timing(c: *Ctx, next: Next) !void {
    var timer = try std.time.Timer.start();
    try next.run(c);
    std.log.info("{s} took {d}µs", .{ c.path().view(), timer.read() / 1000 });
}

const v1 = app.group("/v1");
try v1.use(requireOperator);

const open = v1.without(requireOperator);
try open.post("/sign-up", signUp);
```

### An onion, not before/after hooks

The obvious alternative is two hooks, `before(c)` and `after(c)`. It has nowhere to put the thing that connects them: the timing middleware above needs a start time visible to both halves, and with separate hooks that value has to live in state nilo does not keep per request. With an onion it is an ordinary local variable, and the borrow checker of the human reading it is `try next.run(c)` sitting in the middle.

**The onion makes short-circuiting fall out for free.** A middleware that answers and does not call `next` ends the chain; nothing extra was invented for auth rejection. A middleware that fails goes through the same path as a handler that fails, the fail functions and the mapping table of [ADR 004](./004-http-errors-via-fail-functions.md): `return fail.unauthorized("token expired", .{})` from either produces the same response. One error path, not two.

### The chain is a runtime slice, resolved at listen()

```zig
pub const Middleware = *const fn (*Ctx, Next) anyerror!void;

pub const Next = struct {
    rest: []const Middleware,
    handler: CtxHandler,

    pub fn run(self: Next, c: *Ctx) anyerror!void {
        if (self.rest.len == 0) return self.handler(c);
        return self.rest[0](c, .{ .rest = self.rest[1..], .handler = self.handler });
    }
};
```

`Next` is two words, passed by value, allocating nothing per request. The per-route slice is built once, at `listen()`, by `resolveChains`.

**Resolving at `listen()`, rather than at each route's registration, is what makes mount order irrelevant.** It kills the gotcha other frameworks report most, where a middleware added after a route silently does not apply to it. In nilo, order between `use`/`useOn` and a verb method does not matter. Order *among* `use`/`useOn` calls does, and that is the only ordering rule there is: middleware run in the order they were registered, and one registered with a prefix only runs on routes under that prefix.

Fusing the whole chain into a single function at compile time would remove the indirect call per layer. It was rejected for the same reason [ADR 005](./005-services-via-a-runtime-registry.md) rejected a generic `App`: it would force every route's middleware set to be known at the point the route is registered, buying back a few nanoseconds across two to four layers, well under the [ADR 017](./017-the-trade-budget-has-four-axes.md) threshold.

### The chain runs even when no route matches

Otherwise the logger never sees a 404 and CORS cannot answer a preflight for a path that does not exist, both of which are exactly when they matter. So the chain always runs; when nothing matched, the innermost call is the 404 responder instead of a handler.

### Headers are set on the way in, not streamed

`c.setHeader(name, value)` accumulates into the request arena and is written out by `send`. Middleware sets headers before calling `next`, which is what CORS is built on. A finished response is flushed before the connection waits, not before `send` returns, so a pipelining client gets one write for many responses ([ADR 201](./201-a-response-is-flushed-before-the-connection-waits.md)). The p99 metric stays honest, and the "after" half of a middleware can observe and clean up but cannot rewrite a response `send` has already written.

### A group can say a middleware does not cover it

`without(mw)` hands back the same group, or the App, with that middleware off for the routes registered through what it returns:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);

const open = v1.without(requireOperator);
try open.post("/sign-up", signUp);
try open.post("/sign-in", signIn);
```

Everything else in the chain still runs: the logger still logs the sign-up, CORS still answers its preflight. It is one middleware off one route, not a route with no chain.

Three properties, each of them the reason a different bad shape was not taken:

- **The default stays deny.** The guard is on the group; a route says otherwise about itself. A route added next month is guarded because nobody did anything.
- **The exception is where the route is.** Renaming `/sign-up` moves it, because the exception is recorded by the same `joined(prefix, pattern)` the registration uses; there is no second copy of the string to fall out of step.
- **The URL layout is not decided by the middleware.** `/sign-up` stays inside `/v1` where it belongs, rather than being moved outside the prefix to dodge the guard.

The exclusion list is a comptime parameter of the group's type, `GroupOf(prefix, excluded)`, of which `Group(prefix)` (a plain `app.group(prefix)`) is the empty case, so which routes carry an exception is settled while compiling, and the `inline for` that records them compiles to nothing for a group that has none.

### `mounted_at` is published

A group publishes the prefix it was built with as `mounted_at`, and so does the App (`""`). A `Middleware` is a bare function pointer with nowhere to keep state, so an exclusion or a plugin that needs to know its own prefix used to have no way to ask; a `mount(g: anytype)` plugin now reads `@TypeOf(g).mounted_at` rather than parsing `@typeName` or being handed the prefix a second time as an argument that can fall out of step with the first.

### A guard reads what it needs; it does not hand it over

A middleware guarding `/api` can reject a request but was once unable to pass the user it had just resolved on to the handler, which would have meant a `c.locals` map, untyped state smuggled back in through the side door. **The thing middleware was asked for, a resolved user, is a resolved value instead** ([ADR 015](./015-resolved-values-are-declared-by-their-type.md)): worked out once per request from a function the type itself carries, and asked for by writing the type in a handler's argument list. A middleware guards, a resolved value provides, and `c.resolve(T)` is how a guard reads one without making the handler behind it work the same thing out twice.

## What was rejected

**A path skip-list inside the middleware.** Default-deny, which is the right direction, but the exception is a string compared against `c.path()` in a framework whose whole claim is that the compiler checks the contract. Rename the route and the guard protects a 404 while the real one goes open, and nothing fails to compile.

**`useOn` per resource subgroup**, guarding each prefix by hand. Declarative, and default-*allow*: every new prefix is unguarded until somebody remembers to guard it. This is the shape that ships a security hole eventually.

**Moving the open routes out of the prefix**, `/sign-in` beside `/v1` rather than inside it. Free, but it means the URL layout is decided by the middleware rather than by the API.

**Per-route middleware, `g.postWith(&.{guard}, "/x", h)`.** The positive form of the subgroup idea, and still default-allow. It also needs a second copy of every verb method.

**A `g.open(pattern, handler)` that runs no middleware at all.** Simpler, and wrong: it drops the logger and CORS from exactly the routes an operator most wants to see logged.

**Making `use`/`useOn` take an `except` list of patterns.** The strings end up in the `use` call rather than on the middleware, a smaller version of the same problem: renaming the route still leaves the exception behind, now in a different file.

**Fusing the chain at compile time.** Rejected above under the chain's shape: the saving is under the [ADR 017](./017-the-trade-budget-has-four-axes.md) threshold and the cost is registration order the user has to keep.

**Two hooks, `before`/`after`, in place of the onion.** Rejected above: nowhere to hold what connects them without per-request storage nilo does not keep.

**A `c.locals` map for a middleware to hand a value to the handler.** Untyped state smuggled in through the side door; closed instead by resolved values, above.

**Leaving `Group` out to keep the compile-time engine simple.** It now exists precisely because `without`'s exclusion list needs a type to carry it, and it is what a plugin reads its own prefix from through `mounted_at`.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0. `Next` is two words passed by value; a request that matches no `without` exemption allocates nothing extra |
| Memory per idle connection | 0 |
| Throughput and p99 | An indirect call per middleware layer, two to four deep on a typical route; fusing the chain to remove it was measured against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s threshold and not worth the ordering it would force on the caller |
| Binary size | The exclusion list is a comptime parameter folded away for a group with none; an App with no `without` call carries one empty `ArrayList` and never looks at it |

Chains, and the exemptions inside them, are resolved once per route in `resolveChains`, which runs at `listen()`; the request path only ever sees a resolved slice of function pointers.
