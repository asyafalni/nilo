# Typed handlers

**An ordinary function is nilo's real API: nilo reads its argument list while compiling and turns it into exactly the `Ctx` calls it would have made by hand, so the price is a good error message rather than anything paid at runtime.** How to write one is the guide ([`guide/handlers.md`](../guide/handlers.md), [`guide/services.md`](../guide/services.md)); every argument shape is the reference ([`reference/handlers.md#handler-arguments`](../reference/handlers.md#handler-arguments), [`reference/core.md#run`](../reference/core.md#run), [`reference/core.md#anyscope`](../reference/core.md#anyscope)). The code is `http/typed.zig` (the argument loop, `requirements`, `checkAnswer`), `http/wiring.zig` (`missingService`, `Requirement`), `http/app.zig` (`provide`), `http/ctx.zig` (`resolve`, `cachedResolved`), and `core/scope.zig` (`Run`, `AnyScope`).

## How the pieces fit

```
  fn handler(a: *Db, b: PathType, c: SomeResolved, d: BodyStruct) !T
                |        |             |               |
             service   path/query   nilo_resolve      plain
             by type   by nilo_parse  (once, cached    struct
                                       on Ctx)         (JSON)
                |        |             |               |
                `--------+-------------+---------------'
                         v
              typed.requirements collects services and resolver chains,
              per route, while compiling
                         v
              listen() checks every one against app.provide()
              before the socket opens

  A resolver, a Db statement, an ordinary service function: written
  against a Scope (arena(), str()), a shape rather than an interface,
  so the same body runs under a Ctx and under a Run.

    *Ctx  ── request ──┐                    ┌── Run ── a tick, a CLI, a test
                        ├── same shape ──────┤
              give/resolve on Run, entropy on both

  Storing one as a callback (a bus, a queue) erases it: AnyScope, a
  pointer and a five-entry function table, made only where the erasure
  happens.
```

## The rule in force

1. **A typed handler is a thin compile-time layer over `Ctx`, never a replacement for it.** It costs nothing at runtime; what it spends is the quality of the `@compileError` when an argument does not fit. [ADR 002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md)
2. **A service is matched by the type of a handler's argument, against a runtime registry keyed by `@typeName`.** `app.provide` fills it, in any order, before `listen()`. [ADR 002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md), [ADR 005](../adr/005-services-via-a-runtime-registry.md)
3. **A service a route needs but nobody provided is caught at `listen()`, naming the route and the type**, not on the first request that reaches it. `app.missingService()` returns the same fact as plain data, for a test that checks assembly without a socket. [ADR 005](../adr/005-services-via-a-runtime-registry.md)
4. **A request-scoped value is declared on its own type with `nilo_resolve`, and a handler asks for it by writing it in the argument list.** No registration step, and the compiler answers "can this value be produced here" before the route ever runs. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
5. **A resolver may take a `*Ctx`, a service, the request arena, and other resolved values, and nothing else.** A path param, a query struct or the body would tie the value to one route, and a resolver belongs to the request; a loop between resolvers is a compile error that prints it. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
6. **A resolved value is worked out once per request and memoised on the `Ctx`**, so a guard and the handler beneath it share one lookup rather than paying for it twice; the memory is the request arena and dies with the request. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
7. **Middleware guards, a resolved value provides.** Middleware runs on everything under its prefix whether the handler cooperates or not; a resolved value is pulled only by a route that names it. `c.resolve` is how a guard reaches a value a handler further down also wants. [ADR 015](../adr/015-resolved-values-are-declared-by-their-type.md)
8. **A `Run` answers the same Scope shape a `Ctx` does, so a service function written against `arena()` and `str()` runs under a request and under a tick, a CLI or a test alike.** `Run.entropy` mints a key the same way `Ctx.entropy` does, given an `Io` at construction (`Run.initIo`); a `Run` built without one answers `error.NoIo` rather than inventing bytes. [ADR 128](../adr/128-a-scope-that-can-mint-a-key.md)
9. **What a request derives from itself, a tick has to be told.** `Run.give(V, value)` states a value once at the top and `Run.resolve(V)` hands it back, including a given `null`; `error.NotGiven` means nobody called `give`, never silently absent. A request never calls `give`: the same value is a `nilo_resolve` type there, which removes the third state rather than detecting it. [ADR 133](../adr/133-a-value-that-reaches-the-bottom.md)
10. **Storing a Scope behind a function pointer (a bus, a queue, any stored callback) erases it into `AnyScope`, a pointer and a five-entry table, built only at the point of erasure.** `AnyScope.of(scope)` costs two stores and no allocation; every call on it costs one indirect call, paid only by whoever erased. [ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)
11. **An erased Scope answers `resolve` from what the Scope behind it already holds, and never runs a resolver.** A type only the far side of the erasure asks for is `error.NotGiven` unless something up the stack resolved it first; the fix is a bare `_ = try c.resolve(V);` in the middleware that already proved the value, before `next.run`. [ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)
12. **A `?` around a return wrapper (`Status`, `Response`, `Redirect`, `Versioned`) is refused while compiling, and the message says where the `?` belongs.** `Status(201, ?T)` is the shape nilo reads; `?Status(201, T)` looked the same to the wrapper check and reached the JSON writer as an unrecognised struct. [ADR 203](../adr/203-a-question-mark-goes-inside-the-wrapper.md)

## Decisions

| ADR | What it decides |
|---|---|
| [002](../adr/002-typed-handlers-are-a-thin-layer-over-ctx.md) | A typed handler is a compile-time layer over `Ctx`, free at runtime |
| [005](../adr/005-services-via-a-runtime-registry.md) | Services are matched through a runtime registry, checked at `listen()` |
| [015](../adr/015-resolved-values-are-declared-by-their-type.md) | `nilo_resolve`: a request-scoped value declared by its type, not stashed on the request |
| [128](../adr/128-a-scope-that-can-mint-a-key.md) | `Run.entropy`: a Scope that can mint a key, matching `Ctx.entropy` |
| [133](../adr/133-a-value-that-reaches-the-bottom.md) | `Run.give`/`Run.resolve`: what a tick cannot derive, it is told, with `error.NotGiven` over null |
| [144](../adr/144-a-scope-that-crosses-a-function-pointer.md) | `AnyScope`: a Scope erased only where it has to cross a function pointer |
| [203](../adr/203-a-question-mark-goes-inside-the-wrapper.md) | A `?` outside a return wrapper is refused, naming where it belongs |

Beside this topic: why a Scope is a shape checked while compiling rather than a vtable at the root is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md); why `Ctx.entropy` is reachable only from a `Ctx` and not from a module beneath it is [ADR 042](../adr/042-entropy-belongs-to-the-loop.md); why `Ctx.hashPassword` takes a permit from a process-wide Gate rather than being left to `nilo.blocking` on its own is [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md); the four axes every one of these decisions was put against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md); what `?T` means as a return type on its own is [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md); reading the JSON a body argument arrives as is [json](json.md).

## Open

- **A service argument is found by a linear scan of the registry per request**, 1.2ns an entry, 1.6% of a request at four services and rising to 13.4% at thirty-two. Accepted under ADR 017's bar for every app in `examples/`; resolving it into the route at `listen()` is the fix once a caller has more than about sixteen services. On record in [`docs/decided.md`](../decided.md).
