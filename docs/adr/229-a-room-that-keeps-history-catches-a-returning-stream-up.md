# A Room that keeps history catches a returning stream up

**Status:** accepted
**Topic:** [responses](../design/responses.md)
**Extends:** [ADR 227](./227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md), whose stream starts from what is said after it sits down, and [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md), whose Room forgets a post once every seat has taken it.

## Context

An `EventSource` that loses its connection reconnects by itself and sends `Last-Event-ID`, the `id` of the last event it read. The protocol exists so a server can send what the client missed. Since [ADR 227](./227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md) a feed is handed to its connection the moment its handler returns, and a Room drops a post as soon as the seats that were there have taken it, so whatever was said during the reconnect was gone. A handler could not fill the gap itself: it would have to keep its own copy of every post and write it before the seat was taken, and anything said between the two would be missed or written twice.

## Decision

**`Room.Options.history` keeps a Room's latest text posts, and `c.eventsFrom` writes the ones after the client's `Last-Event-ID` before anything new.**

```zig
var prices = try nilo.Room.initWith(gpa, .{ .history = 256 });

fn ticker(c: *nilo.Ctx, prices: *nilo.Room) !void {
    return c.eventsFrom(prices, .{});   // Last-Event-ID is read here
}
```

1. **Bounded twice, by count and by bytes.** `history` posts, and `history_bytes` between them, 64 KiB by default, each post counted whole. The oldest goes first when either would be passed, and a post bigger than `history_bytes` on its own is not kept. What a Room with history costs is `history_bytes`, and not a count times the biggest message anybody might say.
2. **Kept whether or not anybody is in the Room.** A client that is away is the one the history is for, so a `say` into an empty Room that keeps history composes the post instead of returning.
3. **Text posts only.** Only an event stream reads them back, and it cannot carry a binary post ([ADR 227](./227-an-event-stream-fed-by-rooms-waits-where-a-connection-waits.md)).
4. **Found by the application's id.** `room.event(.{ .id = … })` gives a post its id; the newest kept post with the client's id is the one the replay starts after. An id the Room no longer has, or never had, replays nothing.
5. **Seated and copied under one lock.** The seat is taken and the kept posts after the id are referenced while the Room's roster lock is held. Seated first, a post landing between the two would be in the seat and the copy and written twice; copied first, it would be in neither.
6. **Written from the handler's frame, before it returns.** The replay goes out after the head and `retry:` and before the handover, each post released as it is written and every one released if the writing fails.
7. **A stream in several Rooms is caught up by the one whose id it reports.** The browser keeps one id, the last it read, from whichever Room spoke last; the others have nothing to go on and replay nothing.
8. **A pool's Room keeps its key while it keeps history** ([ADR 228](./228-a-room-for-a-key-is-lent-from-a-pool.md)), so a user who is offline still has somewhere for a notification to wait.

## Why nothing is replayed for an id that is not found

The id could have been forgotten, pushed out by the count or the bytes, and then everything kept is newer than what the client read. Or it could belong to another Room the stream sits in, and then everything kept may already have been read. The Room cannot tell which, and replaying everything in the second case sends a client events twice, which is harder to notice than a gap. An application that must know about a gap can see it: its ids are its own, and the first id after the replay says how far it jumped.

## Why the ids are the application's

A Room could number its posts itself. Two Rooms would then both have a post 17, and a stream in both could not say which it read. It would also be a second id beside the one the application already puts on an event when it has one, a price's sequence number or a message's key. The cost of the application's ids is a rule: **a Room that keeps history wants an id on every post.** A `say` carries none, and a browser that read it still reports the id before it, so it would be written again on the next reconnect. The reference and the guide say so where `history` is described.

## What was rejected

- **Replaying through the seat's ring.** The ring holds `backlog` posts, four by default, so a client away for five would lose one to the drop policy before it read any.
- **Replaying everything kept when the id is not found**, above: events twice for a stream in several Rooms.
- **A Room's own sequence as the id**, above: ids that collide across Rooms and duplicate the application's.
- **A count alone, with a `max_post` on everything said into a Room.** It would refuse a message to WebSockets that never read history, and a count times the largest post is still a figure somebody has to multiply.
- **History for a WebSocket.** A socket sends no `Last-Event-ID`, and what it missed is whatever protocol the application runs over it.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None for a first connection and none for a Room that keeps nothing. A request carrying `Last-Event-ID` to a Room that keeps history takes one slice of `history` pointers from the request arena, per such Room. |
| Memory per idle connection | Unchanged: history is the Room's, not the connection's. |
| Memory, per Room | `history` pointers, eight bytes each, made with the Room, and up to `history_bytes` of posts held. Nothing for a Room that keeps none. |
| Throughput and p99 | Not measured. A post into a Room that keeps history takes one more reference and, past a bound, releases the oldest, under the roster lock the broadcast already holds. |
| Binary size | **+80 B** on `hello` and on `rest`, measured together with [ADR 228](./228-a-room-for-a-key-is-lent-from-a-pool.md). **+1,056 B** on `chat`, the one example with a Room, which links the history's bookkeeping into every broadcast. |

## What it breaks

Nothing. A Room made without `history` keeps nothing and behaves as before, and a request without `Last-Event-ID` replays nothing.
