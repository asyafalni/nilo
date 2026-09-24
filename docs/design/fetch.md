# Outbound calls

**`nilo_fetch` is a Fitting: it borrows the event loop and owns no destination, putting the policy an outbound call needs in front of `std.http.Client` and none of the state a Service holds.**
How to write one is the guide ([`guide/fetch.md`](../guide/fetch.md)); every call and its signature is the reference ([`reference/fetch.md`](../reference/fetch.md)).
The code is `fetch/fetch.zig` (`Client`, `Exchange`, `withQuery`), `fetch/target.zig` (`Target`), `fetch/testing.zig` (`Canned`) and `fetch/deadline.zig`.

## How the pieces fit

```
   Fitting layer: borrows Io, owns no destination, no credentials (ADR 061)
                                │
        fetch.Client: one connection pool, one cert bundle, per program
                                │
        fetch.Target(name, opts): a type per outbound service
        (max_in_flight, timeout_ms, ready path; base URL and
        credential given to open(), not compiled in)
                                │
              ┌─────────────────┴──────────────────┐
              ▼                                     ▼
   client.get/post/postJson/withQuery       Exchange.begin / take / end
   one Response, body read whole            headers read first, body on demand
              │                                     │
   X-Request-Id forwarded (158)              discard() skips the drain (184)
   redirects: .refuse / .follow / .expose (183)      head.keep(c) survives it (187)
   the body decides the framing, not the method (174)
   a bodiless answer ends at its own head (176)
```

## The rule in force

1. **A Fitting borrows the loop and owns no destination.** `nilo_fetch` imports `nilo_core` and nothing above it, is handed a Scope on every call rather than holding a `Ctx`, and its tests run under `std.Io.Threaded` with no Engine, the same entry condition a Tool module's plain `zig test` is. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
2. **A destination is a type.** `fetch.Target(name, .{ .max_in_flight, .timeout_ms, .stall_ms, .max_body, .ready })` returns a type: two services are two types, a handler names the one it wants, and the base URL and the credential are given to `open`, the deployment's rather than the type's. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
3. **The ordinary call sends JSON and a query, never a bare string as a body.** `postJson`, `putJson`, `patchJson` and `sendJson` write the value with `std.json.Stringify.valueAlloc`; a `[]const u8` handed to one does not compile, because it would go out as a quoted JSON string. `withQuery(c, base, .{ … })` builds the query string in one sized arena allocation. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
4. **A target's gate is taken before the client's and given back after it.** `max_in_flight` on the type is a semaphore of that service's own, so a slow third party queues at its own gate rather than eating the permits every other target shares. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
5. **A request id goes out with the call.** `X-Request-Id` carries whichever id the request already has, on every `get`, `post`, `put`, `delete` and `send` made under a `*Ctx`; a `Run`, with no request to name, sends nothing, because a Scope is asked for `requestId` only if it declares one. `Settings.forward_request_id = false` turns it off. [ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)
6. **The body decides the framing, not the method.** A body handed to a method std frames none for, a DELETE, goes out anyway, the head written by std and the length patched in after; no body on a method std frames one for goes out as `content-length: 0`. [ADR 174](../adr/174-the-body-decides-not-the-method.md)
7. **An answer with no body ends at its head.** A HEAD's answer, a 1xx, a 204 and a 304 are marked read to their end the moment the head is in, whatever `content-length` or `transfer-encoding` say, so a connection with a length-less 204 goes back to the pool instead of hanging until the far end reaps it. [ADR 176](../adr/176-an-answer-with-no-body-ends-at-its-head.md)
8. **A header std owns goes out once.** A name in `Begin.headers` that std has its own slot for (`host`, `authorization`, `user-agent`, `content-type`, `connection`, `accept-encoding`) tells std to leave its slot out, so the caller's line goes out verbatim instead of twice; the explicit fields on `Begin` are still an override when both are given. [ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)
9. **A redirect is a decision with a name.** `Begin.redirects` defaults to `.refuse`, a 3xx with a `Location` answering `error.RedirectRefused`; `.follow = &buf` walks it, three deep, and leaves `head.redirected` saying where it ended; `.expose` hands the 3xx over as itself, for a signed request that must not be redirected silently. [ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)
10. **A caller that knows says `discard`.** `ex.discard()` marks the connection closing without weighing `max_drain` against the announced length, for the caller who already knows it will not read this body; the permit still goes back. [ADR 184](../adr/184-a-caller-that-knows-says-discard.md)
11. **The transfer buffer serves nothing on the direct path, and is documented as such.** `Begin.transfer_buffer` only matters to a caller reading buffered off `ex.reader`; `take`, `readInto`, `pipe` and `stream` never fill it and one socket read is the same size with or without it. `Settings.read_buffer_size` (default 8 KiB, std's own) is the number that actually sizes a read. [ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)
12. **A head outlives its body only if it is kept.** `head.keep(c)` copies the header block, the content type and a followed redirect's URL into the Scope, once, on the calls that ask; a whole-body call (`get`, `postJson`, …) makes the same copy automatically before the body is read over it, so `res.header("etag")` and `res.header("retry-after")` answer after the body is gone. [ADR 187](../adr/187-a-head-that-outlives-its-body.md)

## Decisions

| ADR | What it decides |
|---|---|
| [061](../adr/061-a-fitting-borrows-the-loop.md) | The Fitting layer, `Client`, `Target`, `withQuery`, the JSON calls |
| [158](../adr/158-a-request-id-goes-out-with-the-call.md) | `X-Request-Id` forwarded on every call under a `*Ctx` |
| [174](../adr/174-the-body-decides-not-the-method.md) | A body's presence, not the method, decides how a request is framed |
| [176](../adr/176-an-answer-with-no-body-ends-at-its-head.md) | The four RFC 9112 cases that end at the header block regardless of length |
| [182](../adr/182-a-header-std-owns-goes-out-once.md) | A caller's own line for a header std has a slot for replaces the slot |
| [183](../adr/183-a-redirect-is-a-decision-with-a-name.md) | `.refuse` / `.follow` / `.expose`, and `head.redirected` |
| [184](../adr/184-a-caller-that-knows-says-discard.md) | `Exchange.discard()` for a body the caller already knows it will not read |
| [186](../adr/186-the-transfer-buffer-serves-nothing-here.md) | What `transfer_buffer` and `read_buffer_size` each actually do |
| [187](../adr/187-a-head-that-outlives-its-body.md) | `head.keep(c)` and `Response.headers`, copied once past the body |

Beside this topic: the layering rule that makes a Fitting a layer of its own, never a sibling of a Service, is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) and [ADR 057](../adr/057-percent-is-needed-by-two-layers.md) (layering); what an outbound call costs the connection that is holding it open is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); arming a deadline on a call is [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md) (deadlines); `Target` reads as a type the same way a Bucket does in [ADR 059](../adr/059-a-bucket-is-a-type-and-a-key-is-not.md) (s3); a deployment's base URL and credential arriving at `open` rather than compiled in follows the setting/deployment split of [ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md) (config); `nilo_ready`'s started-is-ready default is [ADR 154](../adr/154-a-health-route-asks-the-services.md) (lifecycle).

## Open

- **An `Exchange` begun on a `Target`.** Wanted and not built: a streamed call through a target would need its standing headers and its gate to reach `Exchange.begin`, which today takes a client and a URL directly. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md) leaves it waiting on a caller who streams from a service with standing headers, and names it on [the roadmap](../roadmap.md).
- **Whether a wider `read_buffer_size` cuts syscalls for a caller reading many large bodies at once.** The field exists now for exactly this measurement; [ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md) says it could not be made before the field did.
