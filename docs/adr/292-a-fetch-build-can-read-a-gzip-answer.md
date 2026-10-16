# A fetch build can read a gzip answer

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes, and a feature the linker cannot drop states its size), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) (a fiber holds its stack at its high-water mark), [ADR 066](./066-a-lazy-dependency-is-a-request.md) (a flag, not a request)
**Extends:** [ADR 182](./182-a-header-std-owns-goes-out-once.md) (the `accept-encoding` half, whose array was identity-only), [ADR 212](./212-tls-is-an-option-a-build-asks-for.md) (a feature behind a build flag, the default build unchanged)

## Context

`nilo_fetch` has always asked for `Accept-Encoding: identity` and refused an answer under any other coding with `error.HttpContentEncodingUnsupported`. The comment at that line gave four reasons: decoding needs an `http.Decompress` and a 32 KiB flate window that by ADR 062 would be held per connection on the handler's stack; it links flate into every binary that dials out; a runtime setting would link flate whether anybody chose it or not; and `max_body` has to count the bytes a caller receives, so a small answer cannot inflate into a large one.

All four stand. What it left was a defect: a server that gzips whatever `Accept-Encoding` says (some third-party APIs and CDNs do) made every call to it fail, with nothing a caller could do. And a program of nilo's own, an agent that posts to a nilo server through `nilo_fetch`, wanted the server's gzip on a large answer and had no way to take it (outpost's port, 2026-10-16).

## Decision

**`-Dfetch_gzip` (`.fetch_gzip = true` on `b.dependency("nilo", …)`) makes `nilo_fetch` read a gzip answer. Off, nothing changes.** The flag is a build option of the dependency, wired as `-Dtls` and `-Dlibdeflate` are, and reaches the module as a generated `fetch_config` with one bool. `fetch.reads_gzip` is that bool, a comptime constant: everything the feature adds sits under `if (comptime reads_gzip)`, so a build without the flag analyses none of it. `fetch_config` is in `fetch`'s row of `layers`, the way `net_config` is.

**What a build with the flag does.** A call made through `Client` (`get`, `post`, `send` and the rest, and so `Target` and `Retry`) sends `Accept-Encoding: gzip, identity`, and an answer under `Content-Encoding: gzip` is decoded: `take`, `readInto`, `pipe`, `stream` and `ex.reader` all read the body, never the stream. **A gzip answer is decoded whatever was advertised**, so the server that gzips regardless of `identity`, and a caller's own `accept-encoding` line, get the body and not the error. Any other coding (`deflate`, `br`) is still `error.HttpContentEncodingUnsupported`; `zstd` is read by a build that also passes `-Dfetch_zstd` ([ADR 295](./295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)), which is a second case of this decision and not a different one.

**`max_body` counts the decoded bytes.** `take` reads the decoder under `Limit.limited(max)`, so 4 MiB of one letter, which is a few kilobytes of gzip, is `error.BodyTooLarge` at `max` (a test holds it). The length announced is the wire's, so the exact-size read ADR 061 added does not apply to a gzip answer; it takes the growing read, which is the one that enforces the ceiling on the bytes that arrive. A leftover that `Exchange.end` drains is drained from the wire, never decoded to be thrown away.

**The bytes are checked, which std does not do.** `std.compress.flate.Decompress` reads the gzip footer and compares nothing in it. Without nilo's own check a flipped byte in the middle of a literal run comes out as a different body and no error. The decoded reader runs a CRC-32 and a count over what flows through it and compares them to the footer when the stream ends. A body that is not gzip, one that does not decode, a footer that disagrees and a stream that ends early are all `error.BodyEncodingInvalid`; a connection that dies under the decoder is still the clocks' to name (`TimedOut`, `Stalled`, `ReadFailed`).

**The decoder is one heap allocation, made when an answer announces gzip and given back by `end`.** `gzip.Gunzip` is 73,136 bytes: the 64 KiB window (`flate.max_window_len`), flate's own state (3,384 bytes with its reader), a 4 KiB input buffer (flate asserts ten bytes of input and the body reader has no buffer of its own), and the readers. It comes from the client's allocator, so the stack of a call grows by one pointer, `Exchange.unzip` (a `decode.Reading`, whichever coding) (the frame of the release program's `main`, where `Program.op` inlines, goes from 6,440 to 6,456 bytes; without the flag the field has type `void` and the frame is 6,440 in both), and an answer that is not gzip allocates nothing. The cost per gzip answer is that one allocation, 73 KB for the length of the read.

**`Begin.decode` is the per-driver switch, and it defaults to false.** (It was `Begin.gzip` until the second coding made the name wrong; the release it was named in never shipped.) `Client`'s calls set it when the build reads any coding. A caller driving an `Exchange` itself (an object store, which must hand back the bytes as they were stored) leaves it out and gets identity and the old error, as before, in a build with the flag as in one without: `nilo_s3` is untouched. The field is accepted and does nothing in a build without a reading flag.

**A build without the flag is the build it was**, and says so: an answer under a coding it does not read is still `error.HttpContentEncodingUnsupported`, and a Debug build logs, once per such answer, how to read it. A ReleaseFast build does not: a log call links std's formatting into every program that dials out (1,952 bytes of a 954,208-byte one, measured), and the cost of a hint is not worth paying in every deployment. The reference and the guide say it instead.

**A second coding is a case, not a reshaping, and zstd was it.** `fetch/decode.zig` has `Coding` (the list), `coding(encoding)` (the answer's `Content-Encoding` as one this build reads), `advertised` (the `Accept-Encoding` value, best first) and `Reading` (a header every decoder starts with: the wire it reads, the decoded face, and `close`, `undecodable` and `outOfMemory`); `Reading.open` is the one switch, `gzip.zig` and `zstd_read.zig` are the two decoders, and `fetch.zig` names only `decode`. `fetch.reads_gzip` and `fetch.reads_zstd` are independent comptime constants, so a build can read either or both, and `fetch.accepted_encodings` is what its calls send. What changed in the code that was gzip's: `Exchange.unzip` points at a `Reading`, `fail` asks it two questions, and `Begin.gzip` became `Begin.decode`.

**`Canned.replyGzip(out, status, headers, plain)`** serves `plain` gzipped under `Content-Encoding: gzip`, into a buffer the caller owns, so a caller's decode path is testable; the stream is in `canned.body`, where a test can damage it.

## What was rejected

- **A runtime setting (`Settings.gzip`, `Call.gzip`).** The branch is then at run time and flate is linked in whether anybody chose it, which is ADR 017's complaint about `docs()` and the reason the comment at the line forced identity. The build flag costs a program that did not ask for it 16 bytes (the name of the new error).
- **A second client type (`GzipClient`).** Everything built on `Client` (`Target`, `Retry`, the trace exporter, `s3.Store`) would need the same twin, or would be unable to take the feature. A comptime-selected path inside the one type keeps lazy analysis's benefit and has one API.
- **A comptime argument on each call.** It changes the signature of every call to carry one bool that is the same for a whole program, and the answer to "which build reads gzip" is a property of the build.
- **`std.http.Decompress` and `readerDecompressing`.** The union also holds the zstd decoder, which would be linked for nothing, and its state sits on the stack or in a caller-supplied buffer; the heap allocation of exactly gzip's decoder is smaller and keeps the stack as it was. Direct mode (no window, the destination's buffer is the history) would save the 64 KiB for `take` alone and cannot serve `pipe`, `stream` and `readInto`, which write into buffers of the caller's choosing.
- **Decoding only in `take`.** Then `pipe` and `stream` would hand back gzip with no error, which is the trap the identity default was chosen to close.
- **Trusting the footer to std.** See above: it reads and compares nothing.
- **Logging how to opt in in every build.** 1,952 bytes on every ReleaseFast program that dials out, to say a sentence the docs already say.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 without the flag, and with it 0 on an answer that is not gzip. One allocation of 73,136 bytes on a gzip answer, from the client's allocator, freed by `end`; the body and the head are the arena's, as before |
| Memory per idle connection | 0 without the flag. With it, 8 bytes on the `Exchange` (the frame of the measured program +16 B); the window is on the heap for the length of one read, not on the fiber's stack |
| Throughput and p99 | 0 on an answer that is not gzip (9,798 instructions a call without the flag, 9,747 with it, the 100-byte answer of `bench/release/fetch.zig`). A gzip answer pays its decode: about 114,000 instructions for 4 KiB of JSON, 18.2 million and 2.3 ms for 1 MiB (`bench/result/fetch.md`) |
| Binary size | +16 B without the flag (954,208 → 954,224 B, the program of `bench/release/fetch.zig`). +23,424 B with it (→ 977,648 B), the flate decoder and the CRC |
