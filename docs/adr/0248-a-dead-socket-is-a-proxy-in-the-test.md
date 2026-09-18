# 0248 — a dead socket is a proxy in the test

**Status:** accepted
**Extends:** [ADR 0047](./0047-a-deadline-needs-a-connection-you-hold.md),
whose `fresh` and `revive` now have the test they were missing.
**Applies:** [ADR 0033](./0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md).

## Context

`Tx.fresh` empties the connection's server error before every statement, so
a unique violation followed by a broken pipe is reported as the broken pipe
and not as `AlreadyExists`. `Tx.revive` reads the same field to tell an
aborted transaction from a dead connection. The roadmap carried the gap for
a cycle: the fix had no test under it, because a transport failure between
two statements of one transaction needs a socket the suite never opened. It
stayed open after `fetch/deadline.zig` and `http/live.zig` had shown a real
port could be driven in a test, because those stand a *server* up, and what
this needs is a wire between a client nilo does not own and a server it
does not run — that can be cut at a chosen line.

## Decision

**A TCP proxy in the test, between the pool and the Postgres that
`DATABASE_URL` names, run as tasks on the same `std.Io.Threaded` the pool
dials through.** `sql/severed.zig` listens on port 0, accepts, dials the
real server, pumps both ways, and exposes `cut(index)`. The `Db` under test
is opened against the proxy with `size = 1`, so the connection a
transaction holds is the one the proxy can point at, and the URL it is
given is the real one with its authority rewritten — user, password,
database and query string untouched.

Three properties of the cut are the design rather than the plumbing:

- **It is a reset, not a close.** A FIN leaves the client in `CLOSE_WAIT`,
  its next write succeeds, the far end answers RST, and the read then sees
  `EPIPE` — which `std.Io.Threaded` spells `error.SocketUnconnected`, a name
  `translate` does not list. The caller would get `QueryFailed` and the log
  an `err` line blaming the driver. An RST while `ESTABLISHED` puts
  `ECONNRESET` on the next write, which is `ConnectionResetByPeer` in every
  spelling and `Disconnected` at the caller. `SO_LINGER` with a zero
  timeout is how `close` says RST, and the race does not have to be won: a
  write that beats the reset succeeds, is answered by it, and the read
  after it meets `ECONNRESET` all the same. Only a FIN in front changes the
  spelling, and none is sent.
- **The pumps are cancelled before either descriptor is closed.** A close
  under a thread blocked in `readv` wakes nothing and leaves the socket open
  underneath, so no reset would ever go out. `Future.cancel` is what gets a
  task out of a syscall (ADR 0230), and it runs first.
- **A transaction ends with `commit`, never `deinit` alone**, because a
  rollback that cannot reach the server logs at `err` and the test runner
  counts that as a failure nothing can expect (`docs/history.md`, *a
  behaviour whose only signal is a log*). `commit` walks the same
  `revive` → `fresh` → statement path and returns the error instead.

## What was rejected

**`pg_terminate_backend` from a second connection.** Postgres hangs up when
it gets round to it, not between two lines of the test, and it hangs up
with a FIN — the spelling above. The proxy's cut is a call that has
returned before the next statement is written.

**Putting the case in `live.zig`.** It would run there, on the same
`Threaded`. It is a root of its own so that a proxy that wedges is a binary
that wedges, with a name of its own in `ps`, rather than one test among a
hundred — the reason `CLAUDE.md` gives for reading CPU time before
believing a build is slow.

**Closing the socket and letting the pumps find out.** The order that
deadlocks, above.

## What it costs

Nothing on any of the four axes: a test root under `test-sql`, skipped when
`DATABASE_URL` reaches nothing. The proxy is two 8 KB buffers per direction
on task stacks, for the life of one test.

## What proves it, and what it cannot

Two tests in `sql/severed.zig`. The first runs a second statement after the
cut and then a `COMMIT`, and reads `pg_pool_dirty` move by one — the dead
half of `revive`, against the live half in `live.zig` where it holds still.
The second is the path where a stale `err` and a real transport failure
meet: `revive` lets the aborted transaction out of `.fail` on what it can
know, and the `COMMIT` is the first thing to touch the reset socket. Without
`fresh`, that write failure is reported as the `AlreadyExists` still on the
connection — the bug, verbatim.

What neither can see is a `revive` that wrongly let a *dead* connection
out: a `COMMIT` written to a reset socket fails and is thrown away exactly
as one refused locally is. Telling those apart needs pg.zig's `pg_query`
counter, which moves only when a statement is written, and nothing in
`postgres.zig` reads it yet. That is the one lever left, and it is a
test-facing function beside `dirtyConnections`.

One thing this found by reading rather than running, and records rather
than fixes: `translate` maps `BrokenPipe` to `Disconnected`, and under
`std.Io.Threaded` a socket never says `BrokenPipe` — `EPIPE` on a read or a
write is `SocketUnconnected`, and a peer's plain close is
`error.EndOfStream` off the reader. Both fall to `QueryFailed` with a log
line that blames the driver. Whether zio spells them the same way is not
known here, which is why it is a note and not a change.
