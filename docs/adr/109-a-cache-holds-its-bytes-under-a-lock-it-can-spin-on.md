# A cache holds its bytes in a ring, admits what mattered, and writes under a lock it can spin on

**Status:** accepted
**Topic:** [cache](../design/cache.md)

## Context

`nilo_cache` is `http/allowance.zig`'s table with a harder value: a fixed table, ways to a bucket, a fingerprint per way, the stalest way forgotten when a bucket fills, nothing allocated ever, one 64-byte cache line touched per request ([ADR 092](./092-an-allowance-is-a-table-sized-while-compiling.md)). A `Cart` is not a `u64`, so the bytes live in a ring the cache owns, sized once at `open`, rather than behind a table cell. go-cache is the design this is not: it stores `interface{}` and hands back a pointer, which works because Go collects garbage. The question it never has to answer, who owns the bytes a reader is holding, is this file's whole subject.

Three questions had to be answered once bytes moved into a ring a writer can lap: how a slot says whether its entry is still there, what protects a writer and a reader from each other, and which entry a full cache should forget first. The third one looked answered and was not: the benchmark that checked it drew its keys uniformly at random, the one distribution where an eviction policy provably cannot matter, so every policy scored the same and the score read as "no cliff" when it was the harness agreeing with itself. On Zipf 0.99, the traffic shape real caches see, the shipped policy was scoring 78% of the best a cache that size could reach.

## Decision

**A slot says where an entry is and which pass over the ring wrote it. A write takes the shard's spin lock and stays inside it only as long as a copy takes. New entries are admitted through a small doorkeeper region before they earn a place in the main ring, so eviction is by usefulness rather than by write order alone.**

### Eviction is what writing does

An offset and a pass number (later folded into one word, `Mark`, [ADR 152](./152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)) rather than a monotonically increasing position, because a position has to be masked and masking needs a power-of-two ring, a rounding a caller pays for: flooring a 12 MiB budget to an 8 MiB ring left a third of it unreachable, and the first working version of this module cost 125.8 bytes an entry against go-cache's 96.9. Nothing in the sizing is rounded now: the table takes what `entries` implies, the ring takes the rest exactly, and `bytesHeld()` is never above the `bytes` it was given. Nothing is freed because nothing is owned individually, no free list fragments, and no size class wastes.

### The lock cannot be a mutex, and that is the language's decision

Zig 0.16's `std.Io.Mutex.lock` takes an `io: Io`, because parking a caller on a futex is something only a runtime can do, and a module with no event loop has no `Io` to hand it. A mutex would put `Io` into `get`'s signature, and needing no loop is the entry condition for the layer this module sits in ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md), [ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)), the property that lets `zig test cache/cache.zig` run the whole module with no build graph, and lets a program that is not a server import it.

What is left is `tryLock` and a spin. **That forces a rule rather than merely allowing one: the critical section must stay short enough to spin on**, forever. It is the same sentence that makes the lock safe to hold inside a fiber, a fiber only moves at a point that waits, and a critical section with no wait in it always finishes and releases. The rule is load-bearing and easy to break later by adding something reasonable inside the lock, so it is in the file's header comment as a refusal, not a note. **What "nothing that waits" means is a question about waiting, not about which instruction runs**: a `memcpy` was the rule's original example, and the key comparison, the fingerprint scan, the eviction ranking, and the read-add-write an `incr` does are all inside the same bound, because each is a handful of cycles with no wait in it. What may never go under the lock is a computation somebody would later find reasonable to add there anyway, a callback, a fetch, a `getOrPut` that computes the value, because a critical section with a wait in it is one a spinning lock cannot survive and a fiber cannot be suspended inside.

**A reader was believed to need no lock, and the measurement said otherwise.** The shape that fails reads correct: take the slot's position, copy the key and value out of the ring, and check afterwards that the window still holds that position. The hole is that the reader is not the only thread that can be interrupted: a *writer* descheduled inside its own `memcpy` is lapped by the ring and writes its bytes over an entry newer than itself, whose position still passes every check the reader makes. [`spike/cache_ring/`](../../spike/cache_ring/) put a number on it, on two cores: a lock-free ring gave 7 wrong answers in 19,944,448 gets at one shard and 8 at sixteen, with two writers and two readers; with one of each it gave zero, and a spin lock at 2+2 for 30 seconds gave zero across 73,246,976. Sharding did not fix it (sixteen rings made it eight rather than seven, because the race is inside one ring), and it needed more threads than cores, which is the failure appearing exactly when the machine is busy, exactly when a cache is being used at all. **This module's answer is a write lock, not the lock-free ring**, and [ADR 152](./152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md) is what later took the lock off the *read* side specifically, by relying on a writer being alone in its shard rather than on no lock existing at all.

### A cache that admits everything forgets what mattered

`bench/cache_bench.zig` drew its keys uniformly at random. **Under uniform random every eviction policy scores the same**, `capacity / working set`, because knowing which entries were read recently tells you nothing about which will be read again. That is exactly what read as "no cliff" above. Measured against the analytic ceiling for a stationary Zipfian, `zeta(K) / zeta(N)`, the module was scoring 78% of it at 128 KiB and 85% at 512 KiB, while scoring 100% of the uniform-random one. **A benchmark that cannot distinguish two designs will report that the worse one is fine.**

The fix is two regions rather than one ring. A shard's ring is cut in two: a new entry goes into `small`, a tenth of it, which therefore laps ten times as fast. A key asked for a second time while it is still in `small` is copied into `main` and gets the other nine tenths to live in; one never asked for again never leaves the tenth it came in through. This is S3-FIFO's shape, costing no extra memory: which region a slot is in is read from its offset, so the admission test is a second question rather than a data structure, "is this entry still in the tenth?". Inside `main`, two bits taken from the 16-bit fingerprint hold a saturating frequency counter, bumped on a hit, that ranks a bucket's ways and copies a warm entry back to the head before the cursor reaches it, making `main` a second-chance queue rather than a plain FIFO.

Zipf 0.99, 100,000 keys, 5M lookups, read-through:

| budget | before | after | ceiling | of best |
|---|---|---|---|---|
| 128 KiB | 52.4% | **64.2%** | 66.7% | 78% → 96% |
| 512 KiB | 67.0% | **75.6%** | 78.3% | 85% → 96% |
| 1 MiB | 74.9% | **81.4%** | 84.2% | 89% → 97% |
| 4 MiB | 92.7% | **94.1%** | 96.1% | 96% → 98% |

Read as memory, which is what a cache spends: 75.6% used to need 1 MiB and now needs 512 KiB, two to three times less for the same hit rate, widest exactly where the budget is tightest.

**The doorkeeper only engages once there is something to keep out.** A cache still filling has nine tenths nothing is competing for; sending unread entries through the tenth anyway took a store holding 78,875 entries down to 8,065 and made `perEntry` report 520 ring bytes for a 16-byte value against 53. So admissions go straight to `main` while it has never been round (`main.gen == 1`), one compare. The property that follows had to be stated rather than discovered: `main` advances only when something is promoted into it, so a cache written to and never read holds its first entries indefinitely, harmless (nothing is asking for them, and a TTL still expires on read) but a real change from "the ring forgets the oldest first".

**The table was twice the size the ring could fill.** `Store.open` gave the table a quarter of the budget without knowing what the caller stores: a slot is 8 bytes, so a quarter is `bytes/32` slots, while a three-quarter ring holds roughly `bytes/61` entries (12 header bytes plus key plus value). At a sixth the table matches what the ring can address, at no cost in hit rate and a real one in throughput:

| table share | held | bytes/entry | hit rate | 1 thread | 8 threads |
|---|---|---|---|---|---|
| 1/4 (shipped) | 67,499 | 62.1 | 92.7% | 22.7M | 127.0M |
| **1/6** | **67,711** | **61.9** | **92.7%** | **24.4M** | **133.4M** |
| 1/8 | 59,498 | 70.5 | 91.5% | 28.4M | 148.6M |

An eighth is faster again and pays in hit rate, the wrong currency here: an operation is 40 ns and a miss is a database round trip, so a point of hit rate buys more than 25% of operation speed sells.

**The shard default was costing two thirds of the machine, and it was not the lock's fault.** Every `get` took its shard's lock, so few shards turn a read-mostly load into a queue. Nine reads to a write on eight cores: 16 shards 87.4M ops/s, 64 shards 125.0M, 256 shards 143.6M, and 256 shards with the lock removed altogether 145.6M. The lock was worth 1.4%; the shard count was worth 64%. The default is 64 rather than 256 because 256 costs 4.5 points of hit rate at 512 KiB and 64 costs none at any size. A separate bug compounded the old default: `shard_mask` is `shards.len - 1` used as a bitmask, correct only when the count is a power of two, and `Store.open` made the request a power of two and *then* clamped it to `total_cap / 4096`, leaving a third of a small budget unreachable at the 64 KiB minimum and 78% unreachable at 192 KiB with 64 shards; `bytesHeld()` counted all of it. Flooring the request after the clamp fixed it, with a test.

### `incr`, under the same lock and the same rule

A per-key count, five OTPs per phone number an hour, failed sign-ins per email, a quota per API key, was a `get` and a `put`, and two requests between them lost a count. `nilo.Allowance` is the same thing keyed by address and nothing else.

**`incr(key, delta)` on a Space whose value is an integer: the read, the add and the write happen under the shard's lock, answering the new count.** A key nobody wrote, or whose entry expired, counts from zero and lives the Space's `ttl_s`; one already there keeps the expiry it had, not a refreshed one, because a count that exists to bound a window has to be a count of that window (Redis's `INCR` keeps the TTL for the same reason; `del` is what opens the window early). The arithmetic saturates rather than wraps, so a `u8` counter at 255 stays at 255 instead of opening the quota again by wrapping to 4; `delta` is the Space's own type, so an unsigned Space counts up only, and a Space that has to count down is a Space of `i64`. `write` is one function with a comptime mode, `put`, `claim` or `add`, so the ordinary `put` compiles to what it was, every branch on the mode is on a constant, and an `add` is the claim's scan with two more lines, reading the eight bytes that are there and keeping their expiry. A Space of anything but an integer has no `incr`, and says so while compiling, naming the Space and the type.

### Sizing, which the module documents rather than guesses at

Holding an entry costs 8 bytes of slot, 12 bytes of ring header carrying the expiry, the Space and the two lengths, and the key. Eight eight-byte slots are one cache line, where four sixteen-byte ones were: the same line touched, half the table, and better retention, because a key arriving at a full bucket is what a set-associative table loses and eight ways lose far fewer of them than four. The lengths are in the ring rather than the slot for the arithmetic: a byte in the ring is paid once per entry, a byte in the slot is paid for every slot whether or not anything is in it. The key is in the ring on purpose: a fingerprint is 16 bits and a bucket holds eight, so a collision is ordinary, and the full key comparison behind it is what makes one a wasted probe rather than somebody else's value, because a cache that is quietly wrong is worse than one that misses. A value has a 64 KB ceiling, the header's 16-bit length, and the refusal names it.

The current design costs **64.3 bytes an entry** (against go-cache's 97.5, on the same 200,000-entry measurement), 1.6% over an earlier single-region figure of 63.3, the two regions rounding separately.

## Measured against go-cache, which wins the half it was built to win

[patrickmn/go-cache](https://github.com/patrickmn/go-cache), same box, same load, interleaved three times ([`bench/result/cache.md`](../../bench/result/cache.md)):

| | nilo_cache | go-cache |
|---|---|---|
| 200,000 entries | 63.3–64.3 bytes/entry, 99.1% retrievable | 97.5 bytes/entry, all of them |
| a flat 24-byte value, read | 3.7–4.4M ops/s | 6.0–6.2M ops/s |
| a 512-byte value, read | 1.9–2.0M ops/s | 6.1M ops/s |
| memory when you did not ask | cannot grow | grows |

It uses a third less memory and is between a third and three times slower, and the second half is structural: go-cache hands back a pointer into memory a collector owns, this hands back a copy, because there is no collector to hold the other end, the reason the pointer could not be stored in the first place. On small values the gap is a cache miss: Go's map keeps the key beside the probe, so a lookup is one dependent miss, where this has a slot that points at a ring, two. One entry in this table was wrong the first time: comparing against the very string objects go-cache had stored let Go's pointer-equality fast path make its own key comparison free, reading as a 1.64× gap; giving it a separate copy of the same text, what a key built from a request actually is, moved it to 1.32×. A benchmark against another language's collection can hand it a shortcut this one has no way to take, invisibly.

## What was rejected

**The lock-free ring, as a fast path or behind a flag.** Wrong roughly once in 300,000 hits with more threads than cores. Handing back another entry's bytes is the one failure a cache may not have, and an option that is wrong is not an option.

**Sharding instead of locking**, and (separately) tuning the rescue rule instead of adding a second region: at 128 KiB a 2,137-entry ring laps every ~4,550 lookups under Zipf 0.99, so only the top ~400 keys are ever warm when the cursor arrives, and no threshold reaches the rest. The question was never which entry to save; it was that every miss was being admitted.

**`std.Io.Mutex`.** It needs an `Io`, and taking one costs the module its layer.

**A checksum per entry, verified on read.** Turns corruption into a miss rather than preventing it, at a probability of letting one through, in exchange for avoiding a lock that measured free when uncontended.

**A fixed-size value inline in the slot.** No ring, no lapping, no lock, but it either wastes most of a slot on small values or refuses the row-sized ones the module exists for.

**An allocation per entry, the way go-cache does it.** An allocation per put on the axis [ADR 017](./017-the-trade-budget-has-four-axes.md) treats as fixed, and without a garbage collector it leaves the reader's copy with no owner.

**A ghost queue or a frequency sketch** for admission. Both are the standard answer and both cost memory this module refuses to spend; the table already remembers a key whose entry the ring took (`Stats.evicted`), and the two-region split gets the same admission property out of the ring itself.

**Making `small` a fixed fraction of writes rather than of space.** Admits one-hit-wonders into the main ring for a full lap, the thing being prevented.

**Leaving the uniform-random benchmark as the only one.** Kept for contrast: a policy scoring 100% of best on uniform random and 78% on Zipf is how a cache hides a missing policy for a year.

**A seqlock, or any lock-free read, when the admission work above was measured.** Removing the lock entirely, at 256 shards, bought 1.4% on eight threads and nothing at all on one (29.4 ns against 29.3), and the design work it would have taken read as a rounding error. **That measurement did not survive being taken again against a store sized for its working set**: at 64 shards and an 8 MiB store the same removal was worth 13.3%, because most of the earlier 1.4% was memory latency on an 11 MiB table holding 50,000 keys rather than the lock. [ADR 152](./152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md) is what took the lock off reads once the smaller, more representative store showed the number the first measurement had hidden.

**Leaving the `incr` rule as "nothing but a copy" and refusing the entry.** The honest alternative, and the roadmap named it. Rejected because the rule was never about copying, it was about a lock that cannot park, and the thing that cannot go under such a lock is a wait, which an integer add is not.

**An atomic add in place, for `incr`.** The ring is unaligned bytes, and a reader that copies with nothing held and asks the cursor afterwards ([ADR 152](./152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)) would see a torn read that no cursor check catches. **Refreshing the TTL on every add.** A sliding window is not the window a quota means. **`incr` on any flat value.** A struct has nothing to add to, refused by name rather than by a compiler error about `+|` on a struct.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. `get` and `incr` take the caller's buffer and there is no allocator anywhere in the module; not even an arena allocation, one better than [ADR 017](./017-the-trade-budget-has-four-axes.md) would have allowed on a route that asked for it. |
| Memory per idle connection | None. The table and the ring are the process's, allocated once at `open`. What a handler declares to receive a value into is stack, held per connection for the life of it ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), so a route reading a 1 KB value adds 1 KB per connection, the caller's number rather than this module's. |
| Throughput and p99 | Free uncontended; contended, the write lock costs roughly 1.4% at 256 shards (below). The two-region admission costs one thread 8–10% (a `get` writes a frequency counter on a hit until it saturates, and `put` ranks eight ways by liveness and warmth rather than age) against +29% to +50% on eight threads and 2–3× the hit rate per byte, the right side of the trade for a module whose caller is a server, the wrong side for a single-threaded program. `incr` costs one read and one add inside the same critical section as the scan and the copy; under contention it serialises the way `put` does. |
| Binary size | Paid only by a program that imports it, being a module of its own rather than a file under `http/`; one `add` per integer type a program counts with. |

**And `nilo_http` does not name this module.** A handler asks for `*Carts` in its argument list and gets it from `app.provide`, the way it gets any service, which needs no wiring between the two modules, because a `Space` is a type the *caller* declared. There is no `http/cache.zig`: the front half `nilo_pw` needed exists because a hash holds a thread for 13 ms, and a cache lookup holds one for a few hundred nanoseconds.

**Reads no longer take this lock at all.** [ADR 152](./152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md) replaced the read-side lock with a second look at the cursor after the copy, on the strength of the fact this ADR already relies on: a writer is alone in its shard, so the cursor it publishes is the whole truth about where writing is happening. This ADR's "every operation under one lock" now holds for writes only.

## Consequences

- `cache/store.zig`: the `Region`/`Mark` shape, the `Mode` union on `write` (`put`, `claim`, `add`), `Store.add(Int, space, key, delta, ttl_s)`; `cache/space.zig`: `space.incr(key, delta)`, with the Refusal for a non-integer Space.
- The header comment states both refusals plainly: the critical section holds nothing that waits, and (per ADR 152) a read takes no lock.
- Two tests in `store.zig` for the admission property: a working set that moves takes the old one's place, and a key read twice survives a flood of keys read never.
- `refusals-cache` gained the non-integer `incr` case; the roadmap lost "A Space of integers has no `incr`".
