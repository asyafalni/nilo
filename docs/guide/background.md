# Background work

**Work that no request started (a summary every minute, a queue drained every few seconds) runs in a fiber the server owns, started with `app.spawn` or `nilo.spawn`.**

**Reference:** [`app.spawn`, `app.before`, `app.start`](../reference/app.md#app), [`nilo.spawn`](../reference/app.md#concurrency), [`nilo.spawn` and `app.spawn`](../reference/core.md#nilospawn-and-appspawn) · **Design:** [The engine](../design/engine.md)

Everything else in this guide starts because somebody connected. This page is about the other kind of work: a summary written every minute, a queue drained every few seconds, a cache warmed once at startup and refreshed after that.

nilo has one mechanism for it, a fiber of its own owned by the server, and the only thing to decide is when it starts.

## A background loop

```zig
const std = @import("std");
const nilo = @import("nilo_http");

const Exporter = struct {
    lock: nilo.Mutex = .{},
    pending: u64 = 0,

    fn flush(self: *Exporter) !void {
        try self.lock.lock();
        defer self.lock.unlock();
        // …send them somewhere…
        self.pending = 0;
    }
};

fn flushEvery(exporter: *Exporter) void {
    while (true) {
        nilo.sleep(60_000) catch return;   // Canceled — the server is going
        exporter.flush() catch |err| std.log.err("flush: {t}", .{err});
    }
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    var exporter: Exporter = .{};
    try app.provide(&exporter);
    try app.spawn(flushEvery, .{&exporter});

    try app.listen(.{});
}
```

`zig build run-scheduled` is a smaller version of this, with a route that gives the loop something to count.

Three things about that loop matter.

**`nilo.sleep` pauses the fiber, not the thread.** Many requests share one OS thread. `std.Thread.sleep` there would stop every one of them for a minute; `nilo.sleep` stops only this fiber.

**`error.Canceled` means the server is shutting down, and it is the only way out of the loop.** The server owns the fiber exactly as it owns a connection: it is counted while it runs, and cut off when the shutdown grace period ends. Nothing else ends the loop, so `catch return` is not just tidiness: it is how the process gets to exit. The cancellation is reported once, and it may land in the work rather than in the `sleep`. A nilo call that turns it into an error of its own hands it back, so the next `sleep` still returns `Canceled` ([ADR 223](../adr/223-a-statement-cut-off-by-a-cancellation-hands-it-back.md)).

**The function cannot return an error.** There is no request and nobody to answer, so an error has nowhere to go but the log.

## Choosing when it starts

**`app.spawn` and `nilo.spawn` start the same kind of fiber; the difference is when.**

| | |
|---|---|
| `app.spawn(f, args)` | registered before the server, started once it is up |
| `nilo.spawn(f, args)` | started now; `error.NoServer` if nothing is listening |

A handler calls `nilo.spawn`, for a request that starts something that outlives it. It needs a running server, and inside a handler there always is one.

`main` calls [`app.spawn`](../reference/app.md#app). It exists because `listen()` does not return, so there is no "after the server started" point to write a line in. Registered next to the routes, it starts after the port is taken and before the first connection is accepted.

**Work that has to finish before the first request uses `app.before`.** A migration, a version check, a key set fetched once: such work needs the services, so it runs inside `listen()`, after the services have started and before anything registered with `app.spawn` ([Applying](./sql/migrations.md#applying-migrations)):

```zig
fn migrate(run: *nilo.Run, db: *sql.Db) !void {
    try sql.migrate.applyPending(db, run, try manifest.chain(run.arena()));
}

try app.provide(&db);
try app.before(migrate, .{&db});     // runs once, on the server's loop
try app.spawn(flushEvery, .{&exporter});
try app.listen(.{ .port = 8080 });
```

The function takes the startup's `nilo.Run` first, then whatever it was registered with. If it fails, the server does not start: a migration that could not run means a database this binary must not serve. The order between `before` and `spawn` is fixed, not decided by which line comes first: the services, then `before`, then the fibers ([ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

`app.start(io)` is for a program that never listens: a test, a script, a worker on `jobs.serveOn(io)`. Calling `listen()` after it is refused, because a service keeps the `Io` it was started on and `listen()` runs on a loop of its own (ADR 180).

## What not to pass in

**Do not pass a `Str` or use a fail function in background work.** The compiler catches neither, and both apply to `nilo.spawn` in the same way.

**A `Str`.** It points into the request arena, which is reset when the request ends, and background work outlives the request that started it. Copy anything borrowed from a request before passing it in, with `.keep()` or your own allocation.

**A fail function.** `fail.notFound` and the others write their message into the request being served. There is no request here, so it returns a plain error with no message, and nothing builds a response from it. Log instead.

## What it costs

**Nothing per request and nothing per connection.** The request path is untouched, and each of these is one fiber for the whole process, not one per socket.

The fiber itself is not free. A suspended fiber holds its stack at the highest point it ever reached for as long as it lives ([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). For a fiber like this one that is a few kilobytes that never come back, paid once per thing you spawn. Spawn a handful, not one per row in a table.

## What it does not do

**There is no schedule language here**: no cron expressions, no "at 03:00 on Sundays", no policy for what happens when one tick runs into the next. A `sleep` in a loop is all there is, on purpose. Each of those policies has an answer that is right for some programs and wrong for others, and the loop keeps the choice where you can read it. Those policies *are* written in [`nilo_job`](./jobs.md), where a scheduled job must declare what an overlap and a missed tick mean or it does not compile, and where a tick is a database row that survives a restart. A fiber is for work that is a loop; a job is for work that is a row.

There is also no way to send a message to another connection's socket from here. That is a `Room`, covered in [its own section](./websocket.md#broadcasting-with-niloroom).
