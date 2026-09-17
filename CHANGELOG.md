# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

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

### Added

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
- `sql.Db`, `sql.Named`, `sql.Sqlite` and `sql.SqliteNamed` say their own
  name in a nilo message, rather than `db.DbOf(postgres.Wire,…)`.

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
