# Work that needs the services runs on their loop

**Status:** accepted
**Topic:** [lifecycle](../design/lifecycle.md)

## Context

`nilo.Run` is an arena and a lifetime, not a connection: the pool is opened by a service's `nilo_start`, which only `listen()` (or `app.start(io)`, below) calls, and there is no event loop before either. A query run any earlier used to answer `error.Disconnected`, naming neither the pool, nor `listen()`, nor anything a reader could act on, and that gap forced two shapes that both turned out unsound.

**The first was a phase before the server**, `app.start(threaded.io())` followed by `migrate(&db)` and then `listen()`. A team porting a 59-table schema wrote exactly that and got a server that took SIGINT and never exited, every worker thread parked on a lock. **A service keeps the `Io` it was started on.** `Db.nilo_start` dials the pool through it, `Jobs.nilo_start` copies it and `Jobs.serve` parks its workers on it, and `listen()` then builds a loop of its own, because the Engine owns one and nothing else can ([ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md)). The Postgres pool then blocks a mutex against an `Io` that is not its own tasks' to park, and a job worker started with `app.spawn` running on it is either a general protection fault, if the caller's `Io` has already been torn down, or the hang the team saw, if it has not. The plain shape, `listen()` alone, exits cleanly on SIGINT in the same repro. The bug was the two loops.

**The second was a single-file program that would not boot twice.** The guide's SQLite example is two lines, `db.checking(schema)` and `createMissing` registered as boot work: `Db.nilo_start` ran the schema check on a pool that had just opened, before the boot work had made a single table, so the check reported three tables missing and refused to start, and the *next* boot's own boot work never got a turn to fix it either. The same order let `db.expecting(version)` refuse a fresh database as behind before the migration beside it in the same boot work had run.

## Decision

```zig
fn migrate(run: *nilo.Run, db: *sql.Db) !void {
    try sql.migrate.applyPending(db, run, try manifest.chain(run.arena()));
}

try app.provide(&db);
try app.before(migrate, .{&db});
try app.listen(.{ .port = 8080 });
```

**A service is started once, on the loop that will drive it, and everything that touches a service before the first request runs there too, in a fixed order.**

### `listen()` after `app.start(io)` is refused

`serverStarting` sees `services_started == .start` and a registry with at least one started service, names which ones and what to write instead, and returns `error.StartedOnAnotherLoop`; `listen()` exits the process on it, the way it does for every other boot mistake it has already explained. `app.start(io)` stays, for the programs it is right for: a test driving the App through `testing.Client`, a script, a worker process on `jobs.serveOn(io)`. None of those calls `listen()`, and an App with no service that needs the loop may still call both, which is what `http/live.zig` has always done.

### The boot inside `listen()` is four phases, and the order is the only one available

1. **Every service's `nilo_start` runs**, on the server's own loop, and opens whatever it owns.
2. **The work registered with `app.before(f, args)` runs.** It needs the services from step 1.
3. **Every service's `nilo_check` runs.** It looks at what step 2 made, so it has to come after.
4. **The work registered with `spawn` starts.** It may use any of the above.

`app.start(io)` runs the first three of these on the caller's own `Io`; `listen()` runs all four on the server's. `services_started` and two booleans, `before_ran` and `checks_ran`, make each step idempotent, because a program that calls `start` for a test and then `listen()` reaches the same code twice.

### `app.before(f, args)` is where work that needs a service runs

```zig
pub fn before(self: *App, comptime func: anytype, args: BeforeArgs(func)) !void
```

`func` takes a `*nilo.Run` first, made here on the server's `Io` and thrown away when `func` returns, and then whatever `args` holds, the way a job's `run` takes its Run and then its services. If it fails, the server does not start: one line says so, the error comes back out of `listen()`, and the services already started are put down on the way ([ADR 121](./121-a-service-is-stopped-before-the-loop-is.md)). A migration that could not run is a database this binary must not serve. Three shapes are refused while compiling: a value rather than a function, a function whose first parameter is not `*nilo.Run`, and a function that answers with a value nobody is there to take.

### A service's `nilo_check` runs after `before`, not inside `nilo_start`

`Db`'s schema check and `db.expecting(version)` are what moved here. Run any earlier, `db.checking(schema)` sees a file `createMissing` has not yet touched and a migration sees a database it has not yet applied, both refusing a boot the very next step would have brought level; run here, they see the boot work's result. `Db.nilo_start` still dials one connection for a `Db` that has a check to run ([ADR 115](./115-a-boot-dials-the-connection-its-work-needs.md)), and says so in one line when it cannot; `nilo_check` reads that and skips the checks it was for rather than failing them. A `Db` no App holds calls `nilo_check(io)` itself after its own boot work, or `checkSchema` directly.

### `db.expecting(version)` is the version guard alone

The commonest use of the boot phase is one integer against one query, and it needs no `before` call at all: `db.expecting(manifest.head)` installs a guard `nilo_check` runs on the pool `nilo_start` already opened. A database behind is refused with the sentence naming which migrations are missing; a database ahead is allowed and logged, because that is the middle of an expand-and-contract deploy. A database that cannot be asked starts with a warning, the way the schema check does ([ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md)).

## What was rejected

**Stopping the services and starting them again on the Engine's loop.** It would work for a pool. A restart hides the mistake: the caller's `migrate(&db)` still ran on the wrong loop, and a worker started there has no way to be restarted on the right one. A refusal names the mistake at the moment it is made, which is what every other boot check here does.

**`.expect` as a field on `Db.Opts`.** It reads better than a call, and it costs 17,296 bytes in every program with a `Db` in it, measured with `zig build size-sql`: an option is read on every boot, so the ledger's DDL, the query that reads its head and the sentences round them link whether anybody set it or not. As a call it stores a function with the guard already inside it, and a program that never calls it links none of the migration module; the same two binaries measure that at 16 and 48 bytes.

**Making `before`'s work take an `Io` rather than a `Run`.** Every statement in `nilo_sql` takes a Scope, and a migration is statements; an `Io` would make its first line `var run: nilo.Run = .initIo(gpa, io)`, which is nilo's line to write, not the caller's.

**Letting `nilo.Run` hold an `Io` and start services.** It puts the App's registry inside Core's Scope type, which is upward, and `zig build layering` refuses it correctly. A `Run` is deliberately the smallest thing a query can take.

**Opening the pool lazily at the first query.** It needs an `Io` from somewhere at an arbitrary moment, moves a connect onto the request path, and makes "the database is unreachable" a runtime surprise rather than a startup one.

**`testing.Client.send` calling `app.checkServices()`.** It answers the same complaint this ADR does, for the missing-service case, and it lasted an afternoon: it refuses a test that drives an App to fetch `/openapi.json` and never touches the routes whose services are missing, which is a fair thing to write and not a mistake. What is built instead is narrower and has no false positive to have: a route that needs a service nobody registered logs the type and the pattern the moment it needs one, in `typed.zig`, beside the 500 it already answers. `app.checkServices()` stays public for a test that wants the whole gate.

**`db.checking(schema, .{ .after_before = true })`.** An option that is right for every program with boot work and wrong for none, since a check that runs before the tables exist is not a check anybody wants: there is nothing for the option to choose between.

**A paragraph in the migrations guide saying `db.checking` and `app.before` do not go together.** They do go together; that is the shape a single-file program has. A paragraph would have documented the bug rather than fixed it.

**Running `before` before `nilo_start`.** The work registered with `before` needs the pool.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0. Every phase above runs once, at boot, never on the request path |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size | One enum (`services_started`) in place of a bool, two more booleans (`before_ran`, `checks_ran`), one `ArrayList` that is empty for an App with no `before` call, and one optional function pointer per registered service for `nilo_check` (8 bytes, read once at boot). `db.expecting` is one optional field and a null test at boot, 16 bytes for a program that never calls it |
