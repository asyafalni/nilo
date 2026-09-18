# nilo_id

One page of [the reference](./README.md): UUIDs.

## `nilo_id`

UUIDs, as a module of their own
([ADR 0042](../adr/0042-the-bottom-layer-holds-more-than-one-module.md)). The
same `Uuid` `nilo_sql` reads a `uuid` column into, so a generated key goes
straight into an insert. Nothing here allocates and nothing here does IO.

<!-- compiles: body -->
```zig
const id = @import("nilo_id");

const key = try id.v7Now(c);   // a *Ctx, or a `nilo.Run` built with `initIo`
_ = try db.insert(Doc, c, .{ .id = key, .title = nilo.Str.static("notes") });
```

where `Doc.id` is a `sql.Uuid`, which is this same type.

| | |
|---|---|
| `id.v7Now(scope)` | `!Uuid` — sortable, from the Scope's randomness and the clock |
| `id.v4(entropy)` | random — 122 bits of the `[16]u8` you pass in |
| `id.v7(entropy, ms)` | sortable — `ms` in the first six bytes, then the `[10]u8` |
| `u.toText()` | `[36]u8` by value: `550e8400-e29b-41d4-a716-446655440000` |
| `u.writeText(w)` | the same, into a `*std.Io.Writer` |
| `id.Uuid.parse(text)` | `!Uuid`, `error.InvalidUuid`. Hyphens optional |
| `u.version()` | `u4` — `4`, `7`, or whatever the bytes claim |
| `u.millis()` | `?u64` — the millisecond a v7 carries, null for anything else |
| `u.eql(other)`, `u.isNil()`, `id.Uuid.nil` | |
| `id.Uuid.byte_len`, `.text_len`, `.v4_entropy`, `.v7_entropy` | 16, 36, 16, 10 |

**`{f}` prints one**, which is what a refusal naming the record it could not find
wants ([ADR 0176](../adr/0176-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)):

```zig
return nilo.fail.notFound("partner {f} not found", .{id});
```

`{s}` cannot be made to work — Zig reserves it for byte slices and a `Uuid` is a
struct — and `writeText` is a method, so it answers a writer you already hold and
answers nothing to a format string.

**`v7Now` is the call for a key and `v7` is the call for a key at a time you
chose** — a backfill, a row that existed before its id did. `v7Now` is
`c.entropy(…)` and the clock, which is the pair every `create` writes out
otherwise, `@intCast` included. On a `Run` built by `init` rather than `initIo`
it is `error.NoIo`, which is what `scope.entropy` answers on its own.

A `Uuid` in a returned struct leaves as its text rather than as sixteen
numbers, and one in a Row is written and read as the `uuid` column.

**A v7 is sortable across milliseconds and not within one.** Its first six
bytes are the clock and the other ten are the entropy you passed, with no
counter — so two keys minted in the same millisecond come back in random order
relative to each other, and RFC 9562 allows a counter there deliberately not
taken ([ADR 0042](../adr/0042-the-bottom-layer-holds-more-than-one-module.md)):
a counter is a threadlocal or an atomic, and having no state is what lets `v7`
be called from any fiber without a lock.

**The trap is not "the ids are unordered" — it is "they look ordered as long as
the timestamps differ".** The case that finds it is a row whose timestamp comes
from `now()` inside a transaction. That is Postgres behaviour rather than
nilo's: `now()` is the *transaction's* clock, so every row one command writes
carries the identical instant, and the whole of the ordering then rests on ten
random bytes. `ORDER BY occurred_at, id` looks right in every test where the
writes were a millisecond apart and reshuffles the rows written together.

If the order rows were written in is something your product shows, store it:
an ordinal column the command fills, or a sequence. A v7 orders by *when*, and
two things that happened at the same instant have no *when* to be ordered by.

**The randomness is an argument, and it has to be unguessable.** Entropy is IO
and a module in the bottom layer has no Bulkhead to reach through, so `v4` and
`v7` take what they need rather than fetching it — inside a request that is
`c.entropy(n)`, outside one it is `std.Io.randomSecure`
([ADR 0046](../adr/0046-entropy-belongs-to-the-loop.md)). A v4 built from a
seeded `std.Random.DefaultPrng` is fine in a test and is a session token anybody
can predict in production; nothing here can tell the difference.
