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

### Breaking

- `read_buffer` defaults to 16 KiB, up from 8. It is also the ceiling on a
  request head, and 8 KiB was inside what a browser behind a single sign-on
  sends in cookies on every request. An idle connection holds the same 4,669
  bytes — the pages go back while it waits (ADR 0071) — and a connection
  inside a request holds two pages more. A server that wants the old number
  passes `.read_buffer = 8 * 1024`
  ([ADR 0268](./docs/adr/0268-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)).

### Added

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
