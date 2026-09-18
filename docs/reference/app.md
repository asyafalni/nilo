# The App

One page of [the reference](./README.md): the App and its groups, what `listen()` takes, the loop, and the options behind `static` and the OpenAPI document.

## `App`

| | |
|---|---|
| `App.init(gpa)` | a new App. The allocator is for the App's furniture, not for requests |
| `app.deinit()` | |
| `app.provide(&thing)` | register a service, looked up later by its pointer type. A service may declare `pub fn nilo_start(self: *T, io: std.Io) !void` to finish building itself once there is an event loop ([ADR 0040](../adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)) and `pub fn nilo_stop(self: *T) void` to put it down again before the loop goes ([ADR 0151](../adr/0151-a-service-is-stopped-before-the-loop-is.md)). **A service that put work on the loop needs the second one**, or the loop cannot be torn down. A third, `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8`, is what `app.health` asks ([ADR 0192](../adr/0192-a-health-route-asks-the-services.md)) |
| `app.spawn(f, args)` | work that is not a request, started once the server is up ([ADR 0086](../adr/0086-work-that-is-not-a-request-belongs-to-the-server.md)) |
| `app.before(f, args)` | work that needs the services and has to finish before the first request — a migration, a version guard, a key set fetched once. `f` is `fn (run: *nilo.Run, …) !void`, run once inside `listen()` after the services have started and before what `spawn` registered, on the server's loop; if it fails the server does not start ([ADR 0220](../adr/0220-work-that-needs-the-services-runs-on-their-loop.md)) |
| `app.use(mw)` | middleware, everywhere |
| `app.useOn(prefix, mw)` | middleware, under a path prefix |
| `app.without(mw)` | the same App with `mw` off for the routes registered through what comes back — how a sign-up route sits inside a guarded prefix ([ADR 0080](../adr/0080-a-route-can-say-it-is-not-covered.md)) |
| `app.with(mw)` | the other direction: the same App with `mw` **on** for the routes registered through what comes back, so one endpoint can be guarded where its neighbours are not ([ADR 0126](../adr/0126-a-route-can-say-what-covers-it.md)) |
| `app.guard(mw, cookie)` | say that `mw` refuses a request without the session cookie named `cookie`, so every route it is in front of is written in the API description with a `cookieAuth` requirement and a 401 — which routes is read from `use`/`useOn`/`with`/`without` when the document is written; only the cookie's name is taken on your word. One per App; a second is `error.GuardAlreadyDeclared`. Declaring it does not install it ([ADR 0252](../adr/0252-the-document-takes-a-guards-word-for-the-cookie.md)) |
| `app.named("listPartners")` | the same App with the next route registered through what comes back carrying that as its `operationId`, instead of the one derived from the method and the path ([ADR 0149](../adr/0149-a-route-can-say-its-own-name.md)). Letters, digits, `_` and `-`, starting with a letter or `_` — `auth-login` is a name a generator can carry ([ADR 0200](../adr/0200-a-hyphen-is-a-spelling-a-generator-can-carry.md)) |
| `app.group(prefix)` | a group — see below |
| `app.get / post / put / delete / patch / head / options (pattern, handler)` | a route |
| `app.route(method, pattern, handler)` | any other method |
| `app.static(url_prefix, dir_path)` | a directory, read into memory at startup |
| `app.staticWith(url_prefix, dir_path, options)` | the same, with [options](#static-options) |
| `app.embedded(url_prefix, files)` | files the binary carries — a list of `.{ .path, .bytes }` with `@embedFile` on each — served as a directory is ([Static files](../guide/static-files.md#files-the-binary-carries), [ADR 0249](../adr/0249-a-tree-the-binary-carries-is-served-as-a-directory-is.md)) |
| `app.embeddedWith(url_prefix, files, options)` | the same, with the [options that are not about a disk](#static-options) |
| `app.docs(options)` | serve an [OpenAPI document](../guide/openapi.md) |
| `app.health(path)` | a page that says whether this process can do its job — `200 {"status":"ok"}`, or `503` naming the services that are not ready and why, or `503 {"status":"stopping"}` once the server was told to stop. Asks every service that declared `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope) ?[]const u8` — null is ready, a sentence is why not ([Deploying](../guide/deploying.md#knowing-whether-it-is-ready), [ADR 0192](../adr/0192-a-health-route-asks-the-services.md)) |
| `app.metrics(options)` | count every request and serve the numbers at `/metrics`, Prometheus format ([Metrics](../guide/metrics.md), [ADR 0100](../adr/0100-the-route-table-is-the-registry.md)) |
| `app.expose(name, kind, &atomic)` | publish a `std.atomic.Value(u64)` of your own on that page. `kind` is `.counter` or `.gauge` |
| `app.listen(options)` | run until stopped. Stops the process on a startup error |
| `app.start(io)` | everything `listen()` does before it accepts anything — services checked, chains resolved, pools opened, schemas checked — for a program that never listens: a test through `testing.Client`, a script, a worker on `jobs.serveOn(io)` ([ADR 0079](../adr/0079-there-is-a-phase-before-the-server.md)). **Not before `listen()`**: a service keeps the `Io` it was started on, so `start(io)` followed by `listen()` is refused when any service took one; the phase between the pool and the server is `app.before` ([ADR 0220](../adr/0220-work-that-needs-the-services-runs-on-their-loop.md)). What it does *not* start is `spawn`, which needs a server |
| `app.shutdown()` | stop, from any thread or from inside a handler |
| `app.boundPort()` | `?u16` — the port the server is listening on, from any thread. Null before `listen()` has bound, and for a unix socket. `.port = 0` asks the kernel for a free one and this is its answer |
| `app.tryListen / tryRoute / tryStatic / tryStaticWith` | the same calls, error returned rather than reported |
| `app.checkServices()` | `error.MissingService` if a route needs one nobody provided |
| `app.routes()` | every route, in registration order — a view rather than a copy. `.len()`, `.at(i)` and `{f}` ([ADR 0127](../adr/0127-a-route-pattern-is-the-name-of-its-url.md)). `.at(i)` is `.method`, `.pattern` and `.name` — the `operationId`, given or derived, so a table keyed by it can be held against the route table ([ADR 0201](../adr/0201-a-middleware-can-learn-which-route-it-is-in-front-of.md)) |

`pattern` and `handler` are `comptime`. Registration order never matters.

### `Group`

`app.group("/api")` returns one. It has `group`, `use`, `useOn`, `without`,
`provide`, `get`, `post`, `put`, `delete`, `patch`, `head`, `options`, `route`,
`tryRoute`, `static`, `staticWith`, `tryStatic`, `tryStaticWith` — the same as an
App, minus `listen`, `docs` and `shutdown`. The prefix is compile-time text and
must be literal; the type is `nilo.Group("/api")`.

`@TypeOf(g).mounted_at` is where it is mounted — `"/api"`, and `""` for an App,
so a plugin taking `anytype` can ask either.

`g.without(mw)` is the same group with `mw` off for the routes registered
through it, which is how the two routes that create a session sit inside a
prefix that requires one. Its type is `nilo.GroupOf("/api", &.{mw})`.

`g.with(mw)` is the other direction, for a route that wants *more* than its
neighbours. A carried middleware runs innermost, and both `with` and `without`
match on the joined pattern **and the method**, so a `DELETE` guard does not
cover the `GET` beside it. They compose:

```zig
const v1 = app.group("/v1");
try v1.use(requireOperator);
try v1.without(requireOperator).with(rateLimitSignups).post("/sign-up", signUp);
```

### `listen` options

| | Default |
|---|---|
| `address` | `"127.0.0.1"` — an address, not a host name. `"unix:/run/nilo.sock"` listens on a path ([ADR 0130](../adr/0130-a-path-is-an-address-to-listen-on.md)) |
| `port` | `8787` — not read when `address` names a unix socket |
| `threads` | `0` (one per core) |
| `read_buffer` | `8 * 1024` — also the ceiling on a request head |
| `write_buffer` | `4 * 1024` |
| `arena_keep` | `16 * 1024` — of a connection's request arena, kept between requests |
| `reuse_address` | `true` — on a unix socket, removes a socket file left behind by a process that is gone |
| `stop_on_signal` | `true` — Ctrl-C and SIGTERM |
| `shutdown_grace_ms` | `10_000` |
| `header_timeout_ms` | `10_000` — the whole head, from its first byte |
| `idle_timeout_ms` | `75_000` — a connection between requests |
| `body_timeout_ms` | `30_000` — any one read of a body |
| `body_min_rate` | `8 * 1024` — bytes a second a buffered body has to keep up. `0` = off |
| `body_grace_ms` | `10_000` — before the rate is asked for |
| `write_timeout_ms` | `30_000` — any one write to the client |
| `max_connections` | `10_000` — held at once, 4,669 bytes each when idle. `0` = no limit |
| `max_in_flight` | `0` — the most requests answered at once; past it a request is a `503` with `Retry-After: 1` at once rather than a place in a queue. `0` = no limit ([ADR 0197](../adr/0197-a-server-past-its-limit-says-so-at-once.md)) |
| `max_body` | `1024 * 1024` — the most `c.body()` reads into the arena. One route can say its own with [`nilo.maxBody(bytes)`](./middleware.md#nilomaxbody) |
| `trusted_hops` | `0` — how many proxies stand in front, for `c.clientIp()` |
| `trusted_proxies` | `&.{}` — **which** ones: CIDRs, bare addresses, `"private"`, `"loopback"`. Wins over `trusted_hops` ([ADR 0129](../adr/0129-a-proxy-is-trusted-by-which-one-it-is.md)) |
| `session_secret` | `null` — 32 bytes, for `Session(T)`. The same on every instance |
| `block_warning_ms` | `250` — say so when a handler holds its thread. `0` = off |

**`arena_keep` is the one in that table with a cliff under it.** A response
larger than it does not fit in what the arena retains, so the block goes back to
the operating system after every request and the next one faults it in a page at
a time — 257 minor faults for a megabyte, with the kernel zeroing each page. A
server that assembles large responses in `c.arena()` should set this just past
the largest of them, and no higher: the memory is held **per connection**, so a
megabyte here across ten thousand connections is ten gigabytes
([ADR 0096](../adr/0096-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)).
Leaving it alone is right for a server whose responses fit in 16 KiB.

Each of the four deadlines bounds one wait for the network, not a request, so a
long upload or an hour-long stream is not hurried by any of them. `0` turns one
off. See [Deploying](../guide/deploying.md#deadlines).

Past `max_connections` a connection is accepted and closed at once — no request
read, no status sent
([why](../guide/deploying.md#how-many-connections-at-once)).

### `metrics` options

`app.metrics(.{ … })`, all `comptime`.

| | Default |
|---|---|
| `path` | `"/metrics"` — an ordinary route, so middleware in front of it applies |
| `buckets` | `100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 1_000_000` — latency boundaries in microseconds, climbing. Reported as seconds |

What goes on the page: `nilo_requests_total{method,route,status}` by status
class, `nilo_request_duration_seconds` as a histogram, `nilo_responses_total`
by exact code for the whole process, `nilo_requests_in_flight`, and anything
`app.expose` was given.

Counted per **route**, not per path — `/users/1` and `/users/2` are both
`/users/:id`. Five slots are not routes: `<unmatched>`, `<method not allowed>`, `<shed>`,
`<static file>` and `<unparsed>`. A route that has answered nothing has no
series at all. See [Metrics](../guide/metrics.md).

## Concurrency

| | |
|---|---|
| `nilo.Mutex` | `.init`, then `try lock()`, `unlock()`, `tryLock()`, `lockUncancelable()` |
| `nilo.blocking(f, args)` | run a blocking call off the event loop |
| `nilo.Gate` | `.open(n)`, then `try enter()`, `leave()` — a lock that lets `n` through |
| `nilo.sleep(ms)` | wait without parking the thread |
| `nilo.spawn(f, args)` | run something that is not a request, now — `error.NoServer` if nothing is listening |
| `app.spawn(f, args)` | the same fiber, registered before the server and started once it is up ([the guide](../guide/background.md)) |
| `nilo.randomSecure(&buf)` | fill a buffer you already hold, off the event loop |
| `nilo.verifyPassword(gpa, stored, text)` | `c.verifyPassword` with no request in hand — the same Gate and pool, inline with no loop ([`nilo_pw`](./pw.md)) |
| `nilo.monotonicNanos()` | a clock reading, for durations |

`lock()` and `sleep()` fail with `error.Canceled` if the request went away, which
maps to a 503. `lockUncancelable()` cannot fail and cannot be interrupted, which
is for a cleanup path — one that has nowhere to put a failure, and would leave
something unreleased if it gave up
([ADR 0104](../adr/0104-a-cleanup-path-is-not-cancellable.md)). Only for a short
section that does not itself wait; `lock()` is still the one to reach for.

## Static options

`app.staticWith(prefix, dir, …)`:

| | Default |
|---|---|
| `index` | `"index.html"` |
| `cache_control` | `"public, max-age=3600"` |
| `spa_fallback` | `""` (off) |
| `spa_fallback_for` | `.navigations` — or `.any_path`, which is what shipped before 0.2.0 |
| `max_file_bytes` | `8 * 1024 * 1024` |
| `max_total_bytes` | `64 * 1024 * 1024` |
| `dotfiles` | `false` |
| `reload` | `false` — hold nothing, open every file per request |

`spa_fallback_for` decides which requests the fallback answers: `.navigations`
is a request naming `text/html`, or one that named nothing and has no file
extension in its last path segment, and everything else under the prefix is a
404 naming the path. See
[Static files](../guide/static-files.md#the-fallback-and-what-it-is-for).

`max_file_bytes` is a threshold, not a ceiling: a file over it is listed but not
read, and each request opens it and sends it from the disk — no gzipped copy, an
ETag made of the modification time and the size, and one file descriptor for as
long as the response takes. `max_total_bytes` counts held bytes only. See
[Static files](../guide/static-files.md#files-too-big-to-hold).

Both the length and the ETag of a spilled file come from one look at the
descriptor whose bytes are about to go out, so editing a file under a running
server cannot serve a stale length under a stale tag
([ADR 0125](../adr/0125-a-file-is-described-by-the-descriptor-being-sent.md)).

`app.embeddedWith(prefix, files, …)` takes `index`, `cache_control`,
`spa_fallback`, `spa_fallback_for`, `compress` and `compress_min_bytes`, with the
defaults above, and none of the rest: nothing in the binary can spill, nothing is
over a total, every name was written by the caller, and there is no disk to
reload from. A path listed twice and a fallback that names no entry are refused
at startup
([ADR 0249](../adr/0249-a-tree-the-binary-carries-is-served-as-a-directory-is.md)).

**`reload = true` is `max_file_bytes = 0` with a name**: nothing is held, every
file is opened per request, and editing one works without a restart. For
development — it gives up the in-memory copy and the gzipped one — and a file
that did not exist at startup still needs a restart, because the list of names
comes from the walk.

## OpenAPI options

`app.docs(…)`:

| | Default |
|---|---|
| `title` | `"API"` |
| `version` | `"1.0.0"` |
| `description` | `""` |
| `path` | `"/openapi.json"` |
| `ui_path` | `"/docs"` — empty for none |

A type with a `jsonStringify` is described by what it says, not by its fields —
`std.json` calls the function and never reads them, so reflecting them would
describe something the server does not send
([ADR 0076](../adr/0076-a-type-that-writes-its-own-json-says-so.md)):

```zig
pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
```

`type` is required — `"string"`, `"integer"`, `"number"`, `"boolean"` — and
`format` is an optional hint. nilo's own types carry it already (`Uuid`,
`Timestamp`, `Decimal`, `Interval`, `Inet`). One with a custom writer and no
marker gets `{}` and a description saying so.

### The document without a server

`app.writeOpenApi(w)` writes the same bytes `/openapi.json` serves, to any
writer, with **no port, no database and no network**
([ADR 0167](../adr/0167-the-document-is-a-build-artefact.md)):

<!-- compiles -->
```zig
fn listUsers() ![]const User {
    return &.{};
}

pub fn writeTheDocument(gpa: std.mem.Allocator) ![]u8 {
    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.get("/users", listUsers);
    app.docs(.{ .title = "Orders", .version = "2.1.0" });

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try app.writeOpenApi(&out.writer);
    return gpa.dupe(u8, out.written());
}
```

Call it after the routes are registered and before `listen`. The operations are
collected as each route is registered, so nothing has to have started.

**`app.provide` does not have to be called**, which is what makes the build
step's binary genuinely clean. `provide` is for the request path; writing the
document needs only the operations, so a program that does nothing but write it
links no database driver and needs no stand-in `*Db` to get registration past
the type checker.

**Register the routes in one place both callers use.** A `routes.zig` that
`main.zig` and the document step each call is the same argument as `buildDocs`
going through this method rather than beside it: two route lists is how a
checked-in contract starts describing a server that no longer exists, and the
one somebody forgets to add to the second list disappears with no error and no
failing test.

**This is what makes the document a build artefact rather than a thing you
curl.** A checked-in `openapi.json` is how a typed frontend client is generated
and how a breaking change shows up in review; producing it by booting a server
means `listen`, which means `db.checking`, which means a migrated database — so
a file describing a set of types ends up needing Postgres. `zig build openapi >
openapi.json` needs none of it.

The title and version come from `app.docs(.{ … })` if it was called, and are
`"API"` / `"1.0.0"` if it was not, so a program that serves no document can
still write one. The served copy goes through this same call, which is what
stops a checked-in file and a running server describing two different APIs.
