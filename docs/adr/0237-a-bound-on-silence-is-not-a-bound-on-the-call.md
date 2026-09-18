# 0237 — a bound on silence is not a bound on the call

**Status:** accepted
**Extends:** [ADR 0230](./0230-a-deadline-with-no-engine-cancels-a-task.md).
The same two mechanisms, one fiber timer and one cancelled task, armed for
a second clock.
**Keeps:** ADR 0230's rejection of per-read timeouts. This is not one.

## Context

`timeout_ms` bounds a whole call, and since ADR 0230 it fires with or
without an Engine. For a download that is the wrong shape of bound: the
segment's call *is* the transfer, a transfer may honestly take an hour, so
the only honest value is `0`, and that leaves a segment whose peer went
quiet with nothing to end it. fdm, the download manager on `nilo_fetch`,
ran a watchdog for exactly this: every 100 ms, for every one of sixteen
segments, compare the bytes landed against the last reading, and cancel the
task when the count has not moved for ten seconds. Thirty lines and two
fields, recounting a number `nilo_fetch` already knew, because the only
bound nilo offered was the one that could not be set.

ADR 0230 rejected per-read timeouts for a reason that still holds: a server
sending one byte a second satisfies any per-read limit and never finishes,
so an API call needs an end-to-end bound. A transfer is the case where the
end-to-end bound cannot be set and the one-byte-a-second server is not what
is being guarded against: that server is *slow*, and slow is a judgement
across the caller's other fifteen connections that nilo, seeing one, cannot
make. The failure a download meets is a peer that sends *nothing* and holds
the socket: a CDN edge that lost its origin, a NAT that dropped the
mapping, a Wi-Fi handover. What bounds that is time since the last byte.

## Decision

**`stall_ms`, beside `timeout_ms` on `Settings`, `Call` and `Begin`: the
call is `error.Stalled` when no byte has reached this side for that long.**
Zero, the default, is no such bound. The two compose (`timeout_ms` is the
ceiling on the whole call, `stall_ms` is the ceiling on silence inside it)
and a caller sets either or both. The clock starts at `begin`, so a head
that never comes is silence too, and moves with every chunk of body.

**The chunk is noticed by an unbuffered `std.Io.Reader` in front of std's
body reader**, installed only when `stall_ms` is set: its `stream` and
`discard` hand through to the inner reader and stamp the moment. Every way
of reading the body (`take`, `readInto`, `pipe`, the new `stream`, and the
drain in `end`) goes through it, so nothing has to be rewritten as a loop
and nothing is split that was not already split: a chunk is whatever one
call into std's reader hands over, which on the wire is one socket read.

Then each mechanism ADR 0230 built is armed for the second clock the same
way it was for the first:

- **Under an Engine there is one timer, armed for whichever bound is
  nearer**, what is left of the call or `stall_ms`, and the tap re-arms
  it on every chunk. `stall_armed` remembers which it stood for, and
  `blame` names the failure `Stalled` or `TimedOut` from that rather than
  from a clock comparison that could be a microsecond out. A transfer that
  keeps moving re-arms it before it fires, and a silent one fires it
  `stall_ms` after the last byte.
- **Without one, the wait in `bounded` is re-read from the last byte.** The
  step still runs as one task; the caller's wait is the shorter of the
  call's deadline and `last_byte + stall_ms`, and the tap moves `last_byte`
  from the task's thread, so a moving transfer wakes the waiter once per
  `stall_ms` and never cancels it. One atomic rather than a chunk loop.

**`error.Stalled` rather than `error.TimedOut`**, because the caller does
different things with them: a stalled segment is restarted on a fresh
connection and does not count as a failed attempt; a timed-out probe is a
server that cannot carry the load and the download fails.

**`Exchange.stream(w, limit)` is the chunk read inside both clocks.** fdm's
segment loop read chunks off `ex.reader` directly, up to a boundary another
thread may move, and a read made there is outside the engineless bound —
there is nothing to cancel. The same call on the Exchange runs the chunk as
the bounded task; zero is the end of the body.

**A call its own clock stopped is not drained.** `end` already skipped the
drain when the engineless deadline had fired, because a leftover from a
server that went quiet is the read that never returns. The Engine path had
the same hole and nothing had ever reached it: the one Engine-side test
stalled before the head, where there is no body to drain. `blame` now folds
the Engine's `fired()`, which is consumed on asking, into the same two
flags, and `end` reads those. The stall test under the Engine sat at zero
CPU until it did.

## Alternatives rejected

**A per-read timeout.** The one ADR 0230 rejected, for the reason it gave.
A read that takes a minute because the server is slow is not a failure, and
`stall_ms` does not call it one: the clock moves on every byte, however far
apart the bytes are.

**Re-running each step as a loop of chunk-sized tasks without an Engine**,
which is what the proposal sketched. It costs a thread hop per chunk on the
path that asks for it, and it makes `take` and `pipe` two implementations
each. The tap gets the same answer from one atomic and one wait per
`stall_ms`, and the step stays one task.

**A second `Bound` for the stall under the Engine.** 192 bytes of Engine
slot on a struct that sits on every handler's stack that dials out, for a
bound that is never armed at the same time as the first in a way one timer
cannot express: at any moment exactly one of the two is nearer.

**Leaving it to the caller.** Which is the watchdog fdm wrote, and the
thing this module exists to make unnecessary. The number it recounts,
when the last byte landed, is one only the reader has.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | `@sizeOf(Exchange)` 928 → 992: the tap reader (40 bytes), the inner pointer, the last-byte word, and three small fields. Measured on `bench/fetch_server.zig`'s `/call` at 5,000 connections, interleaved twice against `HEAD`, with ADR 0238's buffer removal in the same diff: 9,450 / 9,451 before and 9,437 / 9,437 after, so the two together are inside the run-to-run spread and read as **unchanged** |
| Throughput and p99 | with `stall_ms` unset, one branch at `begin` and the reader std hands back unchanged. With it set: one indirect call and one atomic store per chunk; under an Engine one timer release and arm per chunk; without one, one futex wake per `stall_ms` of silence |
| Binary size | not measured separately; the tap is two small functions |

## What proves it

`fetch/live.zig`, on `std.Io.Threaded` with no Engine: a server that sends
a head and three bytes and holds the socket is `error.Stalled` in about
200 ms under `.timeout_ms = 0, .stall_ms = 200`, and the permit comes back;
a server that sends eight bytes 60 ms apart (480 ms of body under a 200 ms
silence bound) is answered whole. The same pair under the Engine in
`fetch/deadline.zig`, where the second one is the proof of the re-arm: a
timer armed once at `begin` would have fired at 200 ms. And the chunk loop
a download manager writes, through `Exchange.stream`, stalls the same way.

With it, fdm's segment task returns `error.Stalled`, the restart path it
already has for a failed attempt does the rest, and `last_seen`,
`last_moved_ms`, the branch that compared them and the `future.cancel`
inside it go. The rate sampling stays, because that is a decision across
sixteen connections and nilo sees one.
