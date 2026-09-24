# A refused request is hung up on with a FIN

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Applies:** [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 022](./022-a-deadline-belongs-to-an-operation-not-to-a-request.md),
[ADR 073](./073-a-header-is-answered-as-asked-or-refused.md).
**Found by:** reading [dusty](https://github.com/lalinsky/dusty)'s
`hangUpOnRefused` (`src/server.zig`) against `serve.zig`'s 431 path.

## Context

A 431 is written and the connection is closed. The rest of the head — the
part that did not fit in the buffer, which is why it was refused — is still
queued on the socket, unread. **Closing a TCP socket with unread input makes
the kernel send a reset rather than a FIN**, and a peer that receives a reset
throws away what it had buffered. Windows does; so does any client that
checks the error before draining the data. What that client sees is
`connection reset by peer`, where nilo had written a 431 with `head too long`
in the body.

The same is true of every close with input left behind: a 413 for a body
past `max_body` — the one whose message names `bodyStream()` as the way to
take more, written for exactly the person holding the `curl -d @file` — a
400 for a head that did not parse with a body behind it, a 415 for a coding
nilo cannot read, a 503 shed with a body announced. The message nilo took
care over is the thing the reset takes back.

An ordinary `Connection: close` is not this. A GET with no body leaves
nothing queued, the close sends a FIN, and the answer arrives; nothing
changes for it.

## Decision

**Where the client's bytes may still be unread, shut the send side first,
throw away what arrives until the peer hangs up, then close.** `shutdown(SHUT_WR)`
sends the FIN, which tells the peer there is nothing more to wait for; a
peer that has read the answer closes within a round trip, and the read then
returns end-of-stream. Two bounds keep a peer that does neither from holding
the fiber: `linger_limit` (64 KiB) of discarded input, and `linger_ms`
(one second) on the wait, after which the close goes ahead, reset and all.

**Which closes those are is a field on `Served`**, `linger`, set at the
returns where unread input is possible: `HeadTooLong`; a head that did not
parse, or was refused for its coding; a shed 503 with a body announced; and
after the handler, any close where a body was announced and `drain` did not
finish it — too big to discard, or held back behind an `Expect` nobody
answered. Not set for a peer that is already gone (nothing to tell), a head
that timed out (a stalled peer, and a second's more of it is a fiber held
for nothing), or a close with nothing announced.

**The Engine contract gains one call, `Waker.halfClose`**, which is one
`shutdown(2)` on the connection's socket. It sits on `Waker` for the reason
`releaseStack` does: `Waker` is what a connection's socket looks like from
above the Bulkhead, and nilo has no other handle on one. The wait and the
discard are not the Engine's — `serve.zig` does them through the reader it
already holds, under a deadline it already arms.

## What it costs

**Nothing on the path that answers.** A request that is answered and reused
touches none of this; a `Connection: close` with no body touches none of it.
The primary metric is keep-alive GETs and does not move.

**On a refused request: one syscall and a wait of one round trip.** The
fiber and its 4,669 bytes are held that much longer, bounded at one second
by the deadline and 64 KiB by the discard. A flood of refused requests holds
fibers for a round trip each rather than for nothing — which is a cost an
attacker can choose, and the bound is what keeps it from being a lever: a
second per connection against `max_connections` is the same ceiling every
slow-client deadline in ADR 022 already accepts.

Allocations: none. Binary: two constants and one function.

## Alternatives

**Linger on every close.** nginx's `lingering_close always`. Correct, and
pays the round trip on every non-keep-alive request, which is what `ab` and
a share of real clients send. The precise rule costs the same where it
matters and nothing where it does not.

**`SO_LINGER`.** Changes what `close` does rather than what precedes it, and
a zero linger is the *opposite* of this — a deliberate reset. The
non-zero form blocks `close` in the kernel for the timeout, which is a
thread held rather than a fiber parked.

**Read the whole refused body before closing.** What `drain` does for a body
under `max_body`, so the connection can be reused. Past it, reading a body
to the end so that the 413 arrives is work the client sizes, and ADR 017's
memory axis is the reason `max_body` exists. The FIN tells the client to
stop; the bound is for the one that does not.

**Do nothing, and document that Windows clients see a reset.** The message
in the 431 exists to be read by the person who hit it. A refusal that
cannot be read is a refusal that costs a support question.

## Consequences

- `http/bulkhead.zig`: `Waker.VTable.half_close`, `Waker.halfClose`, a
  line in the contract header.
- `http/engine/zio.zig`: `Wake.handle` and `Wake.halfClose`.
- `http/serve.zig`: `Served.linger`, `hangUp`, `linger_limit`, `linger_ms`,
  and the returns that set it; two tests at the bottom hold which paths do.
- `http/websocket.zig`: the test vtable gains the slot.
- [Deploying](../guide/deploying.md#when-a-bound-is-hit): the 431 and 413
  rows say the send side is shut first.
- Not held end-to-end on Linux, which hands buffered data to `recv` before
  it reports the reset; what the suite holds is that `linger` is set on the
  paths named above and not on the others. A Windows client is the place
  the difference is visible.
