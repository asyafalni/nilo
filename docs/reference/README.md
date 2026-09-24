# Reference

The whole surface, as a list: one page a module, and seven for the server.
For what any of it is *for*, see [the guide](../guide/); for a name, the
[list of every heading](#every-heading) at the bottom of this page.

## The modules

Eleven ship, and a project links only what it imports
([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)).

| | | |
|---|---|---|
| `nilo_http` | the server — the seven pages before the modules, below | [`app.md`](./app.md) first |
| `nilo_sql` | Postgres and [SQLite](./sql.md#sqlite) | [`sql.md`](./sql.md) |
| `nilo_s3` | object storage — S3, MinIO, R2, anything that speaks it | [`s3.md`](./s3.md) |
| `nilo_id` | UUIDs | [`id.md`](./id.md) |
| `nilo_config` | settings out of the environment | [`config.md`](./config.md) |
| `nilo_pw` | password hashing | [`pw.md`](./pw.md) |
| `nilo_cache` | an expiring cache in this process | [`cache.md`](./cache.md) |
| `nilo_jwt` | checking somebody else's signed token | [`jwt.md`](./jwt.md) |
| `nilo_fetch` | calling somebody else's HTTP API | [`fetch.md`](./fetch.md) |
| `nilo_job` | work that runs later, again, or on a schedule — a queue in your database | [`job.md`](./job.md) |
| `nilo_core` | `Str`, the [Scope](./core.md#scope) and [percent coding](./core.md#nilo_corepercent), shared by the rest | [`core.md`](./core.md) |

```zig
const nilo = @import("nilo_http");    // the alias everybody writes
const sql = @import("nilo_sql");      // only if you talk to Postgres or SQLite
const s3 = @import("nilo_s3");        // only if you store objects
const id = @import("nilo_id");        // only if you make identifiers
const config = @import("nilo_config");// only if you read settings
const pw = @import("nilo_pw");        // only if you hash passwords or mint a token
const cache = @import("nilo_cache");  // only if you cache something
const jwt = @import("nilo_jwt");      // only if you verify somebody else's tokens
const job = @import("nilo_job");      // only if some work runs later, or on a schedule
```

**There is no module called `nilo`.** The word names the project — the `nilo: `
prefix on every Refusal, and the `nilo_table` / `nilo_resolve` / `nilo_start`
markers that go in your own structs. Nothing re-exports the others, because an
umbrella module would cost every project the bytes of every module.

`nilo_http` re-exports what it needs from `nilo_core`, so `nilo.Str` and
`nilo.Run` are the same declarations `nilo_core` holds. A program with no server
in it imports `nilo_core` directly and links no router and no event loop.

## Root wiring

```zig
pub const std_options = nilo.std_options;         // engine chatter → warnings
pub const std_options_debug_io = nilo.debug_io;   // std.log off the event loop
pub const panic = nilo.panic;                     // optional: name the request in a crash
```

## Every heading

One page at a time, in the order the single page had them, with every
section on it. A name is found here first and read on its page.

**[The App](./app.md)** — the App and its groups, what `listen()` takes, the loop, and the options behind `static` and the OpenAPI document.

- [`App`](./app.md#app)
  - [`Group`](./app.md#group)
  - [`listen` options](./app.md#listen-options)
  - [`metrics` options](./app.md#metrics-options)
  - [`compress` options](./app.md#compress-options)
- [Concurrency](./app.md#concurrency)
- [Static options](./app.md#static-options)
- [OpenAPI options](./app.md#openapi-options)
  - [The document without a server](./app.md#the-document-without-a-server)

**[Handlers](./handlers.md)** — what a handler's arguments mean, what it may return, and how JSON is shaped.

- [Handler arguments](./handlers.md#handler-arguments)
  - [`FromHeader(name, T)`](./handlers.md#fromheadername-t)
  - [`Authorization(scheme)`](./handlers.md#authorizationscheme)
  - [`Verified(V)`](./handlers.md#verifiedv)
  - [`Idempotent(Replays, options)`](./handlers.md#idempotentreplays-options)
  - [`Cached(Pages, options)`](./handlers.md#cachedpages-options)
  - [A query field that is a list](./handlers.md#a-query-field-that-is-a-list)
  - [`Bound(W)`](./handlers.md#boundw)
- [Handler returns](./handlers.md#handler-returns)
  - [A type that writes its own answer](./handlers.md#a-type-that-writes-its-own-answer)
- [JSON shapes](./handlers.md#json-shapes)
  - [A struct that renames its fields](./handlers.md#a-struct-that-renames-its-fields)

**[The request](./ctx.md)** — one request in flight: reading it, answering it, its cookie, session and uploads, and failing it.

- [`Ctx`](./ctx.md#ctx)
  - [Reading](./ctx.md#reading)
  - [Answering](./ctx.md#answering)
- [`Cookie`](./ctx.md#cookie)
- [`Session(T)`](./ctx.md#sessiont)
- [`Upload`](./ctx.md#upload)
- [Failing](./ctx.md#failing)

**[Core](./core.md)** — `Str`, `Run`, the Scope, percent coding and the clock: `nilo_core`, which the rest share.

- [`Str`](./core.md#str)
- [`Run`](./core.md#run)
  - [A value that reaches the bottom](./core.md#a-value-that-reaches-the-bottom)
- [Scope](./core.md#scope)
  - [`AnyScope`](./core.md#anyscope)
- [`nilo_core.percent`](./core.md#nilo_corepercent)
- [What time it is](./core.md#what-time-it-is)

**[Streaming](./streaming.md)** — a directory, a stream, events, a body read in pieces, a socket and a room.

- [`Dir`](./streaming.md#dir)
- [`Stream`](./streaming.md#stream)
- [`Events`](./streaming.md#events)
- [`Body`](./streaming.md#body)
- [`Socket`](./streaming.md#socket)
- [`Room`](./streaming.md#room)

**[Middleware](./middleware.md)** — the built-in middleware, and `nilo.accept`.

- [Built-in middleware](./middleware.md#built-in-middleware)
  - [`nilo.allowance`](./middleware.md#niloallowance)
- [`allowance.keyed` — counted against something the application knows](./middleware.md#allowancekeyed--counted-against-something-the-application-knows)
  - [`nilo.deadline`](./middleware.md#nilodeadline)
  - [`nilo.maxBody`](./middleware.md#nilomaxbody)
- [`nilo.accept`](./middleware.md#niloaccept)

**[Testing](./testing.md)** — an App and a Client wired together, with no socket.

- [Testing](./testing.md#testing)
  - [An App and a Client, wired together](./testing.md#an-app-and-a-client-wired-together)
  - [A failed assertion that can be read](./testing.md#a-failed-assertion-that-can-be-read)
  - [Catching a refusal with no request in flight](./testing.md#catching-a-refusal-with-no-request-in-flight)

**[nilo_sql](./sql.md)** — Postgres and SQLite: a Row, a Db, queries, a Tx, migrations.

- [`nilo_sql`](./sql.md#nilo_sql)
  - [A Row](./sql.md#a-row)
- [A Row that owns no table](./sql.md#a-row-that-owns-no-table)
- [A field beside the columns](./sql.md#a-field-beside-the-columns)
  - [`Db`](./sql.md#db)
  - [SQLite](./sql.md#sqlite)
  - [Queries](./sql.md#queries)
  - [A batch](./sql.md#a-batch)
  - [Upserts](./sql.md#upserts)
  - [Options](./sql.md#options)
  - [Conditions](./sql.md#conditions)
  - [An order chosen at run time](./sql.md#an-order-chosen-at-run-time)
  - [A row in another table](./sql.md#a-row-in-another-table)
  - [A key of several columns](./sql.md#a-key-of-several-columns)
  - [A parent, children, a group](./sql.md#a-parent-children-a-group)
  - [Streaming](./sql.md#streaming)
  - [`Tx`](./sql.md#tx)
- [Holding the rows a read matched](./sql.md#holding-the-rows-a-read-matched)
- [Savepoints](./sql.md#savepoints)
  - [Types](./sql.md#types)
- [A column type of your own](./sql.md#a-column-type-of-your-own)
  - [Errors](./sql.md#errors)
  - [Migrations](./sql.md#migrations)
- [The schema](./sql.md#the-schema)
- [Creating tables](./sql.md#creating-tables)
- [The diff](./sql.md#the-diff)
- [The ledger, and applying](./sql.md#the-ledger-and-applying)
- [Refusing to serve a database that is behind](./sql.md#refusing-to-serve-a-database-that-is-behind)
- [The files](./sql.md#the-files)
- [The commands](./sql.md#the-commands)
- [Starting a migrations directory](./sql.md#starting-a-migrations-directory)

**[nilo_s3](./s3.md)** — object storage.

- [`nilo_s3`](./s3.md#nilo_s3)

**[nilo_fetch](./fetch.md)** — calling somebody else's HTTP API.

- [`nilo_fetch`](./fetch.md#nilo_fetch)
  - [`fetch.Target`](./fetch.md#fetchtarget)
  - [`fetch.Exchange`](./fetch.md#fetchexchange)
  - [`fetch.testing`](./fetch.md#fetchtesting)

**[nilo_job](./job.md)** — work that runs later, again, or on a schedule.

- [`nilo_job`](./job.md#nilo_job)

**[nilo_id](./id.md)** — UUIDs.

- [`nilo_id`](./id.md#nilo_id)

**[nilo_config](./config.md)** — settings out of the environment.

- [`nilo_config`](./config.md#nilo_config)
  - [A `.env`](./config.md#a-env)

**[nilo_pw](./pw.md)** — password hashing.

- [`nilo_pw`](./pw.md#nilo_pw)
  - [A token that is not a password](./pw.md#a-token-that-is-not-a-password)

**[nilo_cache](./cache.md)** — an expiring cache in this process.

- [`nilo_cache`](./cache.md#nilo_cache)

**[nilo_jwt](./jwt.md)** — checking somebody else's signed token.

- [`nilo_jwt`](./jwt.md#nilo_jwt)
  - [`jwt.Keyring`](./jwt.md#jwtkeyring)
  - [`jwt.Verifier(Claims, Client)`](./jwt.md#jwtverifierclaims-client)
