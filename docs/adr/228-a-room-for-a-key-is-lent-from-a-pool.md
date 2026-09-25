# A Room for a key is lent from a pool

**Status:** accepted
**Topic:** [websocket](../design/websocket.md)
**Extends:** [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md), whose Rooms are the ones an application makes before it starts.

## Context

A Room is a service the application builds, sizes and provides ([ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md)). That fits a lobby and a feed, rooms whose number is known when the program starts. It does not fit the commonest thing a program asks of a hub: **reach one user.** Every tab and device a user has open wants to hear a notification meant for them, and nothing about them is known until they connect. Since [ADR 035](./035-a-broadcast-rings-a-bell-it-does-not-write.md)'s rooms chain a socket can sit in any number of rooms, so a room per user was possible, but it had to be made, found by id, and freed by hand, with nothing to stop a message reaching a room after it had been handed to somebody else.

Other frameworks answer with a map from a string to a channel made on first use. The one read beside this change never removes an entry, so a server that has seen a million users holds a million channels.

## Decision

**`nilo.Rooms` is a pool of Rooms made up front, lent to a key the application makes up for as long as somebody is under it.**

```zig
var rooms = try nilo.Rooms.initWith(gpa, .{ .rooms = 4096, .seats = 8 });
try app.provide(&rooms);

try rooms.join("user:42", socket);          // every tab the user has open
defer rooms.leave("user:42", socket);
try rooms.json("user:42", .{ .unread = 3 }); // from anywhere
return c.eventsFrom(.{ lobby, rooms.named("user:42") }, .{});
```

1. **Sized up front, like a Room's seats.** `init` makes `rooms` Rooms of `seats` seats each and nothing is allocated for a key after that. The pool's cost is a number the application wrote down, not a function of how many users came.
2. **A key has a Room only while somebody is under it.** The first `join` lends one; the last seat given up, by `leave` or by nilo giving up what a loop left behind, gives it back. When every Room is lent, a new key is `error.NoRoomFree`, and in `eventsFrom` a 503 naming `rooms` as the number to raise.
3. **A key nobody is under is nothing.** `say`, `print`, `json` and `event` find no Room and allocate nothing, which is what a notification to a user who is not connected should cost.
4. **A Room is never lent under a new key while anything could still say into it under the old one.** Every call that reaches a Room by key pins it under the pool's lock and unpins it after; a Room goes back only when it has no seat taken and no pin. Without the pin, a Room emptied during a `say` could be lent to the next user and receive the rest of the previous user's message.
5. **A key is at most 64 bytes** (`nilo.rooms.max_key`), copied into the Room it names, and a longer one is `error.KeyTooLong` rather than a key cut short into somebody else's.
6. **One Room per key, with the same seats, backlog and policy as every other in the pool.** A key for a crowd is a Room of its own, built and provided the way ADR 035's are.
7. **A Room that keeps history keeps its key when it empties** ([ADR 229](./229-a-room-that-keeps-history-catches-a-returning-stream-up.md)). It goes on a quiet list, and is lent to a new key only when no Room was never lent, oldest quiet first, forgetting what it kept before anybody else can read it.

## How the pieces stay correct

**Lock order is pool, then room.** Lending a Room back forgets its history under the Room's roster lock while holding the pool's. The other direction never happens: a Room tells the pool a seat was given up through `vacated` after its own roster lock is released, so the two locks are never taken in the opposite order.

**A seat is only taken by somebody holding a pin**, so a Room read as empty with no pins, under the pool's lock, stays empty until that lock is let go. That is what lets the pool read `count` without taking the Room's lock.

**`leave` takes no lock of the pool's.** A Room somebody is sitting in is never lent under another key, so the socket's own chain of seats says which Room the key is, and giving up a seat is the Room's ordinary `leave`.

**The key table never grows and never degrades.** It is sized for every Room at `init`. A removal leaves a tombstone a lookup for a missing key probes past, so after half the pool's worth of removals the table is rebuilt in place. A pool that turns users over all day would otherwise end up probing the whole table to learn a user is not here, on the path every notification takes.

**The Room points back through a pointer.** `Room.vacated` is null on a Room the application made and set on the pool's, so `stand`, which every program with a WebSocket links, does not link the pool.

## What was rejected

- **A Room made on first `join` and freed when it empties.** Allocations on the request path, three per new key, and a memory figure nobody can state, which is ADR 035's reason for sizing seats up front applied to rooms. The map that never frees, above, is where this goes when the free is forgotten.
- **Rooms the application makes, registered under a key** (`rooms.put("user:42", &room)`). The application would be back to deciding when a user's Room is made and freed, which is the whole of the job.
- **The pool's lock held for the whole of a `say`.** Correct, and it puts every message to every user behind one lock. The pin holds the lock for a lookup and a count.
- **A user API beside the Room API** (`joinUser`, `notifyUser`). A user is a key the application formats, and a second vocabulary for it would be a second set of rules for the same thing.
- **A key formatted by nilo** (`rooms.join(.{ "user:{d}", .{id} }, socket)`). One `bufPrint` into a stack buffer does the same, and the key is the application's to spell.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. `join` and `eventsFrom` lend a Room made at `init`; a key with no Room is a lookup. |
| Memory per idle connection | Unchanged. An event stream in a Room and under a key of its own measures **5,184 bytes a connection** from 5,000 to 10,000 connections, the same as one in a Room alone, interleaved over two rounds ([the run](../../bench/result/http.md#a-key-costs-a-connection-nothing-and-a-room-in-the-pool-about-445-bytes)). The first few hundred keys pay about 0.6 MB once, the key table's pages being written for the first time. |
| Memory, up front | About **445 bytes a Room of one seat**, measured as the baseline of a 20,000-Room pool, the allocations included; a seat more is ADR 035's seat. A pool of 4,096 Rooms of 8 seats is a few megabytes, stated before a user connects. |
| Throughput and p99 | Not measured. A call by key adds a hash lookup and a lock and unlock of the pool's mutex to what the same call on a Room costs. |
| Binary size | **+80 B** on `hello` and on `rest`, measured together with [ADR 229](./229-a-room-that-keeps-history-catches-a-returning-stream-up.md): the `vacated` check in `stand`. The pool itself is linked only by a program that names `nilo.Rooms`. |

## What it breaks

Nothing. `nilo.Room` is unchanged for a program that does not name the pool, and the one field it gained is null on a Room the application makes.
