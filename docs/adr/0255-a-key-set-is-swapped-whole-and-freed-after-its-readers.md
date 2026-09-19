# 0255 — a key set is swapped whole, and freed after its readers

**Status:** accepted
**Extends:** [ADR 0140](./0140-nilo-verifies-a-token-and-does-not-fetch-one.md),
whose line — nilo verifies and does not fetch — stands, with the client
borrowed through a parameter for the one part of a rotation that is not
policy.
**Applies:** [ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md),
[ADR 0138](./0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md),
[ADR 0188](./0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md),
[ADR 0198](./0198-a-queue-is-a-table-in-the-database-you-already-have.md).

## Context

Every issuer rotates its signing keys — Google on the order of days — and
the guide said the answer was three lines the caller writes: fetch the
document again on `error.NoSuchKey`, hold a `*const Keys`, and swap it
under a mutex. Each of the three is wrong in a way no test finds. A
`NoSuchKey` with no refetch is every sign-in failing until a restart. A
refetch with no bound is one HTTPS GET to the issuer per forged `kid`,
which is a request from anybody on the internet turned into a request from
this server to Google. And replacing the `Keys` a verify on another thread
is reading, then `deinit`ing the old one, is a use-after-free — the Debug
build has no trap for it, because `Keys.all` is a slice into an arena the
`Str` trap does not know about.

The third is concurrency rather than policy, and the roadmap held the
entry at *waiting on a design* for one question: who owns the old `Keys`
after a swap. `nilo_cache` answers the same question with a generation
and a read-after check (ADR 0188), which works because a cache value is
flat and can be copied out before the check. A key set is not flat — an
RSA verify reads `n` and `e` for the length of a modular exponentiation —
so a copy is not the answer here.

## Decision

**`jwt.Keyring` holds the current set behind an atomic pointer. A verify
pins the set it is about to read and unpins it after; a swap publishes the
new set, waits for the old set's pins to reach zero, and frees it. Readers
never wait.**

```zig
var google: jwt.Keyring = try .init(gpa, .{
    .url = "https://www.googleapis.com/oauth2/v3/certs",
    .issuer = "https://accounts.google.com",
    .audience = client_id,
});
try app.provide(&google);
try app.before(fetchKeys, .{ &google, &api });   // google.refresh(run, api, now_s)

const claims = try google.verifyOrRefresh(Claims, c.arena(), token, now_s, c, &api);
```

The pin is two counters, and the second exists for the window the first
cannot see. A reader increments `crossing`, loads the pointer, increments
the set's own `readers`, and decrements `crossing`. A swap exchanges the
pointer, then waits for `crossing` to be zero, then waits for the old set's
`readers` to be zero. Without `crossing`, a reader that had loaded the old
pointer and not yet pinned it could increment a count on memory the swap
had already freed — the classic hazard. With it, once the swap has seen
`crossing` at zero after the exchange, every pin the old set will ever get
is already counted, and its own count is the truth. The exchange and the
`crossing` operations are `seq_cst`, because a store on one side ordered
against a load on the other is the one pattern acquire and release do not
cover.

**The one wait is the writer's, it spins, and it is bounded by one verify.**
`std.Io.Mutex` needs an `Io` a tool module has none of, and ADR 0138's rule
for a lock down here is that it spins and holds nothing that waits. A
verify is CPU work with no wait in it, so a spin on its count ends when it
ends; and a swap runs once per rotation, so the spin is paid by the fiber
that fetched the new document, once, rather than by any request.

**An unknown `kid` is a fetch at most once per `refresh_interval_s`.**
`verifyOrRefresh` is `verify`, and on `NoSuchKey` a compare-and-swap on the
last-refresh time: whichever verify sees the miss first takes the slot,
fetches, loads and verifies again; the others inside the interval are
`NoSuchKey` as they were. Under a real rotation that is a handful of 401s
in the second the first new-key token arrives; under a flood of forged
tokens it is one GET a minute to the issuer, which is the bound. A
scheduled `refresh` records its time too, so a miss straight after one
does not fetch again.

**The client is a parameter, and the module still imports nothing.**
`refresh(scope, client, now_s)` asks `client` for one call — `get(scope,
url, .{})` answering `ok()` and `body.view()` — which is what
`fetch.Client` answers and what a test's fake answers on `zig test
jwt/jwt.zig`. The shape is ADR 0198's: `job.Table` takes the Db as a type
so the queue sits on the database without the module importing it, and
the keyring takes the client as an argument for the same reason.

**The issuer, audience and leeway are on the ring**, once, rather than on
every `verify` call. They are properties of the issuer whose keys the
ring holds, and a ring that held Google's keys and was asked to insist on
somebody else's issuer would be a ring holding the wrong keys.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** none beyond `jwt.verify`'s own. A pin is
  three atomic operations and no allocation. A swap allocates the new
  set — one `create` and the parse's arena — once per rotation.
- **Memory per idle connection:** unchanged. A verify holds a pointer on
  its stack for as long as it already held a `*const Keys`.
- **Throughput:** three atomics per verify on top of an RSA verify, which
  is a modular exponentiation. Unmeasured, and the roadmap's number for a
  verification is still the one that would put it in proportion.
- **Binary size:** one struct; a program that never names it links none
  of it.

## Alternatives

**A mutex around the swap, as the guide said.** Readers under a mutex wait
for the writer, and a writer under a mutex waits for every reader; a
`std.Io.Mutex` needs an `Io` this layer has none of, and a spinning
reader-writer lock puts two read-modify-writes on every verify, which is
the cost ADR 0188 measured and refused for a lookup.

**A generation and a copy, as `nilo_cache` does.** A key set is a slice
of keys each pointing into an arena; copying it out per verify is an
allocation per request, and a verify that reads `n` for a millisecond is
not a memcpy the generation can be checked after.

**Freeing the old set on the next swap, with no wait.** Simpler, and wrong
twice: a reader can still be inside a verify from two rotations ago on a
slow thread, and a ring that is refreshed once at startup and once a
week holds a dead set for a week.

**Fetching inside the module**, `jwt.Jwks.fetch(url)`. Would put
`nilo_fetch` under `jwt/`, which ADR 0042 refuses and `zig build layering`
holds; and it would decide the policy the roadmap's *Not decided* entry
keeps open, which is when a miss means fetch and when it means refuse.
The interval is the bound, not the policy: a caller who wants no
automatic fetch calls `verify` rather than `verifyOrRefresh`.

## Consequences

- `jwt/keyring.zig`: `jwt.Keyring` with `init`, `deinit`, `load`,
  `refresh`, `verify`, `verifyOrRefresh`; `Keyring.Options` with `url`,
  `issuer`, `audience`, `leeway_s`, `refresh_interval_s`.
- `zig test jwt/jwt.zig` still runs the whole suite, with a fake client
  standing in for `fetch.Client`.
- The guide's "three lines" section becomes the ring, and the roadmap
  loses "A key set cannot be rotated without a race". The *Verified claims
  are not a handler argument* entry stops waiting on it.
