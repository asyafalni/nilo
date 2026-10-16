# Compressing with zstd

**`nilo_zstd` compresses and decompresses zstd in memory you hand it: a whole body into a buffer, a stream with a flush, a frame into one allocation of its announced size, and a stream through a `std.Io.Reader`.**

**Reference:** [`nilo_zstd`](../reference/zstd.md#nilo_zstd), [`Compressor`](../reference/zstd.md#zstdcompressor), [`StreamCompressor`](../reference/zstd.md#zstdstreamcompressor), [`Decompressor`](../reference/zstd.md#zstddecompressor), [`StreamDecoder`](../reference/zstd.md#zstdstreamdecoder) · **Design:** [zstd](../design/zstd.md)

`nilo_zstd` is a thin module over libzstd, which nilo fetches and builds only when you ask. It is for a program that stores or sends zstd itself: a file format that compresses its segments, an agent that uploads a log, a route that reads a body a client compressed. nilo's server uses it for the responses `app.compress` sends and the files `app.static` serves ([Responses](./responses.md#compression), [Static files](./static-files.md#files-your-build-already-compressed)), and to read a body under `Content-Encoding: zstd` for `c.body()`, `c.json`, a typed argument, `c.bodyStream()` and a gRPC message ([Requests](./requests.md)); and `nilo_fetch` reads and sends it (`-Dfetch_zstd`, `Call.encoding = fetch.zstd`, [Calling somebody else's API](./fetch.md)); [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md) has the whole design.

## Turning it on

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .zstd = true });
exe.root_module.addImport("nilo_zstd", nilo.module("nilo_zstd"));
```

Or `nilo.app(b, .{ ..., .zstd = true })`, which imports it for you. Without `.zstd = true` the module is still there and refuses to compile with a message that names the line to write, and nothing is fetched. With it, libzstd 1.5.7 is built from its release tarball, always optimised whatever your program is, and **your program still links no libc**. A program that only decodes does not link an encoder: the stripped binary grows by 123 KB, and by 410 KB if it only compresses.

## Memory is yours

Every context is bytes you provide, and a function says how many. There is no allocation inside the module, which is what lets a server keep one compressor per thread, or a request take its decoder from its arena.

```zig
const zstd = @import("nilo_zstd");

fn compress(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const memory = try gpa.alignedAlloc(u8, zstd.workspace_alignment, zstd.Compressor.contextSize(.{}, body.len));
    defer gpa.free(memory);
    var c: zstd.Compressor = try .init(memory, .{}, body.len);

    const out = try gpa.alloc(u8, zstd.compressBound(body.len));
    errdefer gpa.free(out);
    const frame = try c.compress(out, body);
    return gpa.realloc(out, frame.len);
}
```

`contextSize(options, max_src)` is for a body of at most `max_src` bytes: libzstd shrinks the window to the input, so a context for 4 KB at level 3 is 90 KB and for 1 MB 1.3 MB. One context serves any number of bodies, one at a time, each up to `max_src`. The level is 3 by default (1 is fastest, 22 smallest); the cost in time and memory is in [the numbers](../../bench/result/zstd.md).

**`compress` returns `error.NoRoom` when the frame does not fit.** Give it a buffer as small as you want the result to be, and send the body as it is when it says no.

## A server wants a pool

`zstd.CompressorPool` and `zstd.DecompressorPool` hold one context per executor thread in a single mapping and lend them with one `cmpxchg`, the shape nilo's own response compression uses:

```zig
var pool: zstd.CompressorPool = try .init(gpa, thread_count, .{}, max_bytes);
defer pool.deinit(gpa);

if (pool.borrow(my_thread_index)) |c| {
    defer pool.give(c);
    // compress(...) here, and nothing that can wait
}
```

Borrow, compress, give back, and nothing in between that can park the fiber. An empty pool answers `null`, which for a response means sending the body as it is.

## A stream with a flush

`StreamCompressor` is a `std.Io.Writer` onto another one. `flush` makes every byte written so far decodable by the peer without ending the frame, which is what a chunked upload needs when each line must arrive on time. `finish` ends the frame.

```zig
const options: zstd.EncodeOptions = .{ .level = 1, .window_log = 15 };
const memory = try gpa.alignedAlloc(u8, zstd.workspace_alignment, zstd.StreamCompressor.contextSize(options));
defer gpa.free(memory);
var buffer: [4096]u8 = undefined;
var s: zstd.StreamCompressor = try .init(memory, sink, &buffer, options);

try s.writer.writeAll("{\"line\":1}\n");
try s.writer.flush(); // the peer can decode that line now
try s.finish();
```

The window is most of what a stream holds, so it is yours to choose: level 1 at 2^15 is 312 KB and level 3 at 2^17 is 1.7 MB, and on a stream of log lines the larger window bought nothing. A flush after every small write costs bytes, about 60% more than letting the encoder fill its blocks, still a sixth of the input.

## Reading a frame

A frame says how large it decodes to, and a hostile one can lie, so ask before you allocate:

```zig
const dmem = try gpa.alignedAlloc(u8, zstd.workspace_alignment, zstd.Decompressor.contextSize());
defer gpa.free(dmem);
var d: zstd.Decompressor = try .init(dmem, .{});

const body = try d.decode(arena, frame, max_body); // error.BodyTooLarge before anything is decoded
```

`decode` allocates exactly the announced size (checked against your ceiling first), refuses a frame whose bytes disagree with what it announced, and verifies the content checksum if the frame has one. A frame that does not announce its size, which a streaming encoder cannot, is decoded into at most `max_body + 1` bytes and the allocation is shrunk to what was used. The context is 96 KB whatever the frame is, and **holds no window**: that is why it is smaller than the standard library's decoder, which needs 8.5 MB, and 8 to 37 times faster.

`Decompressor.announced(frame, window_log_max, limit)` gives the claim without decoding, for a caller with a budget to keep.

For a frame you read as it arrives, `StreamDecoder` is a `std.Io.Reader`. Its context holds the frame's window, so it is sized from the frame's own header:

```zig
const bytes = try zstd.StreamDecoder.sizeFromSource(source, .{}); // peeks up to 18 bytes
const memory = try arena.alignedAlloc(u8, zstd.workspace_alignment, bytes);
var d: zstd.StreamDecoder = try .init(memory, source, &.{}, .{ .max_decoded = 1 << 20 });
// read from d.reader; error.ReadFailed, and d.err says why (BodyTooLarge, ChecksumMismatch, ...)
```

`max_decoded` counts the bytes that come out, so 64 MB of zeros that fit in a few kilobytes stop at your ceiling. A frame that asks for a window over `window_log_max` (23 by default, the 8 MB RFC 9659 requires every HTTP decoder to accept) is `error.WindowTooLarge` before its window is sized.

## What it checks and does not

A frame this module writes carries libzstd's content checksum, and any frame that has one is verified as it is read: a flipped bit is `error.ChecksumMismatch`. A frame without one is accepted, because other encoders differ; `Frame.parse(bytes).checksum` says whether it has one for a caller that requires it, and `Frame.matches(frame, plain)` checks a precompressed file against the file it sits beside without decoding it.

Dictionaries, multithreaded compression and the legacy frame formats are not in it.
