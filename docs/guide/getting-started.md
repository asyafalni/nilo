# Getting started

nilo needs **Zig 0.16**. Nothing else — no C library, no system package.

## Add it to your project

Starting from an empty directory, `zig init` first — `zig fetch --save` writes
into `build.zig.zon` and fails with `no build.zig file found` if there isn't one
yet:

```
zig init
zig fetch --save git+https://github.com/nevindra/nilo?ref=v0.4.0
```

That writes nilo into your `build.zig.zon`, pinned to the tag you asked for.
**Keep the `?ref=`.** Without it `zig fetch` resolves whatever `main` is at that
moment and writes *that* commit's hash into your lockfile — so two people
installing a week apart get two different libraries, and neither of them asked
for a version.

What `zig init` leaves behind is a library-and-executable scaffold built around
`src/root.zig`, and it is not what you want. **Replace the generated
`build.zig` with the one below rather than pasting into it, and delete
`src/root.zig`** — that template is Zig's and nothing here can change it. Keep
`build.zig.zon`, which is where `zig fetch` just wrote nilo.

Then hand the module to whatever imports it, in `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the server").dependOn(&run.step);
}
```

That is the whole file — `zig build run` after it, and `src/main.zig` next.
[Restarting on every save](#restarting-on-every-save), below, is three more
lines once the server exists.

The package is `nilo`; the module is `nilo_http`. **The bare name is the
project's, not any one module's** — `nilo_sql`, `nilo_id` and `nilo_core` sit
beside the server, and you add a line here for each one you import and nothing
for the ones you do not
([ADR 0041](../adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](../adr/0042-the-bottom-layer-holds-more-than-one-module.md)). In your
own code the alias goes back:

```zig
const nilo = @import("nilo_http");
```

Pass the same `.optimize` through to the dependency. Building nilo in `Debug`
under a `ReleaseFast` program is legal and slow, and nilo says so at startup
rather than leaving you to find it:

```
nilo was built in Debug and this program in ReleaseSafe, which is legal and
slow. Pass the mode through: b.dependency("nilo", .{ .target = target,
.optimize = optimize }) — in the test step too, which is the one that usually
gets missed.
```

**The test step is the one that usually gets missed**, which is why the same
warning comes out of `nilo.testing.Client` and not only out of `listen()`: a
suite that loops over both optimize modes fetches the dependency in the same
place, and a ReleaseSafe suite running against a Debug nilo is checking a
configuration nobody deploys
([ADR 0084](../adr/0084-a-library-can-tell-what-mode-the-program-was-built-in.md)).

## A server that answers

```zig
const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

fn hello() []const u8 {
    return "hello from nilo\n";
}

fn greet(name: nilo.Str) nilo.Str {
    return name;
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(nilo.logger.standard);

    try app.get("/", hello);
    try app.get("/greet/:name", greet);

    try app.listen(.{});
}
```

```
$ zig build run
$ curl localhost:8787/
hello from nilo
$ curl localhost:8787/greet/wati
wati
```

`hello` takes nothing and returns text. `greet` takes a `nilo.Str`, which is
the first `:param` in the pattern — text that belongs to the request and is only
valid while it runs. Neither function knows what HTTP is, which is the point:
both are callable from a test.

## Restarting on every save

A Zig binary cannot swap its own code, so there is no hot reload; what there
is instead is a server started again every time the build writes a new one.
`nilo-dev` ships with the package and does that — it runs one
`zig build --watch`, and restarts your server whenever the binary it
produces changes
([ADR 0259](../adr/0259-a-restart-on-save-watches-the-binary-not-the-sources.md)).
Three lines under the `run` step:

```zig
const dev = b.addRunArtifact(nilo.artifact("nilo-dev"));
dev.addArgs(&.{ "--zig", b.graph.zig_exe, b.getInstallPath(.bin, exe.out_filename) });
b.step("dev", "Rebuild and restart on every save").dependOn(&dev.step);
```

```
$ zig build dev
nilo-dev: building with `zig build install --watch`; serving zig-out/bin/my-app when it is written
nilo-dev: started zig-out/bin/my-app (pid 41022)
info: nilo listening on 127.0.0.1:8787 across 8 thread(s)
   ← save a file
nilo-dev: zig-out/bin/my-app changed; restarted (pid 41107, the old one drained in 100 ms)
```

**A build that fails changes nothing.** The errors print, the old server keeps
serving, and the next save that compiles is the one that restarts it. The old
server is asked with SIGTERM and gets five seconds to finish what it was
answering before it is killed. Ctrl-C stops all of it. Arguments after `--`
go to your server; `--build <step>` names a build step other than `install`.

**What a save costs is Zig's to decide, and on 0.16.0 it is 23 MB of
`.zig-cache` every time**, because the cache evicts nothing. `--incremental`
keeps the compiler resident and the cache flat instead — and on 0.16.0 its
output only runs under the LLVM backend when libc is linked, which every nilo
server does through zio. So the flag goes with one more line in `build.zig`,
and costs an LLVM emit per save rather than a self-hosted compile:

```zig
exe.use_llvm = true; // or behind a -D option, for the dev loop only
```

```
$ zig build dev -- --incremental
```

The numbers behind both paragraphs — 0.12 s for an incremental binary that
did not run, 23 MB a save for one that did — are in
[`bench/result/build.md`](../../bench/result/build.md#what-a-restart-on-save-costs-per-save).
Files served by `staticWith(.{ .reload = true })` need none of this: they are
read from disk per request already
([static files](./static-files.md)).

## The two lines at the top

They are easy to write the wrong way round, and each fixes a different symptom.
`listen()` says so at startup if either is missing, so you don't have to
remember which.

```zig
pub const std_options = nilo.std_options;
```

Turns the Engine's debug chatter down to warnings. Without it a debug build opens
with `debug(zio): Spawning worker thread 1` and buries your own logs. To keep
settings of your own, start from this one:

```zig
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = nilo.std_options.log_scope_levels,
};
```

```zig
pub const std_options_debug_io = nilo.debug_io;
```

Keeps `std.log` from blocking the event loop. Writing to stderr is a syscall, and
many requests share one OS thread — so without this every log line stops every
request on that thread. The symptom is a server that is merely slow, which is why
`listen()` warns rather than letting you find it under load.

There is an optional third line, worth having in production:

```zig
pub const panic = nilo.panic;
```

It makes a crash say which request caused it — `panic: integer overflow (while
handling GET /boom/50)`. See [Deploying](./deploying.md#panics).

## The allocator

`App.init` takes one, and it is used for the App's own furniture: the route
table, the static files, the service registry. Requests do **not** allocate from
it — each gets an arena of its own that is thrown away when it ends.

`std.heap.smp_allocator` is the one to use for a server: it is built for
allocation from several threads at once. Use `std.testing.allocator` in tests,
which also checks for leaks.

## Where to go next

- [Handlers](./handlers.md) — the rule that decides what each argument means.
- [Routing](./routing.md) — patterns, precedence, and grouping.
- The nine examples in [`examples/`](../../examples/), each runnable with
  `zig build run-<name>`.
