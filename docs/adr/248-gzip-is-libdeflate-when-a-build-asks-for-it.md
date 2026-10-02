# gzip is libdeflate when a build asks for it

**Status:** accepted
**Topic:** [static-files](../design/static-files.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) (a fiber holds its stack at its high-water mark), [ADR 066](./066-a-lazy-dependency-is-a-request.md) (a lazy dependency is fetched only behind a flag)
**Extends:** [ADR 211](./211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md) (the pool, its borrow rule and its sizes), [ADR 212](./212-tls-is-an-option-a-build-asks-for.md) (a library behind a flag, the default build unchanged)
**Closes:** the `nilo_http` roadmap entry *gzip through libdeflate, behind a flag*

## Context

ADR 211 gzips an answer per request on `std.flate`, the only deflate encoder in Zig's standard library, and gzips a static file once at load on the same. It is correct and it is slow: on a quiet Zen 5 it takes 40 µs for 4 KB of JSON, and the CPU an answer spends on gzip is most of the CPU a small JSON answer costs at all.

[libdeflate](https://github.com/ebiggers/libdeflate) is a C library that does one-shot deflate, zlib and gzip on whole buffers, which is the only shape ADR 211's pool ever asks for: the body is whole and in the arena before the compressor is borrowed. It was measured against `std.flate` twice, on a busy 2-core Xeon and on a quiet Ryzen 7 9700X, through a copy of `Pool.gzip` ([`bench/result/http.md`](../../bench/result/http.md#libdeflate-against-stdflate-on-a-quiet-zen-5-and-what-it-keeps-resident)):

| body | `std.flate` 6 | libdeflate 6 | × |
|---|---|---|---|
| 4,190 B | 946 B, 40.3 µs | 937 B, 10.1 µs | 0.25 |
| 8,397 B | 1,521 B, 63.2 µs | 1,478 B, 18.0 µs | 0.28 |
| 65,705 B | 7,191 B, 420 µs | 5,891 B, 144 µs | 0.34 |
| 1,057,992 B | 106,428 B, 6.96 ms | 80,635 B, 2.52 ms | 0.36 |

Two things stood between that and a decision. One was whether a benchmark board would count a C library behind a flag as the framework's own compression, and it does not decide this: the time is what any JSON API behind no proxy pays. The other was what it would cost in memory, where the first figure on the record was the allocation, 668 KB a compressor against 296 KB, and the allocation turned out not to be the cost.

The one Zig package that wraps libdeflate pins 1.18, from 2023, leaves `lib/crc32.c` out of its build so that `libdeflate_gzip_compress` names a symbol nothing defines, links libc, and waits on its author for every Zig release. The library itself is plain C99 with nothing to port.

## Decision

**A build that passes `.libdeflate = true` to `b.dependency("nilo", …)`, `-Dlibdeflate` in this repository, gzips with libdeflate 1.26 everywhere it gzips, and a build that does not is unchanged.** Everywhere is the per-request pool and the static file gzipped at load, through one `compress.backend`, so the libdeflate build carries no `std.flate` compressor at all. The API does not move: `app.compress(.{})`, its `Options` and their defaults are the same in both builds, and so is which bodies go out gzipped.

**The library is the upstream release tarball, fetched lazily and compiled by nilo's own `build.zig`**, the way llhttp is (ADR 231), so a Zig release costs it nothing. Only compression is compiled: `deflate_compress.c`, `gzip_compress.c`, `crc32.c` and the two `cpu_features.c`. It is always `ReleaseFast`, whatever the program is built as, because C at `-O0` under the undefined-behaviour sanitizer is not the library that was measured.

**It is built `FREESTANDING`, and `lib/utils.c` is left out.** nilo's plain build links no libc, and the macro is what keeps libdeflate from naming `malloc`. But under it `utils.c` defines `memcpy`, `memset`, `memmove` and `memcmp` as weak byte loops, and linked in, its 288-byte `memcpy` won over compiler_rt's for every caller in the program, Zig's included. `http/libdeflate.zig` defines the four symbols the compressor needs from that file instead: the two default allocator pointers, null, and the aligned allocation pair, the same arithmetic as the C. `-fbuiltin` after `-ffreestanding` keeps a `memcpy` of constant size a load rather than a call; the freestanding build and a glibc one time the same, 10.0 µs against 10.0 on 4 KB.

**The compressors are in one mapping that is kept off transparent huge pages.** `Pool.init` asks libdeflate how many bytes one compressor takes, rounds it up to a page, maps that times the thread count from the page allocator, gives it `MADV_NOHUGEPAGE` on Linux before anything is written, and builds each compressor at its own page. A compressor allocates 668 KB and a small body writes 229 KB of it; the rest is never resident. Under THP `always`, a common default and this machine's, one write into a 2 MB-aligned stretch of a large anonymous mapping makes the whole 2 MB resident, and sixteen compressors in one `gpa.alloc`, which is how the standard library's slots are held, would be 10.7 MB rather than 3.7. A kernel that refuses the advice, one built without transparent huge pages or qemu's user-mode emulation, has none to give, so the refusal is ignored. libdeflate's allocation callback takes no context, so the address goes in through a thread-local set for the length of one allocation; nothing is ever freed through libdeflate, because the memory is the pool's.

**`Level` maps to 1, 6 and 7.** `.fastest` and `.default` are the levels zlib means by them. **`.best` is 7, not 9**: on a megabyte libdeflate 9 takes 17.7 ms, longer than `std.flate`'s own `.best` (12.8), and on 65 KB six times its level 6 for 0.4% fewer bytes, so `max_bytes` would stop bounding what it was sized to bound. Level 7 is smaller than `std.flate` 9 on every body measured, and on a megabyte takes about what `std.flate`'s `.default` does or less (4.2 ms against 7.0 on one, 9.4 against 9.3 on the other), so the time `max_bytes` was sized against holds for every level.

**The rule for what goes out gzipped is the standard library's, to the byte.** libdeflate writes into a fixed buffer and answers 0 when the result does not fit. The buffer is the one ADR 211 reserves, half the body plus 64 bytes, so the common case is one arena allocation of the same size in either build; a body that compresses worse than half is tried once more in that allocation grown to one byte short of the body, so a result smaller than the body still goes out gzipped. Twice the CPU on that body, which on text is the rare case: no body measured here compressed to more than 37%.

**`compress.reset` stays, for the standard library.** libdeflate's compressor keeps nothing from one body to the next that it does not set up again, so there is no in-place reset to hold under it, and no 99 KB `init` on any stack.

**This repository's http test root links libdeflate whatever the flag says**, the way it builds TLS in (ADR 212), so `compress.zig`'s tests run every pool test against both backends in one `zig build test`. The App under test keeps the default backend, which is the one a dependent gets; `zig build test -Dlibdeflate` runs the whole suite through the other.

## What it costs

Stated against the four axes of ADR 017, for a build that asks. A build that does not is the row at the end.

**Allocations per request: unchanged.** One on a compressed answer, the compressed body, never grown and never resized, the same as the standard library's path: the half it reserves is kept until the arena is reset. `test "the request path stays inside its allocation budget"` and `test "a compressed answer costs one allocation, and it is the compressed body"` pass under `-Dlibdeflate`.

**Memory per idle connection: nothing.** The pool is the App's. **And less stack while compressing**: one `Pool.gzip` writes 2,272 to 2,624 bytes below its caller in `ReleaseSafe` and `ReleaseFast`, against 7,432 to 7,968 for the standard library's, and 5,720 to 6,496 against 13,216 to 14,112 in Debug, on bodies from 4 KB to 888 KB (`zig build bench-compress-stack`). Under a page where the standard library takes two: a fiber that compresses holds one page fewer at its high-water mark.

**Memory per thread: +32 KB resident on small bodies, +78 KB at the ceiling.** Per compressor, through a probe that places each one alone: 229,376 bytes after small bodies against 196,608 for the standard library's slot, and 376,832 after a 1 MB body against 299,008. Through `listen()` on sixteen threads, `bench/compress_rss.py` against `bench/compress_server.zig`, **the libdeflate server holds less than the standard library's**: 8.8 MB idle against 12.3, and 13.0 MB against 16.7 after the same gzip load, because `Compress.init` writes 172 KB of every slot at startup and a libdeflate compressor is 8 KB until it is used. With the advice taken out the same server is 17.1 to 19.1 MB idle, 8.4 to 10.5 MB of it huge pages: that is what the mapping's one line is worth.

**CPU: a quarter to a third of `std.flate`'s**, the table above, and `zig build bench-compress -Dlibdeflate` is the number through `Pool.gzip` itself: 9.4, 13.5 and 16.5 µs at `.default` on the three bodies ADR 211 times at 37.5, 49.8 and 58.3, and 2.39 ms a megabyte against 6.48. So a megabyte holds the thread for about 2.4 ms rather than 7, and `max_bytes` keeps its default: it is the same in both builds, and the size where an answer becomes a download did not move.

**Binary size**, stripped `ReleaseFast`: **+41,696 bytes on `hello` and +42,104 on `rest`** in a build that asks, which is libdeflate's 64.5 KB less the `std.flate` compressor that leaves (the unstripped build has no `flate.Compress` symbol where the default has nine). **The default build is +0 on both**, byte for byte the build before. ADR 017's running total carries both on one row.

## What was rejected

**neurocyte/libdeflate-zig.** A fork of libdeflate 1.18 with a `build.zig` that leaves `crc32.c` out, so gzip compression does not link, calls `linkLibC()`, and is tied to one person updating it for each Zig release. The upstream tarball with nilo's own twenty lines of build is all of what it provides.

**Linking libc under the flag.** The simplest way to give libdeflate `malloc` and `memcpy`, and it would make a build that asked for faster gzip also a build that needs a C runtime, which nilo's plain HTTP build does not.

**`FREESTANDING` with `utils.c` in.** What the macro is for, and it replaced the program's `memcpy` with a byte loop, measured in the linked binary.

**A compressor per `gpa.alloc`, or all of them in one.** The second is where the 10.7 MB comes from. The first leaves it to the allocator and the kernel whether neighbouring mappings merge into one that THP can back; one mapping with the advice on it does not.

**A buffer of `body.len - 1` from the start**, which gives the rule in one call. It doubles what a compressed answer reserves in the arena, a megabyte for a megabyte body, to save a second call on bodies that almost never need it.

**`.best` as libdeflate 9**, for the reason in the Decision, and **libdeflate's decompressor for request bodies**: it inflates a whole buffer into a known bound, and a request body is taken as it arrives (ADR 083), so ADR 089's inbound gzip stays on `std.flate`.

## Consequences

- `http/libdeflate.zig`: the extern declarations, the four `utils.c` symbols, `footprint`, `placeAt`, `gzip`.
- `http/compress.zig`: `Backend`, `backend`, `PoolOf`, `Level.libdeflateLevel`, `gzipOnce`; `Pool` is `PoolOf(backend)`. `http/static.zig` gzips through `gzipOnce`.
- `build.zig`: `-Dlibdeflate`, `libdeflateFor`, and `wireOptions` (was `wireTls`) giving `nilo_build` `libdeflate` and `libdeflate_linked`. `build.zig.zon`: the lazy `libdeflate` dependency.
- `bench/compress_server.zig`, `bench/compress_rss.py` and `zig build bench-compress-server`; `bench/compress_stack.zig` and `zig build bench-compress-stack`; `bench/compare-compress/rss.zig` and `stack.zig`.
- Cross-built for `aarch64-linux-gnu`, `aarch64-macos` and `x86_64-macos`, and `zig build test` passes for `aarch64-linux-musl` under qemu, with the same compressed byte counts as x86 ([the run](../../bench/result/http.md#libdeflate-behind--dlibdeflate-measured-through-nilo)).
- CI's Linux job runs `zig build test -Dlibdeflate` after `test-all`, so the App's own path through libdeflate is on the gate and not only the pool's.
- ADR 211 says which numbers are `std.flate`'s; ADR 017's running total has the row.
