# 0281 — nilo's own routes describe themselves

**Status:** accepted
**Extends:** [ADR 0150](./0150-a-ctx-handler-that-returns-nothing-may-have-written-it.md)
**Applies:** [ADR 0192](./0192-a-health-route-asks-the-services.md),
[ADR 0100](./0100-the-route-table-is-the-registry.md)

## Context

A handler that holds a `*Ctx` and returns nothing may have written its own
answer, and no reading of its signature says what. ADR 0150 has the
document say `default` for such a route and `listen()` say how many there
are, once, so the reader knows which of their handlers the document could
not describe.

`app.health(path)` and `app.metrics(opts)` register exactly that shape:
both are `*Ctx` handlers nilo wrote, and both answer with `c.send`. So an
application with a health page and every handler of its own described
read `info: 1 of 8 routes hold the Ctx and return nothing …` at startup and
went looking for the handler that was wrong. There was none. The line was
about nilo's route, counted as if it were the application's.

## Decision

**A route nilo registers itself is given the answer nilo knows it sends,
and is described like any other.**

After `app.health` registers its route it sets the operation's answer to
`200`, `application/json`, with the schema of `health.Page`, which is the
`{"status":"ok"}` the route sends when everything is ready. After
`app.metrics` registers its readout it sets `200`, the Prometheus text
type, a string. Neither is `written`, so neither is counted in the ADR 0150
line, and the document carries a `200` for each where it carried a
`default`.

The 503s the health page answers are not described, which is the rule for
every route: the document promises what the signature settles, and a
failure is not that (ADR 0017). The one exception was and is the 404 a
`?T` states in the type (ADR 0024).

## What was rejected

**Excluding nilo's routes from the count and leaving them `default`.** It
would have fixed the line and left the document saying it did not know what
`/healthz` answers, when nilo does know. Describing is the fix; the count
follows.

**Rewriting the two handlers as typed handlers.** The health page reads the
service registry, which no argument type names, and the readout's answer is
a text format the JSON writer does not produce. Both are `*Ctx` handlers for
a reason, and the reason is not that their answer is unknown.

## What it costs

One field write per registration, at boot. Nothing per request.

## Consequences

- `http/app.zig`: `describeLast`, called from `health` and `metrics`.
- `http/health.zig`: `Page`, the shape of the 200.
- The OpenAPI guide says the line counts the application's routes and no
  others.
