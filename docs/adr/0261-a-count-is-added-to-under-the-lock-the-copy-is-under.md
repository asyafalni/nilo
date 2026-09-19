# 0261 — a count is added to under the lock the copy is under

**Status:** accepted
**Extends:** [ADR 0138](./0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md),
whose rule about the critical section this reads a second time, and
[ADR 0193](./0193-a-request-answered-once-is-answered-the-same-way-again.md),
whose `putIfAbsent` was the first operation to need the scan and the write
under one lock.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0188](./0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md).

## Context

A per-key count — five OTPs per phone number an hour, failed sign-ins per
email, a quota per API key — was a `get` and a `put`, and two requests
between them lost a count. `nilo.Allowance` is the same thing keyed by
address and nothing else. The roadmap held `incr` at *waiting on a design*
for one sentence: ADR 0138 says the lock is held across "a `memcpy` and
nothing else, forever", and an add is not a `memcpy`.

## Decision

**`incr(key, delta)` on a Space whose value is an integer: the read, the
add and the write under the shard's lock, answering the new count.** A
key nobody wrote, or whose entry expired, counts from zero and lives the
Space's `ttl_s`; one already there keeps the expiry it had. The arithmetic
saturates.

**ADR 0138's rule is "nothing that waits", and the `memcpy` was its
example rather than its content.** The sentence was written to keep out a
computation somebody would later find reasonable to do under the lock —
a callback, a fetch, a `getOrPut` that computes the value — because a
critical section with a wait in it is one a spinning lock cannot survive
and a fiber cannot be suspended inside. An integer add is a handful of
cycles with no wait in it, shorter than the copy it sits beside. Reading
the rule as "nothing but a copy" would have refused this while admitting
the key comparison, the fingerprint scan and the eviction ranking that
already run there. The header comment of `store.zig` now says which
reading is meant.

**`write` is one function with a comptime mode**, `put`, `claim` or
`add`, so the ordinary `put` compiles to what it was: every branch on the
mode is on a constant. An add is the claim's scan with two more lines in
it — read the eight bytes that are there, and keep their expiry — and the
sum copied in where the value would have been.

**The expiry is kept, not refreshed.** A count that exists to bound a
window has to be a count of that window: refreshing the TTL on every
attempt is a window that slides with the attempts inside it, and a client
that keeps trying never reaches the hour. Redis's `INCR` keeps the TTL for
the same reason. `del` is what opens the window early.

**Saturating, not wrapping.** A `u8` counter at 255 that wraps to 4 has
opened the quota again; one that stays at 255 has not. `delta` is the
Space's own type, so an unsigned Space counts up only, and a Space that
has to count down is a Space of `i64`.

**A Space of anything but an integer has no `incr`**, and says so while
compiling, naming the Space and the type.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** none. The sum lives in the caller's frame;
  the Space's `incr` is `Store.add` with the id filled in.
- **Memory per idle connection:** nothing. An entry is what an entry was.
- **Throughput:** on a `put`, nothing measurable — the mode is a comptime
  constant and the generated `put` is the same function. On an `incr`,
  one read and one add inside a critical section that was already the
  scan and the copy; under contention it serialises the way `put` does.
  Four threads adding 20,000 each answer 80,000, which is the test and
  the point.
- **Binary size:** one `add` per integer type a program counts with, and
  nothing for a program that counts with none.

## Alternatives

**An atomic add in place.** The ring is unaligned bytes, and a reader
copies with nothing held and asks the cursor afterwards (ADR 0188); a
value rewritten in place under a reader is a torn read that no cursor
check catches. Rejected.

**Refreshing the TTL on every add.** Rejected above: a sliding window is
not the window a quota means.

**`incr` on any flat value.** A struct has nothing to add to. Refused by
name rather than by a compiler error about `+|` on a struct.

**Leaving the rule as "nothing but a copy" and refusing the entry.** The
honest alternative, and the roadmap named it. Rejected because the rule
was never about copying: it was about a lock that cannot park, and the
thing that cannot go under such a lock is a wait.

## Consequences

- `cache/store.zig`: `Store.add(Int, space, key, delta, ttl_s)`, the
  `Mode` union on `write`, and the header sentence about what the rule
  is about.
- `cache/space.zig`: `space.incr(key, delta)`, with the Refusal.
- `cache/refusals/cache_incr_on_a_struct.zig`; `refusals-cache` is 6.
- The roadmap loses "A Space of integers has no `incr`".
