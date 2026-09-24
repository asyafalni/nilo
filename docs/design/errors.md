# Errors

**A failure is sent by a plain function callable from anywhere, bound to the fiber actually serving the request, and answered as JSON in a shape the application may name.** How to fail a request and read what a client is told is the guide ([`guide/errors.md`](../guide/errors.md)); every `fail.*` function is the reference ([`reference/ctx.md#failing`](../reference/ctx.md#failing)). The code is `http/fail.zig` (`Failure`, `InFlight`, `fail.*`), `http/serve.zig` (`sendFailure`), and `http/http.zig` (the panic handler).

## How the pieces fit

```
  handler body
     │
     ├─ fail.notFound("no user {d}", .{id})   ──► Failure (240-byte buffer, bound to the fiber)
     │                                                │
     ├─ an ordinary Zig error (db, allocator, …) ─────┤
     │                                                ▼
     └─ !?T returning null ──► 404, in the type ──► sendFailure ──► {"error": "...", "status": 404}
                                                       (or app.failures(T)'s shape)

  a panic ──► process aborts; the panic handler names the request that was running, nothing recovers it
```

## The rule in force

1. **A fail function stores a message and returns an error, callable without holding a `*Ctx`.** `fail.notFound("no user {d}", .{id})` works inside any function a handler calls, which keeps the typed layer from collapsing into everything holding a Ctx. [ADR 004](../adr/004-http-errors-via-fail-functions.md)
2. **An ordinary Zig error is still served.** Anything a handler returns that is not a fail-function error goes through a mapping table; unrecognised errors become a 500, logged by name. [ADR 004](../adr/004-http-errors-via-fail-functions.md)
3. **The message lives in a fixed 240-byte buffer on the `Failure`, not the request arena.** The failure path must not have a failure path of its own, so a longer message is truncated rather than risking an allocation. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md)
4. **The `Failure` is bound to the fiber, through `zio.TaskLocal`, never to the OS thread.** Many fibers share a thread and a handler that sleeps mid-call can resume on a different one; a `threadlocal` would let fiber A's message land in fiber B's response, a data leak between users. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md)
5. **One `Failure` per connection, cleared at the start of every request.** A message from a previous request on a reused connection can never carry forward. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md)
6. **Outside the Engine, a threadlocal fallback stands in for the fiber slot.** Unit tests call `App` directly with no fiber and no socket; on a real server the fiber slot always exists and always wins. [ADR 006](../adr/006-failure-box-bound-to-the-fiber.md)
7. **`!?T` means the value may not be there, and null answers a 404 with the failure mode in the type.** The document reads this exactly as it reads the success shape, because there is nothing extra to keep in step (full rule on [`openapi`](./openapi.md)). [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md)
8. **`Status(code, T)` puts a chosen status in the type; `Response(T)` keeps it a runtime field.** Both carry the same headers and behave identically at runtime; only the first lets the document write the real code instead of `default`. [ADR 023](../adr/023-a-failure-mode-belongs-in-the-return-type.md)
9. **Every failure answers as JSON, `{"error": "…", "status": …}` by default**, in the same fixed stack buffer and the same send path a handler's own answer uses, so a 405 keeps its `Allow` and a 401 its challenge. [ADR 024](../adr/024-every-failure-answers-as-json.md)
10. **`app.failures(T)` lets the application name its own shape once.** `T.nilo_failure(status, message) T` fills it; nilo writes it with the same JSON writer a handler's answer goes through, and the document derives `components.schemas.Failure` from `T`'s fields so the wire and the document cannot disagree. A second call is `error.FailureShapeAlreadySet`. [ADR 024](../adr/024-every-failure-answers-as-json.md)
11. **The five answers sent before there is a `Ctx` (a malformed head, a head too long, a head that timed out, a body under a coding nilo cannot read, a request shed past `max_in_flight`) keep nilo's own shape, never the application's.** There is no failure struct to fill yet, and a shed request costing one write matters more than its envelope. [ADR 024](../adr/024-every-failure-answers-as-json.md)
12. **A type nilo names in a message spells the name a reader actually imported**, `nilo.Str` rather than the file it happens to live in inside this repository. A type carries `pub const nilo_type_name` and a test at the bottom of `http.zig` refuses an export that cannot name itself. [ADR 074](../adr/074-a-type-says-its-own-name.md)
13. **A panic is not a failure, and nothing recovers from one.** Zig has no unwind-and-resume; a panic aborts the process. The panic handler names the request that was running (`panic while handling GET /users/42`) using the same fiber slot as `fail`, but the process still dies. [ADR 007](../adr/007-no-recover-middleware.md)

## Decisions

| ADR | What it decides |
|---|---|
| [004](../adr/004-http-errors-via-fail-functions.md) | Fail functions, callable from anywhere, storing a message for the request currently running |
| [006](../adr/006-failure-box-bound-to-the-fiber.md) | The `Failure` is bound to the fiber, not the thread, and capped at 240 bytes with no allocation |
| [023](../adr/023-a-failure-mode-belongs-in-the-return-type.md) | `!?T` documents a 404 and `Status(code, T)` documents a chosen status; every other failure stays a body-only `fail.*` call |
| [024](../adr/024-every-failure-answers-as-json.md) | Every failure answers as JSON; `app.failures(T)` lets the application name its own shape once |
| [074](../adr/074-a-type-says-its-own-name.md) | A nilo type carries `nilo_type_name`, so a message names the type the reader imported |

Beside this topic: a panic killing the process and naming the in-flight request rather than recovering from it is [`middleware`](./middleware.md) (ADR 007), because it was written where a `recover` middleware would otherwise have gone; what a signature settles for the document versus what stays invisible in a `fail.*` call is the same rule read from the other side in [`openapi`](./openapi.md) (ADR 016, ADR 023, ADR 024); a body field binding its own failures rather than a handler's is [ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md) (request-input).

## Open

- **The API description names one failure mode per route, and a real endpoint has several.** `!?T` puts a 404 in the document because the signature settles it; a `fail.conflict` on a duplicate email is a line in a function body and stays invisible. Kept as the rule rather than a gap, since widening it means a second place to write a failure down. Reopened only by a shape that states a failure in the type; on record in [`docs/decided.md`](../decided.md).
