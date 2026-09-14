# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

Needs Zig 0.16, as 0.4.0 does. Ten things the roadmap had marked ready, most
of them a failure that used to arrive somewhere other than where it was made.

### Added

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

- **`zig build snippets` refuses a documentation page that carries a
  `<!-- compiles -->` mark and is not on its list.** It walks `README.md` and
  `docs/` for the mark, so a mark cannot be written anywhere the step will
  not read it. `docs/guide/openapi.md` was the page that had one and was not
  listed; it is now.

### Fixed

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
