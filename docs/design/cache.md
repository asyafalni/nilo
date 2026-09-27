# The in-process cache

**`nilo_cache` keeps bytes in the program's own memory, inside a fixed budget set once at `open` that never grows, and a Space is a named, typed set of keys that you declare on top of it.**

**Guide:** [A cache in this process](../guide/cache.md) · **Reference:** [`nilo_cache`](../reference/cache.md)

The code is `cache/store.zig` (the ring, the table, the lock), `cache/space.zig` (the typed handle) and `cache/flat.zig` (the compile-time check on a value's shape).

## Overview

```
  Store.open(bytes, shards)  ── one Region (a ring) and one table (ways) per shard
                                        │
     put ── shard's spin lock, held only as long as the copy takes
     incr ─┘  (read, add, write, same lock)

  the ring, one shard:  [ small: a tenth, the doorkeeper | main: nine tenths, second-chance ]
                            first write lands here          promoted here on a second ask

  get ── no lock: copy the bytes, then re-read the ring's cursor (Mark)
         cursor moved past the entry while copying → thrown away, counted as an eviction

  cache.Space(name, T) ── the caller's typed handle onto one Store
```

## Rules

1. **A Space is a named, typed set of keys over one Store, and its value type must be flat**: no pointer anywhere inside it, at any depth. This is checked field by field while compiling. Nothing on the other side would keep what a pointer points at alive. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
2. **Each shard stores its bytes in one ring, sized once at `open` and never resized.** No entry is allocated on its own, so nothing is freed, there is no free list to fragment and no size class to waste space. An entry is alive exactly until the ring's cursor writes over it. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
3. **A write takes the shard's spin lock, and nothing inside the lock ever waits.** The lock is `tryLock` plus a spin, not a `std.Io.Mutex`, because this module has no `Io` to give one. A `memcpy`, a key comparison, choosing what to evict and `incr`'s read-add-write all fit inside it; a callback or computing a missing value never may. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
4. **A read takes no lock.** It copies the value out, then reads the ring's cursor again (`Mark`: offset and pass number in one 64-bit word). If the cursor moved past the entry during the copy, the copy is thrown away and counted as an eviction, which is what it is. [ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
5. **A new entry goes into a small doorkeeper area (a tenth of the ring) and only moves to the other nine tenths when it is asked for a second time.** A key nobody asks for again never leaves the small area, so a cache that accepts every write does not push out the entries that matter. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
6. **A dead slot whose fingerprint still matches counts as a ghost**: evidence the key was cached before. Its next write skips the doorkeeper. That evidence is trusted for one lap of the region, no longer. [ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
7. **`incr(key, delta)` runs under the same lock as `put`, saturates instead of wrapping, and keeps the key's existing expiry instead of refreshing it.** A quota counts one fixed window, not a sliding one. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
8. **The table takes a sixth of the budget, and the default is 64 shards.** Both numbers were measured: a sixth is what a ring of that size can actually address, and 64 shards costs nothing in hit rate while keeping the lock off the read-mostly path. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
9. **On aarch64, the reader's second cursor read needs an explicit load-load barrier, and the writer moves the cursor with a `swap`.** There a `seq_cst` load or store is only acquire or release, not a full fence. The bug this closes reproduced on real aarch64 hardware and not on x86. [ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
10. **An in-process cache and a client for another process's cache (such as Redis) are two modules, never one interface over two backends.** They fail differently: one call can never time out and the other can; one can return a value another instance wrote and the other cannot. Hiding that difference turns "the cache is down" into "the cache is cold". [ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)
11. **`nilo_cache` is a tool module, not a Service, because nothing in it waits.** It uses no event loop and its tests run under a plain `zig test cache/cache.zig`. A Redis client would be a Service, because reading a socket waits: the same question gives opposite answers for the two. [ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)

## Decisions

| ADR | What it decides |
|---|---|
| [109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) | The ring, the flat-value rule, the spin lock and what may run under it, two-region admission, `incr`, and the table and shard sizing |
| [110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md) | Why an in-process cache and a Redis client are separate modules and never one interface |
| [152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md) | Reads without the lock: the cursor recheck, the ghost queue, and the memory-ordering proof behind both |

Related topics: why the module needs no `Io` and where it sits is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); `nilo.Allowance` builds its fixed table, sized while compiling, the same way in [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md) (rate-limiting); what a value declared in a handler costs per connection, cited in this module's cost table, is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); the `in_flight` marker that a stampede fix would reuse already exists on the inbound side in [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md) (idempotency).

## Open questions

- **There is no `getOrPut`.** Every caller writes the miss, the compute and the put by hand, so two threads can compute the same value at the same time. The sketched fix is a claim held outside this module rather than a lock inside it, following how `nilo.Idempotent`'s `in_flight` marker does the same job for incoming requests. [The roadmap](../roadmap.md).
- **Whether `Stats` can be turned off.** Counting a read costs 4.2% on eight threads and 7.0% on one now that reads take no lock, and no cheaper exact count has been found. A build flag is sketched, not built. [The roadmap](../roadmap.md).
- **`[]const u8` is the only value type that is not flat.** A struct holding one is rejected by name. The fix (write the slices after the fixed part and point them back into the caller's buffer) is known but not built. [The roadmap](../roadmap.md).
- **`nilo_redis` is not being built.** ADR 110 settles the design; what is missing is a deployment with more than one instance to build it for. [The roadmap](../roadmap.md).
- **Where the remaining gap to quick_cache on eight threads comes from.** Each lever found so far is worth a few percent; nobody has yet run `perf` on both binaries side by side. [The roadmap](../roadmap.md).
