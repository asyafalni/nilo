# A stream let go early reads a megabyte of what is left

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the cost below is put against its four axes), [ADR 223](./223-a-statement-cut-off-by-a-cancellation-hands-it-back.md) (a cancellation met while the rest is thrown away is handed back)

## Context

Postgres sends a result whole, without being asked for each row, so a `db.stream` the caller closes after the row it wanted still has the rest of the result on its way down the socket. pg.zig's pool refuses a connection back unless it is idle, so the Postgres Wire read the rest to its `ReadyForQuery` before giving the connection back, however long the rest was. A stream let go after one of two million 200-byte rows held its connection 295 ms in Debug ([sql.md §18](../../bench/result/sql.md#18-the-count-a-page-reads-keyset-paging-and-a-stream-let-go-early)), and after one of 200,000 took 178 to 313 ms in a ReleaseSafe build ([§20](../../bench/result/sql.md#20-what-a-stream-let-go-early-costs-to-give-back)). The handler that stops reading early is the one `db.stream` exists for: the first row that matches, a report cut off at a size, a client that went away.

## Decision

**A stream closed before its end reads at most `drain_budget` bytes of the rest, 1 MiB, and past that gives its connection back as failed.** pg.zig closes a failed connection and dials a replacement, and the server's backend stops at its next write to the closed socket. A short rest is read off and the connection kept, as before; a long one costs one read of a megabyte and one connect, whatever its length. Only row and completion messages count as the rest; anything else on the socket marks the connection failed at once.

**The budget is under what a new connection costs in bytes read**: 1 MiB is read in 4 to 7 ms and a replacement is dialled in 16 to 27 ms on the same loopback, measured in a ReleaseSafe build on LLVM. So a rest past the budget costs at most one connect more than reading it would have. The worst case is a rest just past it, about 23 ms where reading it would have taken 6; a rest of 42 MB is 21 to 34 ms where it was 178 to 313.

**A result inside a transaction still reads its whole rest.** The connection is the transaction, and closing it would roll back what the caller has not committed. `tx` has no `stream`, but every statement it sends is read through the same `Rows`, which does not own its connection there, and that is the flag the bound checks.

## What it costs

- **Allocations per request**: none.
- **Memory per idle connection**: none.
- **Throughput and p99**: a stream closed past the budget costs a connect in place of the rest, 21 to 34 ms against 178 to 313 on a 42 MB rest. A stream read to its end, or closed with under a megabyte left, is unchanged: the loop is the one it replaced plus a counter.
- **Binary size**: the loop and one `std.log.info` line, under a few hundred bytes.

The connect is paid by the request that closed the stream, because pg.zig dials the replacement inside `release`. The server pays a backend startup for it, and is spared producing the rest.

## What was rejected

- **A CancelRequest past the budget.** It is Postgres's own way to stop a query, and it keeps the connection. It needs the process id and secret key the server sends at startup in `BackendKeyData`, and the pinned pg.zig reads past that message without keeping it (`conn.zig`, `'K' => {}`). It also needs a second connection to send it on, which is a connect as well. Worth taking if pg.zig keeps the key; the budget stays as the bound either way, since a cancel can arrive after the rest has been sent.
- **A named portal read in batches** (`Execute` with a row count). The server sends only what was asked, so a stream let go early has at most one batch to read. It is a round trip per batch for every stream read to the end, which is the case `db.stream` is mostly for, and pg.zig has no portal API to build it on.
- **Always closing the connection.** One connect per stream let go early, even when the rest was a row or two, which is most of them.
- **A larger budget.** 2 MiB, interleaved with 1 MiB in the same run, read in 9 to 18 ms and gave its connection back in 26 to 72 against 21 to 34. It saves a connect only for a rest between the two, and pays twice the read on every rest past both.
- **No bound, as before.** The cost is the length of the result, a multiple of the request it sits in with no ceiling.

## Consequences

- **A stream let go early past the budget logs one `info` line** naming the budget, so a handler that does it on every request shows up as a connect rate rather than as nothing.
- **A pool that is short a connection for a moment**: between the close and the replacement's dial the pool holds one fewer. If the dial fails, pg.zig's reconnector owns it as it owns any other connection that failed.
- SQLite has no socket and no rest to read: a statement stopped early is reset, which ends its read transaction, and its Wire is unchanged.
