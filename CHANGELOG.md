# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

**0.6.0 is the release that reads what is already here, and what the first
application built on 0.5.0 sent back.** `http/` was scanned line by line for
what a stranger on the socket can make it do; what the scan found lands under
`### Fixed` below as it is fixed, and what it found and cannot hold goes to
[`docs/risks.md`](./docs/risks.md). The server then took what the benchmark
arena asked of it: every executor accepts, and a response is flushed before
the connection waits rather than on every `send`. And a SQLite application
built against the guide reported eight things the guide showed working on
the other database or in the other order, which is where the schema check
moving after the boot work, `$n` respelled for the dialect, `rawPage`,
`rawExactlyOne` and `examples/sqlite/` come from. Still to do in it: the
public surface read back against the reference before 1.0 freezes it, and
the ADRs that only correct an older one folded into the one they correct.

Work lands here under `### Breaking`, `### Added`, `### Fixed` and `### Docs`,
newest first.

### Breaking

- `Store.claim` takes the kinds the program can run: `claim(scope, comptime
  kinds: []const []const u8, now, lease_until)`. `job.Jobs` passes its own
  `kind_names`; a store written outside nilo takes the parameter and narrows
  its claim by it. The names are bound, not spelled into the statement, so a
  kind may go on being named whatever it is named
  ([ADR 0291](./docs/adr/0291-a-worker-claims-only-what-it-can-run.md)).

- `nilo_jobs` gains a `priority smallint NOT NULL DEFAULT 1` column.
  `job.Table` creates nothing, so a caller adds it beside their own rows:

      ALTER TABLE nilo_jobs ADD COLUMN priority smallint NOT NULL DEFAULT 1;

  The default is not decoration. A column that may not be null and has no
  default is the one `ADD COLUMN` that fails on a table with rows, and during
  a rolling deploy an older binary's `INSERT` — or a sibling binary's, which
  is [ADR 0291](./docs/adr/0291-a-worker-claims-only-what-it-can-run.md)'s own
  case — never names the column. `createMissing` will not help here: it
  creates tables that are missing and leaves an existing one alone. A queue
  that has not been altered is not subtly wrong — the claim names the column,
  so it fails loudly on the first claim rather than quietly ordering by
  something else. The index stays `(state, run_at)`; widening it to include
  `priority` measured 120x slower on a queue holding future-dated rows, which
  is `bench/result/job.md` ([ADR 0290](./docs/adr/0290-a-job-says-how-urgent-it-is.md)).

- A `Db`'s schema check and version guard run from a new service hook,
  `nilo_check`, which the App calls after the work `app.before` registered
  and before the first request; `nilo_start` opens the pool and nothing
  more. Under an App nothing changes but the order, which is the fix: a
  first boot with `createMissing` in `before` and `db.checking(schema)`
  beside it used to fail on the tables the next line would have made. A
  program driving a `Db` with no App and relying on `nilo_start` to check
  calls `db.nilo_check(io)` after its own boot work, or `db.checkSchema`
  ([ADR 0277](./docs/adr/0277-the-schema-check-runs-after-the-boot-work.md)).
- `app.start(io)` runs the work `before` registered, and every `nilo_check`
  after it, which its doc comment already promised. A test that registered
  `createMissing` with `before` and then made the tables itself makes them
  twice, harmlessly (same ADR).
- `static.load` takes a fifth argument, `Absent`, saying whether a
  directory that is not there is reported in one line or handed back
  alone. Only a caller of the module directly sees it; the four `static`
  calls on the App pass it
  ([ADR 0282](./docs/adr/0282-a-try-call-hands-back-the-error-and-says-nothing.md)).
- `?nilo.Status(code, T)`, `?nilo.Response(T)`, `?nilo.Redirect(code)` and
  `?nilo.Versioned(T)` as a handler's return type are compile errors naming
  the shape to write. The first two compiled and sent the wrapper struct
  itself as JSON, `headers` and all, then crashed; the `?` goes inside,
  `Status(201, ?T)`
  ([ADR 0276](./docs/adr/0276-a-question-mark-goes-inside-the-wrapper.md)).
- `read_buffer` defaults to 16 KiB, up from 8. It is also the ceiling on a
  request head, and 8 KiB was inside what a browser behind a single sign-on
  sends in cookies on every request. An idle connection holds the same 4,669
  bytes — the pages go back while it waits (ADR 0071) — and a connection
  inside a request holds two pages more. A server that wants the old number
  passes `.read_buffer = 8 * 1024`
  ([ADR 0268](./docs/adr/0268-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)).

### Added

- `pub const priority: job.Priority = .high;` on a job kind, beside its
  `timeout_ms`: a free worker takes the most urgent **due** row, and among
  equals the one that has been due longest. `.high`, `.normal` (the default,
  and what every existing kind gets) and `.low`. The case it came from is a
  queue where a model backfill running for minutes stood in front of the
  cache revalidations a person was waiting on — not because the machine was
  busy, but because the backfill was *in front*. Per kind rather than per
  push, because how urgent a kind is belongs to the kind; three levels
  rather than a number, because `2` says nothing about whether it beats `1`,
  and a kind that writes one is a Refusal naming the levels
  ([ADR 0290](./docs/adr/0290-a-job-says-how-urgent-it-is.md)).

- `listen(.{ .also = &.{ .{ .port = 8081, .tls = … } } })`: more addresses
  to answer on, from one process. An entry is an address, a port and a
  certificate and nothing else; everything else on `listen()` belongs to
  the server rather than to one of its addresses, and `max_connections`
  counts the sockets this process holds rather than the sockets a port
  holds. One route table, one thread pool, and a handler is not told which
  listener a request arrived on. A cleartext port beside a TLS one is what
  it is for. Two entries naming one address are refused at `listen()`
  naming both, rather than arriving as the kernel's `AddressInUse`.
  `boundPort()` still answers for `port`, the first listener. Costs 82 KB
  of resident memory per extra listener on sixteen threads and nothing per
  connection: an idle connection measured 9,300 bytes before and after
  ([ADR 0289](./docs/adr/0289-a-server-answers-on-more-than-one-address.md),
  [deploying](./docs/guide/deploying.md#more-than-one-address)).
- `listen(.{ .tls = .{ .cert = "…pem", .key = "…pem" } })`: HTTPS, TLS 1.3, on a build that asked for it with `.tls = true` on the dependency (`-Dtls` in this repository). The library behind it, ianic/tls.zig, is fetched and linked only behind that flag, so every other build is what it was, and refuses the option at `listen()` in one line rather than serving plain HTTP on the port. What it costs is stated where the option is: 560 KB of binary and a page per idle connection in the build that asked, about 300 µs of CPU per handshake with an ECDSA certificate and 2.6 ms with an RSA-2048 one, no session resumption, one certificate per listener, a restart to reload it, and no audit behind the library, which is why a proxy in front stays the recommendation for anything on the internet ([ADR 0288](./docs/adr/0288-tls-is-an-option-a-build-asks-for.md), amending ADR 0028; [deploying](./docs/guide/deploying.md#tls-without-a-proxy)). The handshake is bounded by `header_timeout_ms`. `zig build bench-tls-server -Dtls` and `bench/mem.py --tls` are the benchmark server and the idle reading for it. Until [ianic/tls.zig#59](https://github.com/ianic/tls.zig/pull/59) merges, the library is pinned to a fork that adds one commit to upstream's `zig-0.16.x`: it signs through the key's CRT form, which takes an RSA-2048 handshake from 13.7 ms of CPU to 2.6 ([the run](./bench/result/http.md#what-an-rsa-certificate-costs-a-handshake)).
- `app.compress(.{})`: every answer that is text, at least `min_bytes`
  (1 KB) long and going to a client whose `Accept-Encoding` takes gzip goes
  out gzipped, per request, with `Content-Encoding: gzip`, `Vary:
  Accept-Encoding` and the compressed length; a client that did not ask
  gets the body as it is. `level` is `.fastest`, `.default` or `.best`. The
  compressor is borrowed from a pool of one per thread, `~288 KB` each,
  built when the chains are resolved; a compressed request pays one arena
  allocation for the compressed body and nothing per connection. Streams,
  event streams and static files are not touched: files were gzipped once
  at load. `nilo.compress.Options`, `zig build bench-compress`
  ([ADR 0287](./docs/adr/0287-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).
- `sql.Composed`, `db.compose` and `db.composed` / `db.composedOne` /
  `tx.composed`: a statement composed at run time from literals, checked
  identifiers and parameters — the pieces a query engine has — and from
  nothing that can carry a run-time string. Placeholders are spelled for the
  Db's dialect; the values are counted against them at run time. `raw` is
  unchanged
  ([ADR 0283](./docs/adr/0283-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)).
- `run.loop()`: the `Io` a `Run` was made on, or null for a `Run.init(gpa)`,
  for a job that writes a file or sleeps between attempts and has only the
  Run the worker handed it.
- `jwt.Keyring` takes `remember_tokens`: how many verified tokens to
  remember by digest, so a bearer token seen again skips the signature
  arithmetic and keeps every claims check. A new key set forgets them
  ([ADR 0285](./docs/adr/0285-a-verified-signature-is-remembered-by-the-tokens-digest.md)).
- `examples/sqlite/`: two Rows on one SQLite file, the tables made at boot
  with `createMissing` in `before` and checked after, a list with a
  `Query`, a paged join through `rawPage`, a report through
  `rawExactlyOne` and `raw`, and a transaction. `zig build run-sqlite`;
  its tests run under `test-sql`.
- A service may declare `pub fn nilo_check(self: *T, io: std.Io) !void`,
  run once after `before` and before the first request; a failure is a
  boot that does not happen. A wrong arity is a Refusal
  ([ADR 0277](./docs/adr/0277-the-schema-check-runs-after-the-boot-work.md)).
- `db.rawPage(Row, c, sql, values)` and `tx.rawPage`: a raw statement read
  as a page, the Row's columns then `count(*) OVER ()` as one more on the
  end of the list, answering the same `Page(Row)` `db.page` does. A list
  exactly the Row's width is a Refusal
  ([ADR 0279](./docs/adr/0279-a-raw-statement-can-carry-its-total.md)).
- `db.rawExactlyOne(Row, c, sql, values)` and `tx.rawExactlyOne`: `rawOne`
  for a statement that has one row by construction, an aggregate with no
  `GROUP BY` or a `RETURNING` on a keyed write, answering the Row and
  `error.QueryFailed` for none
  ([ADR 0280](./docs/adr/0280-a-statement-that-always-answers-answers-a-row.md)).
- The `$n` in a raw statement are respelled for the dialect while
  compiling, `?n` on SQLite, so `WHERE ($2 IS NULL OR x = $2)` binds the
  second value on both databases; SQLite read `$2` as a named parameter
  indexed by first appearance and took the first. A statement naming `$3`
  and handed two values is a Refusal on both. `exec` sends its run-time
  text as written
  ([ADR 0278](./docs/adr/0278-a-raw-placeholder-is-spelled-for-the-dialect.md)).
- `app.health` and `app.metrics` describe the routes they register, a
  `200` each, and are no longer counted in the "N of M routes hold the Ctx
  and return nothing" line, which is about the application's handlers
  ([ADR 0281](./docs/adr/0281-nilos-own-routes-describe-themselves.md)).
- nilo's HttpArena entry subscribes to `echo-ws-pipeline`
  and `echo-ws-limited`, each held back until the server was right for it:
  the first waited on ADR 0274, the second on ADR 0273 and then ADR 0275,
  because the first of those alone had made the shape three times worse
  ([frameworks/nilo](https://github.com/MDA2AV/HttpArena/tree/main/frameworks/nilo)).
- A response is flushed before the connection waits, not before `send`
  returns. When the client's next request is already in the read buffer,
  `c.send` leaves the response in the write buffer and it goes out with
  the next one, so sixteen pipelined requests are answered in one write
  rather than sixteen; a client that sends one request and waits, which
  is every browser and every client by default, is answered on `send`
  exactly as before. The same for a WebSocket's `send`, `print` and
  `json`, and a room's posts. The Engine guarantees the hold is never for
  good: every socket read flushes what is pending first, the WebSocket's
  wait does too, and a closing connection flushes before its FIN. Sixteen
  pipelined `/health` on eight cores: 3.05M → 12.3–13.6M req/s, p99
  1.8 ms → 370 µs; sixteen pipelined echoes: 3.6M → 37M messages a second.
  Keep-alive and one-frame-at-a-time shapes are unchanged. What a
  pipelining client gives up is that a fast answer queued behind a slow
  handler now arrives with the slow one, bounded by `write_buffer`
  ([ADR 0274](./docs/adr/0274-a-response-is-flushed-before-the-connection-waits.md)).
- Every executor accepts. `listen()` used to take connections on one fiber,
  which capped a server at ~43,000 connections a second whatever its thread
  count — the arena's short-lived profile read 426K req/s on 18 of 64 cores,
  with a p99 that was the backlog divided by that rate. Now one acceptor sits
  in `accept` on each executor and the connection is dealt round-robin as
  before. Connections closed after ten requests: 660K → 1.97M req/s on eight
  cores, p99 8.2 ms → 1.5 ms; keep-alive throughput unchanged. One parked
  fiber per thread for the life of the server, nothing per connection, and
  one timer per server fewer per connection accepted. Nothing changes in
  what `listen()` takes
  ([ADR 0273](./docs/adr/0273-every-executor-accepts.md)).
- `listen()` takes `backlog`: how many completed handshakes the kernel holds
  for `accept`. 4,096 — `net.core.somaxconn`'s default, what Go listens with —
  up from zio's 128, which nilo had been passing without saying so. Past the
  backlog a SYN is dropped, not refused, and the client retries a second
  later with nothing in the server's log: a burst of a thousand connections
  against 128 put 623 of them on that one-second retry, against 4,096 none.
  A queue capacity, so it costs nothing on a quiet server. `bench/burst.py`
  is the regression check
  ([ADR 0271](./docs/adr/0271-a-backlog-is-sized-for-the-burst-not-the-load.md)).
- `app.failures(T)`: the body every failure goes out with, when nilo's
  `{"error":…,"status":…}` is not the one your clients already read. `T` is a
  struct whose fields are the JSON, with a `pub fn nilo_failure(status: u16,
  message: []const u8) T` that fills it; nilo writes it with the JSON writer a
  handler's answer goes through, and the API description's `Failure` schema
  comes from the same fields. A fail function's sentence, the 404 and 405
  nilo answers itself, a 401's challenge, a 405's `Allow` and the CORS
  headers all survive it. The five answers written before there is a
  request to route — a malformed head, a head too long or too slow, an
  unreadable coding, a shed 503 — keep nilo's own. Nothing changes for an
  App that does not call it. Three refusals
  ([ADR 0270](./docs/adr/0270-a-failure-body-is-a-struct-the-application-names.md)).
- Every response carries a `Date`, second after the status line — RFC 9110
  §6.6.1's MUST, which nilo had never met, and what a cache in front does its
  freshness arithmetic from. Formatted once a second per thread, lazily, from
  `nilo_core`'s clock; no task, no atomic, no allocation. A `Date` a handler
  sets wins. In the same head, `Connection: keep-alive` is no longer written
  on an HTTP/1.1 response — persistence is what HTTP/1.1 means, and the line
  is now written only when it says something: `keep-alive` to an HTTP/1.0
  client being kept, `close` to anybody being closed. The benchmark
  response goes from 1,110 bytes on the wire to 1,123, which is what every
  other server in `bench/compare/` sends for the same body. `Ctx.connection()`
  is the new way to ask; `Ctx.keepAlive()` still answers the bool
  ([ADR 0269](./docs/adr/0269-a-response-says-when-it-was-sent.md)).
- `listen()` takes `request_deadline_ms`: a deadline every request starts
  with, what `nilo.deadline(ms)` gives one route given to all of them. Every
  wait nilo owns is cut to it and `c.overdue()` reads it; a route's own
  `nilo.deadline` replaces it, and a request that takes the connection over —
  a stream, a WebSocket, `bodyStream()` — lets a default go and keeps a
  route's own. Off by default. ADR 0133 had rejected the option; ADR 0267
  is why it is back ([ADR 0267](./docs/adr/0267-a-deadline-every-request-starts-with.md)).
- The accept loop waits out a descriptor shortage instead of returning.
  `ProcessFdQuotaExceeded`, `SystemFdQuotaExceeded` and `SystemResources`
  from `accept` now sleep 5 ms, doubling to a second, and try again, with one
  warning per shortage; before, any of them ended `listen()` with a clean
  "nilo stopping" — at about a thousand connections on a default `ulimit -n`,
  well short of `max_connections`. `listen()` also warns at startup when the
  process's descriptor limit is below `max_connections`, with both numbers and
  the `ulimit -n` / `LimitNOFILE=` to change. `bench/fdlimit.py` is the
  regression check ([ADR 0265](./docs/adr/0265-an-accept-loop-that-is-out-of-descriptors-waits.md)).
- A refused request is hung up on with a FIN before the close, so its answer
  reaches the client. A 431, a 400 or 415 with a body behind it, a 413 for a
  body past `max_body`, a shed 503 — each left the client's bytes unread on
  the socket, and closing over unread input sends a reset, which a Windows
  client answers by throwing the buffered 431 away. The send side is shut
  first and what arrives is discarded, bounded at 64 KiB and one second. An
  ordinary `Connection: close` is untouched. The Engine contract gains
  `Waker.halfClose` ([ADR 0266](./docs/adr/0266-a-refused-request-is-hung-up-on-with-a-fin.md)).
- Every crafted request in the parser's tests — the framing conflicts, the
  strict chunk sizes, the absolute-form target, the head that never ends — is
  now also run split at every byte and trickled a few bytes a read, and has to
  come out identical to the same bytes arriving at once, down to where the
  next request starts. The parser's own tests only ever read from a buffer
  holding the whole input, so every seam that resumes across a read boundary
  was untested at exactly the boundary. `http/http1.zig`, one test.

### Docs

- [Getting started](./docs/guide/getting-started.md#what-a-save-has-to-touch) says what a save has to touch for `zig build dev` to restart the server: a `.zig` the binary is built from, or a file it `@embedFile`s, and nothing else in the checkout, so a front end kept beside the server keeps its own dev server. The static-files guide and `decided.md` said the loop could watch a bundler's directory; it cannot, and both now say so. `bench/devloop.py` is the check: a save the build never reads must leave the server up, a save it reads must restart it. The `dev` step on that page also gained the line that forwards `b.args`, without which the `zig build dev -- --incremental` beside it never reached `nilo-dev`.
- [Past one table](./docs/guide/sql/raw.md) says what a raw parameter may
  be (an optional binds NULL, and `($1 IS NULL OR …)` is the `sql.given`
  of raw SQL), has a section on reporting statements (`rawExactlyOne`,
  `raw` per group, `rawPage` for a paged join, dates per dialect) and one
  on what SQLite does differently. [SQLite](./docs/guide/sql/sqlite.md)
  has the `strftime(col / 1000000, 'unixepoch')` recipe a microsecond
  `Timestamp` needs.
- [Handlers](./docs/guide/handlers.md#where-the--goes) has the table of
  legal return shapes and the refused ones beside it. The `App` reference
  says which calls return an error and which return nothing.
- [Getting started](./docs/guide/getting-started.md#if-the-link-fails-on-sframe)
  and the README say what to pass when the native link fails at
  `crt1.o:.sframe` on a glibc built by GCC 16: `-Dtarget=x86_64-linux-gnu`
  or `-Dllvm`.
- [Static files](./docs/guide/static-files.md#while-you-are-working-on-it)
  says why `.reload` does not pick up a bundler's hashed filenames, and
  the two ways round it. [Writing](./docs/guide/sql/writing.md) says a `Str`
  column takes a literal, a `[]const u8`, a `[]u8` or a `Str` on insert.
- `Ctx.body()` says that a gzipped body comes back inflated while
  `header("Content-Encoding")` and `header("Content-Length")` still describe
  the wire, because the head is read in place and nothing rewrites it — and
  what a handler forwarding the body should send instead. ADR 0251 carries
  the same note.
- [Deploying](./docs/guide/deploying.md#when-a-bound-is-hit) has one table
  for every bound `listen()` takes: what a client sees past it, what the log
  says, and what has to happen before the server takes that work again. The
  prose under it was already there; the lookup was not.

### Fixed

- A fail function called by work registered with `app.before`, a seed calling the same service functions its handlers call, lost its sentence: the boot said `failed with Failed` and nothing else. The line that stops the boot now carries the status and the message, and which of the registered pieces failed, on both `listen()` and `app.start(io)` ([ADR 0161](./docs/adr/0161-a-refusal-outside-a-request-is-still-a-refusal.md)).
- `nilo-dev` started the binary left in `zig-out` before its build had finished, so after a change made with the loop stopped the old server ran first: one application had its SQLite file created and seeded with the schema it had just changed. The loop now builds once to the end before it starts anything, and when that build fails it removes the stale binary and starts the first one that compiles. Nothing changes in a dependent's `build.zig` ([ADR 0259](./docs/adr/0259-a-restart-on-save-watches-the-binary-not-the-sources.md)).
- A response type as wide as a detail page, a record holding lists of records of twelve fields or so, failed to compile inside `http/json.zig` with "evaluation exceeded 1000 backwards branches", whatever its depth, and the advice to raise the quota was not something the application could do. `covers` raises it where the walk starts, to 20,000, room for some 2,500 fields.
- **A worker spun forever on a job kind it did not know.** A row pushed by
  another binary — an older deploy, a sibling service — was claimed, found to
  be of an unknown kind, and handed back at the `run_at` it already had; so
  the same worker claimed it again on the next turn, forever. One such row
  left behind by a removed kind ran up **88 210 claim/release pairs**, kept a
  worker permanently busy and timed out `/health`. Worse than the spin: the
  claim counts an attempt, so a row nobody here could run was walking towards
  `dead` in the binary least able to judge it. The claim now asks only for the
  kinds the program knows, so the row is left queued, untouched and at nought
  attempts, for the binary that does know it
  ([ADR 0291](./docs/adr/0291-a-worker-claims-only-what-it-can-run.md)).

- Every binary with a static set in it, which is every binary with the
  API reader page, was 25 KB larger than it needed to be: the
  `Accept-Encoding` reader answered "is this `q=0`" with
  `std.fmt.parseFloat(f32, …)`. A digit scan now; `hello` is −24,608 bytes
  stripped, `rest` −3,648 ([ADR 0287](./docs/adr/0287-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).
- A `Db` on the default `connect_on_init = 0` dials one connection at boot
  whether or not it has a schema check, so `app.before` — a migration, a
  key set — finds a pool with something to lend. An `unchecked` `Db` with
  a `before` hook got `Disconnected` on every cold boot with the database
  up ([ADR 0284](./docs/adr/0284-a-boot-dials-the-connection-its-work-needs.md)).
- The comptime count of a `raw` select list stopped at `WITHIN GROUP`,
  reading its `GROUP` as `GROUP BY`, so `percentile_cont(0.5) WITHIN GROUP
  (ORDER BY v) AS median, count(*) AS n` counted as one column and the Row
  with two fields was refused. `GROUP` and `ORDER` end the list only with
  their `BY`.
- A database round trip over `block_warning_ms` no longer draws "handler
  held its thread": `core.Limits` gained `waiting`/`waited`, the Engine
  routes them to the watchdog, and the Postgres wire reports every
  statement through them, once from the exchange to the result's close. A
  handler that computes without parking is still reported
  ([ADR 0286](./docs/adr/0286-a-services-wait-on-its-own-socket-is-a-park.md)).

- `app.tryStatic` and `app.tryStaticWith` on a directory that is not there
  hand back `error.StaticDirNotFound` and log nothing; the `error:` line
  belonged to `static`, which stops the process on it. A problem inside a
  directory that is there is still said in one line, since the error
  cannot name the file
  ([ADR 0282](./docs/adr/0282-a-try-call-hands-back-the-error-and-says-nothing.md)).
- A WebSocket client that leaves with a reset rather than a FIN, which is
  every load generator that keeps its ports out of `TIME_WAIT` and every
  tab that was killed rather than closed, ends `receive` with `null` the
  way a FIN does, instead of `error.ReadFailed` and a warning per
  connection. The warning was one lock every connection queued on to
  leave; at 70,000 connections a second it held reset sockets open to
  `max_connections`, and the server began refusing at accept. 512
  WebSocket connections closed after ten frames each: 461K → 1.68M
  frames a second, descriptors mid-run 10,024 → 560
  ([ADR 0275](./docs/adr/0275-a-reset-between-frames-is-a-client-that-has-gone.md)).
- A server that is not busy spends a third less CPU per request. zio's
  scheduler dozes for 100 µs before each park so that work stealing does not
  churn, and on a thread with nothing coming that is a second context switch
  per request: 100 µs of CPU a request at 500 req/s on two threads, 70 with
  stealing off, and +3% at saturation. Stealing is now off, and a handler
  runs on one OS thread from its first line to its last, across every wait
  in it. `bench/paced.py` is the instrument
  ([ADR 0272](./docs/adr/0272-a-connection-is-served-by-the-thread-it-was-dealt-to.md)).
- `c.clientIp()` reads every `X-Forwarded-For` field, as one list in wire
  order, rather than the first. HAProxy's `option forwardfor` adds a field of
  its own instead of appending to the client's, so a forged header arrived as
  two fields with the forgery first — and with `.trusted_proxies` set, the
  walk started from the forgery and returned it. nginx appends, which is why
  the tests passed. Both the rules and `.trusted_hops` now walk
  `proxies.Forwarded`, from the last field's right end; more than eight
  fields is answered with the socket's address. No allocation
  ([ADR 0129](./docs/adr/0129-a-proxy-is-trusted-by-which-one-it-is.md), the
  closing section).
- A client that connects and gives up before the server reaches it in the
  backlog no longer stops the server. zio v0.17.0 surfaced that as
  `error.ConnectionAborted` from `accept`, and the accept loop returned on
  anything but a timeout — so one aborted connection ended `listen()` with
  a clean "nilo stopping" in the log. The pin is v0.18.0, whose `accept`
  retries it on the same deadline. Rare on Linux, which usually hands the
  socket over and fails the read instead; the ordinary path on the BSDs.
  The same bump takes the `BroadcastChannel` fix the roadmap was waiting on,
  and lets the Engine hand a fired completion straight back to `submit`
  instead of rebuilding it first (zio#673, fixed by zio#674).
- A chunked request body nobody read no longer panics on a chunk size that
  overflows a `u64`. It was added to the running total before the total was
  checked, so `ffffffffffffffff` after any earlier chunk overflowed — a crash
  in a safe build, a wrapped limit in a fast one. It is refused on the
  announced size now, before a read, the way a buffered chunked body already
  was.
- A chunk size is read as strict `1*HEXDIG` rather than through a lenient
  integer parse. `+5`, `1_0` (which read as 16), and a size with leading or
  trailing whitespace were accepted, each a length a front end could frame
  differently — the request-smuggling shape a duplicated `Content-Length` is.
- Whitespace between a header field name and its colon — `Content-Length :` —
  is a 400 rather than a line that is silently dropped, which RFC 9112 §5.1
  requires and which closes the same framing disagreement.
- A `Content-Length` body being discarded to reuse a keep-alive connection is
  bounded by `max_body`, and a body over it closes the connection instead of
  being read in full. The drain path ignored the limit the handler path
  enforces, so a body larger than the server would ever accept was read only
  to be thrown away.

## Released

Every tagged release has its notes on its own page, which is where the whole
account of it lives:

- **[v0.5.0](https://github.com/nevindra/nilo/releases/tag/v0.5.0)** — the
  roadmap read back against the tree: a Row that says more about its own
  table and `sql.Schema` as the one value that reads it, `nilo.Verified` and
  `jwt.Keyring`, `fetch.Target`, `nilo.Text` and `nilo_check`, `nilo-dev`, a
  queue that wakes its workers. Seventy-nine entries; eight things to read
  before deploying, listed there.
- **[v0.4.0](https://github.com/nevindra/nilo/releases/tag/v0.4.0)** — one
  module, `nilo_job`, and the thirty-odd shapes a second port needed: a
  listing page in one statement, an order chosen from a closed set, a route
  answering once per key, a health page, and the two fixes that let the suite
  run on a Mac. Twelve things to read before deploying, listed there.
- **[v0.3.0](https://github.com/nevindra/nilo/releases/tag/v0.3.0)** — the
  release a real port wrote: migrations as a diff against a snapshot and the
  `db` command, deadlines and an allowance per route, a metrics page, sessions
  that expire, and eleven things to read before deploying, listed there.
- **[v0.2.0](https://github.com/nevindra/nilo/releases/tag/v0.2.0)** — 0.1.0 was
  an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and that server
  is one of its eight modules. Includes what to change when upgrading from
  0.1.0.
- **[v0.1.0](https://github.com/nevindra/nilo/releases/tag/v0.1.0)** — the first
  release, published as zfast.
