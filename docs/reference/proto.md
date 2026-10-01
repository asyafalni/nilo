# nilo_proto

**`nilo_proto` reads and writes protobuf messages as plain Zig structs, with the field numbers declared on the type and nothing generated.**

**Guide:** [Protobuf messages](../guide/proto.md) · **Design:** [Protobuf](../design/proto.md)

## `nilo_proto`

Protobuf for structs you wrote, with nothing that needs an event loop ([ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)). It is a tool module: it imports nothing, so `zig test proto/proto.zig` runs all of it.

<!-- compiles -->
```zig
const proto = @import("nilo_proto");

const Greeting = struct {
    pub const wire = .{ .name = 1, .times = 2 };
    name: []const u8 = "",
    times: u32 = 0,
};

fn roundTrip(gpa: std.mem.Allocator, arena: std.mem.Allocator) !Greeting {
    const bytes = try proto.encode(Greeting, gpa, .{ .name = "world", .times = 3 });
    defer gpa.free(bytes);
    return proto.decode(Greeting, arena, bytes);
}
```

### `proto.decode` and `proto.merge`

| | |
|---|---|
| `proto.decode(T, arena, bytes)` | `!T`: one message read from `bytes`. Strings and bytes in it borrow `bytes`; repeated fields are allocated from `arena` |
| `proto.decodeWith(T, arena, bytes, opts)` | the same with `proto.Options`: `.max_depth` (default `proto.max_depth`, 100) |
| `proto.merge(T, arena, &v, bytes)` | `!void`: the fields in `bytes` applied on top of a `T` you already hold, by the specification's merge |
| `proto.mergeWith(T, arena, &v, bytes, opts)` | the same with options |
| `proto.defaults(T)` | a `T` with every field at its default |

**A decoded value lives as long as `bytes` and `arena` both.** Nothing is copied out of the input, so a gRPC body, a request body or a file read can be decoded and the strings read in place.

### `proto.encode`

| | |
|---|---|
| `proto.encodedSize(T, v)` | `usize`: exactly how many bytes `v` encodes to |
| `proto.encode(T, gpa, v)` | `![]u8`: `v` in one allocation of exactly that size, yours to free |
| `proto.encodeInto(T, buf, v)` | `![]u8`: `v` at the start of `buf`; `error.NoSpaceLeft` before a byte is written if `buf` is short |

Fields are written in number order, so equal values are equal bytes. A scalar at zero is left out, a `?X` scalar and a present message are always written, and an active oneof member is written even at zero.

### The `wire` table

A message is a struct with a `pub const wire` naming each field's number:

| | |
|---|---|
| `.id = 1` | field 1, encoded the way its Zig type says |
| `.id = .{ 1, .fixed64 }` | field 1 with an encoding: `.fixed64`, `.fixed32`, `.sfixed64`, `.sfixed32`, `.sint64`, `.sint32`, `.bytes` or `.string` |
| `.ids = .{ 2, .unpacked }` | a repeated number written one key a number, as proto2 did. It is read either way |
| `.ids = .{ 2, .sint32, .unpacked }` | an encoding and `.unpacked` together |

### Types

| Zig | protobuf |
|---|---|
| `bool` | bool |
| `i32`, `i64`, `u32`, `u64` | int32, int64, uint32, uint64 (and `.sint*`, `.sfixed*`, `.fixed*` with an encoding) |
| `f32`, `f64` | float, double |
| `[]const u8` | string, checked to be UTF-8; `.bytes` for bytes |
| `enum(i32)` with `_` | an open proto3 enum, which keeps a number the program does not know |
| `enum(i32)` without `_` | a closed enum: a number it does not name is dropped, and the field keeps what it had |
| a struct with `wire` | a message; `?S` where its presence matters |
| `?i32`, `?f64`, `?[]const u8` | proto3 `optional`: present exactly when it was on the wire |
| `[]const X` | repeated X: numbers are packed, strings and messages one key each |
| `?union(enum)` with `wire` | a oneof; its numbers are on its members, and the field is optional |
| `[]const proto.Entry(K, V)` | `map<K, V>` |

**Every field of a message is declared or the type does not compile**, and the message says which field and what to write. [`proto/refusals/`](../../proto/refusals/) holds all 26, and `zig build refusals-proto` checks each.

### Maps

**A `map<K, V>` travels as a repeated message with the key at 1 and the value at 2**, so it is a slice of entries. `proto.Entry(K, V)` is that struct:

<!-- compiles -->
```zig
const proto = @import("nilo_proto");

const Labels = struct {
    pub const wire = .{ .labels = 1, .sizes = 2 };
    labels: []const proto.Entry([]const u8, []const u8) = &.{},
    sizes: []const proto.EntryOf(u32, i64, .default, .sint64) = &.{},
};
```

`proto.EntryOf(K, V, key_encoding, value_encoding)` is for a map whose key or value needs an encoding. A slice, not a hash map: nilo does not choose a map type for you, and a lookup over a handful of entries is a scan. Build the hash map you want from the slice.

### Merge rules

**A field that occurs twice is merged the way the protobuf specification says.** A scalar takes the last value, a repeated field appends, a message merges field by field, and a oneof member replaces another member but merges into itself. Two encodings concatenated are one message.

### Unknown fields and groups

**Unknown fields are skipped, groups included, and not kept.** A message decoded and encoded again does not carry them. proto2 groups are skipped when they are not declared, and a declared field arriving as a group is `error.WrongWireType`.

### Errors

| | |
|---|---|
| `error.Truncated` | the input ended inside a field |
| `error.VarintTooLong` | a varint past ten bytes or 64 bits |
| `error.InvalidKey` | field number 0, a wire type of 6 or 7, or a key past 32 bits |
| `error.WrongWireType` | a declared field arrived as a wire type its type cannot have |
| `error.InvalidUtf8` | a string field that is not UTF-8 |
| `error.TooDeep` | messages nested past `max_depth`, or groups past it |
| `error.UnexpectedEndGroup` | an end-group with no start, or for another group |
| `error.OutOfMemory` | the arena said no |

**The decoder never panics on input.** `proto.zig` carries a loop of 20,000 damaged and random messages that has to come back with a value or one of these, in Debug and ReleaseSafe.

### `proto.Reader`

The wire without types: `proto.Reader.init(bytes)` with `.more()`, `.key()`, `.varint()`, `.fixed32()`, `.fixed64()`, `.bytes()` and `.skip(key, depth)`, and `proto.Key`, `proto.WireType`. **A hand-written decoder is a real choice** when a receiver wants a stream of rows and never a tree of structs; it reads the wire with these and gets the same refusals for the same bytes. `proto.validUtf8(bytes)` is the string check the decoder uses.

### What it does not do

- **proto2.** No required fields, no declared defaults on the wire, no extensions.
- **The well-known types.** Write `Timestamp` as the two-field struct it is.
- **A `.proto` compiler, JSON, reflection or services.** gRPC framing is [`nilo_http`'s](./app.md), and the message inside a call is this module.
- **A hash map for `map<K, V>`**, and a message that contains itself without a slice or a message between (`?*const S`).
