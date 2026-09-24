# Routing

**A route's pattern is the whole of its identity: what matches a request, what a URL is built back from, and what a route is called are all read off the same compile-time string, so none of them can drift out of step with another.** How to register and group routes is the guide ([`guide/routing.md`](../guide/routing.md)); every method is the reference ([`reference/app.md#app`](../reference/app.md#app), [`reference/ctx.md`](../reference/ctx.md)). The code is `http/router.zig` (`validatePattern`, `Route`, `add`, `match`, `max_segments`), `http/app.zig` (`routeNamed`, `checkName`, `named`), `http/ctx.zig` (`url`, `routeName`) and `http/url.zig`.

## How the pieces fit

```
  "/api/partners/:id"  ── validatePattern (comptime) ──► six refusals:
                                                          no leading slash, empty,
                                                          `:` with no name, a name
                                                          used twice, `*` not last
                                                          or mixed with text,
                                                          `{id}` where `:id` goes
        │
        ├── app.add(): a specificity score, computed once ── error.DuplicateRoute
        │               (literal > param > `*`, MSB-first)     if the shape exists
        │
        ├── match(): highest score wins, not first registered
        │
        ├── app.named("…") / checkName: the operationId, or the derived default
        │
        └── c.url(pattern, .{ .id = 7 }): the same literal, walked at
            comptime, values percent-encoded, every mismatch a compile error
```

`app.routes()` is a read-only view onto the same table `match` scans and `app.metrics` indexes into: method, joined pattern and name, nothing more.

## The rule in force

1. **The most specific route wins, not the one registered first.** Specificity is two bits per segment, packed most-significant-first, so a literal beats a param beats a `*` and an earlier segment always outranks a later one. [ADR 012](../adr/012-the-most-specific-route-wins-and-duplicates-are-refused.md)
2. **A second route of the same shape is refused at registration**, `error.DuplicateRoute`, naming the pattern already there; param names are not part of the shape, so `/users/:id` and `/users/:name` collide. [ADR 012](../adr/012-the-most-specific-route-wins-and-duplicates-are-refused.md)
3. **A pattern that cannot work at all is a compile error, not a startup assertion.** `validatePattern` catches no leading slash, an empty pattern, a `:` with no name, a param name used twice, a `*` that is not last or is mixed with other text, before `App` ever runs. [ADR 012](../adr/012-the-most-specific-route-wins-and-duplicates-are-refused.md)
4. **`{id}` is refused rather than matched as five literal characters.** OpenAPI's brace syntax is what nilo's own document prints and what a porter's existing document already says, so the message names that source rather than only the rule: write `:id`. [ADR 118](../adr/118-a-pattern-written-the-way-the-document-prints-it.md)
5. **A route pattern is its own name, and nothing is kept in step with it.** `c.url(pattern, args)` walks the identical compile-time string a route was registered with, so a renamed or reshaped pattern cannot leave a URL builder pointing at a route that no longer exists. [ADR 100](../adr/100-a-route-pattern-is-the-name-of-its-url.md)
6. **Every mistake in a `c.url` call is a compile error naming the field**: a param with no value, a value with no param, a value of a type a segment cannot carry, or a `*` catch-all, which cannot be built at all. [ADR 100](../adr/100-a-route-pattern-is-the-name-of-its-url.md)
7. **A `c.url` value is always percent-encoded**, one segment per field regardless of what is inside it, so a value cannot smuggle an extra path segment into the result. [ADR 100](../adr/100-a-route-pattern-is-the-name-of-its-url.md)
8. **`app.routes()` is a view, not a copy**, carrying only what a reader should be able to see: method, joined pattern and name, never the handler, the chain or the split segments. [ADR 100](../adr/100-a-route-pattern-is-the-name-of-its-url.md)
9. **A route may declare its own `operationId` with `app.named("…")`, checked while compiling** against letters, digits, `_` and `-`, starting with a letter or `_`; a hyphen is admitted because the document on the other side of a port was spelled by somebody else's generator. [ADR 119](../adr/119-a-route-can-say-its-own-name.md)
10. **Two routes sharing one name are refused at registration, the way a duplicate route is**, because a document with the same key twice leaves whichever consumer reads it seeing only one of them. A route that says nothing keeps its derived name. [ADR 119](../adr/119-a-route-can-say-its-own-name.md)
11. **A name says what a route is called, never what it does.** `named` takes only a name; a summary, tags or a deprecated flag are annotations, and annotating a route is the one thing this framework does not ask for. [ADR 119](../adr/119-a-route-can-say-its-own-name.md)

## Decisions

| ADR | What it decides |
|---|---|
| [012](../adr/012-the-most-specific-route-wins-and-duplicates-are-refused.md) | Matching picks the most specific route; a duplicate shape is refused at registration |
| [100](../adr/100-a-route-pattern-is-the-name-of-its-url.md) | `c.url` builds a URL from the pattern itself; `app.routes()` reads the table |
| [118](../adr/118-a-pattern-written-the-way-the-document-prints-it.md) | `{id}` is refused, naming OpenAPI's brace syntax as the likely source |
| [119](../adr/119-a-route-can-say-its-own-name.md) | `app.named("…")` gives a route its own `operationId`, checked while compiling |

Beside this topic: how the derived `operationId` and the rest of the API description are read off a handler's signature is [ADR 016](../adr/016-the-api-description-comes-from-the-signatures.md); how a middleware learns which route it is in front of, through the same name, is [ADR 162](../adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md); why an error message is held to the wording a build step checks is [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md).

## Open

- **Whether the router needs a tree instead of the linear scan it has today.** Indexing the first segment moved ADR 017's 10% bar out to about 40 routes, and an application with 203 routes exists; a real structure would have to carry specificity ordering itself rather than as a cost added on top, which is what [ADR 012](../adr/012-the-most-specific-route-wins-and-duplicates-are-refused.md) flagged as unresolved when it landed. On record in [the roadmap](../roadmap.md), with two attempts that lost written up in [`docs/history.md`](../history.md).
