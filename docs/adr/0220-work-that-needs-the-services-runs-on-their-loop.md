# 0220 — work that needs the services runs on their loop

**Status:** accepted
**Amends:** [ADR 0079](./0079-there-is-a-phase-before-the-server.md)

## Context

ADR 0079 built the phase between the pool and the server as a call of the
caller's own:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();

try app.start(threaded.io());        // pools open on the caller's Io
try migrate(&db);
try app.listen(.{ .port = 8080 });   // does not start them twice
```

`guide/sql/migrations.md` recommended it, `guide/background.md` drew it, and
the `sql.migrate.expect` example was written around it. A team porting a
59-table schema followed all three and got a server that took SIGINT and never
exited, with every worker thread parked on a lock.

The repository reproduced it in an afternoon and the shape is unsound, not
misconfigured. **A service keeps the `Io` it was started on.** `Db.nilo_start`
dials the pool through it; `Jobs.nilo_start` copies it and `Jobs.serve` parks
its workers on it. `listen()` then builds a loop of its own, because the Engine
owns one and nothing else can own it (ADR 0002), and hands every fiber that
loop. So after `app.start(threaded.io())`:

- The Postgres pool blocks on a mutex against `std.Io.Threaded` from a fiber
  that belongs to zio. `Threaded` cannot park a caller that is not one of its
  own tasks, which is the constraint `sql/live.zig` already writes down for
  the test harness; here it is a server.
- A job worker started with `app.spawn(Jobs.serve, …)` runs `group.concurrent`
  on the `Threaded` it was handed. In the repro that is a general protection
  fault at boot, because `defer threaded.deinit()` had already run when
  `listen()` returned control to nothing; without the `defer`, it is the hang
  the team saw, because nothing on the Engine's loop can cancel a wait on
  another.

The plain shape, `listen()` alone, exits cleanly on SIGINT in the same repro.
The bug is the two loops.

## Decision

**A service is started once, on the loop that will drive it, and work that
needs a service before the first request runs there too.**

Three things change, and the first is a refusal.

1. **`listen()` after `app.start(io)` is refused when a service kept the
   `Io`.** `serverStarting` sees `services_started == .start` and a registry
   with at least one `nilo_start`, says in one line which services took the
   wrong loop and what to write instead, and returns
   `error.StartedOnAnotherLoop`. `listen()` exits the process on it, the way
   it does for every other boot mistake it has already explained.

   `app.start(io)` stays, for the programs it was right for: a test driving
   the App through `testing.Client`, a script, a worker process on
   `jobs.serveOn(io)`. None of those calls `listen()`. An App with no service
   that needs the loop may still do both, which is what `http/live.zig` has
   always driven.

2. **`app.before(f, args)` is the phase, and it is inside `listen()`.**

   ```zig
   fn migrate(run: *nilo.Run, db: *sql.Db) !void {
       try sql.migrate.applyPending(db, run, try manifest.chain(run.arena()));
   }

   try app.provide(&db);
   try app.before(migrate, .{&db});
   try app.listen(.{ .port = 8080 });
   ```

   It runs once, after the services have started and before the work `spawn`
   registered, on the Engine's loop, with a `nilo.Run` made there on that
   `Io` so a key can be minted from it (ADR 0160). The function takes the Run
   first and then whatever it was registered with, the way a job's `run`
   does. If it fails the boot fails: one line, the error back out of
   `listen()`, the services put down on the way (ADR 0151). A migration that
   could not run is a database this binary must not serve.

   Three shapes are refused while compiling: a value rather than a function,
   a function whose first parameter is not `*nilo.Run`, and a function that
   answers with a value nobody is there to take.

3. **`db.expecting(version)` is the version guard, on the `Db` itself.**
   The most common thing the phase was used for is one integer against one
   query, and it needed no phase at all: `nilo_start` runs `migrate.expect`
   on the pool it just opened, before the schema check's caller gets its
   `Db`. Behind is refused with `expect`'s sentence; a ledger that cannot be
   read is a warning, the way the schema check's is (ADR 0039). It dials one
   connection on a `Db` written with `connect_on_init = 0`, for the reason
   ADR 0144 gives.

## What was rejected

**Stopping the services and starting them again on the Engine's loop.** It
would work for a pool, it would have made the ADR 0079 shape keep compiling,
and it was not taken. A restart hides the mistake: the caller's `migrate(&db)`
still ran on the wrong loop, and a worker started there has no way to be
restarted on the right one. A refusal names the mistake at the moment it is
made, which is what every other boot check here does.

**`.expect` as a field on `Db.Opts`.** It reads better than a call, and it
costs 17,296 bytes in every program with a `Db` in it, measured with
`zig build size-sql`: an option is read on every boot, so the ledger's DDL,
the query that reads its head and the sentences round them are linked whether
anybody set it or not. As a call it stores a function with the guard inside
it, the way `checking` does, and a program that never calls it links none of
the migration module. The same two binaries measure that at 16 and 48 bytes.

**Making `before` work take an `Io` rather than a `Run`.** Every statement in
`nilo_sql` takes a Scope, and a migration is statements; handing the work an
`Io` would make its first line `var run: nilo.Run = .initIo(gpa, io)`, which
is nilo's line to write.

## What it costs

One enum on the App in place of the bool, one list that is empty for every
App that does not call `before`, and one branch in a function that runs once.
Nothing on the request path. `db.expecting` is one optional field and a null
test at boot, and 16 bytes of binary for a program that never calls it.
