# An idle connection is asked before it is used

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)

## Context

pg.zig's `pool.acquire` hands back whichever connection it holds without asking it anything. A connection that sat idle while the server restarted, failed over, or a NAT forgot the flow is dead by then, and nothing finds out until a statement is written down it and the read after comes back empty. So after every restart, each connection that had been idle cost one request a 5xx: a pool of ten answered ten errors before it was whole again. `severed.zig`'s proxy reproduces both ways of dying: a reset, and a FIN from a server that closed the socket itself.

## Decision

**`Wire.take` asks each connection whether its socket has anything to say before handing it out.** Nothing was sent down an idle connection, so anything readable on it is the server going away: the FIN, the `57P01` Postgres sends before it, or a reset. The check is one `poll` with no wait on the socket's fd. A connection that answers is marked failed and given back, which pg.zig takes as its cue to destroy it and dial a replacement, and the next one is asked. After the pool's size in replacements the loop stops asking and returns what it has, so a check that misreads a socket cannot spin.

Every `acquire` on the Postgres Wire goes through `take`: a statement, a transaction's `BEGIN`, a stream, and `describe`.

## What it costs

- **Allocations per request**: none.
- **Memory per idle connection**: none. The `pollfd` is 8 bytes on the stack of a frame that returns before the statement is sent.
- **Throughput and p99**: one `poll` syscall per acquire, a few hundred nanoseconds against a round trip of tens of microseconds. Not measured on its own; it is under the spread of the Postgres runs in [`bench/result/`](../../bench/result/).
- **Binary size**: the loop and one syscall wrapper, under a hundred bytes.

A connection found dead is dialled again inside the request that found it, so that request pays a connect (a round trip, plus TLS where there is TLS) in place of the 5xx it paid before.

## What was rejected

- **Sending the statement again after a failure on a dead connection.** It is what most pools do, and it can run a statement twice. A failure on the read after the write cannot tell a FIN that arrived before the statement from a server that committed it and then died, and an `INSERT` sent again is two rows. A socket that already said it is closing is known dead before anything went out, so replacing it is safe for every statement, not only for reads.
- **A `SELECT 1` before every use.** It catches the silent death too, but it is a round trip on every statement, the one cost ADR 017 does not let a convenience spend on a path that did not ask.
- **A keepalive, TCP or a timer sending `SELECT 1` to idle connections.** It catches a NAT timeout before it happens, but not a restart, and it is a fiber or a setting per pool doing work while nothing is asked of it. It stays open if the silent case turns out to matter.

## Consequences

- **A connection that died silently, dropped with nothing sent back, still reads as quiet**, and its first statement fails as before. pg.zig replaces it when it is returned, so it costs one request, not one per connection forever.
- **A connection with something unasked-for to read is replaced even when it was alive**: a `NOTIFY` for a session that ran `LISTEN` through `db.raw`, or a `ParameterStatus` after a reload. It costs a reconnect and never a wrong answer. nilo itself never listens.
- **On Windows the check is compiled out**, since the fd is a `SOCKET` there and `poll` takes another shape; the pool behaves as it did before.
- SQLite has no socket to lose, so its Wire is unchanged.
