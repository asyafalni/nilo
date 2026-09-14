<h1 align="center">nilo</h1>

<p align="center">
  <strong>Your types are the contract. The compiler is the check.</strong>
</p>

<p align="center">
  <a href="https://ziglang.org/"><img alt="Zig 0.16" src="https://img.shields.io/badge/zig-0.16-f7a41d?style=flat-square&logo=zig&logoColor=white"></a>
  <a href="./CHANGELOG.md"><img alt="version 0.4.0" src="https://img.shields.io/badge/version-0.4.0-3b82f6?style=flat-square"></a>
  <a href="./docs/reference.md"><img alt="11 modules" src="https://img.shields.io/badge/modules-11-8957e5?style=flat-square"></a>
  <a href="./refusals/README.md"><img alt="283 refusals" src="https://img.shields.io/badge/mistakes%20refused%20while%20compiling-283-e05d44?style=flat-square"></a>
  <a href="./docs/adr/"><img alt="219 ADRs" src="https://img.shields.io/badge/decisions%20on%20file-219-6b7280?style=flat-square"></a>
  <a href="./LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-16a34a?style=flat-square"></a>
</p>

<p align="center">
  <a href="#-quickstart">Quickstart</a> ·
  <a href="#-philosophy">Philosophy</a> ·
  <a href="./docs/guide/">Guide</a> ·
  <a href="./docs/reference.md">Reference</a> ·
  <a href="./examples/">Examples</a> ·
  <a href="./bench/result/http.md">Benchmarks</a> ·
  <a href="./CHANGELOG.md">Changelog</a>
</p>

---

Zig gives you a compiler and not much else. Routing a request, reading settings,
hashing a password, creating a table, talking to Postgres: you write all of that
yourself, or you don't ship.

nilo is a toolkit for that layer. Eleven modules, one idea: **a plain function is
a route, a plain struct is a table**, and nothing is annotated anywhere, because
the signature and the field list already say everything nilo needs. The biggest
module is an HTTP server, but you import what you use and Zig never compiles the
rest.

| | |
|---|---|
| **One rule** | a pointer is a service, a value is request data. There is no second rule. |
| **One allocation** | per request. A test fails if it ever becomes two. |
| **283 refusals** | mistakes that stop the build with a sentence nilo wrote, held by seven build steps. |
| **Zero glue** | routing, the 400, the 404, the OpenAPI document and the SQL all read the same struct. |

## ⚡ Quickstart

Zig 0.16 and nothing else — no C library, no system package.

```console
$ zig init                                                          # only if you have no build.zig.zon yet
$ zig fetch --save git+https://github.com/nevindra/nilo?ref=v0.4.0
```

**Keep the `?ref=`.** Without it `zig fetch` takes whatever `main` is that day.

```zig
const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;       // two lines of wiring, once, in your root file;
pub const std_options_debug_io = nilo.debug_io; // forget one and `listen()` says which

fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}

fn createUser(db: *Db, incoming: NewUser) !nilo.Status(201, User) {
    return .{ .value = try db.add(incoming) };
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.provide(&db);
    try app.use(nilo.logger.standard);
    try app.get("/users/:id", getUser);
    try app.post("/users", createUser);
    try app.static("/", "public");
    app.docs(.{ .title = "Users", .version = "1.0.0" });

    try app.listen(.{});
}
```

Then, in `build.zig`:

```zig
const nilo = b.dependency("nilo", .{
    .target = target,
    .optimize = optimize,
    // Only if you import nilo_sql. This is what fetches the database drivers;
    // leave it off and a project that serves HTTP downloads none of them.
    .sql = true,
});

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
```

The package is `nilo` and the modules are `nilo_http`, `nilo_sql`, `nilo_s3`,
`nilo_fetch`, `nilo_job`, `nilo_cache`, `nilo_jwt`, `nilo_config`, `nilo_pw`,
`nilo_id` and `nilo_core` — one import line for each you use. **There is no
module called `nilo`.** Alias it back in your own code:
`const nilo = @import("nilo_http");`.

`zig build run` and it's serving. [Getting started](./docs/guide/getting-started.md)
walks the same ground line by line.

> **Coming from 0.3.0?** Five things the compiler finds and seven it cannot,
> each with its fix:
> [Read this before you deploy](https://github.com/nevindra/nilo/releases/tag/v0.4.0#read-this-before-you-deploy).
> From 0.2.0, start at [v0.3.0's](https://github.com/nevindra/nilo/releases/tag/v0.3.0#read-this-before-deploying);
> from 0.1.0, at [Upgrading](https://github.com/nevindra/nilo/releases/tag/v0.2.0#upgrading-from-010).

## A route is just a function

```zig
fn getUser(db: *Db, id: u32) !?User {
    return db.find(id);
}
```

That is the whole route. nilo reads the signature while your program compiles
and hands back the URL matching, `id` already parsed into a `u32`, a 400 with a
real sentence in it when it isn't a number, a 404 when `db.find` returns `null`,
and an OpenAPI document that mentions all of the above. Delete the `?` and the
404 leaves the document too — there is no second copy of the contract.

> ### A pointer is a service. A value is request data.
>
> That's it. That's the API.

| You wrote | It means |
|---|---|
| `db: *Db` | a pointer, so it's a service: the one you handed to `provide` |
| `id: u32` | a value, so it's request data: here `:id`, converted, or a 400 if it won't convert |
| `!?User` | it might not be there, so `null` goes out as a 404, and the API document says so |
| `!Status(201, User)` | the status is part of the type, so the API document names it |

**Registration order doesn't matter.** `/users/new` and `/users/:id` both work
whichever you write first; `use` after `get` still applies; `docs()` can go
anywhere. And because a handler takes only what it needs, a test just calls it —
no server, no socket, no fixture:

```zig
test "getUser" {
    var fake = Db.fake(.{ .id = 7 });
    try expectEqual(7, (try getUser(&fake, 7)).?.id);
    try expect(try getUser(&fake, 99) == null);
}
```

## 🧰 What's in the box

| Module | What it does | What isn't in it |
|---|---|---|
| **`nilo_http`** | routing, typed handlers, middleware, cookies and sessions, static files, streaming, WebSocket, OpenAPI, metrics, rate limiting | templates and TLS, both on the record below |
| **`nilo_sql`** | Postgres and SQLite. Your struct is the table, and it makes the table: reads, writes, transactions, streaming, the schema, the diff and the ledger | joins, aggregates and `GROUP BY`, which go through `db.raw`. A migration `down` |
| **`nilo_s3`** | object storage: S3, MinIO, R2. Your bucket is a type. Get, put, range, stream, presigned GET and POST | `LIST`, `COPY`, multipart |
| **`nilo_fetch`** | calling somebody else's HTTP API from inside a request: the policy in front of `std.http.Client` | retries, circuit breaker |
| **`nilo_job`** | work that runs later, again, or on a schedule: a queue in the database you already have, a cron schedule parsed while compiling | priorities, exactly-once, time zones |
| **`nilo_cache`** | an expiring cache in this process, on a fixed budget with nothing allocated per operation | pointers in a cached value, which is a compile error naming the field |
| **`nilo_jwt`** | checking somebody else's signed token: RS256 and a JWKS | fetching the key set and refreshing it |
| **`nilo_config`** | settings out of the environment, every bad one named at once | file parsing, and that's a decision |
| **`nilo_pw`** | password hashing: argon2id, stored as PHC | rate limiting the endpoint |
| **`nilo_id`** | UUIDs, v4 and v7 | where the randomness comes from |
| **`nilo_core`** | `Str`, the Scope, the clock and percent coding, shared by the rest | any IO at all, on purpose |

A module imports downward only and never sideways, and `zig build layering`
holds that as a build step rather than a paragraph
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](./docs/adr/0042-the-bottom-layer-holds-more-than-one-module.md)).
It's why `nilo_sql` asks for a Scope instead of a `Ctx`: the same query runs
inside a handler, a CLI, or a test with no server in the process.

Mail is unwritten but no longer blocked, and is the most useful thing an outside
contributor could pick up; [`docs/roadmap.md`](./docs/roadmap.md) has the queue,
one list per module.

## 🐈 Philosophy

Nilo was my cat. She isn't around any more. She was quick, the kind of quick you
notice from across a room, cheerful about it, and she spent most of her time
looking after the other cats in the house, which nobody had asked her to do.
This was called `zfast` before, which said what it did and nothing about how it
should feel to use; naming it after her is what made me write that half down.

**Helpful, quick, cheerful — in that order**, and the order is what settles it
when two of them disagree.

- **Helpful.** If you pick Zig up for an ordinary job — an API, a form, a
  settings struct, a password to store — that job should already be done, in a
  module small enough to read in one sitting. Things get built because the job
  is common, not because it is interesting.
- **Quick.** One allocation per request, 4,669 bytes per idle connection:
  measurements with tests holding them in place, not adjectives. A nicer API
  wins if it costs under 10%, and never if it costs an allocation
  ([ADR 0001](./docs/adr/0001-dx-wins-below-the-10-percent-threshold.md)).
- **Cheerful.** Nothing here scolds you. A mistake comes back as a sentence
  saying what you did and what to do instead, usually before your program has
  finished compiling.

Two rules keep it that way. **A part gets in if it's a type you already wrote,
checked while compiling, with its cost written down**
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)) — and a
feature that can't be made to fit doesn't ship in a worse shape. **Nothing
load-bearing lives in one head**: a decision goes in an ADR naming the
alternative it beat, a rule becomes a build step, and a number without a run in
[`bench/result/`](./bench/result/) behind it is a claim.

## The same idea, three more times

### Your struct is a table

```zig
const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{ .{ .email, .ignoring_case } },
        .references = .{ .org_id = .{ Org, .id } },
    };

    id: i64,
    org_id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

const adults = try db.select(User, c, .{
    .where = .{ .age = .{ .gt = 18 } },
    .order = .{ .created_at = .desc },
    .limit = 10,
});
```

No tags on the fields, no schema file, no generated client. That query is a
constant in your binary before the program starts — only the `18` reaches
runtime:

```sql
SELECT "id", "org_id", "email", "age", "created_at" FROM "users"
WHERE "age" > $1 ORDER BY "created_at" DESC LIMIT 10
```

So a typo is a build error instead of a 500 at 3am:

```
$ zig build
error: nilo: User has no column `agee`, asked for in a condition.
       Did you mean `age`?
```

**The same struct also makes the table, and diffs it.** `createMissing` creates every table a list of Rows describes:

```zig
try sql.migrate.createMissing(&db, &run, &.{ Org, User });
```

For a schema that changes, your project gets a `db` command out of a `main` of
ten lines:

```console
$ db check                       # do the Rows and the migrations agree?
$ db generate --name add_nickname
$ db migrate
```

`generate` and `check` **open no database**: your types on one side, a
snapshot kept in git on the other, so CI needs no service container. A rename
is written in the type (`.was = .{ .email = "e_mail" }`) rather than guessed
from the diff. There is no `down`, and
[ADR 0153](./docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md) is the
reasoning.

Every word in the marker is checked while compiling, `.references` hardest:

```
$ zig build
error: nilo: User.org_id is []const u8 and points at Org.id, which is i64.
         Two sides of a foreign key hold the same value, so they are the same
         type. One of the two is wrong about its column.
```

Postgres and SQLite, written the same way. It is not an ORM and won't turn into
one: no change tracking, no lazy relations, no identity map. Joins and
aggregates go through `db.raw`, which still fills your struct and still counts
the `SELECT` list against it while compiling
([ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

### Your settings are a struct too

```zig
const Settings = struct {
    port: u16 = 8080,                  // a default means "not set is fine"
    database_url: []const u8,          // no default means required
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

const read = config.fromEnv(Settings, init.minimal.environ);
const settings = read.value() orelse {
    try read.report(stderr);
    std.process.exit(2);
};
```

`database_url` is read from `DATABASE_URL`. Three wrong settings come back as
three lines at once, not one per redeploy:

```
3 settings could not be read from the environment:
  PORT has to be a whole number, not "soon"
  DATABASE_URL is not set
  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
```

### Passwords are a value

<!-- compiles: body -->
```zig
// signing up
const stored = try c.hashPassword(gpa, form.password.view());
_ = try db.insert(User, c, .{ .email = form.email, .password = stored.text() });

// signing in
const row = try db.one(User, c, .{ .where = .{ .email = form.email } });
if (!try c.verifyPassword(gpa, if (row) |r| r.password.view() else null, form.password.view()))
    return nilo.fail.unauthorized("that is not a sign-in", .{});
```

argon2id, stored as a PHC string any other library can read. One hash costs
13ms and 19 MiB, so the method lives on `c`: it moves the work off the event
loop and lets only eight run at a time. And `stored` is optional on purpose —
an email with no account does the hashing anyway, because answering in one
millisecond instead of thirty would turn your login form into a list of who has
an account.

### Three modules, agreeing

`nilo_sql` never imports `nilo_http`. But `db.one(...)` returns `?User`, a
handler returning `!?User` answers 404, and the OpenAPI document says so. Three
pieces of the toolkit agree without talking to each other, because all three
read the same struct you wrote. Nothing here is glued together at runtime.

## 📏 What it costs

Most frameworks say "fast" and "lightweight". Here are numbers instead.

| | |
|---|---|
| **1 allocation** | per request. A test fails if it ever becomes 2 |
| **4,669 bytes** | per idle connection, for the framework. Flat from 1,000 to 10,000. An idle WebSocket is 5,183. A handler adds the stack it touches ([ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md), [ADR 0071](./docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)) |
| **69µs** | p99 under load: 9.4× below Go's `net/http`, 11× below Fiber |
| **5.4 MB** | idle server |
| **1,401,412 req/s** | on four physical cores, and the least interesting number on this page |

Against eight other servers on the same machine, every candidate returning the
**same 982 bytes** of JSON, verified byte for byte
([`docs/comparison.md`](./docs/comparison.md)):

| | Where nilo lands |
|---|---|
| Throughput | 1st of 9, and inside the noise of http.zig |
| p99 under equal load | 2nd of 9, and 3–45× ahead of everything outside the top two |
| CPU per request | 2nd of 9 |
| Memory, idle server | 2nd of 9, at 5.4 MB |
| Memory per connection | 3rd of 9, and it was 7th before this measurement got the code changed |
| Warm rebuild, release | **last of the five compiled languages**, at 7.4s |

The last row is the honest one. Throughput is the least interesting because
[the benchmarks page says so itself](./bench/result/http.md): at this payload
nilo's own code is about 4% of a request's CPU. The tail latency is a result,
and so is the build time, against us.

### Binary size, and how the trade-offs get made

Zig doesn't compile what nothing imports, so an HTTP-only project pays **zero
bytes** for `nilo_sql` and downloads no database driver either — the drivers sit
behind `.sql = true`, and `zig build fetch-check -Dnetwork` fails if anything
but zio lands ([ADR 0075](./docs/adr/0075-a-lazy-dependency-is-a-request.md)).
A stripped `ReleaseFast` program naming only the Postgres driver is
**1,785,640 bytes**; the same with SQLite is **2,291,696**, and the difference
is the amalgamation ([`bench/result/sql.md`](./bench/result/sql.md)).

That trade runs on four axes, not one
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| Axis | The rule |
|---|---|
| Throughput and p99 | a nicer API wins if it costs under 10% |
| Allocations per request | fixed. Currently 1, held by a test |
| Memory per idle connection | fixed. Every feature states its own cost |
| Binary size | anything the linker can't drop states its measured cost |

Response compression is what "doesn't ship in a worse shape" looks like in
practice: the shape that would fit is known, it hasn't been built, and no
allocate-per-request version shipped in the meantime.

## 🙂 What happens when you get it wrong

An error message is a feature right up until somebody refactors it into mush.
So this repository has **283 programs that are supposed to fail to compile**,
and seven build steps checking the wording of every failure:

| Step | Programs | Over |
|---|---|---|
| `zig build refusals` | 137 | the framework |
| `zig build refusals-sql` | 105 | queries, rows and schemas |
| `zig build refusals-job` | 14 | jobs and schedules |
| `zig build refusals-s3` | 10 | buckets and keys |
| `zig build refusals-config` | 9 | settings |
| `zig build refusals-cache` | 5 | cached values |
| `zig build refusals-pw` | 3 | passwords |

Every one says what you did *and* what to do about it:

```
$ zig build
error: nilo: route "/users/:user/pets/:pet" has 2 path params (:user, :pet), but its handler only takes 1.
       Path params are matched by position, so the ones at the end would never be read.
       Add the arguments (`id: u32`, `name: nilo.Str`, …), drop the unused `:` from the
       pattern, or ask for a `*Ctx` if you would rather fetch them yourself with `c.param("…")`.
```

### And the two places a compiler can't reach

**At startup, before a single request is served** — a route registered twice,
a service nobody provided:

```
error: the route "GET /users/:name" answers the same requests as "/users/:id", which is
       already registered — whichever came second would never run. Drop one, or give them
       different paths.

error: service *Db was never registered, but 3 routes need it ("/users/:id", "/users",
       "/users/:id/orders") — call app.provide() before app.listen()
```

**While running.** Holding request data past its request is trapped in a Debug
build, and a handler that blocks the thread its neighbours share is timed and
named in the log, in any build:

```
panic: Str used after its request finished. Request data dies with the request; copy it
       with .keep() while the handler is still running if you need to hold on to it.

warning: handler GET /report held its thread for 412ms. Every other request being served
         on that thread waited the whole time. Hand the call that waits to
         nilo.blocking (ADR 0014).
```

**This is also why agents do well here.** A model needs a surface small enough
to hold at once, no ordering to infer, and a build that says what's wrong
instead of a server that starts anyway — the same list a person in a hurry
needs. Point one at [`docs/reference.md`](./docs/reference.md) and
[`CONTEXT.md`](./CONTEXT.md); both together are small enough to hand over
whole, and the running server serves its own contract at `/openapi.json`.

## 🚫 What it won't do

| | Why, and where to go instead |
|---|---|
| **Templates** | rendering means a string per request, which is an allocation per request, and that number is fixed. If your app's job is HTML, [jetzig](https://www.jetzig.dev/) is built for it |
| **TLS**, and so HTTP/2 and gRPC | terminate it in front. The [deploying guide](./docs/guide/deploying.md#tls-and-the-proxy-in-front) has the five lines ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)) |
| **Revoking a session** | `Session(T)` is sealed into the cookie, so there is no table, no sweep, and no way to revoke one ([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)) |
| **Parsing config files** | `nilo_config` reads the environment; a TOML parser taxes every project that imports the module ([ADR 0043](./docs/adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)) |

None of these are gaps. Each has an ADR naming the alternative it lost to, so if
you think a decision is wrong there's something specific to argue with.

## 🧪 Examples

Nine runnable examples live in [`examples/`](./examples/), and their tests run
in the same suite:

```console
$ zig build run-hello      # the smallest thing that serves
$ zig build run-rest       # a service: JSON in and out, query params, auth middleware
$ zig build run-orders     # the same ideas on a domain that is not one flat struct
$ zig build run-forms      # an HTML form, a session cookie, an upload and a redirect
$ zig build run-spa        # a single-page app's files next to its API
$ zig build run-stream     # a streamed report, an event stream, an upload
$ zig build run-chat       # a WebSocket, browser page included
$ zig build run-scheduled  # work that is not a request, owned by the server
$ zig build run-outbound   # calling somebody else's API from inside a handler
```

Read **`rest`** first, **`orders`** when you hit "yes, but what about…", and
**`forms`** if you're building a web page rather than an API.

## 📚 Documentation

**[The guide](./docs/guide/)** is one page per thing you might want to do, in
the order you'd meet them — handlers, routing, requests, forms, responses,
sessions, streaming, WebSocket, middleware, services, errors, settings,
background work, then one page per module
([nine](./docs/guide/sql/README.md) for the database), then testing, OpenAPI,
metrics, deploying.

| | |
|---|---|
| [`docs/reference.md`](./docs/reference.md) | the entire API surface on one page |
| [`docs/adr/`](./docs/adr/) | 207 decisions, each naming the alternative it rejected |
| [`CONTEXT.md`](./CONTEXT.md) | the vocabulary, and the words this project refuses to use |
| [`docs/roadmap.md`](./docs/roadmap.md) | what's next, what's refused, what's undecided |
| [`docs/history.md`](./docs/history.md) | what got measured, and what turned out to be wrong |
| [`docs/comparison.md`](./docs/comparison.md) | how this sits next to the other Zig options |
| [`bench/result/`](./bench/result/) | every benchmark run, and what each one changed |

## 🤝 Contributing

This is one person's toolkit so far, and it's built to stop being one.
Questions, issues and "why on earth is it like this?" are all welcome — if the
answer isn't already written down somewhere, that's the bug.

Nothing load-bearing lives only in my head: every decision has a file in
[`docs/adr/`](./docs/adr/), the rules are build steps (`zig build layering`,
`zig build refusals`) rather than review comments, and the roadmap is one list
per module so two people can work at once without a merge to negotiate.
**[CONTRIBUTING.md](./CONTRIBUTING.md)** has what a change has to carry, where
to start, and how to point an agent at this.

**Where the ideas came from:** FastAPI, for the signature being the whole
contract. Elysia, for resolved values and plugins. nginx and TigerBeetle, for
putting numbers on memory. Elm, for deciding error messages were worth the work.
Drizzle, for the shape of the query.
[ADR 0015](./docs/adr/0015-what-nilo-borrows-and-from-whom.md) says who gets
credit for what.

## License

MIT. See [LICENSE](./LICENSE).
