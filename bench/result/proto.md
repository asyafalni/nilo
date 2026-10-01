# nilo_proto

How close a decoder generic over the caller's types gets to one written by hand
for the same job, what each thing done to close the gap bought, and what the
rest costs. The number the module was promoted on is the first table; the
floor is the last.

Machine: AMD Ryzen 7 9700X (8 cores, SMT), Linux 7.2.5, **logical CPU 5**
under `taskset`, load average about 1 while the numbers below were taken (it
was 8 to 25 earlier the same afternoon, with other sessions compiling, and
those runs are not quoted). Zig 0.16.0, `ReleaseFast`,
`-Dtarget=x86_64-linux-gnu` and the baseline CPU, both sides built the same
afternoon. nilo `36863f6` plus the module, uncommitted. `perf` is not
installed here, so the profile below is stage timing and an isolated timing of
the counting pass, not a sampling profile.

## What was run

photon's S1 spike (`photon/zig/spike/s1-ingest`, the OTLP logs receiver) has two
decoders for `ExportLogsServiceRequest`: **variant a**, written by hand,
reading each field off the wire into the column builders and building no
message, and **variant b**, `proto.decode` into the plain types of `otlp.zig`
followed by a loop that walks them into the same builders. `s1-tool
decode-bench <file> a|b` runs one on one thread: decode, map, columns, a sealed
WAL frame with its CRC, the arena reset between iterations.

Four binaries, run round-robin, 2 s each, 9 to 15 rounds: **a(base)** and
**b(base)** are the spike as it stands (its own `proto.zig`); **a(new)** and
**b(new)** are the same tool with `src/proto.zig` replaced by this module's
files (`proto/proto.zig`, `wire.zig`, `schema.zig`, `decode.zig`,
`encode.zig`), `fixtures.zig`'s one forward-writer call changed to
`proto.wire.Writer`, and nothing else. `a(new)` reads with the new `Reader`;
`a(base)` is the baseline every percentage is against. The payloads are
prost's: `s1-rust-check gen` writes them from photon-loadgen, so the bytes are
what a Collector would send.

## The numbers

ns a row, whole pipeline (min of the rounds; the spread is the min to the max).

| payload | a(base) | b(base) | a(new) | **b(new)** | b(new) vs a(base), min / median | b(base) vs a(base) |
|---|---|---|---|---|---|---|
| loadgen, 500 rows, 10 services, 70 KB | 247 (247 to 251) | 279 (279 to 283) | 247 (247 to 250) | **248 (248 to 251)** | **+0.4% / +0.8%** | +13.0% |
| alloc fixture, 1,000 rows, 320 KB | 533 (533 to 535) | 593 (593 to 599) | 543 (543 to 556) | **532 (532 to 537)** | **-0.2% / 0.0%** | +11.3% |
| loadgen, 37 rows, 4 services, 5.8 KB | 265 (265 to 267) | 303 (303 to 306) | 266 (266 to 271) | **272 (272 to 275)** | **+2.6% / +2.6%** | +14.3% |

The target was 3% on every payload, and it holds on all three. The smallest
request is the closest: the slab and the counting pass are paid once a message
and a 5.8 KB request has few of them to spread it over.

The frames are byte for byte the ones variant a and the spike's own decoder
build (`s1-tool dump` over all seven prost payloads, and the spike's 64 tests
in ReleaseSafe against the new module, edge cases and the a/b identity check
among them).

## What each thing bought

Stage timing of the 500-row request, ns a row, taken in isolation with the
spike's decoder b and then this module (`stage.zig`, 20,000 iterations, three
runs each, within 1 ns of one another):

| | spike | this module |
|---|---|---|
| `proto.decode` alone | 105 | **80** |
| decode, then the walk into columns | 265 | **240** |
| variant a, decode into columns | 237 | 236 |

Of the 25 ns a row decoding gained, nearly all is the **one-byte-key table and
the reader that returns its position** (the spike compared every declared
number in turn). Two other changes were tried and moved nothing end to end:

- **The slab** (one block from the arena, exact slices carved from it): 79.5 ns
  a row with it and 79.7 without. It stays for the allocation count: the arena
  calls `s1-tool alloc` counts for the 1,000-row request went from **1,039 to
  38**, variant a making 35. Under the arena, 6 allocations to 3.
- **The UTF-8 check with a short-string path**: 79.5 with it and with std's, in
  place. In isolation (20 M calls a length, one core) it is 0.57 ns against
  1.8 to 2.6 at 8 to 12 bytes, 0.8 against 1.2 at 3, 0.6 against 0.7 at 16,
  parity at 24 to 100 bytes and faster at 1,000, so it is not slower anywhere
  measured. The check is off the critical path, which is why the end-to-end
  number does not see it.

The decoded tree is **1.8 to 2.6 times the input** on the seven payloads
(`alloc-1000` 1.82, `loadgen-b500` 2.17, the one-row request 2.58); the slab is
sized at three times the input and the unused end of the last block goes back
to the arena.

## The floor

**What is left is the second pass.** A message with a repeated field is scanned
once to count it and once to fill it, so its slice is exact. Timed alone on the
500 `LogRecord`s of the loadgen request, the counting pass is **14.9 ns a
record**, 6% of the whole row. Variant a never counts, because it streams each attribute to the builder as it
is read, and it builds no tree. Those two are the whole of the difference the
generic decoder cannot remove, and in this pipeline they are 0.4 to 2.6% of a
row, because what the result is used for (the mapping, the columns, the CRC) is
160 ns of the 250 and is the same on both sides.

With nothing downstream the tree shows. `zig build bench-proto` decodes 500
records of ten attributes into structs and adds up what a consumer reads,
against `proto.Reader` doing the same adding off the wire without a struct
(both refuse bad UTF-8):

| | ns a record | MB/s at the min |
|---|---|---|
| `decode`, then a walk | 147.8 (median 148.7) | 2,169 |
| `stream`, by hand | 85.7 (median 86.0) | 3,740 |
| `encodeInto` | 124.7 (median 128.1) | 2,572 |

**Decoding to a tree is 73% over streaming the same fields** when nothing else
happens to the result. That is the true cost of the shape, and it is the
reason `proto.Reader` is public: a receiver that wants rows and never a tree
should read the wire. One decode of that request makes 2 allocator calls
(160,335 bytes, 321 a record).

## Can it go further

A single pass over a message that keeps its repeated elements in a scratch
stack and copies them out exact would save most of the 15 ns a record, at the
price of writing every element twice and a stack discipline across nested
messages (a nested message needs its region above its parent's, so growing the
stack cannot move an element the parent still points at). It was not built:
the whole pipeline is already at 0.4% on the headline payload and the third
decimal of what is left is the allocation and the second pass. **What would
settle it** is a caller whose messages are all repeated fields and whose work
on the result is negligible, which is the `bench-proto` row and not photon.

## Size

Stripped `ReleaseFast`, `bench/release/proto.zig` (seven message types, decode
and encode a 20-record logs request): **261,656 bytes**, against 229,384 for a
program of the same harness that does nothing. **+32,272 bytes**, and none for
a program that does not import the module. That program's operation is
2.4 KB of input, 1 allocator call and 13,336 bytes requested (the slab, which
the arena takes the unused end of back; the counter does not see the give-back).
`bench/release.py` needs valgrind, which this machine does not have, so the
instruction count is the next release's.

## What it decided

[ADR 245](../../docs/adr/245-protobuf-is-read-from-the-struct-that-declares-it.md):
the table dispatch and the slab stay, the slab for the allocation count and the
table for the time; the short-string UTF-8 check stays as the first thing to
drop if the module should be smaller; the single-pass decoder is not built.
