# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

**0.6.0 adds nothing.** It is the release that reads what is already here:
`http/` scanned line by line for what a stranger on the socket can make it do,
the public surface read back against the reference before 1.0 freezes it, and
the ADRs that only correct an older one folded into the one they correct. What
the scan found lands under `### Fixed` below as it is fixed; what it found and
cannot hold goes to [`docs/risks.md`](./docs/risks.md).

Work lands here under `### Breaking`, `### Added`, `### Fixed` and `### Docs`,
newest first.

### Added

- Every crafted request in the parser's tests — the framing conflicts, the
  strict chunk sizes, the absolute-form target, the head that never ends — is
  now also run split at every byte and trickled a few bytes a read, and has to
  come out identical to the same bytes arriving at once, down to where the
  next request starts. The parser's own tests only ever read from a buffer
  holding the whole input, so every seam that resumes across a read boundary
  was untested at exactly the boundary. `http/http1.zig`, one test.

### Docs

- [Deploying](./docs/guide/deploying.md#when-a-bound-is-hit) has one table
  for every bound `listen()` takes: what a client sees past it, what the log
  says, and what has to happen before the server takes that work again. The
  prose under it was already there; the lookup was not.

### Fixed

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
