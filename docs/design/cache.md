# The in-process cache

**`nilo_cache` holds bytes in this process's own memory, in a fixed budget taken once at `open` and never grown, and a Space is the named, typed keyspace a caller declares over it.** How to use it is the guide ([`guide/cache.md`](../guide/cache.md)); every name and signature is the reference ([`reference/cache.md`](../reference/cache.md)). The code is `cache/store.zig` (the ring, the table, the lock), `cache/space.zig` (the typed handle) and `cache/flat.zig` (the compile-time check on a value's shape).

## How the pieces fit

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

## The rule in force

1. **A Space is a named, typed keyspace over one Store, and its value must be flat**: no pointer anywhere inside it, at any depth, checked by field path while compiling. There is no collector on the other end to keep what a pointer points at alive. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
2. **The bytes live in one ring a shard, sized once at `open` and never resized.** Nothing is owned individually, so nothing is freed, no free list fragments and no size class wastes; an entry is live exactly while the ring's cursor has not written over it. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
3. **A write takes the shard's spin lock and the critical section holds nothing that waits**, ever, because the lock is `tryLock` and a spin, not a `std.Io.Mutex`, since this module has no `Io` to hand one. A `memcpy`, a key comparison, an eviction ranking and `incr`'s read-add-write all fit; a callback or a computed miss never may. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
4. **A read takes no lock at all.** It copies the value out, then reads the ring's cursor a second time (`Mark`, offset and pass number in one 64-bit word); if the cursor passed the entry while the copy was in flight, the copy is thrown away and counted as an eviction, because it is one. [ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
5. **A new entry is admitted through a doorkeeper, a tenth of the ring, and only earns the other nine tenths on a second ask.** A key nobody asks for again never leaves the tenth it came in through, which is what keeps a cache that admits everything from forgetting what mattered. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
6. **A dead way whose fingerprint still matches counts as a ghost**, evidence the key was here before, and skips the doorkeeper on its next write; one lap of the region is as far back as that evidence is trusted. [ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
7. **`incr(key, delta)` runs under the same lock `put` does**, saturates rather than wraps, and keeps the expiry a key already had rather than refreshing it: a quota is a count of one window, not a sliding one. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
8. **The table takes a sixth of the budget and the default is 64 shards**, both measured rather than guessed: a sixth is what a ring at that budget can actually address, and 64 shards is the count that costs nothing in hit rate while still taking the lock off the read-mostly path. [ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)
9. **On aarch64 the reader's second cursor read needs an explicit load-load barrier, and the writer's cursor move is a `swap`**, because a `seq_cst` load or store is only acquire or release, not a full fence, and the bug it closes reproduced on real hardware and not on x86. [ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
10. **An in-process cache and a client to somebody else's process are two modules, never one interface over two backends.** What can fail differs: a call that never times out against one that can, a value another instance wrote against one that cannot arrive. Hiding that turns "the cache is down" into "the cache is cold". [ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)
11. **`nilo_cache` is a tool module, not a Service**, because nothing in it waits: it names no loop and runs under a plain `zig test cache/cache.zig`. A Redis client would be a Service, since reading a socket waits; the same question gives the two opposite answers. [ADR 110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)

## Decisions

| ADR | What it decides |
|---|---|
| [109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) | The ring, the flat-value rule, the spin lock and its critical-section rule, two-region admission, `incr`, and the table/shard sizing |
| [110](../adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md) | Why an in-process cache and a Redis client are separate modules and never one interface |
| [152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md) | Taking the lock off reads: the cursor recheck, the ghost queue, and the memory-ordering proof behind both |

Beside this topic: why the module needs no `Io` and sits where it does is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); the fixed, sized-while-compiling table `nilo.Allowance` builds on the same shape is [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md) (rate-limiting); what a value a handler declares into costs per connection, cited in this module's own cost table, is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); the `in_flight` marker a stampede fix would reuse already exists on the inbound side in [ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md) (idempotency).

## Open

- **There is no `getOrPut`.** Every caller writes the miss, the compute and the put by hand, so two threads can compute the same value at once; the shape sketched is a claim outside this module rather than a lock inside it, on the strength of `nilo.Idempotent`'s `in_flight` marker doing the same job on the inbound side. [The roadmap](../roadmap.md).
- **Whether `Stats` may be absent.** Counting a read costs 4.2% on eight threads and 7.0% on one now that a read holds no lock, and there is no cheaper exact version found so far; a build flag is sketched, not built. [The roadmap](../roadmap.md).
- **A value of `[]const u8` is the only shape that is not flat.** A struct holding one is refused by name; the fix, writing the slices after the fixed part and pointing them back into the caller's buffer, is known and unbuilt. [The roadmap](../roadmap.md).
- **`nilo_redis` is not being built.** The design is settled by ADR 110's position; what is missing is a deployment with more than one instance to build it for. [The roadmap](../roadmap.md).
- **Where the remaining gap to quick_cache on eight threads goes.** The levers found so far are each a few percent; nothing has run `perf` on both binaries side by side. [The roadmap](../roadmap.md).
