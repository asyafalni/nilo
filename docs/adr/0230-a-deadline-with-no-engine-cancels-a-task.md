# 0230 — a deadline with no Engine cancels a task

**Status:** accepted
**Extends:** [ADR 0065](./0065-the-way-out-was-open-the-clock-was-not.md).
The bound is on the fiber where there is one; where there is none, it is on
a task.
**Applies:** [ADR 0033](./0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md),
to the guard itself.

## Context

`fetch.Settings.timeout_ms` was honoured only where an Engine ran the bound:
`Bound.arm` on a `Limits` with no Engine under it arms nothing, by design,
and that design is right for a `Limits` — Core cannot cancel a fiber. What
was wrong was what the client did with it. On a client started with
`nilo_start(io, .off)` — a CLI, a worker, every test in `fetch/live.zig` —
a non-zero `timeout_ms` was a number that meant nothing, and nothing said
so. A connection that stopped sending was held forever.

fdm found it the way a guard that does nothing is always found: by writing
its own. It set `.timeout_ms = 0` with a comment saying why, and ran a
per-segment stall watchdog beside sixteen connections — a second timeout
mechanism, written by a caller, because the first one was silently off.

`std.Io.Threaded` cannot cancel the thread a caller is on, but it can cancel
a *task*: `Future.cancel` sends a signal into a blocking syscall and returns
once the task has come out of it. zio can too. So there is a way to bound a
call on any `Io` — run the call as a task, and cancel the task.

## Decision

**With no Engine, an `Exchange` bounds each step of the call itself: the
step runs as a task of the `Io` and is cancelled when the clock passes the
deadline.**

`begin` reads the timeout once and puts it where whichever mechanism can
enforce it: `Bound.arm` under an Engine, or an absolute time on Core's
monotonic clock when `client.limits.engineless()` says there is none. Every
step that can block — the head in `begin`, `take`, `readInto`, `pipe`, and
the drain in `end` — goes through `bounded`, which is the call itself when
there is no deadline and, when there is, `io.concurrent` of the call plus a
futex wait on a word the task sets when it is done, with what is left of
the deadline as the wait's timeout. Past it the task is cancelled, `expired`
is set, and `blame` names the failure a timeout the way it does under an
Engine — the bound is the authority and the error is not, exactly as ADR
0065 found.

A cancellation of the *caller's* task — a shutdown — comes back through the
wait, is passed to the inner task, and is put back with `io.recancel()` so
the next `Io` call the caller makes still sees it.

**`Limits.none` is the name.** `.off` read as "start with something off",
and the first guess at what was logging. `none` says what it is — *there is
no Engine here* — and the doc comment now says what a Fitting is expected to
do about it. `.off` is kept as the same value so nothing already written
breaks.

## Alternatives rejected

**Refuse a non-zero `timeout_ms` at `nilo_start` with no Engine.** Honest,
cheap, and what the feedback offered as acceptable. It leaves every CLI
writing its own watchdog, which is the thing fdm did and the thing this
module exists to make unnecessary. The refusal is the fallback for an `Io`
that cannot spawn: a single-threaded one gets `ConcurrencyUnavailable` from
`io.concurrent`, and the call then runs unbounded exactly as before — and
that case is now the only one, and it is written down.

**A watchdog task that shuts the socket down.** One task per call that
sleeps and calls `shutdown(2)` on the connection's socket, which unblocks a
read on Linux. It cannot reach the connect: before the socket exists there
is nothing to shut down, so DNS and the TCP handshake would still be
outside the deadline. Cancelling the task covers those too.

**A `Limits` implementation for Threaded, so `Bound.arm` works there.** The
vtable arms against *the current fiber*, and `std.Io` gives no handle to the
current task — only the spawner holds the `Future`. The shape does not fit
the API, and forcing it would put a thread-cancel in Core.

**Per-read timeouts.** `std.Io.net` has none; and a server sending one byte
a second satisfies any per-read limit and never finishes, which is why the
timeout was end-to-end in the first place.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 — `io.concurrent` on Threaded takes memory from its own pool, and the live test that counts allocations still counts one |
| Memory per idle connection | **0**, measured: `@sizeOf(Exchange)` is 928 before and after. The deadline is an `i64` rather than a 48-byte `std.Io.Timeout` for exactly that reason, and it fits in padding the struct already had |
| Throughput and p99 | one thread hop per step, **only** on a client with no Engine and a non-zero timeout. Under `listen()` nothing changes: the branch is `engineless()` at `begin`, and the Engine path is the code it was |
| Binary size | not measured separately; one generic function per step type |

## What it changes for a caller's own `io.async`

**A task per call is a task the `Io`'s pool counts, and `std.Io.async` may
run its function inline whenever that pool is full.** `Threaded` allows
itself `cpu_count - 1` tasks — one, on a two-core machine — and its worker
wakes whoever is awaiting a finished task *before* it takes the lock to
count itself free. So a caller that awaits a bounded call and then
`io.async`es a server can find the pool full for a microsecond and get the
server run on its own thread, where `accept` waits for a connection the same
thread was about to make. `fetch/live.zig` and `s3/canned.zig` did exactly
that in forty-four places, held for a day as a `zig build test-all` at zero
CPU, and were found at test 19 of 34 with two binaries running at once.

That is not a bug in `Threaded`; it is `async`'s contract, which says the
function *may* be called before `async` returns. Anything that has to be on
another thread — a server the caller is about to connect to — asks for
`io.concurrent`, which either is or says `ConcurrencyUnavailable`. Both
harnesses now do, and the rule for anybody starting a listener beside a
`nilo_fetch` client on `Threaded` is the same one.

The proof is the two tests under "a deadline with no Engine" in
`fetch/live.zig`: a server that accepts and never answers, and one that
sends a head and stalls in the body. Both come back `error.TimedOut` in
about 200 ms on `std.Io.Threaded`, against a bound of five seconds; without
the mechanism neither returns. The client is whole afterwards — the permit
came back — which the first test checks by counting them.
