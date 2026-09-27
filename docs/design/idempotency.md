# Idempotency

**A request that was answered once gets the same answer again, byte for byte, whether the client is retrying a POST whose answer it never received or asking for the same page a hundred times a second.**

**Guide:** [Answering once](../guide/idempotency.md) · **Reference:** [`Idempotent(Replays, options)`](../reference/handlers.md#idempotentreplays-options), [`Cached(Pages, options)`](../reference/handlers.md#cachedpages-options)

The code is `http/idempotent.zig` and `http/cached.zig`, built on `Store.putIfAbsent`, `Space.getInto` and `Space.putFor` in `cache/`.

## Overview

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

Neither one ever keeps a failed answer: a failure is exactly what a retry is for, so the marker is released and the next attempt runs the handler again.

## Rules

1. **Both are route arguments, never middleware.** A typed handler returns its answer before anything is written, so nilo can render it, keep it and send it in that order without intercepting anything. A handler that writes through `*Ctx` and returns nothing has no answer to keep, so the route is rejected at registration instead of failing on the first replay. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
2. **`Idempotent(Replays, .{ .by })` uses the client's `Idempotency-Key` header as the key.** A retry with the same key gets exactly the first answer's status, headers and body; the handler does not run, and `Idempotent-Replayed: true` is added. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
3. **Three checks run on the key before the handler**: 400 if the key is missing or longer than 255 bytes, 409 if the key is still being answered, and 422 if the key is reused for a different request (method, path, query and body are all fingerprinted with it). [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
4. **`.by` scopes the key to its owner**, such as an account or a tenant read from the `*Ctx`. Two callers who happen to pick the same key must never see each other's stored answer. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
5. **`Store.putIfAbsent` is what makes two racing requests safe.** It does the same key scan `put` already does and adds one entry under the same shard lock, so of two callers racing for one key, exactly one gets `.stored`. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)
6. **`Cached(Pages, .{ .ttl_s })` is `Idempotent` with three changes**: the key is the request line, only GET and HEAD are allowed, and a request that finds the entry still being answered waits instead of getting a 409. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
7. **A second `Cached` request that finds the marker waits.** It checks again every `poll_ms` (10 ms) for at most `max_wait_ms` (2,000 ms) or half of the time `nilo.deadline(ms)` left the route, whichever is shorter. After that it runs the handler itself and replaces the marker with its own answer. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
8. **`Cached`'s key is `.path_and_query` by default, or `.path`, or `.{ .header = "..." }`.** The query is used exactly as it arrived, not normalised, so `?a=1&b=2` and `?b=2&a=1` are two entries. A header key rejects `Cookie`, `Authorization` and `Proxy-Authorization` by name. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
9. **A write method can never use `Cached`.** `app.post` and the other typed write methods reject it while compiling; `app.route(.POST, …)`, where the method is a run-time value, rejects it at registration with `error.CachedWrite`. [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)
10. **The Space that stores the answers is checked by its shape, not by importing a type.** Anything with `getInto`, `putIfAbsent`, `put`/`putFor`, `del`, `max_bytes` and `Held` works; this is checked while compiling and each missing member is named. A `nilo_cache` bytes Space has all of them, and so could your own type backed by Redis. A route cannot use both `Idempotent` and `Cached`. [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)

## Decisions

| ADR | What it decides |
|---|---|
| [155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md) | `Idempotent`: the key, claiming it, the three checks, the Space shape |
| [188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md) | `Cached`: `Idempotent`'s machinery reused for a GET, keyed on the request line, waiting instead of answering 409 |

Related topics: the Store's `putIfAbsent` and the flat-value Space the marker is stored in come from [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) (cache); why the Space is checked by shape instead of imported is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); why the stored answer is read into the request arena instead of a stack buffer is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory).

## Open questions

- **`Cache-Status` has no `Age` or `ttl=`.** The Space does not report how long an entry has left, so a replay cannot say. Recorded in [ADR 188](../adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)'s consequences as not built, and not blocked.
