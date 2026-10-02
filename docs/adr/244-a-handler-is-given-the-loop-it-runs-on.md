# A handler is given the loop it runs on

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Applies:** [ADR 015](./015-resolved-values-are-declared-by-their-type.md) (a value is declared by its type), [ADR 028](./028-a-spawned-fiber-belongs-to-the-server.md) (a spawned fiber belongs to the server), [ADR 013](./013-handlers-must-not-block-the-thread.md) (a wait parks the fiber), [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes)

## Context

Porting photon's write-ahead log found a handler that could not reach the server's `std.Io`. The log is one writer fiber with group commit: a handler puts an append on a `std.Io.Queue(*Append)` and waits on a `std.Io.Event`, and the writer, started with `app.spawn`, takes a batch, writes it once and sets each event. `Queue.putOne` and `Event.wait` both take an `Io`, and a handler had none. The spike kept `run.loop()` from an `app.before` in a global, which works and is documented nowhere; `testing.Wired` cannot run `app.before` or `app.spawn`, so nothing that needed the `Io` could be driven in memory.

Nothing on the record refuses this. [`docs/decided.md`](../decided.md) says nothing about an `Io` in a handler, and ADR 028 gives a *spawned* fiber the `Run` and its `loop()`; it never needed to say what a handler gets, because until a handler had something to put on a queue it had no use for one.

## Decision

**A handler asks for the server's `std.Io` the way it asks for the request arena: by writing it.**

```zig
fn append(io: std.Io, wal: *Wal, body: nilo.Body) !Committed { … }
fn append(c: *nilo.Ctx, wal: *Wal) !Committed { … c.io() … }
```

- `io: std.Io` in a handler's or a resolver's argument list is a role of its own beside `std.mem.Allocator` ([ADR 015](./015-resolved-values-are-declared-by-their-type.md)). It is not a service: nothing is `provide`d, and `listen()` has nothing to check.
- `c.io()` is the same value for code that holds the `*Ctx` (a middleware, a helper), and `nilo.io()` for a fiber `app.spawn` started, which has neither.
- **It is the loop the connections run on**, the one `app.spawn`'s fibers run on, so a queue a handler fills is drained by a fiber the server owns and cancels at shutdown ([ADR 028](./028-a-spawned-fiber-belongs-to-the-server.md)).
- **Nothing is stored per connection or per request.** The engine keeps one atomic pointer to the running Runtime, set when the server's group is set (`background`'s lifetime and its one-server-per-process limit), and the `Io` is built from it on the way out. It is also readable from a pool thread, which a lookup of the current executor is not: a handler handed to `nilo.blocking` has no executor.
- **With no server running, it is a process-wide `std.Io.Threaded`**, started on the first ask and kept. `testing.Client` and `testing.Wired` have no server, so a handler written against `io` runs in memory, and `Wired.io()` hands a test the same value to start the writer on with `io.concurrent`. Threads are real, so a writer and a handler waiting on it make progress.
- **A test of what only a running server does starts one: `testing.Live`.** `Live.start(gpa, &app, options)` runs `app.tryListen` as an `io.concurrent` task (ADR 056) of a `std.Io.Threaded` it owns, on port 0 with `stop_on_signal` off, and returns once `app.boundPort()` answers; `live.port` is the port, `live.stop()` shuts the server down and waits for it, and every wait is bounded, with a failed listen returned as its own error. It lives in `nilo.testing`, so a program that does not name it compiles none of it. A live test (`http/live.zig`) runs a spawned writer on the server's loop, checks it holds the same `userdata` the route's `io` does, and sees the writer's idle deadline fire with no request in flight.
- **The detector is not told, and does not need to be.** A wait on an `Io` nilo did not see parks the fiber, and the watchdog notices that the run loop turned over since the stretch began, so a wait past `block_warning_ms` is not reported as a handler holding its thread ([ADR 013](./013-handlers-must-not-block-the-thread.md)). A spin after the wait still is.

The pattern, with its shutdown story, is in the [background guide](../guide/background.md#a-queue-a-handler-fills-and-a-fiber-empties).

## What was rejected

- **A field on `Ctx`.** `Ctx` is on the connection fiber's stack and a field is bytes held for every idle connection (ADR 062, 17). The engine already knows the loop; carrying it twice is a cost with no reader on most routes.
- **Only `app.before` plus a global**, the spike's shape. It works for exactly the program that knows to do it, and the next test of it stubs the global by hand.
- **A free function as the way for a handler.** A handler's argument list is where what it needs is read ([ADR 015](./015-resolved-values-are-declared-by-their-type.md)), and a call in the body hides that a route needs a server. `nilo.io()` exists, but for a fiber `app.spawn` started, which has no argument list to put it in: `app.spawn` takes the function's own arguments, and the writer needs the same `Io` the handlers hold. Called with no server running it answers the process-wide `Threaded`, so it is documented as not to be kept across `listen()`.
- **A `Wired` that runs `app.spawn`.** It would need the server it exists to avoid. A test starts its own writer on `wired.io()`, which is the line a reader wants to see.
- **`nilo.Queue` and `nilo.Event` wrappers that tell the detector.** They would be a second queue API over `std.Io.Queue` to tell the detector something the run loop's turn already says.

## Consequences

- The handler is still a function: `append(io, &wal)` in a test is a call with a `Threaded` `Io`, and `Wired` runs it with no change.
- The request path allocates nothing new, a connection holds nothing new, and the read is one atomic load per ask (measured: the allocation-budget test is unchanged, an idle connection is the same bytes, and the stripped binary of a server that never asks is the same size).
- A second server in one process would share `background`'s limit and answer the first's loop. Nothing does that; the line to move is the same one.
