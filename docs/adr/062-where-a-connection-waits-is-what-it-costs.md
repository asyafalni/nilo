# A handler's stack is per connection, and where it waits is what it costs

**Status:** accepted
**Topic:** [memory](../design/memory.md)

## Context

[ADR 017](./017-the-trade-budget-has-four-axes.md) makes memory per idle connection a hard axis, disclosed by every feature that spends it. What nobody had measured was what a **handler** adds on top of the framework's own floor, and the answer turned out to be the largest number in this cycle: a handler that does nothing but touch its own stack holds more per idle connection than one that runs a database query, because a suspended fiber does not give its stack back.

A first attempt to fix that (release the stack pages once a connection goes idle) changed nothing. `strace` showed the `madvise` firing on every idle connection, and `VmRSS` did not move by a byte. Finding out why is most of this ADR.

## Decision

### A suspended fiber holds its stack at its high-water mark

zio reserves 8 MiB of address space per fiber stack and commits pages as they are touched; nothing lowers the commit until the fiber exits. A connection blocked in `read` is a suspended fiber, so **every byte of stack a handler ever touches is resident for the rest of the connection's life, whether or not the request that touched it is still running.** Measured one for one: a WebSocket loop that `@memset`s 64 KiB (`/ws/deep` in `bench/ws_server.zig`) costs exactly 65,536 bytes more per idle socket than one that touches none, `5,183` against `70,719` ([`bench/result/http.md`](../../bench/result/http.md)).

**It is touched bytes, not declared ones.** `bench/s3_server.zig` has a route that pulls a megabyte into the request arena and one that declares `[64 << 10]u8` and streams the same megabyte through it, touching none of it beyond the buffer. Out to 10,000 connections: `/health` 4,674, `/o/1k` (1 KB, arena) 6,731, `/o/1m` (1 MB, arena) 8,782, `/stream/1m` (1 MB through 64 KiB of stack) 12,876. **The route that never holds the whole megabyte costs 47% more at rest than the one that does**, because the arena is reset at the end of the request and the stack is reset by nothing. Rebuilding the streaming route with an 8 KiB buffer instead of 64 KiB moves the number by one byte: the depth is the call path's, not the buffer's declared size.

**So in this framework the arena is cheaper than the stack:**

```zig
fn report(c: *nilo.Ctx) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;      // ✗ 64 KiB × every connection, forever
    …
}

fn report(c: *nilo.Ctx) ![]const u8 {
    const buf = try c.arena().alloc(u8, 64 * 1024);   // ✓ reset per request
    …
}
```

A big stack buffer is the idiomatic way to avoid an allocator, and here it is a **per-connection** cost that never comes back, while the arena is reset per request and capped at `arena_keep`. "The stack is free" is true per request and false per connection, and a server is measured per connection. The cost also tracks live connections rather than requests served: a route answered once and then left idle costs the same as one that has answered a thousand times, because what is resident is the high-water mark, not a running total.

### Releasing the pages is not the fix; where the wait happens is

The first attempt left the connection loop waiting exactly where it always had, four to six kilobytes down the call chain, and added a release of the pages below that point. The release ran, and cost nothing: **the connection then called `readHead` → `fillMore` and suspended again, faulting every released page back in from the same depth the release had just measured from.** The saving was real for about two microseconds.

> Where a fiber is suspended is what the connection costs, and it is not where the release runs.

So the wait moves up instead:

1. **The idle wait happens at the connection loop's own frame.** `waitForRequest` in `http/serve.zig` does the whole wait: peek for `idle_peek_ms`, release the read and write buffers and the stack if that comes back empty, then wait for the next request there, at the shallowest frame the connection ever has.
2. **The request's machinery is a frame of its own.** `App.serveRequest` is `noinline`; its `Ctx`, parsed head and route match are a callee's frame, below the sleeping one and dead by the time the connection parks.
3. **The cold half of a request costs nothing until it runs.** A format string builds its argument tuple and `Io.Writer` state in the frame of whatever it is inlined into, so `sendFailure`, `endAbandonedStream`, `warnFailedAfterAnswering`, `warnSocketFailed`, `Socket.deliver`, `handleControl` and `ping` are `noinline` for that reason alone.
4. **A WebSocket handler hands its loop back instead of keeping it**, which breaks [ADR 021](./021-a-websocket-is-a-handler-that-does-not-return.md)'s shape on purpose:

```zig
// before — the handler keeps the loop, suspended inside serveRequest
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    var socket = try c.upgrade();
    while (try socket.receive()) |m| try room.say(m.kind, m.data);
}

// after — the handler answers the handshake and says who reads the socket
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    return c.upgrade(chatLoop, room);
}

fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
    while (try socket.receive()) |m| try room.say(m.kind, m.data);
}
```

`Ctx.upgrade` answers the handshake, leaves a `Handover` in a slot the connection loop owns, and returns; the connection loop then runs the socket loop from its own frame, with the request unwound underneath it. `state` is what the handler knows and the loop needs, and it travels in the connection's frame with a ceiling of `websocket.state_max = 128` bytes; anything larger goes in the request arena, which stays alive for the loop's life, with a pointer carried across (`refusals/ws_state_too_big.zig`). 128 rather than the 32 it briefly was, because a `Str` is 40 bytes in Debug and 16 in `ReleaseFast` (the use-after-request marker compiles out), so a state that fit in Debug and not in release would be a mistake the optimize mode decides rather than nilo. **A `*Ctx` in the state is refused while compiling**, as the state itself or anywhere in its fields, optionals and arrays (`refusals/ws_state_is_ctx.zig`, `ws_state_holds_ctx.zig`): the Ctx lives in the frame that has unwound by the time the loop runs, so `c.upgrade(loop, c)` passed every other check and had the loop read the next request's memory. A pointer of the caller's is not walked, because what is behind it is the caller's to know.

### A blocker is a claim too, and it deserves the scrutiny a number gets

The stack release was first recorded as blocked on zio: no supported way to read the *running* fiber's `StackInfo`, filed as [zio#677](https://github.com/lalinsky/zio/issues/677). The call was public all along, one file over: `zio.coro.Coroutine.getCurrent()`, carrying `context.stack_info`. **A conclusion of "blocked on somebody else" is worth one more hour than it usually gets**, and this one had been written into an ADR, put on the roadmap and filed upstream before somebody read a different file in the same package.

Two later cases showed the rule aimed one step short of where it needed to: a blocker naming an upstream invites somebody to go and check it, but a blocker naming a design or a mechanism invites nothing, because there is visibly nothing to re-examine. `Upload.saveTo` was argued at length as blocked on a design, from a premise about nilo's own wrapper that nobody opened the manifest to check ([ADR 097](./097-a-file-is-written-by-the-engine.md)). The whole-body deadline was blocked on a union's arms, "zio's `Timeout` cannot express both", which is true and is a sentence about a type rather than about the slow client the feature exists to catch ([ADR 022](./022-a-deadline-belongs-to-an-operation-not-to-a-request.md)). An allowance's key was recorded as a choice between two named mechanisms, either arm true and the pair not exhaustive, and the answer was a third neither one named. So the rule generalizes past attribution, to grammar:

> **A requirement written as one mechanism reads as a blocker. Written as what it has to catch, it reads as a choice.**

An enumeration of alternatives is the easiest version of this to fall for, because weighing two named mechanisms looks like diligence, and the question of whether the pair is exhaustive never gets asked.

## What was rejected

**Guessing a floor for the stack release rather than reading `StackInfo`.** zio carves 64 stacks out of one slab mapping; an `madvise` that ran a page past `limit` would succeed and zero another connection's live stack, a corruption that is silent and lands in another module.

**Releasing the stack pages without moving the wait.** The first position, and it measured no change at all: 8,767 bytes before and after. The pages come back the instant the fiber suspends again at its old depth, which is deeper than the release ever reached.

**Shaving the last 761 bytes off `receive` and the typed wrapper instead of changing the upgrade API.** It reaches one page and leaves 3,573 bytes against a 3,584 threshold: one future field on `Ctx` and every WebSocket in every deployment silently costs 4 KB more, with no test that could catch it. A number that passes by eleven bytes is not an invariant.

**Running the socket loop on a second fiber and letting the connection fiber die.** The `Wake` an engine posts to lives in the connection fiber's frame ([ADR 028](./028-a-spawned-fiber-belongs-to-the-server.md)), and the read and write buffers are the accept loop's; all three would have to move into the engine's contract. It also costs a spawn per upgrade, and zio's `stackRecycle` uses `MADV_FREE`, which is lazy and leaves the pages in `VmRSS` regardless.

**Keeping both upgrade shapes.** Two ways to open a WebSocket where one silently costs 4,096 bytes a connection more is the same "the option is a lie" problem ADR 021 refused a `max_message` over.

**Reading the stack's cost as a leak, or as the arena's fault.** It scales with live connections, not with requests served, and sweeping `arena_keep` from 0 to 64 KiB changed nothing about it: the arena is reset per request regardless of size, and the resident bytes are the stack's, not the arena's.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes, before and after the connection-loop change, the two servers run alternately in one session so a machine that drifts drifts under both ([`bench/result/http.md`](../../bench/result/http.md) has every run):

| Axis | Before | After |
|---|---|---|
| Allocations per request | 1 | 1, unchanged: nothing here allocates |
| Memory per idle connection | 8,767 bytes | **4,669 bytes** |
| Memory per idle WebSocket | 9,290 bytes | **5,183 bytes** |
| Throughput, `GET /users/:id` | 1,420,424 req/s | 1,429,293, unchanged |
| p99, the same | 59–82µs | 58–98µs, unchanged |
| Binary size, stripped `ReleaseFast`, `examples/hello` | 886,680 B | **887,920 B**, +1,240 |

**Both numbers stand as the floor, and both are still that: a floor, not a total.** A handler adds every byte of stack it touches on top of them, as measured above; `/ws/deep` holds 70,719. The +1,240 bytes are the cold paths becoming real functions instead of inlined copies, plus one trampoline per distinct socket loop in the program; `examples/hello` has no WebSocket route and still pays it, which is the disclosure [ADR 017](./017-the-trade-budget-has-four-axes.md) asks for rather than a defence of it.

An open WebSocket no longer counts as a request in flight, because the loop now runs from the connection loop's own frame rather than inside `serveRequest`, which brings the shutdown counter into line with its own stated rule: requests, not connections, because a connection parked in a read is holding no work.

**The next flat number to distrust is this one.** 8,767 was correct, published, repeated in six files, and described a shape that had never been re-measured after the code around it moved; this one has `bench/ws_idle.py` behind it and five control routes beside it, and it should still be re-run rather than quoted.
