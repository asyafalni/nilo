# A Ctx handler that returns nothing may have written it

**Status:** accepted
**Topic:** [openapi](../design/openapi.md)

## Context

The reference says a `void` return is "200, empty, no `Content-Type`", and it is. The generated document said otherwise about the same route:

```
info: 1 of 10 routes write their own response, so the API description does not
describe what they answer
```

```json
"responses": { "default": { "description": "this endpoint writes its own response, so its signature does not describe it" } }
```

A caller read the two, believed the first, and filed the second as a bug. Both sentences were about the same handler and only one of them was true.

Once the wording was fixed, the count it fed on turned out to include routes nilo writes itself. `app.health(path)` and `app.metrics(opts)` register a `*Ctx` handler that answers with `c.send`, the same shape as any handler nilo cannot see inside. An application with a health page and every handler of its own described read `info: 1 of 8 routes hold the Ctx and return nothing …` at startup and went looking for the handler that was wrong. There was none: the line was about nilo's own route, counted as if it were the application's.

## Decision

### What is actually the case

```zig
answer.written = wants_ctx and returnsNothing(Fn);
```

A handler that takes a `*Ctx` and returns nothing is in one of two states, and they are both ordinary: it wrote the response itself, with `c.json`, `c.send`, a `Stream`, a `sendfile`; or it took the Ctx to read a header, set a cookie or check something, wrote nothing, and left nilo to send 200 with an empty body. Zig cannot look inside a function body at comptime, so `wants_ctx` is the only signal there is, and it does not separate the two.

**The classification does not change**, deliberately. It fails in the safe direction: a document claiming an empty 200 on a route that streams a file would be a document that lies, and a document saying "I do not know" about a route that answers 200-empty is only unhelpful. Between an over-claim and an under-claim, the under-claim is the one a client generator survives.

**The wording says what is actually true.** The handler holds the Ctx and returns nothing, so the signature does not settle what it answers, and both the `listen()` line and the document name the way out. The reference gained the row it was missing: right about a handler that takes no Ctx, silent about one that does, which is the row the earlier caller read.

The way out was already built: `Status(code, void)`, the answer to "an empty response with a status I choose" since [ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md).

```zig
fn cancel(c: *nilo.Ctx, db: *Db, id: u32) !nilo.Status(200, void) {
    try db.cancel(id, c.header("x-actor") orelse "");
    return .{};
}
```

It settles the status in the signature, so the document names it, and the handler still holds its Ctx. Nothing new had to be built for this half.

### A route nilo registers itself is given the answer nilo knows it sends

**A route nilo registers is described like any other, with the answer nilo knows it sends, and is not counted among the undescribable ones.** After `app.health` registers its route it calls `describeLast` to set the operation's answer to `200`, `application/json`, with the schema of `health.Page` (`{"status":"ok"}`, what the route sends when everything is ready). After `app.metrics` registers its readout, `describeLast` sets `200`, the Prometheus text type, a string. Neither is `written`, so neither is counted in the line above, and the document carries a `200` for each where it carried a `default`.

The 503s the health page answers are not described, the rule for every route: the document promises what the signature settles, and a failure is not that ([ADR 016](./016-the-api-description-comes-from-the-signatures.md)). The one exception was and is the 404 a `?T` states in the type ([ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md)).

## What was rejected

**A marker return type meaning "I wrote it myself"**, so that `!void` could mean 200-empty. It reads well and it silently re-describes every existing `fn (c: *Ctx) !void` handler that *does* write its own response, whose documents would start claiming an empty 200. A silent documentation regression is worse than the over-claim it replaces.

**Letting the route say, the way `app.named` lets it say its name.** A second place to write down what an endpoint answers is an annotation wearing another name, and [ADR 016](./016-the-api-description-comes-from-the-signatures.md) is the whole reason this framework does not have one. The return type is where a handler says what it answers, and it already can.

**Excluding nilo's own routes from the count and leaving them `default`.** Fixes the line and leaves the document saying it does not know what `/healthz` answers, when nilo does know. Describing is the fix; the count follows from it.

**Rewriting `health` and `metrics` as typed handlers.** The health page reads the service registry, which no argument type names, and the readout's answer is a text format the JSON writer does not produce. Both are `*Ctx` handlers for a reason, and the reason is not that their answer is unknown.

## What it costs

Two message strings and one reference row for the wording fix; no behaviour. One field write per registration, at `app.health` and `app.metrics`, nothing per request. `http/app.zig`: `describeLast`. `http/health.zig`: `Page`.

## Consequences

- The `listen()` line says how many routes are in the undescribable state and what to return instead of it, counting only the application's own routes, so the number is actionable rather than a number to feel bad about.
- The OpenAPI guide says the line counts the application's routes and no others.
