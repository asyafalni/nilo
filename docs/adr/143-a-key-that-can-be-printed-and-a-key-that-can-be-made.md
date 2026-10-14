# A key that can be printed, and a key that can be made

**Status:** accepted
**Topic:** [id-clock-entropy](../design/id-clock-entropy.md)

Two reports about `Uuid` from the same port, a fortnight apart, and they are one
decision: the type carried a value it could not spell and could not produce.

## Printing it

```
error: no field or member function named 'format' in 'uuid.Uuid'
```

So every refusal that named the record it could not find was written the long
way:

```zig
return nilo.fail.notFound("partner {s} not found", .{&id.toText()});
```

An ampersand and a call, five times in one context, in the one place where a
reader is being told what went wrong.

**Two things landed before this and neither reached it.** `writeText(w)` is a
*method*: it answers a caller who already holds a writer and answers nothing at
all to `{f}`, because Zig looks for a declaration called `format` and finds one
or gives up. `testing.show` (ADR 137) answers the failure-message half, which
was the other place this hurt and is not this place.

`Str` was given `format` for exactly this reason and its comment says why:
printing the value is the first thing anybody writes. `{s}` cannot be made to
work — Zig reserves it for byte slices and a `Uuid` is a struct — so it is `{f}`
here, four lines, and the same thirty-six characters `toText` produces.

## Making one

```zig
const seed = try c.entropy(nid.Uuid.v7_entropy);
const key = nid.v7(seed, @intCast(nilo.nowMillis()));
```

Six times in one context — `partner.create`, `contact.add`, `comment.write`,
`events.insert` and both fixture writers. Neither half is a decision a caller
makes. The `@intCast` is in all six because `nowMillis` answers `i64` and the
field it goes in is a `u48`.

```zig
pub fn v7Now(scope: anytype) !Uuid
```

`scope` is the `*Ctx` a handler was given or a `nilo.Run` built with `initIo`.
The randomness comes from it, the millisecond from the clock, and the cast is
gone.

## The clock is read twice, and that is the cost

`nilo_id` **imports nothing at all**, which is what `zig build layering` holds
and what keeps `zig test id/id.zig` running with no module graph (ADR 039). So
`v7Now` cannot call `core/clock.zig`, and the alternative to twelve lines of
`clock_gettime` here is an import that moves the module out of its layer.

`http/bulkhead.zig` already keeps its own monotonic clock beside Core's for the
same reason and says so. The two cannot drift in a way that matters: both are
`CLOCK_REALTIME`, and what a caller gets from either is the same instant.

**`v7` stays**, for the caller who has the millisecond already — a backfill, a
key made for a row that existed before it did.

## Keys made in a loop come out in order

**`v7Now` keeps a counter in `rand_a`** (RFC 9562 §6.2, method 1), so rows
inserted in a loop and read back by id come out in the order they went in. An
outbox, an audit log or an event table that pages by id needs that.

- The twelve bits after the version nibble are the counter. It is seeded from
  the key's own entropy (eleven bits, top bit clear, so a fresh millisecond
  has room for at least 2048 keys) when the wall clock reaches a later
  millisecond, and goes up by one for each key after it.
- **When the counter passes 4095 inside one millisecond, the timestamp moves
  ahead by one and the counter is seeded again.** The key's clock then runs a
  little ahead of the wall for the length of the burst. The same rule covers a
  wall clock that steps back: the key keeps the last millisecond it used.
- **The state is a `threadlocal`**, sixteen bytes a thread that mints, no
  allocation, no lock. Order is therefore per thread: two threads in the same
  millisecond count apart, and a fiber that changes threads between two calls
  joins the other thread's count. Nothing between reading the state and
  writing it waits, so a fiber is never switched out inside it.
- `v7(entropy, ms)` stays as it was: the format, no state, random order inside
  a millisecond. It is the call for a caller who chose the millisecond.
- 62 bits of `rand_b` stay random; a `v7Now` key carries twelve fewer random
  bits than before.

Against ADR 017: allocations and idle memory are zero. Cost per key is one
threadlocal read and write and an add, and it is in `bench/release/id.zig`,
which now mints through `v7Now` as well as `v7`. Binary size is the same as
before for a program that does not call `v7Now`.

## What it asks for, and where the refusal lives

`v7Now` checks for `entropy` and not for a whole Scope, because that is the whole
of what it uses — and because a second reading of *what a Scope is*, living in a
module that cannot import `core/scope.zig`, is a rule that can drift from the one
the compiler is really enforcing.

The refusal file is in `sql/refusals/` rather than `refusals/`, and that is worth
a sentence: `nilo_id` has no table of its own, the framework's refusals are built
against `nilo_http` alone, and `sql.Uuid` is `nilo_id`'s `Uuid` — the same
declaration, through an import line `sql.zig` documents. A seventh table and a
seventh build step to hold one message would cost more than it checks.

## Against ADR 017's four axes

Zero on the first two. `format` and `v7Now` are called from handler code, never
from a path nilo takes itself, and neither allocates. Binary size: both are
dropped by the linker in a program that names neither, which is what `nilo_id`
being a module of its own already buys.

## Consequences

- `Uuid` prints with `{f}` wherever `Str` does, which is every fail function and
  every `std.log` line.
- `writeText` stays. It is the same bytes and it is the call for a writer already
  in hand; nothing in the repository had to change.
- `id.v7Now(scope)` is the spelling for a key, and `id.v7(entropy, ms)` is the
  spelling for a key at a time somebody chose.

## What was rejected

- **No counter at all**, which this ADR and the `v7` comment first held: a
  counter is a threadlocal or an atomic, nobody had asked for ordering inside a
  millisecond, and no state let `v7` be called from any fiber without a lock.
  What moved it: an outbox, audit log or event table that pages by id gets rows
  back out of insertion order from a loop of inserts, and the cost of the
  counter turned out to be sixteen bytes of threadlocal and an add, with no
  lock because nothing in the critical stretch waits.
- **A counter inside `v7(entropy, ms)`.** That call takes its millisecond from
  the caller, so a counter there would be state keyed on an argument: a
  backfill at a past time would fight the counter of a key made now. `v7Now`
  owns the clock and so owns the counter.
- **An atomic shared by all threads**, for order across threads: a contended
  cache line on every key from every core, to order keys whose real order the
  caller cannot observe anyway.
- **Waiting for the next millisecond when the counter runs out**: a sleep in a
  module that has no loop to sleep on.
