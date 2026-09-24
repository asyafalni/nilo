# Rate limiting

**An allowance is a shaper against a client that asks too often, not a defence against a flood, and it costs one compare-and-swap on a table that was sized before the socket opened.** The guide section is [`guide/middleware.md#when-one-client-asks-too-often`](../guide/middleware.md#when-one-client-asks-too-often); the names are in the reference at [`reference/middleware.md#nilo-allowance`](../reference/middleware.md#nilo-allowance); the code is `http/allowance.zig`.

## How the pieces fit

```
allowance.with(.{ .per_window, .window_s, .ipv6_prefix })   allowance.keyed(keyFn, .{ .per_window, .on_null })
  key: clientIp(), IPv6 masked to /64                          key: whatever keyFn(ctx) returns, or null
  fingerprint: packed into the counters' own u64                fingerprint: a second, dedicated u64 tag
                    │                                                       │
                    └──────────── one seed, drawn once per process ─────────┘
                                  (an offline-computable mapping is an aimable eviction)
                                              │
                                four ways, one cache line, one CAS
                                fail open while a slot is still ambiguous,
                                fail closed once the fingerprint has matched
                                              │
                     under `per_window`: through        over it: 429 + Retry-After
                                                          key was null + `.reject`: 403, no Retry-After
```

## The rule in force

1. **An allowance is a table sized while compiling, living in `.bss`, with no allocation at startup or per request.** A program that never calls `with` or `keyed` links none of it. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
2. **Four slots share a bucket, one 64-byte cache line**, and a full bucket evicts its stalest way (the oldest window) rather than refusing whoever just arrived. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
3. **Fail open while a slot is still ambiguous, fail closed once the fingerprint has matched.** The first protects a stranger colliding with an arriving address; once the fingerprint is this client's own, letting contention through would raise the ceiling to however many requests the server can run at once. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
4. **The window slides, two counters in one word**, weighing the previous window by how far into the current one a request lands; the window number is a `u16` that wraps every 65,536 windows (about 45.5 days), and a retained slot can carry stale counters for up to two windows around that wrap, left as a documented approximation rather than widened. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
5. **An IPv6 address is masked to `/64` (`.ipv6_prefix`) before hashing**, and both address families are parsed to bytes and tagged by family rather than hashed as text, so `10.0.0.1`, `010.0.0.1` and `::ffff:10.0.0.1` count as one key instead of three. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
6. **The hash seed is drawn once per process from `getrandom`**, so the address-to-bucket mapping cannot be computed offline and an eviction cannot be aimed at a chosen victim's slot. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
7. **Behind a proxy with `trusted_hops` left at zero, the whole table collapses onto one slot.** The refusal path alone checks for an `X-Forwarded-For` counted against the socket's own address and names the option to set, at no cost to a request that was let through. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
8. **`allowance.keyed(keyFn, options)` counts against whatever the application knows** (an account id, an API key, a tenant), in a table of its own, because a key an attacker can grind offline, a username, a tenant slug, needs a fingerprint wide enough on its own: a dedicated 64-bit tag rather than the address table's packed one, since the packed fingerprint's bits are traded against the bucket index and do not grow the product. [ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)
9. **`on_null` has no default.** A key function returning null is either `.skip` or `.reject`, a missing field is a compile error, and `.reject` answers 403 rather than 429, since nothing was rated and a `Retry-After` would be a lie. [ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)
10. **`with` and `keyed` compose by calling `use` twice.** A sign-in route keys on the claimed username with `.on_null = .reject` over an address-keyed `with` underneath it, rather than one middleware growing a fallback mode. [ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)
11. **Two `with` (or two `keyed`) calls carrying identical options are one table**, because Zig settles a generic once; `.name` is the field that exists only to make two otherwise-identical allowances separate. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)

## Decisions

| ADR | What it decides |
|---|---|
| [092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md) | `allowance.with`: the compile-time table, the sliding window, eviction, the address key |
| [104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md) | `allowance.keyed`: counting against an application-known key instead of an address |

Beside this topic: the one-allocation-per-request budget an allowance is designed around is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles); the coarse clock reading a window check costs is [ADR 041](../adr/041-core-knows-what-time-it-is.md) (id-clock-entropy); the proxy nilo expects in front, which is why an allowance is a shaper and not the only limit, is [ADR 027](../adr/027-tls-is-terminated-in-front.md) (tls).

## Open

Nothing is open on the record.

