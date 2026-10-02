# Protobuf

**nilo reads and writes protobuf from the struct you declared, with the field numbers on the type, and compiles no `.proto` file and generates no code.**

**Guide:** [Protobuf messages](../guide/proto.md) · **Reference:** [`nilo_proto`](../reference/proto.md)

The code is `proto/proto.zig` (the API and its tests), `proto/wire.zig` (varints, keys, the reader and the back-to-front writer, the UTF-8 check), `proto/schema.zig` (what a type says about itself, and every compile error), `proto/decode.zig` and `proto/encode.zig`.

## Overview

```
 struct + pub const wire = .{ .id = 1, ... }
            │  specsOf(T), while compiling: one Spec a field number,
            │  or a sentence naming the field that is wrong
            ▼
  decode:  key byte ──► 128-entry table ──► the field's own code
           (a miss: full key, compare numbers, or skip)
           pass one counts each repeated field, pass two fills exact slices
  encode:  encodedSize ──► one buffer ──► written last field first
```

A message is a struct, a oneof is a `?union(enum)`, a repeated field is a slice and a map is a slice of entries. Everything the decoder and the encoder do is a loop over the specs of one type, unrolled by the compiler, so the cost of a type is the code for its own fields.

## Rules

1. **The types are the schema.** nilo reads no `.proto` file and runs no generator: a message is the struct the caller wrote, with `pub const wire` naming each field's number. This is the same idea the rest of nilo rests on, that your types are the contract and the compiler is the check. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
2. **The Zig type decides the protobuf type, and the table says only what the type cannot.** A number, and for a number the encoding it travels as. A field missing from the table, a number used twice, a type with no protobuf word, a oneof that is not optional: each is a compile error naming the field, and `zig build refusals-proto` holds all of them. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md), [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md)
3. **`[]const u8` is a string, and a string is checked to be UTF-8; `.bytes` opts out.** The loud default is the safe one: a binary id forgotten as a string fails on the first request, and a string forgotten as bytes would pass invalid text in silence. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
4. **An enum is open when it has `_` and closed when it does not.** The open one is proto3's and keeps a number the program has not heard of. The closed one is proto2's: the number is dropped and the field keeps what it had. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
5. **`?X` on a scalar is proto3 `optional`, and `?union(enum)` is a oneof.** A plain scalar at zero is left out of an encoding; an optional one is present exactly when it was written. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
6. **Unknown fields are skipped, groups included, and are not kept.** A newer sender is read by an older receiver, and a message decoded and encoded again loses what it did not know. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
7. **A field that occurs twice is merged by the specification's rule**: a scalar takes the last value, a repeated field appends, a message merges, and a oneof member replaces another but merges into itself. Two encodings back to back are one message. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
8. **Strings and bytes borrow the input; a repeated field is one exact slice, cut from one block the arena gives the decoder.** A message is counted before it is filled, so no slice is ever grown, and the block's unused end goes back. The value lives as long as the input and the arena both. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
9. **A one byte key finds its field in one table load.** Field numbers under 16 are one byte, and a 128-entry table built while compiling maps the byte to the field and the one wire type it can take; anything else takes the general path. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
10. **Encoding sizes a message once and writes it once, last field first.** A length prefix is the distance the write position moved, so a nested message is never sized a second time. Fields come out in number order, so equal values are equal bytes. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
11. **Nesting is bounded at 100, prost's limit, and nothing panics on input.** Every length is checked against what is left and every count comes from a scan, never from a length taken on trust. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)
12. **It is a tool module, and `nilo_http` names it only inside `app.trace`.** A gRPC method is an ordinary route ([ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)) and its message is whatever the caller decodes. The OTLP exporter is the one place the server encodes protobuf itself, in a file only `app.trace` reaches ([ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)), so a program that neither speaks protobuf nor traces links none of this. [ADR 245](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md), [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)

## Decisions

| ADR | What it decides |
|---|---|
| [244](../adr/245-protobuf-is-read-from-the-struct-that-declares-it.md) | The module, the `wire` table, the type rules, the decoder's table and slab, the encoder's back-to-front write, and what it costs on the four axes |

Related topics: [layering](layering.md) for why a tool module imports nothing, and [the SQL types](sql-types.md) for the same move made for a column: the Zig type decides, and a declaration says only what the type cannot. The transport a protobuf message usually rides on is [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)'s.

## Open questions

- **A message that contains itself directly** (`?*const S`) is not supported: recursion goes through a slice. Whether a caller has one that a slice of at most one element cannot stand in for has not come up.
- **Keeping unknown fields** for a proxy that must pass a message through untouched is not built. A caller who needs it reads the message with `proto.Reader` and copies the bytes it did not name.
