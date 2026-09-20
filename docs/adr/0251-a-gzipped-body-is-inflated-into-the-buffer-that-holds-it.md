# 0251 — a gzipped body is inflated into the buffer that holds it

**Status:** accepted
**Amends:** [ADR 0111](./0111-a-body-under-an-encoding-nilo-cannot-read-is-refused.md),
whose refusal now stands for every coding but one.
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0105](./0105-a-body-is-taken-as-it-arrives.md).

## Context

ADR 0111 turned a body under any `Content-Encoding` but `identity` into a
415, and said why decoding was not the answer: *"a deflate window is 64 KB,
and one per connection multiplies the 4,669 bytes an idle connection holds
while one per request breaks the allocation budget. A pool sized to the
thread count is the shape that would fit, and it is unbuilt on both sides."*
The roadmap carried the inbound half inside the response-compression entry,
*waiting on a design* for what happens when the pool is empty.

Then a caller hit it as a default rather than as a choice. The stock
OpenTelemetry Collector gzips its exports, and so do most agents that push
to a server, so a nilo server on the receiving end of one refused their
stock configuration and needed a proxy in front to undo it. That is the
shape ADR 0028 accepts for TLS and nothing else: a proxy that has to
*rewrite the body* is not terminating anything, it is a second server.

## Decision

**A body under `Content-Encoding: gzip` is inflated once into the arena,
in place of the bytes that arrived, and nothing after that line knows how
it was sent.** `c.body()`, `c.json`, a struct argument, a `Form(T)` — every
reader goes through `body()` and sees the JSON, the way each already sees
neither framing. Every other coding, and two codings stacked, is still
ADR 0111's 415, and the message now says which one is decoded.

**There is no pool, because the premise that needed one was about the
other direction.** A deflate *compressor* holds a 64 KB window and a hash
chain of its own and has to. A *decompressor* needs only the last 32 KiB
of what it has written, to copy back-references from — and
`std.compress.flate.Decompress` has a mode in which that history is the
destination writer's own buffer. Handed no window at all (`&.{}`), it
writes straight into the writer and reaches back into `w.buffer` for a
match. The arena is going to hold the decoded body anyway, so the buffer
that holds the body *is* the window, and the thing the pool was for does
not exist on this side.

**The allocation is exact, and the ceiling is a comparison.** The last
four bytes of a gzip stream are the uncompressed length modulo 2³². Read
first, that number is what the arena allocation is sized to — one `alloc`,
no growth loop — and what `max_body` is checked against before a byte is
inflated. Two checks come before the number is believed, and both exist
because a wrong number sends the client to the wrong header: the three
magic bytes, so the JSON somebody forgot to compress is "not gzip" and not
"too large"; and deflate's own ceiling of about 1032 to one, so a stream
cut off mid-way — whose last four bytes are whatever happened to be there
— is "broken" and not "too large" either. A stream whose bytes disagree with its trailer, in either
direction, fails to decode: too many bytes run the fixed writer out of
room, too few or corrupt end the stream short of its footer, and both are
one answer — a 400 naming the coding, from the handler's own request path
so the connection is kept. The compressed bytes were already bounded by
`max_body` on the way in (ADR 0105); the inflated ones are bounded by the
same number, so a small body cannot inflate into a large one.

**`c.bodyStream()` is the one reader that does not decode**, and it says
so with a 415. A stream hands bytes out as they arrive into the caller's
buffer and holds nothing, so there is no buffer to be the history, and the
caller's is handed back a piece at a time. Decoding on that path is a
different design — a window per stream, which is the pool question again,
or a decoder over the caller's buffer with a minimum size — and it is not
the path the Collector takes.

`x-gzip` is read as `gzip`, because RFC 9110 says a recipient should.

## What it costs

Against ADR 0018's axes:

- **Allocations per request:** unchanged on every request that is not
  gzipped, which is the path the budget test holds. A gzipped request pays
  one more arena allocation, of the inflated size exactly, on top of the
  one or two `readSizedBody` already makes for the compressed bytes. The
  compressed copy is not freed — it is arena memory, and goes with the
  request.
- **Memory per idle connection:** unchanged for a connection that never
  sends one. The inflater's state is 3,384 bytes of Huffman tables
  (`@sizeOf(std.compress.flate.Decompress)`, measured) on the handler's
  stack while `body()` runs, and the fiber does not suspend inside it —
  the compressed bytes are already in the arena, so the inflating is a
  loop with no wait in it. But a fiber's stack is its high-water mark for
  the life of the connection (ADR 0063), so a connection that has ever
  sent a gzipped body holds up to 3.4 KB more than one that has not,
  where the frames were shallower before. Per request that asked, and
  for a connection reused by a Collector that is every request; a
  compressor's 230,096 bytes is the number that kept the other direction
  out, and this is 1.5% of it.
- **Throughput:** nothing on a request without the header. `finish` tests
  an enum instead of a bool, which is the same instruction.
- **Binary size:** `std.compress.flate.Decompress`, which `http/static.zig`
  already links for its own test and which a program that serves gzipped
  static files carries the compressor's half of. Unmeasured on its own;
  small against ADR 0018's running total.

## Alternatives

**The pool, as the roadmap described it.** Right for the outbound half,
where the compressor's state is real and per-thread is the only place to
put it. For the inbound half it would have been a 64 KB window borrowed to
do what the destination buffer does for nothing, and a policy for an empty
pool to decide for no reason.

**Inflating straight from the socket** rather than reading the compressed
bytes first. Saves the compressed copy in the arena. It would need a bounded
reader over the connection for the sized case and the chunked reader taught
to be one for the other, and it moves the inflater's stack frame to where
the fiber suspends waiting for bytes — which is where a frame costs per
connection (ADR 0071). The compressed copy is cheaper than that.

**Growing into an `Allocating` writer** rather than trusting the trailer.
Works for a stream with no trailer, and gzip always has one. Reading the
number costs four bytes and buys an exact allocation and a ceiling check
that runs before the work rather than partway through it.

**Decoding `deflate` too.** HTTP's `deflate` is a zlib stream that some
clients send raw, and telling the two apart is a heuristic. Nothing that
pushes telemetry sends it, and the 415 says gzip in the sentence.

## Consequences

- `http/encoded.zig`: `inflate(arena, raw, limit)`, standalone under
  `zig test`, with the trailer-disagreement cases as tests.
- `http1.Request.encoded` becomes `content_encoding: Encoding`, three
  values; `finish` refuses `.other` with a body, as before.
- `Ctx.body` inflates `.gzip`; `Ctx.bodyStreamWith` refuses any coding
  with a 415 of its own.
- `RESPONSE_415`'s sentence names gzip.
- **The head is not rewritten.** `header("Content-Encoding")` still says
  `gzip` and `header("Content-Length")` still gives the wire length after
  `body()` has inflated it, because the head is read where it lies
  (ADR 0107) and there is nothing to remove a line from. A proxy handler
  that forwards `body()` with the request's own headers sends plain bytes
  labelled `gzip`; `Ctx.body`'s doc comment says so and says what to send
  instead. dusty removes both headers after decoding and keeps the wire
  values on the request, which is the right answer for a parser that copies
  headers into a table and the wrong trade for one that does not.
- The roadmap's compression entry loses its inbound paragraph and keeps
  one sentence for the stream and the other codings.
