# Lifecycle

**A service is not finished when it is provided, and not stopped when the caller's `defer` runs; both happen on the loop, at a moment `listen()` owns.** How to use it is the guide ([`guide/deploying.md`](../guide/deploying.md), [`guide/background.md`](../guide/background.md)); every hook and its signature is the reference ([`reference/app.md`](../reference/app.md)). The code is `http/service.zig` (the four markers and the registry), `http/app.zig` (`provide`, `before`, `start`, `listen`, the boot phases) and `http/health.zig`.

## How the pieces fit

```
provide(&svc) ──► registry records nilo_start / nilo_stop / nilo_ready / nilo_check
                   (a null check per hook the service does not declare)

listen():
  1. every nilo_start(io[, limits])   ── opens what the service owns, on this loop
  2. every app.before(f, args)        ── a *nilo.Run, thrown away after
  3. every nilo_check(io)             ── looks at what step 2 made
  4. every spawn(...)                 ── may use any of the above
       … requests served …
  stop: connections cancelled, then nilo_stop() in reverse order, then the Runtime goes

app.start(io) runs phases 1-3 on the caller's own Io, for a program with no listen().
```

## The rule in force

1. **A service finishes building itself once there is a loop, not when it is provided.** It declares `pub fn nilo_start(self: *T, io: std.Io) !void`, run once by `listen()` in provide order; a service without one costs a null check at startup. [ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
2. **The boot order is bind, then start, then say "listening".** A port already taken is still reported first, and the log line that claims the server is up is not printed until every `nilo_start` has returned. [ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
3. **A `*const` service with a `nilo_start` is a compile error.** Finishing means writing to yourself. [ADR 037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
4. **A service is put down before the loop is**, with `pub fn nilo_stop(self: *T) void`, run inside `listen()`'s teardown after connections are cancelled and before the Runtime is deinitialised. [ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)
5. **Services stop in the reverse of provide order**, and `nilo_stop` runs even on a boot that failed partway, so a pool `ready` opened is still closed. [ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)
6. **A service that put work on the loop needs `nilo_stop`, or the loop cannot be torn down.** A task still outstanding when the Runtime deinitialises is an assertion failure, not a clean exit. [ADR 121](../adr/121-a-service-is-stopped-before-the-loop-is.md)
7. **A health route asks the services, not the process.** `app.health(path)` answers `200 {"status":"ok"}`, a `503` naming which service is not ready and why, or `503 {"status":"stopping"}` once told to stop, always with `Cache-Control: no-store`. [ADR 154](../adr/154-a-health-route-asks-the-services.md)
8. **Readiness is a sentence, not a bool**, from `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8`: null is ready, a string is why not, and a service that declares none is assumed ready. [ADR 154](../adr/154-a-health-route-asks-the-services.md)
9. **One route, and it means ready, not merely alive.** A liveness check is answered by any route already; a probe against a metered service such as S3 is not built, because a request a second to somebody else's bucket is a bill, not a check. [ADR 154](../adr/154-a-health-route-asks-the-services.md)
10. **Work that needs a service runs on that service's own loop, in a fixed order, never before it or on a different one.** `app.before(func, args)` hands `func` a fresh `*nilo.Run` and then `args`; if it fails, `listen()` does not start the server and the services already started are stopped on the way out. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)
11. **The boot is four phases and the order is the only one available**: every `nilo_start`, then every `app.before` call, then every `nilo_check`, then `spawn` work. `nilo_check` sees what `before` built, which is why a schema check moved out of `nilo_start` and into its own hook. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)
12. **`app.start(io)` runs phases one to three on the caller's own `Io`, for a program that never calls `listen()`**: a test through `testing.Client`, a script, a worker on `jobs.serveOn(io)`. A service keeps the `Io` it was started on, so `listen()` after `app.start(io)` is refused once any service has started, naming which. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)
13. **`db.expecting(version)` is the version guard alone**, installed as a `nilo_check` on the pool `nilo_start` already opened, needing no `before` call: behind is refused by name, ahead is allowed and logged. [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)

## Decisions

| ADR | What it decides |
|---|---|
| [037](../adr/037-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md) | The `nilo_start` hook: when a service finishes building itself, and the boot order around it |
| [121](../adr/121-a-service-is-stopped-before-the-loop-is.md) | The `nilo_stop` hook: a service is put down before the Runtime is, in reverse of provide order |
| [154](../adr/154-a-health-route-asks-the-services.md) | The `nilo_ready` hook and `app.health`: readiness as a sentence, asked of the services rather than the process |
| [180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md) | `app.before`, `nilo_check`, `app.start(io)`, and the four-phase boot order that makes them safe together |

Beside this topic: why the one dependency a plain build links is zio, and why `serve` is the only place an `Io` is handed out, is [ADR 001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md) (engine); why a handler must not block the loop, which is what `nilo_start` dialling a pool would otherwise do, is [ADR 013](../adr/013-handlers-must-not-block-the-thread.md); the four trade axes every cost in this page is measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md); a boot dialling the one connection its work needs, which `nilo_check` relies on, is [ADR 115](../adr/115-a-boot-dials-the-connection-its-work-needs.md); the migration process that is the commonest thing to put in `app.before` has its own page at [`sql-migrations.md`](./sql-migrations.md).

## Open

- **The allocation count of a `select` run during `app.before` or `nilo_start`** is unmeasured; ADR 037 records it as still to check against the request-path budget test.
