# zstd

**nilo's zstd is a module that places libzstd's contexts in the caller's memory, built behind a flag with no libc, and a design for the eight places the framework will use it.**

**Guide:** [Compressing with zstd](../guide/zstd.md) · **Reference:** [`nilo_zstd`](../reference/zstd.md)

The code is `zstd/zstd.zig` (the module and its tests) and `zstd/shim/string.h`; the library's build is `zstdLibFor` in `build.zig`. The numbers are in [`bench/result/zstd.md`](../../bench/result/zstd.md).

## Overview

```
 b.dependency("nilo", .{ .zstd = true })      -Dzstd in this repository
            │  lazyDependency("zstd") only behind the flag (ADR 066)
            ▼
  libzstd 1.5.7 tarball ──► 22 C files, ReleaseFast, no libc, no assembly
            │
            ▼
  nilo_zstd:  Workspace bytes ─► ZSTD_initStatic{C,D}Ctx ─► never malloc
     Compressor        one body into a buffer          contextSize(options, max_src)
     StreamCompressor  a Writer with flush and finish  contextSize(options)
     Decompressor      a frame, one allocation         contextSize()
     StreamDecoder     a Reader, ceiling on output     sizeFrom(header)
     *Pool             one context a thread, borrowed  one mapping, no huge pages
```

## Rules

1. **A context is the caller's bytes and a function says how many.** libzstd's static contexts never call `malloc` and fail with `ContextTooSmall` instead of overrunning, so the same module serves a server's per-thread pool, a request's arena and a program's heap. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)
2. **A build that does not ask fetches, builds and links nothing.** `.zstd = true` is the flag, `lazyDependency` is called only behind it, and the module without it is a compile error that names the line to write. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md), [ADR 066](../adr/066-a-lazy-dependency-is-a-request.md)
3. **It links no libc.** One shim header, `XXH_NO_STDLIB`, and the allocation macros defined to a null; the three functions left over are compiler_rt's. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md), [ADR 248](../adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md)
4. **A program links only the half it calls.** One archive, and the linker takes the members a symbol asks for: decoding is +123 KB, encoding +410 KB. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)
5. **The window is bounded twice.** The encoder's by the body's size (`max_src`) and by the 8 MB RFC 9659 allows, the decoder's by the same cap, so a peer chooses a decoder's memory only up to a number the deployment set. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)
6. **A frame is a claim.** `announced` checks the magic, the window, a size no frame of that length could hold and the ceiling before anything is allocated; `decode` refuses a stream whose bytes disagree; the streaming decoder counts decoded bytes against a ceiling. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)
7. **A checksum is written and verified when present, and not demanded.** Other encoders differ; a static `.zst` is judged by decoding it against the file, which needs none. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)
8. **The server and the client use it in eight places, designed together.** Response compression, request bodies, `bodyStream`, static siblings and a load-time copy, `nilo_fetch` reading and sending, a streaming upload, and the test client. The module is the part all eight share; the request bodies, `bodyStream`, gRPC messages, the responses, the static files and the test client and `nilo_fetch`'s reading and sending are wired. [ADR 295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)

## Decisions

| ADR | What it decides |
|---|---|
| [295](../adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md) | The flag and the library build, the module and its API, the checksum and window rules, and for each of eight uses what it holds, where, and what it adds to the four axes |

Related topics: [static files](static-files.md) for the pool and the siblings zstd joins, [the HTTP/1.1 wire protocol](http1-protocol.md) for the codings a request body is read under, [outbound calls](fetch.md) for the answer a client decodes, and [layering](layering.md) for why a tool module imports nothing.

## Open questions

- **A trained dictionary** for small JSON would beat a factor of two on a 4 KB body. A static context cannot load one; `ZSTD_initStaticCDict` is the seam, and it adds an option rather than changing the API.
- **Compressed streaming responses** stay refused with ADR 211's reason (a compressor held across writes breaks the borrow rule); the streaming compressor is the shape that would fit, and is built for the upload.
- **gRPC message compression** (`grpc-encoding: zstd`) is a header the gRPC side reads and is not a `Content-Encoding`; whether it uses this module is not decided.
