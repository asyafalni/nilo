# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

Needs Zig 0.16, as 0.4.0 does. Five things the roadmap had marked ready, each
one a failure that used to arrive somewhere other than where it was made.

### Fixed

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
  `Server.socket.address` carries it after `listen`. `http/live.zig` still
  walks its range, because `App.listen` does not hand a port back out — the
  roadmap has the entry.

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
