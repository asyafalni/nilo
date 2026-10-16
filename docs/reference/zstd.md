# nilo_zstd

**`nilo_zstd` compresses and decompresses zstd with libzstd's contexts placed in memory the caller provides, behind `.zstd = true`, with no allocation inside and no libc.**

**Guide:** [Compressing with zstd](../guide/zstd.md) · **Design:** [zstd](../design/zstd.md)

## `nilo_zstd`

zstd for a program that stores or sends it, with nothing that needs an event loop ([ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)). It is a tool module: it names only a generated module of one bool, `zstd_build`, which says whether libzstd was linked. The library is C, so `zig test zstd/zstd.zig` alone cannot link it; `zig build test-zstd` runs the whole suite in Debug and ReleaseSafe.

```zig
const zstd = @import("nilo_zstd");
```

**It needs a flag.** `.zstd = true` on `b.dependency("nilo", …)` (or `nilo.app(b, .{ .zstd = true })`, `-Dzstd` in this repository) fetches libzstd 1.5.7 from its release tarball and builds it `ReleaseFast` whatever the program's mode. Without it `@import("nilo_zstd")` is a compile error that says so, and nothing is fetched. A program that calls only the decoder links no encoder (+122,976 bytes stripped; the encoder alone is +409,696).

**Memory.** Every context is a `Workspace` (`[]align(8) u8`) the caller provides, sized by a `contextSize` function. A context given less than that is `error.ContextTooSmall`, never an overrun.

| | |
|---|---|
| `zstd.Workspace`, `zstd.workspace_alignment` | the memory type and its alignment (8) |
| `zstd.compressBound(n)` | the most bytes a frame of `n` input bytes can take: a destination that is never `NoRoom` |
| `zstd.http_window_log` | 23: the 8 MB window RFC 9659 requires a decoder to accept and forbids an encoder to exceed |
| `zstd.ratio_max` | 32,768: no frame decodes to more than this many times its length |
| `zstd.frame_header_max` | 18: the most bytes a frame header takes |
| `zstd.version()`, `zstd.describe(code)` | libzstd's version number, and its words for a failure code (`detail` on each type) |

### `zstd.EncodeOptions`

| field | meaning |
|---|---|
| `level: i32 = 3` | 1 is fast, 22 smallest, negative levels faster still. Time and memory both grow with it |
| `checksum: bool = true` | write the content checksum (four bytes) |
| `window_log: u5 = 23` | the largest match distance as a power of two, never above the level's own. For a stream, most of its memory |
| `content_size: ?u64 = null` | streaming only: the total length, if known, written into the frame header |

### `zstd.Compressor`

A whole body into a caller's buffer, in a context that serves any number of bodies one at a time.

| | |
|---|---|
| `Compressor.contextSize(options, max_src)` | bytes of context for bodies up to `max_src`; the window is bounded by it (4 KB at level 3: 90,128; 1 MB: 1,303,568) |
| `Compressor.init(memory, options, max_src)` | `!Compressor` |
| `c.compress(dst, src)` | `![]u8`: one frame in `dst`, with the content size in its header. `error.NoRoom` if it does not fit, `error.SourceTooLarge` over `max_src` |

### `zstd.StreamCompressor`

A `std.Io.Writer` onto another one.

| | |
|---|---|
| `StreamCompressor.contextSize(options)` | bytes of context: the window, a block of input and a block of output (level 1, window 2^15: 312,513) |
| `StreamCompressor.init(memory, sink, buffer, options)` | `!StreamCompressor`; `buffer` is the writer's own and may be empty |
| `s.writer` | the `std.Io.Writer` to write plaintext into. `s.writer.flush()` makes every byte so far decodable by the peer and flushes `sink` |
| `s.finish()` | ends the frame, its checksum included, and flushes `sink` |
| `s.err`, `s.detail` | after a `WriteFailed` that was libzstd's and not the sink's, which error and its code |

### `zstd.Decompressor`

One frame in one call, with no window.

| | |
|---|---|
| `Decompressor.contextSize()` | 95,968, whatever the frame is |
| `Decompressor.init(memory, .{ .window_log_max = 23 })` | `!Decompressor` |
| `Decompressor.announced(src, window_log_max, limit)` | `!usize`: what the frame says it decodes to, checked before anything is decoded: `NotZstd`, `Truncated`, `SizeNotAnnounced`, `WindowTooLarge`, `Corrupt` for a size over `ratio_max` times the length, `BodyTooLarge` over `limit` |
| `d.decompress(dst, src)` | `![]u8`: `src` decoded into `dst`. `NoRoom`, `Truncated`, `Corrupt`, `ChecksumMismatch` |
| `d.decode(allocator, src, limit)` | `![]u8`: one allocation of exactly the announced size, or for a frame that announces nothing, at most `limit + 1` bytes shrunk to what was used. Allocate from an arena |

### `zstd.StreamDecoder`

A `std.Io.Reader` over another one, counting what it decodes.

| | |
|---|---|
| `StreamDecoder.sizeFrom(header, options)` | `!usize`: the context for the frame whose first bytes are `header`. `WindowTooLarge` over the cap |
| `StreamDecoder.sizeFromSource(source, options)` | the same, peeking up to 18 bytes of a reader without consuming them |
| `StreamDecoder.contextSize(options)` | the context for the largest frame the cap allows (8,877,856 at 23) |
| `StreamDecoder.init(memory, source, buffer, .{ .window_log_max = 23, .max_decoded = … })` | `!StreamDecoder`; `d.reader` is the `std.Io.Reader` |
| `d.reset()` | ready for another frame in the same memory |
| `d.err`, `d.decoded` | after `error.ReadFailed`, which error (`BodyTooLarge`, `Truncated`, `ChecksumMismatch`, `NotZstd`, `ContextTooSmall`, …), and the bytes produced |

### `zstd.Frame`

| | |
|---|---|
| `Frame.parse(bytes)` | `!Frame`: `content_size: ?u64`, `window_size`, `checksum: bool`, `header_len`. `Truncated` if the header is cut, `NotZstd`, `Unsupported` for a skippable frame |
| `Frame.matches(frame, plain)` | whether `frame` announces `plain.len`, carries a checksum and that checksum is `plain`'s, without decoding it |
| `zstd.contentChecksum(content)` | the low 32 bits of XXH64 over `content`: the checksum a frame carries |

### `zstd.CompressorPool` and `zstd.DecompressorPool`

One context a thread in one mapping kept off transparent huge pages.

| | |
|---|---|
| `CompressorPool.init(gpa, n, options, max_src)`, `DecompressorPool.init(gpa, n, options)` | `n` contexts; `gpa` holds only the flags and the table, the contexts come from the page allocator |
| `p.borrow(start)` | `?*Compressor` or `?*Decompressor`: a free one, scanning from `start % n`; `null` if all are out. One `cmpxchg`, never waits |
| `p.give(c)` | return it |
| `p.deinit(gpa)` | |

**The borrow must span no wait**: borrow, compress or decode, give back, and nothing between that can park a fiber.

### Errors

`zstd.Error`: `NotZstd` (the magic is wrong), `Unsupported`, `WindowTooLarge`, `Corrupt`, `Truncated`, `ChecksumMismatch`, `NoRoom`, `BodyTooLarge`, `SizeNotAnnounced`, `SourceTooLarge`, `ContextTooSmall`, `Failed`.

### What it does not do

No dictionaries (a static context cannot load one), no multithreaded compression, no legacy frame formats, no skippable frames at the start of a body, and no allocation of its own beyond the pools' one mapping. It does not choose where zstd is used in the server or the client: that is [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)'s second stage, whose request side reads a body under `Content-Encoding: zstd` on a `DecompressorPool` slot and a `StreamDecoder` from the request arena.
