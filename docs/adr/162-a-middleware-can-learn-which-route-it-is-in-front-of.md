# A middleware can learn which route it is in front of

**Status:** accepted
**Topic:** [middleware](../design/middleware.md)

A middleware is `fn(*Ctx, Next) !void`, and the `Ctx` carried the method, the
path and the params. It did not carry the name the route was registered under,
and `app.routes()` published method and pattern only.

The port that asked for [ADR 119](119-a-route-can-say-its-own-name.md)
found the gap at the seam that ADR was built for. Its authorisation is one
middleware and one table: the middleware reads the matched route's
`operationId`, looks it up in a default-deny table, and refuses anything the
table does not name — for everybody. Their own ADR's argument is the whole of
it: **a check per handler leaves the ninety-first endpoint open with no error
and no failing test, and a table consulted from one place does not.** A test
then reads the OpenAPI document in both directions to hold the table against
the contract.

On nilo that shape could not be written. What the port did instead was move the
lookup to compile time — a `route(g, "createPartner")` wrapper that attaches
the right guard per registration — and a test that scans every source file for
the string `.named(` to make sure nothing registered a route the wrapper did not
see. That holds, and it holds the way a rendering rule held by reading the
source holds: because nothing at run time can be asked.

## Why it is filed rather than kept

Three things are weaker than the one-middleware shape, and each is a
consequence of the same absence.

- The guard is per route, so what makes it universal is a test about spelling.
  A route registered in a file the scan does not read, or through a helper that
  wraps `.named(` inside a function, passes.
- **nilo's own error text already treats the `operationId` as the key an
  authorisation table is written against.** `checkName`'s refusal of an empty
  name says to give a route "the name the generated client and your own
  authorisation table will use". The name is the one identifier a route has
  that a contract also has; a middleware that cannot read it cannot be the
  place the contract is enforced.
- The per-route shape spends the middleware slot: one closure per route,
  allocated at registration. Fine at forty-four operations, a thing to count
  at 267.

## `c.routeName()`

```zig
fn authorize(c: *nilo.Ctx, next: nilo.Next) !void {
    const name = c.routeName() orelse return next.run(c);
    const needed = table.get(name) orelse
        return nilo.fail.forbidden("{s} is not in the permission table", .{name});
    …
    try next.run(c);
}
```

The `operationId` of the route this request matched — **what `app.named` gave
it, or the name derived from the method and the pattern, exactly as the API
description prints it.** Null when nothing matched: a 404, a 405, a static
file. A `HEAD` answered by a `GET` route carries the `GET`'s name, because that
is the operation that ran.

**The derived name too, not only the given one.** The other reading — null for
a route that said nothing — was considered and is wrong for the thing this
exists for. A table is held against the document, and the document prints a
name for every route. A middleware that saw null for an unnamed route would
see a route the document describes and the table cannot name, and the two
halves of the port's test would disagree about what an operation is. So the
name is worked out once at registration, by the same function the document
calls (`openapi.writeDerivedName`, which `writeOperationId` now goes through),
and kept on the `Route`. One copy of the derivation is what keeps the two from
drifting — which is the property a table keyed by the name depends on.

**`routeName` rather than `route`.** A method called `route` on a `Ctx` that
already has `path` and `url` reads as the pattern, and it is not the pattern:
it is the word the document prints.

**A `[]const u8` rather than a `Str`.** Nothing about it ends with the request.
It points at a comptime literal or at a name the App derived at registration
and owns for its whole life, and a `Str` would say the opposite.

## Also on the route table

`app.routes().at(i).name` is the same word. The port said it was not asking
for `app.routes()` to change, and it is one field on `Registered`, published
for the test the port described: holding a table against the route table
without going through the document — every key names a registered route, and
every registered route has a key.

## What was not done

**The name reachable from `Next`.** The other spelling the port offered. It
would have made a middleware two shapes — one that takes the name and one that
does not — for a value the `Ctx` is the natural home of, next to `param` and
`path`.

**A chain per entry on `app.routes()`.** The port mentioned it and did not ask
for it. With the name on the `Ctx` the source scan is deleted and the guard is
one middleware, which is what the chain would have been for.

## Against ADR 017's four axes

- **Allocations per request: zero.** The name is on the `Route`, and the `Ctx`
  holds a pointer to the `Route` the match found — the index the router was
  already carrying for metrics ([ADR 079](079-the-route-table-is-the-registry.md)),
  turned into a pointer once per request. The budget test is unchanged at one.
- **Memory per idle connection: 4,669 bytes, unchanged.** The pointer is eight
  bytes on a `Ctx`, and a `Ctx` lives on the frame `serveRequest` unwinds
  before the connection waits ([ADR 062](062-where-a-connection-waits-is-what-it-costs.md)).
  **A handler that parks its frame pays eight bytes per connection** — a
  WebSocket, a stream nobody closes — by the rule of
  [ADR 062](062-where-a-connection-waits-is-what-it-costs.md), on top of the
  5,183 an idle WebSocket measured. Not re-measured; the figure is the size
  of an optional pointer.
- **Throughput and p99: nothing measurable.** One pointer store on a matched
  request.
- **Binary size: nothing the linker keeps** for a program that never calls
  `routeName`. What every program pays is the derivation at registration —
  one allocation per unnamed route, at boot, freed with the App.

## Consequences

- `Route.name` is set for every route registered through `App`. The Router's
  own `add` keeps its signature and leaves the name empty, which only its own
  tests reach; `addNamed` is what `App` calls.
- The derived names are owned by the App (`derived_names`), one per route that
  said nothing; a route registered through `named` points at its comptime
  literal and takes no slot.
- The port's `guard.zig` becomes one middleware on the group, `table.zig` is
  unchanged, and the source scan goes.
