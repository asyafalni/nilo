# 0286 — a service's wait on its own socket is a park

**Status:** accepted
**Applies:** [ADR 0034](./0034-the-thing-a-handler-holds-is-watched-at-run-time.md)
(a handler that holds its thread is noticed and named),
[ADR 0132](./0132-what-is-watched-is-one-unparked-stretch.md)
(what is measured is one unparked stretch),
[ADR 0065](./0065-the-way-out-was-open-the-clock-was-not.md)
(`core.Limits` is what the Engine hands a service).
**Found by:** a query engine running a 400 ms scan through `db.raw` under
`listen()`, and reading in its log, nine times a second:

```
handler POST /query held its thread for 4629ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 0014).
```

The handler had done nothing but call `db.composed` and wait. The fiber
was parked on the socket the whole time, on zio, the way every fiber
parks. The thread was serving everybody else.

## Context

The watchdog measures the longest stretch a fiber ran without parking, and
it learns of a park from the places that park: `nilo.blocking`,
`nilo.sleep`, `nilo.Mutex`, the body reader, the response writer, a
stream, a WebSocket (ADR 0132). A service that waits through its own `Io`
— pg.zig on a socket, `std.http.Client` in `nilo_fetch`, a pool a caller
queues on — parks the fiber just the same, and told the watchdog nothing.
So every database round trip over `block_warning_ms` (250 by default) was
reported as a handler holding its thread, with advice to hand it to
`nilo.blocking`, which would have made it worse.

The report is the one that finds the invisible bug (ADR 0034). A false
positive on the most ordinary slow thing a handler does — a query — is a
report nobody reads twice.

## Decision

`core.Limits.VTable` gains `waiting` and `waited`: a service about to wait
on the operating system through its own `Io` says so, and says when it is
done. The Engine's `Limits` implements them with the watchdog
(`waitingAnywhere` / `waitedAnywhere`); `Limits.none` implements them as
nothing. `nilo_sql`'s Postgres wire keeps the `Limits` it was started
with and reports every exchange — the pool acquire and the statement as
one wait that stays open until the result is closed, a transaction's
`BEGIN`, its statements, its `COMMIT` and `ROLLBACK` — through the pair.

**One wait per statement, not one per row.** The rows come off the socket
one `next` at a time, and the first draft wrapped each read: two
function-pointer calls, a slot lookup and a coarse clock per row, which a
10 000-row result pays 10 000 times to say what one pair says. So `run`
opens the wait and `Rows.close` ends it. What that hides from the watchdog
is the handler's own work *between* rows — converting each one — and that
work is bounded by the row, not by the handler; a handler that then
computes for 250 ms on the result it holds is watched again from `close`.

The seam is `Limits` because it already is the thing the Engine hands a
service so that the service can be bounded by the fiber it runs on
(ADR 0065); a park is the other half of that relationship. `sql/` stays
below `http/`: it names the seam and never the watchdog.

## The alternatives that were rejected

**Measure the fiber's CPU time instead of wall time between parks.** The
operating system accounts CPU per thread, not per fiber, and a thread
serves many; there is no clock to read.

**Have the Engine record every suspend.** zio knows when a fiber parks,
and an Engine hook would catch every service at once. It is the right
long-term shape and the wrong first change: it reaches into the runtime's
scheduler for something two vtable entries say from the outside, and the
services that park are the ones nilo ships.

**Exempt `db.*` calls by name.** The watchdog has no view of what a
handler called, only of whether it parked; and a driver that truly blocks
a thread (one that does not go through `Io`) should still be caught.

## Consequences

- A slow query is no longer a warning about the handler; a handler that
  computes for 250 ms without a database call still is.
- Two function-pointer calls per statement, on a path that already made a
  round trip, whatever the row count. Nothing on the request path
  allocates for it.
- `nilo_fetch` does not yet report its waits and still draws the false
  report on a slow outbound call; it is the next caller of the seam.
- `sql/live.zig` holds it: a statement is one wait from `run` to `close`
  whatever its row count, and a transaction's three steps each report
  through the `Limits` the wire was opened with.
