# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

Needs Zig 0.16, as 0.4.0 does. Two halves. The schema half is what a Row can
say about its own table — its defaults, a `CHECK`, a trigger, a foreign key
over more than one column — and beside it the ten things the roadmap had
marked ready, most of them a failure that used to arrive somewhere other than
where it was made.

### Breaking

- **`app.start(io)` followed by `listen()` is refused** when any provided
  service declares `nilo_start`. The shape ADR 0079 recommended handed the
  pool one loop and the requests another: a job worker started that way
  crashed at boot, and a server took SIGINT and never exited. `listen()`
  now says which services took the caller's `Io` and stops, with
  `error.StartedOnAnotherLoop` from `tryListen`. `app.start(io)` stays for
  a program that never listens — a test through `testing.Client`, a script,
  a worker on `jobs.serveOn(io)`
  ([ADR 0220](./docs/adr/0220-work-that-needs-the-services-runs-on-their-loop.md)).

  What to change: move the work between `start` and `listen` into a
  function taking `*nilo.Run` first, and register it with `app.before`:

  ```zig
  fn migrate(run: *nilo.Run, db: *sql.Db) !void {
      try sql.migrate.applyPending(db, run, try manifest.chain(run.arena()));
  }

  try app.provide(&db);
  try app.before(migrate, .{&db});
  try app.listen(.{ .port = 8080 });
  ```

  A `sql.migrate.expect(&db, &run, manifest.head)` on its own becomes
  `db.expecting(manifest.head)` beside `db.checking`, and needs no phase.

- **`migrations/snapshot.zon` written before this release is read and
  upgraded, not refused.** A foreign key holds a list of columns now rather than
  one, so `Reference.column` is `columns` and `target` is `targets`. `std.zon`
  fills a *missing* field from its default and has nothing to say about a
  renamed one, so nilo keeps a mirror of the older shape, tries it when the
  current one does not parse, and diffs against what comes back
  ([ADR 0222](./docs/adr/0222-a-foreign-key-is-columns-and-a-table-name.md),
  [ADR 0224](./docs/adr/0224-a-snapshot-an-older-nilo-wrote-is-still-read.md)).

  What to change: nothing. `db generate` says one line noting the file is in
  the older shape and writes the current one out. The tables themselves are
  unaffected — a one-column foreign key is still written inline and byte for
  byte as before — so the diff against a live database is empty and the
  regenerated snapshot is the whole of the change.

- **A version file now has a generated block rather than being one.** `generate`
  writes a `before`, an `after`, a `version` whose `.steps` is
  `before ++ generated ++ after`, and the generated list between two
  `// nilo:generated` marker lines. Files written by an earlier release still
  compile and still apply, and their hashes do not move, because the hash is
  taken over the steps and not over the file
  ([ADR 0223](./docs/adr/0223-a-version-file-is-a-generated-block-and-the-rest.md)).

  What to change: nothing, unless you want `--baseline` to be able to rewrite
  version 1 in place. That needs the two marker lines around the generated
  steps, and the refusal says so with the line to paste.

- **`Exchange.Begin.redirect_buffer` is `redirects`**, a union with a name
  for each intent: `.refuse` (the default: a 3xx with a `Location` is
  `error.RedirectRefused`), `.follow = &buf`, or `.expose` (the 3xx as
  itself). An empty buffer used to mean "not followed" and "not thought
  about" in the same spelling, and the second read as a broken server
  ([ADR 0239](./docs/adr/0239-a-redirect-is-a-decision-with-a-name.md)).

  What to change: `.redirect_buffer = &buf` becomes
  `.redirects = .{ .follow = &buf }`. An `Exchange` that wants a 302 handed
  over as itself (a signed request, a client that reads the body of a 301)
  says `.redirects = .expose`; one that left the field out and never met a
  3xx changes nothing.

- **`jwt.Key` is a `kid` and a `material` union**, `.rsa = .{ .e, .n }` or
  `.ec = .{ .crv, .x, .y }`, now that a key set can hold two kinds of key
  ([ADR 0242](./docs/adr/0242-the-key-decides-the-algorithm.md)).

  What to change: `key.n` becomes `key.material.rsa.n`, and a `switch` on
  `key.material` is how to tell the two apart. Code that only ever handed
  `&keys` to `verify` changes nothing.

- **`Bucket.stream(c, key, &reading)` takes no buffer.** The one it took was
  documented as what the body moved through, and no byte ever crossed it:
  the body goes from the connection's own read buffer to the writer `pipe`
  is given ([ADR 0238](./docs/adr/0238-the-transfer-buffer-serves-nothing-here.md)).

  What to change: drop the fourth argument and the `var transfer` above it.

### Added

- **`nilo.Cached(Pages, .{ .ttl_s = 60 })`** as a route argument: the
  answer a GET or HEAD returned is kept under the path and query in a bytes
  Space and served again, byte for byte, for `ttl_s` — the handler does not
  run. A request that finds the answer still being made waits for it rather
  than running the handler again, which is the stampede answer `nilo_cache`
  cannot give on its own. `.by` picks the key (`.path_and_query`, `.path`,
  or one header); a credential as the key is a Refusal, and so is a POST.
  Costs what `Idempotent` costs, on the route that asks and nowhere else
  ([ADR 0247](./docs/adr/0247-a-route-can-say-cache-this-answer-for-a-minute.md)).
- **`pw.Token`** — the secret that is not a password: a reset link, an email
  verification, an API key. `pw.Token.new(try c.entropy(pw.token_len))`,
  then `token.text()` to send (43 characters of base64url) and
  `token.digest()` to store (SHA-256); `pw.Token.matches(stored, presented)`
  decodes, hashes and compares in constant time, and answers `false` for
  every wrong shape rather than an error that says which. No argon2: a
  256-bit token needs no stretching, and a reset endpoint that took 13 ms to
  say no would be one that can be walked. `pw.Token.parse` is the token read
  back, for the lookup where the digest is the key. A `[16]u8` — a UUID's
  bytes — is refused in nilo's words
  ([ADR 0241](./docs/adr/0241-a-token-is-not-a-password-and-a-check-needs-no-request.md)).
- **`nilo.verifyPassword(gpa, stored, text)`** and `nilo.verifyPasswordWith`:
  `c.verifyPassword` with no request in hand, through the same Gate and the
  same blocking pool, for a CLI resetting an account, a job re-hashing at a
  raised Cost, or a test with neither an App nor a `Ctx`. Checking reads the
  salt out of the stored string and never needed the request; the method
  keeps its signature and calls this
  ([ADR 0241](./docs/adr/0241-a-token-is-not-a-password-and-a-check-needs-no-request.md)).
- **`nilo_jwt` reads ES256.** A JWKS key that says `"kty":"EC"` on `P-256`
  is checked as ECDSA over P-256 with SHA-256 — what Supabase and Apple sign
  with — through the same `verify`, and the token's header still picks
  nothing: the key's type decides the algorithm, the header's `alg` is
  compared against the two names before a key is looked up and against the
  key's own name after, so `ES256` over an RSA key and `RS256` over an EC
  key are both `error.WrongAlgorithm` before any arithmetic. A curve with
  no branch is `error.CurveNotSupported` by name; a DER-shaped signature,
  which is the mistake every signer outside JOSE makes, is
  `error.SignatureWrongLength` rather than a `BadSignature`. `jwt.curves`
  lists the one curve, beside `jwt.key_sizes`. The vector is RFC 7515
  Appendix A.3, verbatim
  ([ADR 0242](./docs/adr/0242-the-key-decides-the-algorithm.md)).
- **`client.postJson(c, url, value, .{})`**, with `putJson`, `patchJson` and
  `sendJson(c, method, url, value, .{})`: the value written out with
  `std.json` into the Scope and sent under `content-type: application/json`,
  unless `headers` names one. What `res.json(T, c)` is for the way in.
  Text handed to any of them is a Refusal — it would go out as one JSON
  string — and a body already encoded goes through `post`
  ([ADR 0243](./docs/adr/0243-the-ordinary-call-sends-json-and-a-query.md)).

- **`fetch.withQuery(c, base, .{ .page = 2, .q = "a b" })`** is
  `base?page=2&q=a%20b` in the Scope, one allocation sized exactly. A field
  is an int, a bool, text or an optional of one, where null is the param
  left out; any other type is a Refusal naming the field. A base that
  already has a `?` gets `&`. The path half — a segment encoded on the way
  in — waits on a target to hang it off
  ([ADR 0243](./docs/adr/0243-the-ordinary-call-sends-json-and-a-query.md)).

- **`res.header(name)` and `res.headers`** on `fetch.Response`: the header
  block the answer arrived with, kept into the Scope before the body read
  over it, so `Retry-After` off a 429 or `ETag` for the next conditional
  GET is one call away after `get` returns. **A whole-body call now makes
  two arena allocations rather than one** — the block, then the body — and
  the test that held the one now holds the two
  ([ADR 0244](./docs/adr/0244-a-response-carries-its-headers.md)).

- **`fetch.testing.Canned`** — the loopback server the module's own tests
  drive, exported for a suite of your own: `open(io)`, `reply(status,
  headers, body)`, `serveOne`, `url(&buf)`, `request()`, `requestBody()`.
  Port 0 and the kernel's answer read back, so it needs no port range. The
  guide's testing section used to say "copy the shape of `fetch/live.zig`'s
  `Canned`"; it now shows the call
  ([ADR 0243](./docs/adr/0243-the-ordinary-call-sends-json-and-a-query.md)).

- **`zig build refusals-fetch`**, `nilo_fetch`'s first Refusals table:
  three rows, run by `test-fetch` and so by `test` and `test-all`.
- **`stall_ms`**, on `fetch.Client.Settings`, `Call` and `Exchange.Begin`:
  the call is `error.Stalled` when nothing has arrived for that long,
  counted from the last byte rather than from the start. The other shape
  of bound, for the call whose whole point is the transfer and whose only
  honest `timeout_ms` is `0`: a peer that goes quiet and holds the socket
  now ends, and a slow one that keeps moving never fires it. Under a server
  it is the Engine's timer re-armed on every chunk; on a client with no
  Engine it is ADR 0230's cancelled task, with the wait re-read from the
  last byte. `Exchange.stream(w, limit)` is one chunk of the body inside
  both clocks, for a body moved in pieces of the caller's own choosing,
  and its zero is the end of the body and nothing else: std's TLS reader
  answers zero for a record that carried no application data (a session
  ticket, a record decrypted into its own buffer), and `stream` reads on
  past those, which fdm's first run against it over TLS found as every
  segment ending short
  ([ADR 0237](./docs/adr/0237-a-bound-on-silence-is-not-a-bound-on-the-call.md)).

- **`head.keep(c)`** is the same `Head` copied into the Scope, so it reads
  the same after the body has been through: the `etag` taken before a
  download and compared against after it, without a `[512]u8` of the
  caller's own ([ADR 0240](./docs/adr/0240-a-head-that-outlives-its-body.md)).

- **`fetch.Client.Settings.read_buffer_size`**, std's 8 KiB passed through:
  the buffer each connection reads the socket through, and so the number
  that decides how much one read brings in. `Begin.transfer_buffer` never
  did, and its comment now says what it is for: a caller reading buffered
  off `ex.reader`, and nothing else. `Client.send` no longer declares 4 KiB
  of it ([ADR 0238](./docs/adr/0238-the-transfer-buffer-serves-nothing-here.md)).


- **`Exchange.Begin` takes a `user_agent`**, beside `host`, `authorization`
  and `content_type`: the fourth header `std.http.Client` writes for itself.
  A `User-Agent` put in `headers` went out twice — std's `zig/0.16.0
  (std.http)` and then the caller's — which is what a download manager
  sending the header a browser's "Copy as cURL" carries found the first time
  a host looked at it.
- **`nilo_core` reads the clock on Windows.** `nowMicros` and `monotonicMicros`
  were a `@compileError` there; a program on `nilo_fetch`, `nilo_sql` and
  `nilo_job` with no Engine now cross-compiles for `x86_64-windows`
  ([ADR 0228](./docs/adr/0228-core-reads-the-clock-on-windows.md)).
- **A Row can say its columns' defaults**, `.default = .{ .created_at = .now,
  .state = .draft, .seats = 1 }`. `.now` is the one word and is refused off a
  `sql.Timestamp`; everything else is a literal of the column's own Zig type,
  and a column with words of its own takes one of them written the way a column
  is (`.draft`, not `"draft"`). The snapshot carries it, so changing a default
  is a migration, and a `NOT NULL` column added with one needs no backfill
  ([ADR 0221](./docs/adr/0221-the-marker-has-two-kinds-of-word.md)).
- **A Zig enum column writes its own `CHECK`.** A column read as a plain Zig
  enum is `text` with `CHECK ("state" IN ('draft', 'live', 'archived'))` beside
  it, and the words are in the snapshot — so adding a tag is a migration rather
  than an insert the database refuses. `db.checking` now judges such a column at
  boot, but only on a table this program builds. An enum naming its own database
  type (`pub const nilo_column = "user_role"`) is unchanged: its words are the
  database's, added with `ALTER TYPE`.

  What to expect on an existing schema: the next `generate` writes one
  `ADD CONSTRAINT … CHECK` per enum column, because the snapshot did not record
  the words before. Applying it is the point — the rows already agree with the
  enum or the program was already failing on them — and a table whose data does
  not agree is what the failing `migrate` is telling you.
- **`.index` takes a direction and a `.where`** —
  `.{ .columns = .{ .org_id, .{ .created_at = .desc } }, .where = .{ .deleted_at = null } }`.
  The predicate is the grammar a `db.select` condition already uses, not a
  string: `null`, `.{ .ne = null }`, a literal, `.{ .ne = lit }`. A name that is
  not a column is a Refusal and a literal of the wrong type does not compile.
- **A constraint can be named**, `.name = "users_one_account_per_address"` on a
  `.unique`, an `.index` or a `.references`. Postgres reports a violation by
  constraint name and nothing else, so this is what makes the violation a
  sentence.
- **Every constraint name is checked at 63 bytes on both databases.** Postgres
  cuts a longer one down in a `NOTICE` nothing reads, which left the snapshot
  holding a name the database did not have. Two entries that end up with one
  name are refused too.
- **`sql.Date`** — a calendar day, `date` on Postgres and `TEXT` on SQLite,
  **read out of the column rather than out of a `::text`**, so a `db.raw`
  reading one needs no cast. `2026-09-17` in JSON, `format: date` in the
  document. A day is not a moment: a due date read into a `timestamptz` gets a
  midnight, and a midnight has a zone. A day before 1970 is ordinary, which is
  where `sql.Timestamp` stops.
- **`app.before(f, args)`** — work that needs the services and has to finish
  before the first request. Runs once inside `listen()`, after the services
  have started and before what `spawn` registered, on the server's loop,
  with a `nilo.Run` made there. If it fails, the server does not start.
  Three shapes are refused while compiling: a value rather than a function,
  a first parameter that is not `*nilo.Run`, a function answering with a
  value.
- **`db.expecting(version)`** — refuse to serve a database whose migration
  ledger is behind the binary, checked at boot on the pool `listen()` just
  opened. A call rather than an option on `Db.Opts`, because the option
  measured 17,296 bytes in every program with a `Db` in it and the call
  measures 16.
- **A `.references` can name its table as text**, `.{ "orgs", .id, .cascade }`,
  for a program whose files may not import each other's Rows — a context per
  directory, where contexts never import each other. **The type check is not
  given up**: it runs against the Row list `sql.cli.Tool` and `db.checking` are
  given, where every Row is in one place, and a table no Row in that list claims
  is a compile error naming both spellings. That is what lets a context own its
  Row once instead of declaring every table twice
  ([ADR 0222](./docs/adr/0222-a-foreign-key-is-columns-and-a-table-name.md)).
- **A `.references` can span several columns**, which is how "the Epic has to be
  on the same board" gets said in the schema:

  ```zig
  .references = .{
      .epic = .{ .columns = .{ .epic_id, .department_id },
                 .to = .{ WorkEpic, .{ .id, .department_id } } },
  },
  ```

  Keyed by a label rather than a column, because a Zig field name cannot be a
  tuple. A composite key is written as a table constraint and a one-column key
  stays inline, so every table generated before this is unchanged. `.exists`
  joins on every column of it.
- **`db generate --baseline`** — forget the snapshot, diff the Rows against
  nothing and rewrite version 1 where it stands, keeping everything outside its
  generated block. What porting a schema needs, where the loop is one version
  derived over and over. Refused once there is a version 2, when `--name`
  disagrees with the version 1 on disk, or when the file has no generated block;
  each message names the files and nothing is written.
- **A Row can name a `CHECK` and a trigger**, which is the second kind of word
  ADR 0221 described and did not build
  ([ADR 0226](./docs/adr/0226-the-marker-has-a-word-the-database-checks.md)):

  ```zig
  .check = .{
      .work_items_range_runs_forwards =
          "start_date IS NULL OR target_date IS NULL OR start_date <= target_date",
      .work_items_priority_is_known = .{ .words_of = .priority },
  },
  .trigger = .{
      .work_items_updated_at = .{
          .when = "BEFORE UPDATE",
          .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
      },
  },
  ```

  The key is the name the object goes into the database under, because a check
  has no column list to derive one from and the name is the whole of what
  Postgres says when a row breaks it. nilo does not read the body: it writes it,
  hashes it, and notices when the hash moves — so a changed body is one drop and
  one create in the version where it changed, and a name the types no longer
  have is a drop.

  A trigger is two halves because nilo writes `ON "<table>"` between them. The
  table is the one thing the marker already knows, and a second copy of it is a
  copy that stops matching the day the table is renamed.

  `.{ .words_of = .<column> }` is how an enum column's generated `CHECK` gets a
  name of its own instead of `<table>_<column>_check`. Moving that name is a
  migration: the constraint in the database still has the old one.

  A `CHECK` is written inside the `CREATE TABLE`, so SQLite takes it; changing
  one there is the four-statement rebuild the diff already spells out for every
  other table constraint. A trigger is a statement of its own and both databases
  do all three cases.

  **Postgres 14 is now the floor**, because `createMissing` writes
  `CREATE OR REPLACE TRIGGER` and no version of Postgres has
  `CREATE TRIGGER IF NOT EXISTS`. Nothing else in the module needs it.
- **An array column takes a default like any other**, `.read_tags = &.{}` or
  `.write_capabilities = &.{ "deals", "work" }`. Each element goes through the
  column's own element type, and the Postgres array literal is escaped so a
  comma, a brace, a quote, a backslash or an apostrophe inside an element does
  not change how many elements there are
  ([ADR 0225](./docs/adr/0225-an-array-column-has-a-default-like-any-other.md)).
- **`db generate` writes a `.sql` twin beside every version file**, and
  `db check` fails when one no longer says what the version beside it says
  ([ADR 0227](./docs/adr/0227-a-version-has-a-sql-twin-nobody-reads-back.md)):

  ```
  migrations/0007_work_items_get_a_priority.zig
  migrations/0007_work_items_get_a_priority.sql
  ```

  The same statements in the same order, wrapped in `BEGIN`/`COMMIT`, with the
  ledger table created if it is not there and the ledger row on the end — so
  `psql -f`, a CI job with no toolchain or somebody on a jump host can bring a
  database to head, and `db.expecting(manifest.head)` still serves it and
  `verify` still holds the hash. It is an output: nilo reads the `.zig` and
  never this.

  One case writes nothing and says so. `--baseline` rewriting a version 1 that
  has hand-written steps in it produces a file whose `before` and `after` are
  Zig nothing has compiled yet, so the twin's hash cannot be worked out. Build,
  then run `db check` or any `db generate`.
- `sql.Db`, `sql.Named`, `sql.Sqlite` and `sql.SqliteNamed` say their own
  name in a nilo message, rather than `db.DbOf(postgres.Wire,…)`.

- **A connection URL is read the way libpq reads it, and a parameter the
  driver would not act on is refused by name.** `dialOpts` used to understand
  `sslmode` and `tcp_user_timeout` and stop the server on anything else, so
  the URL a hosted Postgres hands out — `application_name`,
  `connect_timeout`, `pgbouncer=true`, `sslrootcert` — was a server that
  would not start. Every libpq parameter now goes one of three ways.
  *Carried* onto the field pg.zig has for it: `user`, `password`, `dbname`,
  `host` and `port` as query forms (checked against the part before the
  `?`), `sslmode` disable/require/verify-full, `sslrootcert` beside
  `verify-full` (`system` for the platform's store), `application_name` and
  `fallback_application_name`, `connect_timeout` in seconds,
  `tcp_user_timeout`, and the four `keepalives` settings. *Dropped* with one
  `warn` line naming them, because the driver does it already or nothing
  observable changes: `pgbouncer`, `pool_mode`, `sslsni=1`,
  `gssencmode=disable|prefer`, `channel_binding=prefer|disable`,
  `target_session_attrs=any`. *Refused* with a line naming the parameter,
  the reason and the list understood: `sslmode=prefer|allow` (would fall
  back to plaintext), `verify-ca` (checks half of what `verify-full` does),
  `sslcert`/`sslkey`, `options`, `channel_binding=require`,
  `gssencmode=require`, any other `target_session_attrs`, `sslsni=0`,
  `client_encoding`, and anything unknown. A query string is split before it
  is percent-decoded, so a `password=` holding `&` survives. Two new error
  names, `UnsupportedConnectionParamValue` and `ConflictingConnectionParam`,
  both counted as URL problems by `nilo_start`.

- **`sql.on(D).selectFor(Row, Options)` — and the fourteen beside it — spell
  a statement for the Dialect you name.** `sql.selectFor` and its siblings
  hard-code Postgres, so a program on SQLite could not ask what SQL its own
  query compiles to. `sql.on(sql.SQLite)` binds them all to that Dialect;
  `sql.SQLite` is exported beside `sql.Postgres` for it. The old
  spellings are unchanged.

- **`app.boundPort()` says which port the server is listening on.** `?u16`,
  null until `listen` has bound and null for a unix socket. The Engine
  reads the address back after `listen`, so `.port = 0` is now something a
  test can ask for: `http/live.zig` does, and nothing in the suite walks a
  range of loopback ports any more.

- **An enum column's values are checked at startup.** `db.checkSchema` used
  to judge an enum field carrying `pub const nilo_column = "user_role"` by
  the column's type name and stop there, so a Zig enum that had fallen
  behind its Postgres type was found by the first request that read such a
  row. It now asks `pg_enum` for the type's labels and reports each one the
  Zig enum lacks (`value_zig_lacks`) and each tag the type lacks
  (`value_type_lacks`), the same way a missing column is reported. SQLite
  has no enum type and skips the check; a Dialect says whether it can with
  `enum_values`, and a Wire answers it with `labelsOf`.

- **The reference is a folder.** `docs/reference.md` was 4,154 lines, and
  is now `docs/reference/`: one page a module, seven for the server cut
  where the guide cuts, and every heading listed once on its `README.md`. A
  link into the old page names the new one under the same anchor, so
  `docs/reference.md#run` is `docs/reference/core.md#run`
  ([ADR 0236](./docs/adr/0236-the-reference-is-a-folder-one-page-a-module.md)).

- **`zig build snippets` refuses a documentation page that carries a
  `<!-- compiles -->` mark and is not on its list.** It walks `README.md` and
  `docs/` for the mark, so a mark cannot be written anywhere the step will
  not read it. `docs/guide/openapi.md` was the page that had one and was not
  listed; it is now.

- **A `push` wakes a worker.** `jobs.push` from the process the workers run
  in used to wait out `poll_ms` — half a second on average at the default —
  so the first CLI set it to 100 and paid sixteen workers × ten idle claims a
  second against one SQLite file. A push now wakes one sleeping worker
  through the `Io`'s futex, and `poll_ms` is what finds a row *another*
  process pushed. `jobs.wake()` is for that row, or one `pushIn` put under a
  transaction that has since committed
  ([ADR 0229](./docs/adr/0229-a-push-wakes-a-worker.md)).

- **A job can push the next one.** `.deps` on a `job.Jobs` may be a
  function of the queue type, `fn (comptime Jobs: type) type`, answering
  the struct of pointers a plain `.deps` is; a `run` then asks for
  `jobs: *Jobs` and pushes the next kind. `.deps = struct { jobs: *Jobs }`
  was a `dependency loop` in the compiler's words, and so was a `run`
  naming `*Jobs` — every check that reads a `run`'s signature now waits
  for the queue type when `.deps` is a function, so for such a queue a
  `run` with the wrong shape is reported at the first `open` rather than
  at the `job.Jobs(…)` line. `Jobs.Deps` names the struct either way; a
  plain-struct `.deps` is unchanged. Two Refusals: a `.deps` function of
  another shape, and one whose struct lacks what a `run` asks for
  ([ADR 0245](./docs/adr/0245-a-job-can-push-the-next-one.md)).

- **A `run` may ask for `tick: job.Tick`** beside its deps — the row's
  `id`, `attempts`, `run_at`, and `last` for whether this is the attempt
  `retry` stops at — by value, since after the job and the Run a pointer
  is a service. `*job.Tick` is a Refusal naming the rule. On top of it,
  `jobs.progress(tick.id, n)` writes a figure into the `status` Space and
  `job.Status` carries it as `progress`, reset by every change of state
  except `done` ([ADR 0246](./docs/adr/0246-a-tick-knows-which-one-it-is-and-a-test-says-when.md)).

- **`jobs.drainAt(&run, now)` and `jobs.runOneAt(&run, now)`** run what
  would be due if it were `now`, and every read of the clock inside the
  tick — the retry's wait, the schedule's next tick, a missed tick — reads
  that number, so a test walks a backoff or a cron to three in the morning
  without sleeping. `jobs.seed(&run)` / `seedAt(&run, now)` queue every
  schedule's first tick, which is what `serve` does at start. `drain` and
  `runOne` are the same calls at `nilo.nowMicros()`, and `drain` now reads
  the clock once for the whole run rather than once per row
  ([ADR 0246](./docs/adr/0246-a-tick-knows-which-one-it-is-and-a-test-says-when.md)).

- **`fetch.Settings.timeout_ms` fires without an Engine.** On a client
  started with `nilo_start(io, .none)` — a CLI, a worker, a test — a non-zero
  timeout used to arm nothing and say nothing, and a server that stopped
  sending was held forever. Each step of the call now runs as a task of
  that `Io` and is cancelled when the clock runs out, so `error.TimedOut`
  means the same thing at either end. One thread hop per step, only on a
  client with no Engine and a non-zero timeout; under `listen()` nothing
  changes ([ADR 0230](./docs/adr/0230-a-deadline-with-no-engine-cancels-a-task.md)).

- **`nilo.Limits.none`** is the name for "no Engine underneath". `.off` read
  as "start with something off" and the first guess at what was logging; it
  stays as the same value, so nothing already written breaks.

- **A header std has a slot for is sent once, and it is the caller's.**
  `host`, `authorization`, `user-agent`, `content-type`, `connection` and
  `accept-encoding` in `Begin.headers` or `Call.headers` used to go out
  beside std's own copy. A caller taking headers off a pasted `curl` line
  no longer routes them into fields by hand; the six names are known in
  `fetch.zig` and nowhere else
  ([ADR 0231](./docs/adr/0231-a-header-std-owns-goes-out-once.md)).

- **`head.redirected` and `head.location(&buf)`** say where a followed
  redirect ended, so the connections after a probe go to the final URL
  rather than walking the chain again. The text lives in the
  `redirect_buffer` the call was given
  ([ADR 0232](./docs/adr/0232-a-followed-redirect-says-where-it-ended.md)).

- **`ex.discard()`** — "I will not read this body; close the connection" —
  for the probe that asked for one byte and got the whole file. `max_drain`
  stays a policy for every call rather than a lever pulled for one
  ([ADR 0235](./docs/adr/0235-a-caller-that-knows-says-discard.md)).

- **`sql.migrate.addMissingColumns(db, run, &.{ Rows… })`** — the step
  between `createMissing` and `apply`: one `ALTER TABLE … ADD COLUMN` per
  field a shipped table has not got, from the same `Desc` the create reads,
  in one transaction. For the single-file program that added a field and
  wants neither a ledger nor a version for it. A required column with no
  default is `error.NeedsBackfill` with the statement in the log, and
  nothing is sent. `db.liveColumns` is the introspection it reads, made
  public ([ADR 0233](./docs/adr/0233-a-column-a-shipped-table-has-not-got.md)).

- **`db.raw` and `db.rawOne` take a column type.** `db.raw([]const u8, run,
  "SELECT name FROM pragma_table_info('downloads')", .{})` reads column one
  of every row with no Row and no marker; `i64`, `?bool`, a `Str` the same.
  A `SELECT` list of two into a scalar is refused while compiling, the way a
  short list into a Row is
  ([ADR 0234](./docs/adr/0234-a-scalar-out-of-raw.md)).

### Fixed

- A `Json(T)` column whose `T` holds text pointed that text at the driver's
  read buffer rather than the arena when the string had no escape in it, so
  the second row read made the first row's text garbage. `std.json`'s
  default is a view into the input where it can be; the read now asks it to
  copy, the way a text column is copied. Found by the same reading that
  found it in `nilo_jwt`, one module over.
- **`jwt.verify`'s claims and `jwt.parseKeys`'s `kid` no longer point at
  memory that is gone.** `std.json`'s default for a slice input hands back
  a slice *into the input* for any string with no escapes, so `claims.sub`
  pointed into the scratch arena `verify` frees on the way out, and a key's
  `kid` pointed into the response body it was parsed from — while both doc
  comments promised the opposite. Unnoticed because every caller so far
  handed `verify` an arena, and a scratch arena freed into an arena gives
  nothing up. Both parses copy now, and a test frees the claims one string
  at a time on the debug allocator
  ([ADR 0242](./docs/adr/0242-the-key-decides-the-algorithm.md)).

- **A call the Engine's own deadline stopped no longer drains the body it
  stopped waiting for.** `end` skipped the drain when the engineless clock
  had fired and not when the Engine's had, so a body that stalled after its
  head under `listen()` was given up on and then read to keep the
  connection, which on a server that went quiet is the read that never
  returns. Found by the first stall test under the Engine, at zero CPU
  ([ADR 0237](./docs/adr/0237-a-bound-on-silence-is-not-a-bound-on-the-call.md)).

- **A Row over a view in an attached SQLite database is introspected as a
  view.** `columnsOf` rewrote `pragma_table_info` to the attached schema and
  left `sqlite_master` beside it pointing at `main`, so the view's columns
  came back all-nullable — the failure
  [ADR 0056](./docs/adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)
  was written to remove. Both relations are qualified now.


- **A Row column of a type no Dialect can decode is a compile error naming
  the field.** A plain struct of your own in a Row used to pass the startup
  check and stop on the first read inside pg.zig, as `cannot decode value of
  type …User__struct_3276`. `db.select` and `Streamed` now refuse it while
  compiling, listing what a column may be and the three ways to make the
  field readable (`sql.Json(T)`, `sql.AsText("…")`, `nilo_beside`). Nothing
  that compiled before stops compiling. One refusal.

- **`.ilike` on SQLite is spelled `LIKE`.** It was written `ILIKE` on both
  Dialects and came back a syntax error from SQLite, whose `LIKE` already
  folds ASCII case — so it is the same one-word swap `icontains` makes there
  ([ADR 0061](./docs/adr/0061-the-second-dialect-is-the-test-of-the-seam.md)).
  `.not_ilike` likewise. Nothing could have depended on the old spelling.

- **A batch on SQLite is refused in one sentence naming the dialect.** The
  Refusal used to fire from the per-column branch, call itself "a batch
  insert" from `updateMany` as well, and blame the column — *the sqlite
  dialect has no column type for `i64`* — which was false and sent the
  reader to `dialect.accepts` to find out. It now says the database has no
  array parameter and what to do instead, with the caller's own verb. Two
  refusals.

- **A `Str` parsed out of a job's payload goes stale when the tick does.**
  `Str.jsonParse` answers `static`, so a payload `Str` held past its tick
  used to pass the Debug trap that catches the same mistake in a handler.
  `nilo_job` stamps the parsed payload through the Run now, the way `Ctx.json`
  stamps a body. `core.stampWith(&value, scope)` is the call, beside `stamp`.

- **`fetch/live.zig` and `s3/canned.zig` bind port 0.** Both walked a
  thousand loopback ports from a thread-derived start, held apart from each
  other by comment, because this repository believed `std.Io.net.Server`
  could not report the port it was given. It could all along:
  `Server.socket.address` carries it after `listen`. `http/live.zig` binds
  port 0 too, through `app.boundPort()` above.

### Docs

- **The keyset form of a deep page.** `db.page`'s `OFFSET` gets slower as a
  list goes deeper; [Reading](./docs/guide/sql/reading.md#the-keyset-form-of-a-deep-page)
  now shows the `(created_at, id) < (…)` condition written as `.any`, with the
  order term that keeps NULLs in a stable place beside it.
- **`cache.Space` of bytes, with a struct behind it.** The guide's own
  Refusal for a value that holds a pointer pointed at
  [a sentence and no code](./docs/guide/cache.md#the-value-type-decides-the-shape-of-get);
  it now shows `std.json.Stringify` into a bytes Space at `put` and
  `std.json.parseFromSliceLeaky` off the request arena at `get`.
- **A `<!-- compiles -->` block that only declares a type is now a documented
  convention rather than a silent gap.** `docs/snippets/README.md` says why a
  block declaring a Row and nothing else needs a `comptime { _ = … }` naming
  it, and the guide's own Row examples that were missing one now carry it.

## Released

Every tagged release has its notes on its own page, which is where the whole
account of it lives:

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
