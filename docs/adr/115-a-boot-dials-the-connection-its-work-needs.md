# A boot dials the connection its work needs

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

`sql/db.zig`'s header once claimed that a server boots with its database switched off: `connect_on_init` defaults to zero, so startup asks for a pool rather than for a connection, and somebody working on an endpoint that never touches Postgres does not need Postgres running. It was false in two different ways, found a cycle apart.

**First, the option was not read.** `pg.Pool.initUri` parses the URI into its own `Opts` and copies across `size` and `timeout`, but leaves `connect_on_init_count` at `null`, which `Pool.init` then reads as `orelse size`, the largest value available. So every pool nilo ever opened dialled itself in full at startup, whatever `connect_on_init` said, and a server whose database was not up refused to start. It was found by pointing a load generator at `bench/sql_server.zig` with the pool size turned up and getting `sorry, too many clients already` at a pool of 128 against a Postgres with `max_connections = 100`, while `connect_on_init` was 8: eight connections cannot exhaust a hundred, so `connect_on_init` was not the number being dialled. Nothing in the test suite had caught it, because the whole of what the option does is visible only when Postgres is *absent*, and the live tests skip without a database rather than assert something about not having one.

**Second, once the option was honoured, `db.checking` ran into it.** `db.checking(&.{ User, Order })` compares every Row against its table while the server starts, and the point of doing that at boot is that a Row disagreeing with its table stops a deploy. On the corrected defaults, `connect_on_init` sat at 0, which is what makes a server boot with its database switched off, so a pool that had dialled nothing had nothing for the check to borrow: `pool.acquire()` answered `Disconnected` on the first line of the check, every cold boot, on every program that wrote `.{}`. The server started, the deploy went green, and nothing was checked. This was not a race; it fired every time.

**Third, once the check itself was covered, `app.before` was not.** The check is not the only work that runs before the first request: [ADR 180](./180-work-that-needs-the-services-runs-on-their-loop.md) made `app.before` the place for a migration, a version guard or a key set, and it runs a moment after `listen()` starts the services, while the reconnector is still dialling the pool from its own task. A query engine whose tables are its own DDL, `.unchecked = true` and nothing else set, loading its models in `app.before`, hit `Disconnected` from `pool.acquire()` on every cold boot with Postgres up: the fix scoped to `self.check != null` had closed the shape for a checked `Db` and left it open for the hook.

## Decision

**`nilo_start` dials one connection whenever `connect_on_init` is 0, for whatever the boot is about to ask of it, and the pool it dials against is opened from an `Opts` this module builds field by field rather than one pg.zig assembles and half-drops.**

### The dial covers the check, the boot hook, or both

```zig
const dialing_for_check = self.opts.connect_on_init == 0;
```

Nothing else about the pool changes, and a caller who set the number themselves gets exactly what they set. `nilo_start` cannot see what the App will run next, a schema check, a version guard and a `before` hook all want the same one connection, so it is dialled for whatever they turn out to be, rather than gated on `self.check != null` the way the first version of this rule read.

The dial is still allowed to fail. [ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)'s promise is older than this decision and is not being traded away: a database that is merely down does not stop the server. A failed dial falls back to opening the pool the way `.{}` asked for, and says in one line which of the two happened, naming `app.before` beside the check since a hook that then fails with `Disconnected` stops the server:

```
warning: nilo could not dial the database for the work that runs at boot
(ConnectionRefused), so it is starting without the schema check, and
anything `app.before` asks of this database will find it down.
`connect_on_init` is 0, which is what asks for a server that starts
while its database is down.
```

A URL nilo cannot read does not get the retry: that failure will not become a different failure on a second attempt, and it already has a message written for it.

### `sql/postgres.zig` parses the URI and calls `pg.Pool.init` with a whole `Opts`

```zig
fn poolOpts(uri: std.Uri, arena: std.mem.Allocator, opts: Opts) !pg.Pool.Opts {
    var out = try lib.parseOpts(uri, arena); // pg.zig's own, not re-exported
    out.connect_on_init_count = opts.connect_on_init;
    // … every other field named once, so one pg.zig adds is a compile error
    return out;
}
```

The copy is tested against pg.zig's own defaults (username `postgres`, a ten-second auth timeout, `sslmode`, `tcp_user_timeout`) so a drift is a failing test rather than a connection to the wrong database. `poolOpts` returns one struct literal naming every field, which is what `initUri` gave up by building the value internally and letting three of its fields, including `connect_on_init_count`, be silently overwritten. `sql/postgres.zig` is the only file allowed to name pg.zig ([ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)), so the workaround has exactly one address.

### The reconnector is real, and it does not run everywhere

`Pool.init` hands `size - connect_on_init_count` connections to a `Reconnector`, which spawns an OS thread and retries every two seconds; fixing the dropped option turned this on for the first time. Under the Engine it works: a server with `connect_on_init = 0` boots with the database down, connects when it comes up, and served 134,967 requests a second at a pool of eight in the run that checked it. It does not shut down clean if the database never comes up before the process stops: the reconnector's thread parks on a mutex against the `Io` it was handed, and there was, before services could be stopped ahead of the loop, no way to ask it to stop first.

**Under `std.Io.Threaded` it panics outright**, and not only at shutdown: the reconnector's thread parks on `xsync.Mutex` against the `Io` it was handed, and `Threaded` cannot park a caller that is not one of its own tasks, reaching `unreachable` in `Mutex.zig`. zio parks across threads, which is why the server is fine there and the test harness is not. `sql/live.zig` dials its whole pool for that reason, with `Opts.connect_on_init` set to `size` wherever a `Db` is driven from a `std.Io.Threaded`. That is a sharp edge left rather than papered over: nilo cannot see which `Io` it was given, and building a second pool lifecycle to avoid a driver's mutex would be inventing a connection manager to work around it.

## What was rejected

**Refuse to start when a check or a boot hook is pending and the pool would have nothing to lend.** The strongest version of "the check always runs", and it reopens the exact failure the dropped-option fix closed: every service that follows the guide calls `db.checking`, so under this rule every one of them refuses to start while its database is restarting, and a rolling deploy during a database blip becomes an outage. The check is worth a connection. It is not worth that.

**Wait inside `acquire` while the pool is still filling**, rather than dialling one connection ahead of time. `PoolExhausted` from a pool that has never had a connection and one that lost every connection in an outage are the same state to pg.zig, and waiting on it would turn the outage's fail-fast into a wait of `timeout_ms` on every request, the parked fiber [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) counts against every connection.

**Have the App tell the `Db` there is a `before` hook**, a service hook for a phase the App already runs. It would make `sql/` learn about `http/`'s phases, which the layering forbids.

**Keep the dial scoped to `self.check != null` and document `connect_on_init = 1` as the workaround for anything that adds a `before` hook.** The check was correct where it was written and the option was correct where it was written, with the bug in neither file; a default that the documented example (`app.before(migrate, .{&db})`) fails on is not a default.

**A pool-wide ceiling in the startup packet**, so Postgres itself would bound a statement without a second connection. Belongs to a different problem (a statement's own deadline, [ADR 043](./043-a-deadline-needs-a-connection-you-hold.md)), not to whether a pool has anything to lend at boot.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:

| Axis | Cost |
|---|---|
| Allocations per request | None. The URI is parsed once, at `nilo_start`, into a scratch arena that goes back before `open` returns. |
| Memory per idle connection | None, and less at startup for anybody who left `connect_on_init` at its default: the pool no longer opens `size` backends before serving its first request, only the one the boot's own work needs. |
| Throughput and p99 | None on the request path. |
| Binary size | +0 stripped ReleaseFast on every example; the workaround is forty lines replacing a call into forty lines of pg.zig. |

## Consequences

- A rolling deploy no longer stampedes the database: `size` backends per new instance are no longer opened at boot whether traffic needs them or not, and a checked `Db`, an `unchecked` one with a `before` hook, and a plain `Db` with neither all now dial exactly the one connection their boot work needs.
- A `size` larger than the server's `max_connections` is a pool that fills as far as it can, not a server that will not start.
- `sql/live.zig` holds the unchecked case: a `Db` on the defaults answers a query the moment `nilo_start` returns.
- Three times now a behaviour has survived because its only evidence was an absence: the dropped option (no test can arrange a missing database), the check with nothing to check against (the deploy goes green), and the `before` hook (the fix for the first shape did not generalise to it). An option whose default disables a feature somewhere else is not visible from either place, and scoping its fix to the one caller that found it is how the next caller finds it again.
