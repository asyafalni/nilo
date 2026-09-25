# The engine

**The Engine is the bottom layer, the one that touches the operating system, and nilo never speaks to it directly: everything crosses the Bulkhead, a fixed contract that lets the Engine be swapped without a line of user code changing.** How to deploy on it is the guide ([`guide/deploying.md`](../guide/deploying.md), [`guide/background.md`](../guide/background.md)); every option and every concurrency primitive is the reference ([`reference/app.md`](../reference/app.md#listen-options), [`reference/app.md`](../reference/app.md#concurrency)). The contract is `http/bulkhead.zig`; the one file allowed to name zio is `http/engine/zio.zig`.

## How the pieces fit

```
  user code (App, Ctx, Service)
          │  never names zio
          ▼
  http/bulkhead.zig ── the contract: accept, read, write, Mutex, blocking,
          │             sleep, spawn, halfClose, Limits.arm/release
          ▼
  http/engine/zio.zig ── the only file that may name zio (ADR 001)
          │
          │  one acceptor fiber per executor, all parked on one listening
          │  socket, backlog 4,096 (ADR 198, ADR 200)
          ▼
  spawn deals the connection round-robin to an executor, which then
  keeps it start to finish (ADR 199)
          │
          ▼
  serve() reads the head, sheds past max_in_flight (ADR 159), runs the
  handler; a completion the loop still holds is cancelled before the
  frame returns, and a refused request is half-closed before it is
  closed (ADR 077, ADR 195)
```

## The rule in force

1. **Everything nilo needs from the Engine goes through the Bulkhead, and only the Engine names zio.** nilo stands on zio for io_uring, epoll, kqueue and IOCP on top of fibers rather than writing its own event loop. [ADR 001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md)
2. **A Service with mutable state locks with `nilo.Mutex`, which parks the fiber rather than the OS thread.** Handlers run concurrently across every executor thread nilo starts (`Options.threads`, one per core by default), and a `std.Thread.Mutex` would stall every connection sharing that thread. [ADR 010](../adr/010-shared-services-need-a-lock-from-the-bulkhead.md)
3. **A call that waits on the operating system goes through `nilo.blocking` or `nilo.sleep`, and a handler that skips them is caught at run time.** The watchdog measures the longest stretch a fiber ran without parking, one message at a time on a WebSocket, and logs a handler that held its thread past `block_warning_ms`. [ADR 013](../adr/013-handlers-must-not-block-the-thread.md)
4. **Work that is not a request runs as a fiber joined to the server's lifetime.** `nilo.spawn` answers `error.NoServer` with nothing listening; `app.spawn` registers before `listen()` and is started once it arms the accept loop's group. Neither may carry a `Str` or a fail function across the boundary. [ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md)
5. **A completion the loop still holds outlives the frame that submitted it, so the frame does not return until the loop has handed it back.** A WebSocket's `Wake` is torn down before its stack and before the socket closes. [ADR 077](../adr/077-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md)
6. **A file a handler writes goes through one Bulkhead operation, `Dir.writeFileAtomic`, and parks the fiber rather than the thread.** `Upload.saveTo` writes to a temporary name beside the destination and renames it into place, so a reader never sees a truncated file. [ADR 097](../adr/097-a-file-is-written-by-the-engine.md)
7. **`address` is read as a prefix, and `"unix:"` listens on a path instead of a port.** A leftover socket file is removed before binding only when it is both a socket and dead, and a connection that arrived over one is trusted the way a loopback proxy is, by construction. [ADR 103](../adr/103-a-path-is-an-address-to-listen-on.md)
8. **Past `max_in_flight` requests answered at once, the next one is a 503 at once, not a place in a queue.** Counted before the arena is touched or the router is asked, and the connection is closed rather than kept, because a shed client belongs on a different replica. [ADR 159](../adr/159-a-server-past-its-limit-says-so-at-once.md)
9. **An accept loop that runs out of descriptors waits, it does not stop the server.** `ProcessFdQuotaExceeded`, `SystemFdQuotaExceeded` and `SystemResources` back off from 5 ms to a one-second cap and retry; `listen()` warns at startup when `ulimit -n` is short of `max_connections`. [ADR 194](../adr/194-an-accept-loop-that-is-out-of-descriptors-waits.md)
10. **A refused request's connection is half-closed before it is closed, wherever its unread bytes could turn the close into a reset.** `shutdown(SHUT_WR)` sends the FIN and discards up to 64 KiB for up to a second, so a 431, 413 or shed 503 arrives before the socket goes rather than being thrown away with a reset. [ADR 195](../adr/195-a-refused-request-is-hung-up-on-with-a-fin.md)
11. **The listen backlog defaults to 4,096, sized for a burst rather than the steady load.** Past it a SYN is dropped, not refused, and the client's TCP retries it a second later with nothing in the server's log; the kernel's `somaxconn` still caps the request on an older ceiling. [ADR 198](../adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md)
12. **A connection is served, start to finish, by the executor it was dealt to.** `enable_task_migration = false` trades zio's steal-on-idle for a lower CPU cost per request below saturation, and it is what lets a handler's threadlocal state read before a wait still be valid after it. [ADR 199](../adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)
13. **Every executor accepts, on one shared listening socket.** One acceptor fiber per thread replaces the single accept loop that capped every server at the rate one fiber could round-trip through it; the accepted connection is still dealt round-robin exactly as before. [ADR 200](../adr/200-every-executor-accepts.md)
14. **A server can answer on more than one address, sharing one route table, one connection budget and one thread pool.** `Options.also` lists further listeners, each an address, a port and a certificate; the handler is never told which one carried a request, and `max_connections` counts sockets across all of them. [ADR 213](../adr/213-a-server-answers-on-more-than-one-address.md)
15. **A `nilo.Gate` serves its waiters in the order they came, and `enterWithin(ms)` bounds the wait.** A turn given back goes to the oldest waiter by name, never onto a count a newcomer could take first; a wait that runs out holds nothing and leaves the line. [ADR 222](../adr/222-a-gate-serves-its-waiters-in-the-order-they-came.md)

## Decisions

| ADR | What it decides |
|---|---|
| [001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md) | zio is the Engine, reached only through the Bulkhead |
| [010](../adr/010-shared-services-need-a-lock-from-the-bulkhead.md) | `nilo.Mutex`, a lock that parks the fiber, comes from the Bulkhead |
| [013](../adr/013-handlers-must-not-block-the-thread.md) | `nilo.blocking`/`nilo.sleep` as the way out, and the watchdog that catches a handler that skipped them |
| [028](../adr/028-a-spawned-fiber-belongs-to-the-server.md) | `nilo.spawn`/`app.spawn`, work that is not a request, joined to the server's lifetime |
| [077](../adr/077-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md) | A completion the loop holds must be handed back before its frame returns |
| [097](../adr/097-a-file-is-written-by-the-engine.md) | `Upload.saveTo`, one atomic Bulkhead write operation |
| [103](../adr/103-a-path-is-an-address-to-listen-on.md) | `"unix:"` as an address prefix, and when the stale socket file is removed |
| [159](../adr/159-a-server-past-its-limit-says-so-at-once.md) | `max_in_flight`, shedding a request rather than queueing it |
| [194](../adr/194-an-accept-loop-that-is-out-of-descriptors-waits.md) | The accept loop backs off on a descriptor shortage instead of stopping |
| [195](../adr/195-a-refused-request-is-hung-up-on-with-a-fin.md) | A refused request's connection is half-closed before it is closed |
| [198](../adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md) | The listen backlog defaults to 4,096 |
| [199](../adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md) | Task migration is off; a connection stays on the executor it was dealt to |
| [200](../adr/200-every-executor-accepts.md) | One acceptor fiber per executor, not one accept loop for the server |
| [213](../adr/213-a-server-answers-on-more-than-one-address.md) | `Options.also`, more than one listener sharing one server |
| [222](../adr/222-a-gate-serves-its-waiters-in-the-order-they-came.md) | `nilo.Gate` hands a freed turn to the oldest waiter, and `enterWithin` bounds the wait |

Beside this topic: [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles) is the budget every "what it costs" section above is measured against; [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory) is the per-idle-connection floor these decisions are careful not to move; [ADR 022](../adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md) and [ADR 210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md) (deadlines) cover the timeouts the accept loop and the watchdog sit beside; [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md) (lifecycle) is why the accept loop's group has to arm before a `ready` hook that might spawn something; [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md) and [ADR 027](../adr/027-tls-is-terminated-in-front.md) (tls) are what `also`'s `tls` field and a unix listener's trust both lean on.

## Open

- **An inherited listener cannot be taken over.** A supervisor handing a process an already-open descriptor, so a deploy with nothing in front stops dropping connections in flight, is not built; it needs a naming protocol (`LISTEN_FDS` or a bare number) and a caller who runs with no proxy. On record in [ADR 103](../adr/103-a-path-is-an-address-to-listen-on.md)'s "What is left" and [`docs/decided.md`](../decided.md).
- **A handler cannot tell which listener answered it.** No field says so on `Ctx`, and no route is scoped to one; the case that would justify it, an admin surface the public listener must not reach, has not been brought yet. In [`docs/roadmap.md`](../roadmap.md).
- **An extra listener that asked the kernel for port 0 cannot report which one it got.** `boundPort()` answers only for the first listener. In [`docs/roadmap.md`](../roadmap.md), waiting on a caller who binds a second listener to port 0 outside a test.
- **A connection is still handed from the accepting executor to another one by round-robin `spawn`.** Serving it on the executor that accepted it would remove the last per-connection cross-thread hop; zio has no way to say "here" yet. Tracked upstream as [zio#704](https://github.com/lalinsky/zio/issues/704) and in [`docs/roadmap.md`](../roadmap.md).
