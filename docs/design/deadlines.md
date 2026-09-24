# Deadlines

**A deadline in nilo bounds one wait for the network, never a request, and nothing here ever cancels a handler that is running.** How to set one is the guide ([`guide/deploying.md#deadlines`](../guide/deploying.md#deadlines)); the numbers and the calls are the reference ([`reference/app.md`](../reference/app.md#listen-options), [`reference/ctx.md`](../reference/ctx.md), [`reference/middleware.md#nilodeadline`](../reference/middleware.md#nilodeadline), [`reference/fetch.md`](../reference/fetch.md), [`reference/core.md`](../reference/core.md#what-time-it-is)). The code is `http/bulkhead.zig` (`Options`, `Deadlines`), `http/ctx.zig` (`overdue`, `timeLeftMs`, `giveDeadline`, `giveDefaultDeadline`, `tookOver`), `http/deadline.zig` (the `nilo.deadline` middleware), `core/limits.zig` (`Limits`, `Bound`), `fetch/deadline.zig` and `fetch/fetch.zig` (`Exchange`, `timeout_ms`, `stall_ms`), and `sql/postgres.zig` (`Limits.waiting`/`waited` around a wire).

## How the pieces fit

```
inbound, listen()                          outbound, a Service
------------------------------             ------------------------------
header_timeout_ms   one head, absolute     nilo_start(io, limits)
idle_timeout_ms     between requests       Bound.arm(limits, ms)  -> zio.AutoCancel
body_timeout_ms      \ one read run,       Bound.fired()          -> Engine: cancels the fiber
body_min_rate, grace / rate-floored        (no Engine)            -> cancels a task instead
write_timeout_ms    one write

request_deadline_ms (listen floor)         fetch's Exchange:
  |> nilo.deadline(ms) on a route (wins)     timeout_ms  the whole call
  |> Deadlines.set: the tighter always wins  stall_ms    silence since the last byte
  |> dropped by a takeover unless named

a Service's own wait on its socket (pg.zig, a pool queue)
  -> Limits.waiting()/waited() so the watchdog blames the wait, not the handler
```

## The rule in force

1. **A deadline is a limit on one wait for the network, not on a request or a computation.** Nothing in nilo is interruptible mid-handler, so every failure this introduces is an ordinary read or write error, a shape every call site already handles. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
2. **`listen()` carries four operation limits**: `header_timeout_ms` (10,000, one clock for the whole head, armed once), `idle_timeout_ms` (75,000, between requests), `body_timeout_ms` (30,000, one read of the body) and `write_timeout_ms` (30,000, one write). Zero turns any of them off. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
3. **A buffered body also has to arrive at a rate.** A run of reads that assembles one carries `body_grace_ms + bytes / body_min_rate` (defaults 10,000 and 8 KiB/s) on top of the per-read limit, because a per-read limit alone is satisfied forever by one byte every twenty-nine seconds. `body_min_rate = 0` turns the rate floor off and leaves the per-read limit as it was. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
4. **A body that misses its deadline is a 408, not a 500.** `Ctx.slowBody` asks `Deadlines.timedOut()` on the `error.ReadFailed` every timeout collapses into, and turns it into `error.BodyTooSlow`; a 500 would blame the server for something the client did. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
5. **A WebSocket has no read deadline once the handshake is done.** A quiet connection is a working one; what would catch a peer that vanished without a FIN is a ping, which is a WebSocket feature of its own and not shipped as part of this. The write limit still applies, which is what catches a client that has stopped reading. [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)
6. **A Service reaching the network on its own is handed the same clock nilo hands the connection**, through `core.Limits` at `nilo_start(io, limits)`, the same door it is handed `std.Io`. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
7. **A `Bound` is armed in place and never returned by value.** `bound.arm(limits, ms)` takes `*Bound` because the Engine's arming state is address-sensitive (`zio.AutoCancel` stores `&self` as its own timer's userdata); a `Bound` copied after arming would leave the timer pointing at an abandoned slot. Forgetting the `arm` call is the one mistake this shape allows, and it is harmless: an idle `Bound` bounds nothing. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
8. **The bound is the authority, the error is not.** `std.Io.Reader`'s error set is fixed, so a cancellation crosses it as an ordinary `error.ReadFailed`; a caller asks `bound.fired()` after the call rather than reading the error to find out why it ended. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
9. **With an Engine, a `Bound` cancels the fiber's operation; with none, it cancels a task instead**, because `std.Io.Threaded` has no fiber to interrupt but can cancel the task the wait runs as. The Engine's slot is `zio.AutoCancel`, measured at 176 bytes and held in the 192-byte `Limits.slot_size` Core declares and `http/bulkhead.zig` checks at compile time. [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
10. **An outbound call has two separate clocks, and they compose.** `timeout_ms` bounds the whole call; `stall_ms` bounds silence since the last byte arrived, because a call that is honestly slow and a peer that has gone quiet are different failures needing different responses (a stalled segment is retried on a fresh connection; a timed-out one is not). [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md)
11. **A route sets its own request deadline with `nilo.deadline(ms)`, and `listen()`'s `request_deadline_ms` is only the floor every request starts with.** `Deadlines.set` is the one clamp every `arm*` call goes through: whichever of two limits is nearer wins, and a clamp can only shorten, never lengthen. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
12. **A request deadline does not interrupt a running handler either.** It catches exactly what the operation deadlines above already clamp (a slow read, a slow write) and hands a handler `c.overdue()` and `c.timeLeftMs()` to check itself; both answer safely (`false`, `null`) on a route with no deadline set. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
13. **What happens at the deadline depends on what has gone out.** Nothing sent and overdue is a 503 naming the budget; something already sent is left alone, because a half-sent response cannot become a 503; a handler that finishes late without checking still answers, logged as a warning rather than discarded. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
14. **Taking the connection over drops a default deadline but keeps one asked for by name.** `c.stream()`, `c.events()`, `c.upgrade()` and `c.bodyStream()` all go through one function, `tookOver`, so a health-check's default cannot cut an hour-long stream off, while a route that called `nilo.deadline(ms)` and then streamed anyway keeps what it asked for. [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)
15. **A Service's own wait on its socket is a park too, and has to say so.** `Limits.waiting()`/`waited()` tell the watchdog a fiber is parked inside a Service's own `Io` (a Postgres round trip, a pool queue), one pair per statement rather than per row; without it every slow query was misreported as a handler holding its thread. [ADR 210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md)

## Decisions

| ADR | What it decides |
|---|---|
| [022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md) | The four inbound operation limits, the body rate floor, and what each timeout tells the client |
| [056](../adr/056-the-way-out-was-open-the-clock-was-not.md) | `core.Limits`, how a Service arms a `Bound`, and the fetch split between `timeout_ms` and `stall_ms` |
| [105](../adr/105-a-route-can-say-how-long-it-has.md) | `nilo.deadline(ms)`, `request_deadline_ms` as a floor, and what a takeover does to it |
| [210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md) | A Service's own wait reported to the watchdog through `Limits.waiting`/`waited` |

Beside this topic: the watchdog these deadlines report through, and what counts as a park, is [ADR 013](../adr/013-handlers-must-not-block-the-thread.md) (engine); the per-connection memory a `Bound`'s slot costs is priced against [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); the general per-route override shape `nilo.deadline` follows is [ADR 099](../adr/099-a-route-can-say-what-covers-it.md) (middleware); why a Fitting is the layer that can hold `Limits` at all is [ADR 061](../adr/061-a-fitting-borrows-the-loop.md) (fetch); the SQL-side deadline this does not replace, `tx.deadline`, is [ADR 043](../adr/043-a-deadline-needs-a-connection-you-hold.md) (sql-runtime).

## Open

- **Nothing tells a handler its client has gone.** A read-side EOF is not "the client left" (a half-closed client is still waiting for its answer), so the obvious implementation is wrong; on record in [the roadmap](../roadmap.md), under `nilo_http`, needing two named signals rather than one flag.
- **`nilo_fetch` does not yet report its waits through `Limits.waiting`/`waited`.** A slow outbound call still draws the watchdog's "held its thread" misreport that ADR 210 fixed for SQL; on record as the next caller of the seam in [ADR 210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md)'s own consequences.
- **A deadline that also covers `nilo.sleep` and `nilo.Mutex.lock`.** Both already return `error.Canceled` for a shutdown, and a caller cannot yet tell that apart from a deadline by the name alone; recorded in [ADR 105](../adr/105-a-route-can-say-how-long-it-has.md) as worth doing, not done here.
