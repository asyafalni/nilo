# nilo_id

**`nilo_id` makes, prints and parses UUIDs (v4 and v7), with no allocation and no IO.**

**Guide:** [Identifiers](../guide/id.md) · **Design:** [The clock, entropy, and a UUID](../design/id-clock-entropy.md)

## `nilo_id`

UUIDs are a module of their own ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)). The `Uuid` here is the same type `nilo_sql` reads a `uuid` column into, so a generated key goes straight into an insert. Nothing here allocates and nothing here does IO.

<!-- compiles: body -->
```zig
const id = @import("nilo_id");

const key = try id.v7Now(c);   // a *Ctx, or a `nilo.Run` built with `initIo`
_ = try db.insert(Doc, c, .{ .id = key, .title = nilo.Str.static("notes") });
```

where `Doc.id` is a `sql.Uuid`, which is this same type.

| | |
|---|---|
| `id.v7Now(scope)` | `!Uuid`: sortable, from the Scope's randomness and the clock |
| `id.v4(entropy)` | random: 122 bits of the `[16]u8` you pass in |
| `id.v7(entropy, ms)` | sortable: `ms` in the first six bytes, then the `[10]u8` |
| `u.toText()` | `[36]u8` by value: `550e8400-e29b-41d4-a716-446655440000` |
| `u.writeText(w)` | the same, into a `*std.Io.Writer` |
| `id.Uuid.parse(text)` | `!Uuid`, `error.InvalidUuid`. Hyphens optional |
| `u.version()` | `u4`: `4`, `7`, or whatever the bytes claim |
| `u.millis()` | `?u64`: the millisecond a v7 carries, null for anything else |
| `u.eql(other)`, `u.isNil()`, `id.Uuid.nil` | |
| `id.Uuid.byte_len`, `.text_len`, `.v4_entropy`, `.v7_entropy` | 16, 36, 16, 10 |

A `Uuid` in a returned struct is sent as its text, not as sixteen numbers, and one in a Row is written and read as the `uuid` column.

### `id.v7Now` and `id.v7`

**Use `v7Now` for a new key, and `v7` for a key at a time you chose**, such as a backfill or a row that existed before its id did. `v7Now` is `c.entropy(…)` plus the clock, which is the pair every `create` would otherwise write out by hand, `@intCast` included. On a `Run` built by `init` rather than `initIo` it returns `error.NoIo`, which is what `scope.entropy` returns on its own.

### Printing a `Uuid`

**`{f}` prints one**, which is what an error message naming a missing record needs ([ADR 143](../adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)):

```zig
return nilo.fail.notFound("partner {f} not found", .{id});
```

`{s}` cannot work: Zig reserves it for byte slices, and a `Uuid` is a struct. `writeText` is a method, so it writes to a writer you already hold and does nothing for a format string.

### How v7 keys sort

**A v7 sorts across milliseconds, not within one.** Its first six bytes are the clock and the other ten are the entropy you passed, with no counter. Two keys made in the same millisecond therefore come back in random order relative to each other. RFC 9562 allows a counter there, and nilo deliberately does not use one ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)): a counter needs a threadlocal or an atomic, and having no state is what lets `v7` be called from any fiber without a lock.

**The risk is not that the ids are unordered, but that they look ordered as long as the timestamps differ.** The usual case is a row whose timestamp comes from `now()` inside a transaction. That is Postgres behaviour, not nilo's: `now()` is the *transaction's* clock, so every row one command writes has the same instant, and the ordering then depends only on ten random bytes. `ORDER BY occurred_at, id` looks right in every test where the writes were a millisecond apart, and shuffles the rows written together.

If your product shows the order rows were written in, store that order: an ordinal column the command fills, or a sequence. A v7 orders by *when*, and two things that happened at the same instant have no *when* to order by.

### Entropy

**The randomness is an argument, and it has to be unguessable.** Entropy is IO, and a module in the bottom layer has no Bulkhead to reach it through, so `v4` and `v7` take what they need instead of fetching it. Inside a request that is `c.entropy(n)`; outside one it is `std.Io.randomSecure` ([ADR 042](../adr/042-entropy-belongs-to-the-loop.md)). A v4 built from a seeded `std.Random.DefaultPrng` is fine in a test, and in production it is a session token anybody can predict. Nothing here can tell the difference.
