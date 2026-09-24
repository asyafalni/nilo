# A lookup asks the cursor afterwards instead of taking a lock

**Status:** accepted
**Topic:** [cache](../design/cache.md)

## Context

[ADR 109](./109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) put every cache operation behind one spin lock a shard, including reads. That was most of what separated this module from the fastest cache measured against it: on eight threads, four builds side by side put the lock at 10% of the figure and the writes a read does inside it at another 16% ([`bench/result/cache.md`](../../bench/result/cache.md) §5). A read can be made to take nothing at all, because the ring already answers the question the lock was being held to answer: a region is a cursor that only goes forwards, and an entry is live exactly while the cursor has not written over it yet.

The first attempt at this, a lock-free ring recorded in ADR 109, was wrong: it let **writers** run concurrently, so a writer descheduled inside its own `memcpy` could be lapped by another writer, and the bytes at an offset could be older than the cursor said with no reader able to tell. Sharding did not fix it, because the race is inside one ring. What makes this design different is that a writer is still alone in its shard: the cursor it publishes is the whole truth about where writing is happening, and a reader comparing against it is comparing against something that cannot be stale in the direction that matters.

## Decision

**A lookup copies the value out with no lock held, then reads the ring's cursor a second time; if the cursor moved past the entry while the copy was being made, the copy is thrown away and counted as an eviction. Writers still take the shard's lock against each other.**

1. `reserve` publishes the moved cursor **before** the caller copies a byte.
2. A lookup reads the slot, reads the entry, copies the value into the caller's buffer, and then reads the cursor **again**.
3. If the cursor has passed the entry in between, some `put` was writing over those bytes while they were being read. The answer is thrown away and counted as an eviction, which is what it is.

That is a seqlock whose sequence number was already there and already read: the second load is of the same word the liveness check reads anyway. The offset and the pass number live in one 64-bit `Mark` so both arrive in one load, because two fields would let a reader take the offset from before a wrap and the pass number from after it, and conclude that an entry the ring had just written over was still there.

### What says so, rather than what argues so

A soak: sixteen threads, a quarter of the operations writes, values of every length from 8 to 908 bytes so entries never line up, a budget small enough that the ring laps continuously. Every value is self-describing, its length and every byte come from the key's number, so half of one entry and half of another is caught, and so is a value read out of somebody else's bytes. **542 million verified hits across six shapes, none wrong.** With the second cursor read deleted and nothing else changed, the same shapes gave 14,564 wrong answers on sixteen threads, 2,864 on another, and 519 on eight: a test that cannot fail proves nothing, and that control is what says this one can. A short version runs in the suite, `test "a lookup that holds no lock never hands back a value that is not the key's"`.

### The ghost that costs no memory

`put`'s first loop already walks exactly the ways whose fingerprint could be this key, and steps past the dead ones. A dead way whose fingerprint matches is a record that *this key was here and the ring took it*, S3-FIFO's ghost queue, with nothing allocated for it. A key with a ghost skips the doorkeeper and goes straight to `main`, worth +0.1 to +0.3 points of hit rate on every size measured, and one lap of the region is what measured best (ten laps of `small`, the same stretch of writing as one lap of `main`, measured *worse* on five of six sizes while holding 3% more entries: a ghost reaching back too far stops being evidence about this key and becomes evidence that keys exist). The same reordering fixed a second thing for free: `put`'s same-key scan now runs before the region is chosen, so a key already in `main` is not sent back through the doorkeeper by being refreshed, where the old order demoted every refresh into the tenth of the ring that laps ten times as fast.

### The orderings, argued on the processor that runs them

Every ordering here is a promise about *one direction*, and a `seq_cst` on a single load or store adds nothing in the other: a `seq_cst` load is an acquire (nothing after it moves before it) and a `seq_cst` store is a release (nothing before it moves after it). x86 forbids reordering loads against loads or stores against stores on its own, so on x86 the orderings only had to hold the compiler, and they did. aarch64 forbids neither, and the first time the suite ran on an Apple M1 Pro, the seqlock test reported one to three wrong answers per run in five of nine runs, because a `seq_cst` load is only an acquire and the copy a lookup does comes *before* it: the bytes could be read after the cursor is, checking a cursor that has not yet moved against a value that has already been overwritten. Every word of the original design was checked on the processor that could not exhibit the bug.

What was measured, three variants each a separate `ReleaseFast` binary, interleaved for three rounds at one and eight threads on the M1 Pro:

| | correct on aarch64 | 8 threads, reads |
|---|---|---|
| as first shipped | no (5 of 9 runs wrong) | not applicable |
| both sides a `seq_cst` read-modify-write | yes (0 of 9) | −30% to −33% |
| reader `dmb ishld`, writer `swap` | yes (0 of 8) | inside the spread of the original |

The read-modify-write is the portable answer, and it loses on aarch64 for the same reason it was rejected on x86: every reader writes the cursor's cache line, and eight of them pass it round. The fence that wins is a load-load barrier and nothing else, precisely the sentence the reader's proof was missing and not one word more.

**The orderings as shipped:**

- `reserve` (the writer's move of the cursor) is a `swap` everywhere but x86_64, where it stays a plain store; a read-modify-write is acquire and release at once, so the `memcpy` after it cannot land first. It runs under the shard's lock, so the line is not contended.
- `settled` (the reader's second look at the cursor) issues `dmb ishld` on aarch64 before the load; on x86 the line compiles to nothing, because x86 already forbids the reorder the fence exists to stop.
- `Slot.load` is **acquire**, because the cursor is read after the slot: without it, a slot a `put` has just written could be judged against a cursor from before that same `put` moved it, and a key just stored would read back as a miss.
- The bucket scan's eight loads are **unordered**, the weakest ordering that is still not a race: it may see any one write but never half of two, which is all the scan needs, since what it returns is a list of candidate ways and every one is loaded again with its whole key compared.
- Every other slot access is an atomic load or store of the whole eight bytes, because a slot is written by `put`, by `carry`, by a reader clearing an expired entry and by a reader warming one, so a plain field write would be a race whatever the hardware does; it costs nothing, eight aligned bytes is one `mov` either way.
- `carry` swaps the slot rather than storing it, because a reader may have warmed or cleared it while the copy was being made, the first a reason to try again, the second a reason to stop.

x86 is byte-for-byte what was first measured; its figures stand.

## What was rejected

**A reader-writer lock**, the obvious answer. Sharing the lock was worth 11% on eight threads and cost 11% on one: two atomic read-modify-writes per lookup is a large fraction of what a 30 ns lookup costs, and one thread pays them with nothing to gain. Taking nothing was worth 12% more than sharing, on both thread counts. Its first version cost a separate lesson: moving the promotion out of the read and having `promote` re-find the key by walking the bucket again measured 2.5% slower than the exclusive lock it replaced, because about an eighth of reads want a promotion, and an eighth of reads paying a second lock and a second scan costs more than seven eighths gain from running together. Handing back the way rather than the key is what made it a win.

**One set of counters per thread instead of per shard.** Counting a read costs 4.2% of the eight-thread figure and 7.0% of the one-thread figure once the increment has to be atomic; lanes measured 1.5% better on eight threads and 3% worse on one, a lane lookup buying back contention it also pays for. Per shard stayed.

**A wider ghost window**, above: ten laps of `small` measured worse than one.

**The read-modify-write on both sides, for the aarch64 fix.** Correct, portable, and a third of the read throughput at eight threads.

**A fence on the writer too, `dmb ish` after the store.** The symmetric answer, and it would work; the swap was measured and the fence was not, and the swap needs no inline assembly, where a second asm line for a path that already holds a lock buys nothing known.

**Gating the whole lock-free path to x86 and taking the lock elsewhere on aarch64.** A working cache on aarch64 at the pre-fix speed, but it leaves the module with two concurrency designs, one of which nobody runs the benchmark against, when the fence costs nothing measurable.

**Relying on `seq_cst` meaning a full barrier.** LLVM emits it as `xchg`/plain `mov` on x86 and as `ldar`/`stlr` on aarch64, which are acquire and release and not barriers; the language never promised more than it delivers, and the original design read the x86 assembly and called it the model.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | Zero. Nothing here allocates. |
| Memory per idle connection | Zero. The `Mark` is the two fields the region already had, folded into one word; `Counters` moved to a cache line of its own (64 bytes a shard), which was false sharing before. |
| Throughput and p99 | Reads: +13% at eight threads, −1% at one, interleaved, four rounds a side; hit rate up 0.1 to 0.3 points at every size from the ghost window. Writers: unchanged on x86; the aarch64 fence adds one load-load barrier to the reader's second cursor read and turns the writer's cursor store into a `swap`, both inside the already-uncontended shard lock. |
| Binary size | Unchanged to the nearest kilobyte; one instruction of inline assembly behind a comptime arch check, for the first time in a tool module. |

## Consequences

- **A hit can now be counted as an eviction**, when a `put` overwrote the entry while it was being read. Rare, and the truthful classification, but `Stats.evicted` is no longer only about the ring being too small.
- `Store.stats()` takes no lock: the counters are atomic and nothing branches on them, so the answer is a sum over a moving target either way. `Store.clear()` writes the slots one at a time rather than in one `memset`, because a lookup that holds nothing may be reading any of them.
- ADR 109's header sentence, every operation under one lock, is superseded for reads and still holds for writes.
- `zig build test` is green on an aarch64 machine for the first time; every test under `cache/` passes five of five runs with the fence and fails three of three without it.
- A proof about memory ordering carries the architecture it was argued on, the way a benchmark carries its machine. The place to check is the *other* direction of every `seq_cst`: what it does not pin is where the next bug like this one is.
