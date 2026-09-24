# Middleware

**Middleware is an onion of `Ctx` functions resolved once at `listen()`, so mount order between a route and a `use` call never matters and a route can say what covers it or what covers it more.** What it enforces versus what a resolved value provides is the guide ([`guide/middleware.md`](../guide/middleware.md)); every built-in and the chain's own type is the reference ([`reference/middleware.md`](../reference/middleware.md)). The code is `http/middleware.zig` (`Middleware`, `Next`, `chainFor`), `http/app.zig` (`use`, `useOn`, `with`, `without`, `GroupWith`), `http/wiring.zig` (`resolveChains`), and `http/ctx.zig` (`routeName`).

## How the pieces fit

```
  registration time                          listen()                    request time
  ────────────────                          ──────────                   ────────────
  app.use(logger)         ─┐
  v1.use(requireOperator)  ├─► per-route exclusions/attachments ─► resolveChains ─► []Middleware, resolved
  v1.without(op).with(rl)  ─┘        (with/without recorded by                        │
       .post("/sign-up")             the joined prefix+pattern)                       ▼
                                                                          Next{ rest, handler }.run(c)
                                                                          mw1(c, next) → mw2(c, next) → … → handler(c)
                                                                          (before next.run: on the way in
                                                                           after next.run: on the way out)
```

## The rule in force

1. **Middleware operates at the `Ctx` layer and produces no value for the handler; it enforces, a resolved value provides.** The two are not interchangeable ways to reach the same thing. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
2. **A middleware is one function, `fn(*Ctx, Next) anyerror!void`, wrapped as an onion rather than split into `before`/`after` hooks.** A local variable that has to be visible on both sides of `next.run(c)`, such as a timer start, has nowhere to live under two hooks; under the onion it is an ordinary local. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
3. **Not calling `next` ends the chain**, which is the whole of what a rejecting auth middleware has to do; a middleware that fails goes through the same fail-function path a handler does (full rule on [`errors`](./errors.md)). [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
4. **The chain is a runtime slice built once, at `listen()`, by `resolveChains`, not fused into one function at compile time.** `Next` is two words passed by value, allocating nothing per request; fusing the chain was measured against ADR 017's throughput threshold and rejected for the ordering discipline it would force on every route. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
5. **Resolving at `listen()`, not at each route's registration, is what makes mount order between `use` and a verb method irrelevant.** Order among `use`/`useOn` calls themselves still matters: middleware run in the order they were registered, and one registered with a prefix only runs on routes under that prefix. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
6. **The chain runs even when no route matches**, with the 404 responder standing in for the handler, so a logger sees every miss and CORS can answer a preflight for a path that does not exist. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
7. **A group can say a middleware does not cover it.** `without(mw)` hands back the same group (or the App) with `mw` off for what is registered through it; everything else in the chain still runs, the default stays deny, and the exception is recorded against the same `joined(prefix, pattern)` the route itself uses, so renaming the route moves the exception with it. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
8. **A route can say what covers only it, with `with(mw)`, the same vocabulary in the other direction.** `app.with(adminOnly).delete("/users/:id", removeUser)` needs no second registration shape and no options struct; a carried middleware runs innermost, after whatever the group already required. [ADR 099](../adr/099-a-route-can-say-what-covers-it.md)
9. **A guard reads what it needs through a resolved value; it does not hand a value to the handler through untyped state.** There is no `c.locals` map: a middleware that resolves a user and a handler that wants it both go through `c.resolve(T)`, worked out once per request. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
10. **A group publishes the prefix it was built with as `mounted_at`**, so a plugin or an exclusion that needs its own prefix reads it rather than parsing `@typeName` or taking it as a second argument that can drift from the first. [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md)
11. **A middleware can ask `c.routeName()` for the route it is in front of**, the given or derived `operationId`, null when nothing matched (a 404, a 405, a static file). It is worked out once at registration by the same function the OpenAPI document calls, so a table held against the document and a table held against `routeName` cannot disagree about what an operation is. [ADR 162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)
12. **There is no `recover` middleware, because Zig cannot recover from a panic.** `@panic` aborts the process; nothing unwinds and no `defer` runs. What ships instead is a panic handler that names the in-flight request, using the same fiber slot `fail` uses (full rule on [`errors`](./errors.md)), and the documented advice to run `ReleaseSafe` behind a supervisor. [ADR 007](../adr/007-no-recover-middleware.md)

## Decisions

| ADR | What it decides |
|---|---|
| [007](../adr/007-no-recover-middleware.md) | Why there is no `recover` middleware, and what a panic handler does instead |
| [008](../adr/008-middleware-is-an-onion-of-ctx-functions.md) | The onion shape, `Next`, chains resolved at `listen()`, and `without` |
| [099](../adr/099-a-route-can-say-what-covers-it.md) | `with`, the positive counterpart to `without`, attached innermost |
| [162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md) | `c.routeName()`, so a permission table can be held against the same name the document prints |

Beside this topic: the fail-function path a middleware's own failure goes through, and the fiber-bound `Failure` the panic handler reads, is [`errors`](./errors.md) (ADR 004, ADR 006); the specific built-ins (`logger`, `cors`, `allowance`, `deadline`, `maxBody`) are documented in the reference rather than here, and `allowance`'s own rule is [`rate-limiting`](./rate-limiting.md); resolved values as the alternative to a guard handing over state is [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md) (typed-handlers); the `operationId` a route can also give itself, which `routeName` reads back, is [ADR 119](../adr/119-a-route-can-say-its-own-name.md) (openapi).

## Open

Nothing is open on the record.
