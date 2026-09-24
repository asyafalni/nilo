# Memory per request and per connection

**Request data is a type that cannot leak by accident, and an idle connection has a floor that a handler can only add to, never lower.** How to use it is the guide ([`guide/deploying.md`](../guide/deploying.md), the tuning and "knowing whether it is working" sections); every name is the reference ([`reference/core.md#str`](../reference/core.md#str), [`reference/app.md`](../reference/app.md), the `arena_keep` row). The code is `core/str.zig` (`Str`, `Lifetime`, the walk that stamps a value), `core/scope.zig` (`arena()`, `str()`), and `http/serve.zig` (`waitForRequest`, the connection loop's own frame).

## How the pieces fit

```
request arrives ──► request arena (reset per request, arena_keep bytes retained)
                     every Str born here carries the connection's current Lifetime span

handler returns ──► Lifetime.end(): the span moves out of reach
                     a Str read afterwards either mismatches (Debug: trap fires) or is UB (Release)

connection idles ──► waitForRequest, the shallowest frame the connection has:
                      release the read/write buffers, and the stack if it comes back empty
                      floor: 4,669 bytes; 5,183 for a WebSocket, whose loop hands its own frame back
                      a handler's own stack use is added on top, and never released below its high-water mark
```

## The rule in force

1. **Request data is `Str`, never a bare `[]const u8`.** Its contents cannot be read out without asking, so there is no way to keep one "by accident"; `.keep()` is the one function that copies it into memory that outlives the request. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
2. **A Debug build stamps a `Lifetime` marker on every `Str`, walking structs, optionals, arrays, mutable slices and the active arm of a tagged union**; reading one after its request has ended stops hard, naming `.keep()`. A Release build carries none of this, at no cost. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
3. **Every `Lifetime` takes its own span from a process-wide counter**, so two connections never count through the same numbers; a stale `Str` from a finished connection either mismatches (the trap fires) or reads memory that is no longer defined, never the old bug of a silent right-looking answer. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
4. **A `Str` reached through something nilo's walk does not cover carries no marker.** A `const` slice or an untagged union is outside the trap's reach; the guarantee is a shape that makes the mistake visible, not a proof the compiler enforces. [ADR 003](../adr/003-request-arena-and-the-str-type.md)
5. **A suspended fiber holds its stack at its high-water mark.** zio commits stack pages as a fiber touches them and lowers nothing until it exits, so every byte of stack a handler ever touched is resident for the rest of the connection's life, whether or not the request that touched it is still running. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
6. **In this framework the arena is cheaper than the stack.** A big stack buffer (`var buf: [64 * 1024]u8`) is a per-connection cost that never comes back; `c.arena().alloc` is reset every request and capped at `arena_keep`. It is touched bytes that cost, not declared ones. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
7. **Where a fiber is suspended is what it costs, not whether its pages are released.** Releasing stack pages below the point a connection actually waits at buys nothing, because the next suspend faults them straight back in from the same depth; the fix was moving the wait itself to the connection loop's own, shallowest frame (`waitForRequest`). [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
8. **The cold half of a request is `noinline` on purpose**, so its format machinery and argument tuples sit in a frame that is dead once the connection parks, rather than in the frame that lives as long as the connection. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
9. **A WebSocket handler hands its loop back to the connection loop rather than keeping it**, through `Ctx.upgrade(loop, state)`; `state` travels in the connection's own frame up to `websocket.state_max = 128` bytes, and anything larger goes in the request arena instead. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
10. **The floor is 4,669 bytes per idle connection and 5,183 for an idle WebSocket, and both are a floor, not a total.** A handler adds every byte of stack it touches on top; a route that `@memset`s 64 KiB costs exactly 64 KiB more per idle connection, whether or not it holds the whole buffer at once. [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)
11. **A response larger than `arena_keep` costs a page fault per page, every request.** The arena hands the block back once it exceeds the kept size, and the kernel zeroes it again on the next request that needs it: 257 minor faults for a megabyte at the 16 KiB default. [ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)
12. **`arena_keep` is a `listen()` option, and its default does not move.** The memory it retains is per connection, so raising the default would multiply by every connection a server holds, not by the responses that need it; a caller who knows their response size sets it just past the largest one, and no higher. [ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)
13. **Filling a large buffer is the caller's cost, not nilo's to hide.** `@memset` being slower than glibc's `memset` is Zig's fact to fix, and nilo does not quietly substitute inline assembly for a builtin the caller wrote. [ADR 075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)

## Decisions

| ADR | What it decides |
|---|---|
| [003](../adr/003-request-arena-and-the-str-type.md) | Request data is a `Str`, wrapping the request arena; the Debug-only lifetime trap and its per-connection generation counter |
| [062](../adr/062-where-a-connection-waits-is-what-it-costs.md) | A suspended fiber's stack is resident at its high-water mark; the connection loop's own frame is where the idle wait has to happen for a release to mean anything |
| [075](../adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md) | `arena_keep`: a response bigger than it is a page fault per page, and why the default stays put |

Beside this topic: the four trade axes memory per idle connection is measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (topic principles, no page); why a header's name and value are `Str` rather than a plain slice, and when the request head is borrowed rather than copied, is covered from the request side in [`request-input.md`](./request-input.md); a `-Dtls` build's extra page per idle connection is added on top of this page's floor, in [`tls.md`](./tls.md); a WebSocket's own upgrade shape and state ceiling are covered from the protocol side in [`websocket.md`](./websocket.md); the Engine's fiber-per-connection model this floor is measured on is [`engine.md`](./engine.md) (ADR 001).

## Open

- **The next flat number to distrust is 4,669 (and 5,183).** ADR 062 says so itself: the previous flat figure, 8,767, stood unquestioned for a year after the code around it moved. `bench/ws_idle.py` and the control routes exist so it can be re-run rather than quoted.
- **A per-thread block cache under the arena**, which would close the remaining gap to a per-request allocator without asking the caller to set `arena_keep`, is a real design ADR 075 wrote down rather than built: it changes where request memory lives, which is ADR 003's territory.
