# 0287 — a response is compressed on a compressor borrowed from a pool

**Status:** accepted
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md)
(one allocation a request, a stated cost per connection),
[ADR 0063](./0063-a-handlers-stack-is-per-connection.md)
(a fiber holds its stack at its high-water mark)
**Extends:** [ADR 0010](./0010-static-files-are-held-in-memory.md)
(a file is gzipped once, at load), [ADR 0251](./0251-a-gzipped-body-is-inflated-into-the-buffer-that-holds-it.md)
(the other direction closed without a pool)
**Closes:** the `nilo_http` roadmap entry *a response body is never
compressed, and only a held file is*

## Context

A static file under the spill threshold has been gzipped once while the
App is built since ADR 0010, and a handler's own answer never has. The
README named that as what "does not ship in a worse shape" looks like: the
shape that fits was known, a pool of compressors sized to the thread
count, and no allocating-per-request version was shipped meanwhile. The
roadmap carried it with three open questions: what happens when the pool
is empty, what it does to a stream, and what it does to an event stream.

What brought it forward is a benchmark board that will not rank a server
as a framework unless it answers `GET /json/{count}` gzipped, through
"the framework's built-in compression middleware", per request, to a
client sending `Accept-Encoding: gzip, br`, and sends no
`Content-Encoding` at all to one that sends nothing. That is also what a
JSON API behind no proxy wants, so the profile is a fair description of
the job.

The premise the roadmap entry rested on turned out to be half the story.
A deflate compressor's window is 64 KB, and `std.compress.flate.Compress`
in Zig 0.16 holds another `~224 KB` beside it: a 128 KB hash table and a
96 KB token buffer, as fields of the struct. So the thing to be pooled is
not 64 KB but `~288 KB`, and the cost of putting one where the standard
library's `init` puts it is not the window at all.

## Decision

**`app.compress(.{})` gzips every answer worth gzipping, per request, on
a compressor borrowed from a pool that holds one per executor thread.**
The pool is built when the chains are resolved, on the heap, sized to the
thread count `listen()` was given; a request borrows a slot, gzips its
whole body into the request arena, hands the slot back, and then writes
the answer with the compressed length. `Content-Encoding: gzip` goes out
when the body was compressed; `Vary: Accept-Encoding` goes out on every
answer that could have been, whether or not this client wanted it
(ADR 0089).

**What qualifies** is a body of at least `min_bytes` (1 KB by default)
whose type is text (`text/*`, JSON, the `+json` and `+xml` structured
types, the same allowlist static files use), on a status that carries a
body, from a handler that did not set `Content-Encoding` itself, to a
client whose `Accept-Encoding` says gzip is welcome, read the way the
static handler reads it: `gzip;q=0` is no, `*` is yes unless gzip is named.
A HEAD is answered with the length the GET would have carried.

**The borrow spans no wait.** Nothing between taking a slot and giving it
back can park the fiber (the arena does not, the compressor does not, and
the socket is not written until afterwards), so at most one slot per
thread is ever out, and a pool of one per thread is never empty on a
server. That is the answer to the roadmap's first question, and it is a
property of the shape rather than a size somebody picked. The fallback
for an empty pool, which an App driven with no server under it can reach,
is the uncompressed body, not an error.

**The compressor is reset in place rather than re-initialised.** `finish`
puts the standard library's writer into its failing state, and its only
way back is `init`, which builds the 96 KB token buffer as a temporary
and copies it into place: **99,048 bytes of stack for one call**, read off
the assembly of a `ReleaseFast` build. On a fiber that is 99 KB held at
the high-water mark for the life of the connection (ADR 0063), released
only when the connection goes idle (ADR 0071): four thousand busy
keep-alive connections would hold four hundred megabytes for a feature
meant to save bandwidth. `compress.reset` does what `init` does, field by
field, into the slot's own memory, and measures 40 bytes of stack the
same way. It depends on the fields `Compress` has in the pinned Zig, and
`test "a compressor reset in place produces what a fresh one does"` holds
it byte for byte against `init`'s own output, twice over on one slot, so
the second use sees what the first left behind.

**The roadmap's other two questions are answered by leaving both out.** A
stream is written in pieces to the socket, so it has no whole body to
compress into the arena and its compressor would be held across every
write, which is the one thing the borrow rule forbids; an event stream
must never be buffered at all. Neither is compressed, and `app.compress`
says so. The shape that would fit a stream (a compressor held for the
stream's life, from a pool larger than the thread count, with chunked
framing) is known and is not built, for the reason the roadmap entry
itself was not built for a year: no caller has asked for it.

## What it costs

Stated against the four axes of ADR 0018.

**Allocations per request: one more, on a request that is compressed, and
it is the compressed body.** Sized to half the input plus a little, which
is where text lands, so it is not grown; held by `test "a compressed
answer costs one allocation, and it is the compressed body"`. A request
that is not compressed (under the threshold, not text, a client that did
not ask) allocates exactly what it did before, held by `test
"compression switched on adds nothing to a request under its threshold"`
on the primary metric's own shape.

**Memory per idle connection: nothing.** The compressors are the App's,
`~288 KB` a thread, allocated once: 4.6 MB on sixteen threads, 18 MB on
sixty-four. A request that compresses touches roughly three more pages of
its fiber's stack while it does (the Huffman builder and the sort under
it are 4.9 KB each), which ADR 0071's release hands back once the
connection is idle. Nothing per connection is held that was not held
before.

**CPU: `zig build bench-compress` is the number**, on the three bodies
the arena rotates through, one thread, `ReleaseFast`, this machine
(Ryzen 7 9700X, eight cores and sixteen threads, Zig 0.16.0):

| items | bytes in | `.fastest` | `.default` | `.best` |
|---|---|---|---|---|
| 25 | 4,091 | 873 B, 35.0 µs | 748 B, 37.5 µs | 744 B, 38.1 µs |
| 40 | 6,553 | 1,252 B, 44.5 µs | 1,041 B, 49.7 µs | 1,036 B, 51.3 µs |
| 50 | 8,178 | 1,483 B, 50.6 µs | 1,225 B, 58.4 µs | 1,218 B, 63.7 µs |

Two things in that table decided defaults. The levels are closer in time
than expected because **6 µs of every body is the reset**, nearly all of
it the 128 KB hash table being cleared, which is not optional: a stale
entry is a distance the matcher subtracts from an index with no bounds
check, so the clear is what keeps the second body from reading before the
buffer. And `.best` buys under one percent of size over `.default` for
five to nine percent more time, which is why `.default` is the default
and `.best` is offered rather than recommended.

**Binary size: +4,896 bytes on `hello` and +4,064 on `rest`** for the
feature, measured as stripped `ReleaseFast` builds of both trees. That is
`Ctx.squeezed`, the eligibility check, the type allowlist and the pool's
`gzip`, none of which the linker can drop because the switch is a runtime
null on the Ctx. The deflate itself was already in every binary: the API
reader page is a static set, and static sets gzip at load. **The same
change is a net −24,608 on `hello` and −3,648 on `rest`**, because the
`Accept-Encoding` reader that static files have used since ADR 0010
answered "is this `q=0`" with `std.fmt.parseFloat(f32, …)`, and that
generic is 25 KB of machine code in a binary that parses no other float.
It is a nine-line digit scan now. ADR 0018's table carries both figures
on one row so that neither hides the other.

**Throughput on a request that is not compressed: unchanged.** The
addition to `send` is one null check.

## What was rejected

**A compressor per connection.** Sixty times the 4,669 bytes an idle
connection holds, for a feature most connections never use.

**A compressor per request, on the handler's stack.** The shape
`Compress.init` is written for, and the 99 KB above. It would have passed
every test in the suite and shown up only in `bench/mem.py` on a busy
server, which is how ADR 0063's 17,022 was found.

**Compressing straight into the connection's write buffer, chunked.** No
arena allocation and no copy, and the shape a stream will want one day.
Rejected here because the compressor is then held across every write to
the socket, and a slow client holds it for as long as it likes; the pool
would need to be larger than the thread count by a number nobody can
name, and a request finding it empty would go out uncompressed on a
server that is merely busy. With the body whole and in the arena the
borrow is bounded by CPU, the length is known, HEAD is free, and the
answer is one write.

**Brotli.** The arena scores bytes per response quadratically and its
clients advertise `br`, so an entry sending gzip sits behind one sending
brotli whatever else it does. There is no brotli encoder in Zig's standard
library and the only complete one is Google's C. That is a dependency
decision of its own, and not one to make inside this ADR.

**A middleware, `app.use(nilo.compress)`.** It reads well, and the arena's
rule uses the word. But a middleware is a function pointer with no state,
and the pool is sized to a thread count the App learns at `listen()`; a
middleware that set a flag for `send` to read would need the pool built
anyway, on every App, for a flag most would never set. `app.compress(.{})`
is one line, records the ask, and `resolveChains` builds the pool when it
knows how many.

**Waiting for a free slot.** There is nothing to wait on: a slot held by
a fiber on another thread comes back in tens of microseconds, and a lock
in the `cache` module's position, with no `Io` to park on, would spin. The
bitmask borrow is one `cmpxchg`, and empty means uncompressed.

## Consequences

- `http/compress.zig`: `Options`, `Level`, `Pool`, `reset`, and the
  `acceptsGzip` and `compressible` that `static.zig` and `serve.zig` now
  import from here.
- `http/ctx.zig`: `_compressors`, and `send` runs `squeezed` before the
  wait.
- `http/app.zig`: `compress()`, three fields, and `tryListen` records the
  thread count before the chains are resolved; `http/wiring.zig`:
  `sizeCompressors`, run by `resolveChains` and idempotent, because the
  test client resolves the chains before every request.
- `http/engine/zio.zig`: `threadCount`, the Engine's own reading of
  `Options.threads`, re-exported by the Bulkhead so the pool and the
  executors are sized from one number.
- `bench/compress_bench.zig` and `zig build bench-compress`.
- The roadmap entry closes; what is left (a stream, an event stream,
  brotli) is one sentence under `Known, waiting for a caller`.
