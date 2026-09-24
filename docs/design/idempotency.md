# Idempotency

**A request answered once is answered the same way again, byte for byte, whether the client is retrying a POST that never got an answer back or asking for the same page a hundred times a second.** How to use it is the guide ([`guide/idempotency.md`](../guide/idempotency.md)); the two arguments are in the reference ([`reference/handlers.md#idempotentreplays-options`](../reference/handlers.md#idempotentreplays-options), [`reference/handlers.md#cachedpages-options`](../reference/handlers.md#cachedpages-options)). The code is `http/idempotent.zig` and `http/cached.zig`, over `Store.putIfAbsent`, `Space.getInto` and `Space.putFor` in `cache/`.

## How the pieces fit

```
  Idempotent(Replays, .{.by})              Cached(Pages, .{.ttl_s})
     key: Idempotency-Key header              key: the request line (.path_and_query, .path, or a header)
              │                                          │
       putIfAbsent a marker (kind, status 0, fingerprint), under the shard's lock
              │                                          │
     first request: handler runs, its answer rendered and kept over the marker
              │                                          │
  a second request, same key ──┬── fingerprint matches ──► kept answer replayed
                                │                            Idempotent-Replayed: true / Cache-Status: nilo; hit
                                ├── still being answered ──► Idempotent: 409
                                │                             Cached: waits (poll_ms, up to max_wait_ms or
                                │                              half the route's deadline), then reads or runs itself
                                └── fingerprint differs ──► Idempotent: 422
```

What the handler failed with is never kept by either: a failure is the case a retry exists for, so the marker is released and the next attempt runs the handler again.

## The rule in force

1. **The behaviour is a route argument, never a middleware**, because a typed handler returns its answer before a byte is written, so nilo can render it, keep it and send it in that order with nothing intercepted. A handler that writes through `*Ctx` and returns nothing has no answer to keep, and is refused at the route rather than surprised on the first replay. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
2. **`Idempotent(Replays, .{ .by })` keys on the client's `Idempotency-Key` header.** A retry with that key gets the first answer's status, its own headers and its body back exactly, the handler does not run, and `Idempotent-Replayed: true` says so. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
3. **Three refusals guard the key before the handler runs**: 400 for one missing or over 255 bytes, 409 for a key still being answered, 422 for a key reused on a different request, method, path, query and body all fingerprinted with it. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
4. **`.by` scopes the key to whoever it belongs to**, an account or a tenant read off the `*Ctx`; two callers who happen to choose the same key must never see each other's kept answer. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
5. **The claim that makes two racing requests safe is `Store.putIfAbsent`**: the same key scan `put` already does, one answer added under the same shard lock, so of two callers racing for one key exactly one gets `.stored`. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
6. **`Cached(Pages, .{ .ttl_s })` is `Idempotent` with three things changed**: the key is the request line, GET and HEAD only, and the wait replaces the 409. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
7. **A second `Cached` request that finds the marker waits**, reading again every `poll_ms` (10 ms) for at most `max_wait_ms` (2,000 ms) or half of what `nilo.deadline(ms)` left the route, whichever is less; past that bound it runs the handler itself and overwrites the marker with its own answer. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
8. **`Cached`'s key is `.path_and_query` by default, or `.path`, or `.{ .header = "..." }`**; the query is taken as it arrived with nothing normalised, so `?a=1&b=2` and `?b=2&a=1` are two entries, and a header key refuses `Cookie`, `Authorization` and `Proxy-Authorization` by name. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
9. **A write verb may never carry `Cached`.** `app.post` and the other typed write verbs refuse it while compiling; `app.route(.POST, …)`, whose verb is a runtime value, refuses it at registration with `error.CachedWrite`. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
10. **The Space either argument keeps its answer in is a shape, not an import.** Anything with `getInto`, `putIfAbsent`, `put`/`putFor`, `del`, `max_bytes` and `Held` qualifies, checked while compiling with each missing one named; a `nilo_cache` bytes Space has all of them, and so could a caller's own type over Redis. A route may not ask for both `Idempotent` and `Cached` at once. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)

## Decisions

| ADR | What it decides |
|---|---|
| [155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md) | `Idempotent`: the key, the claim, the three refusals, the Space shape |
| [188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md) | `Cached`: reusing `Idempotent`'s machinery for a GET, keyed on the request line, with a wait instead of a 409 |

Beside this topic: the Store's `putIfAbsent` and the flat-value Space it claims a marker in belong to [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) (cache); why the Space is checked by shape rather than named as an import is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); why the kept answer is read into the request arena rather than a stack buffer is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory).

## Open

- **`Cache-Status` carries no `Age` or `ttl=`.** The Space does not say an entry's remaining life, so a replay cannot report one; on the record in [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)'s consequences as not built and not blocked.
