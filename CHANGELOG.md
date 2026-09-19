# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

Nothing yet. Work lands here under `### Breaking`, `### Added`, `### Fixed`
and `### Docs`, newest first.

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
