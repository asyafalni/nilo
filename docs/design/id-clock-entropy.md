# The clock, entropy, and a UUID

**Core knows what time it is and hands entropy through the loop, and a UUID is the format built on both without owning either.**
The names and signatures are [`reference/core.md#what-time-it-is`](../reference/core.md#what-time-it-is), [`reference/ctx.md#reading`](../reference/ctx.md#reading) (`c.entropy`, `c.entropyInto`), and [`reference/id.md`](../reference/id.md); the code is `core/clock.zig`, `http/ctx.zig` and `http/bulkhead.zig` (`randomSecure`), and `id/uuid.zig`.

## How the pieces fit

```
core/clock.zig      nowMillis(), nowMicros()      no Io, a vDSO read on every platform
http/bulkhead.zig    c.entropy(n) / c.entropyInto(buf)   parks the fiber, an App-layer call
id/uuid.zig          v7(entropy, ms)     the format only, and its own clock read for v7Now
```

The clock sits in Core because two layers below the App wanted it (`nilo_sql`'s `Timestamp.now()`, `nilo_id`'s millisecond) and reading it never waits. Entropy sits one layer up, on `Ctx`, because a real operating-system call can wait and only the App has a loop to pay that wait out of. `id.v7Now(scope)` is the two joined for any scope that can supply `entropy` and needs its own reading of the clock, because `nilo_id` cannot import `nilo_core` without leaving its layer.

## The rule in force

1. **`nilo_core.nowMillis()`, `nowMicros()` and `monotonicMicros()` are free functions, not calls on a Scope.** Nobody owns the time: there is no lifetime to carry and nothing to release, so there is nothing for a Scope to be the holder of. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
2. **The layering question is "does it need the event loop", not "does it do IO".** A clock read is a syscall by the letter and a read from a page the kernel keeps mapped in practice: nothing for a fiber to wait on, so it can sit in Core even though `nilo_core` does none of the App's IO otherwise. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
3. **The clock reads on Windows too**, `RtlGetSystemTimePrecise` and `RtlQueryPerformanceCounter`, both reads of the page the kernel maps into every process, the same argument as the vDSO on Linux; this does not make an Engine run on Windows, it makes the three layers under the Engine already correct there. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
4. **The unit is in the function's name.** `nowMillis` and `nowMicros` rather than a bare `now()`, because an `i64` that does not say what it counts is the mistake `sql/types.zig` exists to stop. [ADR 041](../adr/041-core-knows-what-time-it-is.md)
5. **`Ctx.entropy(comptime n)` answers `[n]u8` through `bulkhead.randomSecure`, and it is a method rather than a free function on purpose.** An operating-system call made straight from a fiber stops every request sharing that thread; going through the Bulkhead parks the fiber on the blocking pool and tells the blocking detector this wait is not the handler's fault. [ADR 042](../adr/042-entropy-belongs-to-the-loop.md)
6. **Entropy is an App-layer call because the only open question about it is how the wait gets paid for, and only the App has a loop to pay it out of.** A `Run` gets no separate entropy call of its own: a program holding one already has an `Io` and can reach `std.Io.randomSecure` directly. [ADR 042](../adr/042-entropy-belongs-to-the-loop.md)
7. **`nilo_id` takes its randomness and its millisecond as arguments and does not fetch either.** It has no Bulkhead to reach through, so `v4(entropy)` and `v7(entropy, ms)` are the format only; `zig build layering` and the entry condition of a plain `zig test id/id.zig` are what keep it that way. [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md), [ADR 042](../adr/042-entropy-belongs-to-the-loop.md)
8. **`entropyInto(buf)` sits beside `entropy(n)` on `Ctx` and `Run`, for a caller a comptime width cannot serve.** A type-erased Scope crossing a function pointer needs a vtable entry whose signature does not freeze at one caller's byte count; `entropy` is now written in terms of `entropyInto`, one implementation rather than two that can drift. [ADR 134](../adr/134-entropy-a-function-pointer-can-carry.md)
9. **`id.v7Now(scope)` reads its own millisecond rather than calling `core/clock.zig`.** `nilo_id` imports nothing at all, so pulling in Core's clock would move the module out of its layer; `v7Now`'s own `clock_gettime(.REALTIME, ...)` and Core's clock read the same clock, so what either hands back is the same instant. `v7` (given the millisecond) stays, for a caller backfilling a key for a row that already existed. [ADR 143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)
10. **`Uuid` prints with `{f}`, not `{s}`.** `{s}` is reserved for byte slices and a `Uuid` is a struct; `format` is the same thirty-six characters `writeText` produces, reached the way `Str` already is everywhere nilo names a value in a message. [ADR 143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)
11. **`v7Now` checks only for `entropy`, not for a whole Scope**, because that is the only thing it uses, and a second definition of "what a Scope is" living in a module that cannot import `core/scope.zig` is a rule that could drift from the one the compiler actually enforces. [ADR 143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)

## Decisions

| ADR | What it decides |
|---|---|
| [041](../adr/041-core-knows-what-time-it-is.md) | The clock lives in Core as a free function, and why that does not break "no event loop" |
| [042](../adr/042-entropy-belongs-to-the-loop.md) | Entropy is an App-layer call on `Ctx`, not a Core function or a `nilo_id` capability |
| [134](../adr/134-entropy-a-function-pointer-can-carry.md) | `entropyInto` for a width chosen at runtime, for a caller crossing a function pointer |
| [143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md) | `Uuid.format` and `v7Now(scope)`, and why `nilo_id` reads its own clock rather than importing Core's |

Beside this topic: the layer rule both the clock and entropy decisions amend and apply is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md), see [layering](layering.md); `nilo_pw`'s salt is the same entropy call reused for a different value, [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md); a `Session(T)`'s nonce reaches the same Bulkhead call by a second route, see [cookies-sessions](cookies-sessions.md).

## Open

- **A per-thread entropy pool**, caching what `getrandom` answers instead of a syscall on every call, is held open in [the roadmap](../roadmap.md) pending a number that justifies the stored state, the fork hazard and the seeding moment it would cost.
