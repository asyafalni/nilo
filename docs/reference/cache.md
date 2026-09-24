# nilo_cache

One page of [the reference](./README.md): an expiring cache in this process.

## `nilo_cache`

An expiring cache in this process, and nothing that needs a loop
([ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).
A tool module: it imports nothing, so `zig test cache/cache.zig` runs the whole
of it and a program that is not a server can take it on its own.

<!-- compiles: body -->
```zig
// once, where the program starts
store = try cache.open(gpa, .{ .bytes = 64 << 20 });
defer store.deinit();
carts = Carts.open(&store);

// and wherever the work is
carts.put("u42", .{ .owner = 42, .items = 3, .total_cents = 125_000 });
if (carts.get("u42")) |cart| {
    _ = cart.items;
}
```

`Carts` is a type of your own, declared once beside the others:

```zig
const Cart = struct { owner: u64, items: u16, total_cents: u64 };

const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });
```

| | |
|---|---|
| `cache.open(gpa, .{ .bytes = n })` | `!Store` — all the memory, taken here |
| `cache.Space(name, V, .{ .ttl_s = s })` | a keyspace, as a type |
| `Space.open(&store)` | the value a handler holds |
| `space.put(key, value)` | for the Space's `ttl_s` |
| `space.putFor(key, value, ttl_s)` | for a life of its own. `0` is "until the ring writes over it" |
| `space.get(key)` | `?V` for a flat value; `?[]const u8` and a `*Held` for bytes |
| `space.del(key)` | `bool` — was there anything to forget |
| `space.incr(key, delta)` | `V` — the new count, for a Space whose `V` is an integer; anything else is a Refusal. The read, the add and the write are under the shard's lock, so two callers count two. A key nobody wrote counts from zero and lives `ttl_s`; one there keeps the expiry it had. Saturating ([ADR 109](../adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)) |
| `space.putIfAbsent(key, value)` | store only if the key is free, and say whether it was — `bool` for a flat value, `!bool` for bytes. One shard lock around the scan and the write, so two callers racing get one `true` between them. What `nilo.Idempotent` claims a key with ([ADR 155](../adr/155-a-request-answered-once-is-answered-the-same-way-again.md)) |
| `space.getInto(key, buf)` | the bytes read as `get` reads them, into a buffer of your choosing rather than a `Held` — for a caller whose buffer is an arena |
| `store.stats()` | hits, and the three different ways of missing |
| `store.bytesHeld()` | every byte it will ever hold, and it never moves |
| `store.shardCount()` | how many it got, which is at most the `shards` asked for |
| `store.clear()` | forget everything |

**The value type decides the shape of `get`.** A flat value — a number, an
enum, a struct with no pointer anywhere in it — has a size known while
compiling, so it comes back by value and nobody declares a buffer. Bytes do
not, so the Space says how large one can be and hands out the array to read
into:

<!-- compiles -->
```zig
const Pages = cache.Space("page", []const u8, .{ .max_bytes = 4096 });

fn render(pages: *Pages, path: []const u8) ![]const u8 {
    var held: Pages.Held = undefined;
    if (pages.get(path, &held)) |cached| return cached;
    const html = "…";
    try pages.put(path, html);
    return html;
}
```

**`Held` is your stack, and stack is held per connection for the life of it**
([ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md)). A handler
declaring a 4 KiB `Held` has added 4 KiB to every connection that reaches it.
It is written as an array you declare rather than a buffer the cache hides
because that is the only way the number is yours to see.

**A value with a pointer in it is a compile error, and the field is named.** A
cache entry outlives the call that wrote it, so a slice stored in one would
point at a request that has ended. Go's cache stores `interface{}` and gets
away with it because a collector holds the other end; there is none here.
Encode it and use a `Space` of `[]const u8`.

**One number decides the memory and it is a ceiling.** `bytes` is the whole
budget — the ring the values live in and the table that points at them come out
of it together, and `bytesHeld()` is never above it. Nothing is allocated after
`open`, nothing grows, and there is no sweep: an entry goes when its time is up
or when the ring writes over it.

| | |
|---|---|
| `.bytes` | the budget. Five sixths to the values, the rest to the table |
| `.entries` | how many the table points at, when that split is wrong. Clamped to the budget rather than added to it |
| `.shards` | how many writers can be inside at once, and how many independent rings. 64, and cut down if the budget cannot carry that many |

**`stats()` is how "why is my cache not hitting" gets an answer.** A miss with
nothing ever written under that key is `misses`; one whose entry the ring wrote
over is `evicted`; one past its time is `expired`. `Stats.evictionRate()` asks
the question directly: high means the cache wants more `bytes`, low with few
hits means it is being asked about keys nobody wrote. `rescued` counts entries a
read moved out of the write cursor's way, which is the policy working.

The counters are exact and the *reading* is not a snapshot: nothing is locked
while they are summed, because a lookup takes no lock either
([ADR 152](../adr/152-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)).
`evicted` also counts the rare read whose bytes a `put` overwrote mid-copy —
that read found the key and lost it to the ring, which is what the word means.

**A `get` takes no lock at all**, so readers do not queue behind each other:
124.5M reads a second on eight threads against 108.8M when they did. A `put`
does take one, per shard.

**A new entry has to be asked for twice before it gets the run of the ring.** It
lands in a tenth of it and is copied into the rest when something reads it
again, so a flood of keys nobody asks for twice cannot flush what the cache is
holding (ADR 109). Two things follow: a cache with room still admits freely,
and a cache written to and never read holds its first entries indefinitely
rather than forgetting the oldest.

Sizing, measured rather than guessed: on Zipf 0.99 a ring at a fortieth of the
working set answers 63.9% of lookups and one at a fifth answers 94.1%, which is
96–98% of what a cache that size could reach. **Ask for the hit rate you want
rather than for a multiple of the data**, and read `stats()` to find out whether
you got it.

Holding one entry costs 8 bytes of table slot, 12 bytes of header, and the key
— about 20 bytes over the value, and **64.3 bytes an entry on 200,000 of them,
against go-cache's 100.2, freecache's 132.0 and bigcache's 149.4**. That budget
is the whole of nilo's memory; the two Go ring caches bound only their values
and put the index on top, so the same 12 MiB budget cost them 25.2 and 28.5 MiB
of RSS ([`bench/result/cache.md`](../../bench/result/cache.md), which also records
the single-threaded rows where go-cache is faster, and why).

**What it will not do is leave this process.** Two instances of your program
have two caches that do not agree, neither survives a restart, and nothing here
reaches a network. That is the trade the module is for; ADR 110 argues it, and
names `nilo_redis` as the other answer nobody has needed yet.
