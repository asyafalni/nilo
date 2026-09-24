# A caller that knows says `discard`

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)
**Extends:** the drain policy in `fetch.zig`'s header and
`Exchange.dropIfDrainIsDearer`.

## Context

`Exchange.end` decides whether to drain an unread body or drop the
connection from `max_drain` and the announced length, and that is the right
default: a leftover cheaper than a handshake is read, one dearer is dropped.
fdm's probe asks for one byte of a file and is sometimes answered `200`
with the whole file. It set `max_drain = 4 << 10` on the client to be sure
that drops — turning a policy for every call into a lever pulled for one.

## Decision

**`ex.discard()` — "I will not read this body; close the connection."**
It marks the connection closing, so `end` neither drains nor keeps it; the
permit still goes back. For the caller who knows what `end` would otherwise
have to weigh, and `max_drain` stays a policy rather than a lever.

The private `discard` the stale-connection retry used is now `forget`,
because it does a second thing — it also drops the attempt — and a public
name should not be two things.

## Alternatives rejected

**Lower `max_drain` per call.** A `Call` override would work and would be
the wrong axis: the caller does not know a number, it knows *this body is
not wanted*, and that is what it should be able to say.

## What it costs

Nothing on any axis: one `bool` store on a connection the caller was about
to give up. The test refuses a 32 KiB body under a 1 MiB `max_drain` — the
control that would have kept the connection — and counts two accepts.
