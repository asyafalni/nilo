# zstd

What libzstd costs next to gzip in a program that asks for it, what the contexts weigh, and how its decoder compares with the one in the standard library. The decisions these numbers moved are in [ADR 295](../../docs/adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md).

## What was run

`zig build bench-zstd` (`bench/zstd_bench.zig`), once as it is and once with `-Dlibdeflate`, which swaps only the gzip column from `std.flate` to libdeflate; the zstd columns are the same code in both runs, and they agree to 3% (4.9 µs and 4.9 µs on the 4 KB body, 487.8 and 502.3 µs on the 1 MB one), which is the drift of the machine between the runs. Beside it `zig build bench-zstd-stack` (the stack a call writes below its caller), `zig build size-zstd` (four programs whose stripped sizes price each half of libzstd) and `bench/release/zstd.zig` (the module's row in `bench/release.py`).

The bodies are `bench/compress_bench.zig`'s (the arena's `json-comp` shapes, here 25, 40, 50, 250, 1,000, 6,000 and 24,000 items), because HttpArena's `dataset.json` is not on this machine, and two files that are not JSON: this repository's guide and ADR pages concatenated (`prose.txt`, 1.6 MB of Markdown) and `/usr/bin/git` (4.9 MB of machine code), which have far more literals in them than a JSON body does. Every compressed output is decoded by the module's own decoder in the test suite; the benchmark times and does not check.

**Machine and commit.** AMD Ryzen 7 9700X (Zen 5), Linux 7.2.5, Zig 0.17.0, libzstd 1.5.7, at `88209de` plus the module, uncommitted. The timed runs were pinned with `taskset -c 5` and read thread CPU time (`CLOCK_THREAD_CPUTIME_ID`, which leaves out the time a busy machine makes a thread wait for a core), the best of three runs of enough calls for 80 ms. **The machine was busy**: load average 3.5 to 6.5 from other sessions compiling, so a figure is good to about 5% and a ratio carries further than a microsecond count. `-Dtarget=x86_64-linux-gnu`, the baseline CPU (no `-Dcpu`), which is what a dependent builds without asking.

## Compressing: CPU a body and bytes out

| body | in B | `std.flate` .fastest | `std.flate` .default | libdeflate .fastest (1) | libdeflate .default (6) | zstd 1 | zstd 3 | zstd 6 |
|---|---|---|---|---|---|---|---|---|
| 25 items | 4,093 | 871 B, 21.0 µs | 743 B, 23.7 µs | 817 B, 5.0 µs | 721 B, 9.1 µs | 734 B, 4.4 µs | 745 B, 4.9 µs | 685 B, 11.0 µs |
| 40 items | 6,545 | 1,246 B, 30.7 µs | 1,024 B, 36.1 µs | 1,172 B, 6.6 µs | 985 B, 13.3 µs | 991 B, 5.9 µs | 1,002 B, 6.4 µs | 899 B, 16.3 µs |
| 50 items | 8,172 | 1,478 B, 37.1 µs | 1,202 B, 44.8 µs | 1,402 B, 7.8 µs | 1,165 B, 16.3 µs | 1,155 B, 6.8 µs | 1,170 B, 7.3 µs | 1,071 B, 20.2 µs |
| 250 items | 41,028 | 6,410 B, 167.5 µs | 4,690 B, 243.4 µs | 6,001 B, 29.8 µs | 4,028 B, 88.8 µs | 4,387 B, 22.8 µs | 4,364 B, 24.4 µs | 4,099 B, 103.8 µs |
| 1000 items | 164,398 | 24,667 B, 681.6 µs | 17,104 B, 1,044.7 µs | 22,535 B, 120.5 µs | 13,314 B, 365.4 µs | 15,980 B, 88.2 µs | 15,899 B, 91.0 µs | 13,672 B, 425.6 µs |
| 6000 items | 991,794 | 145,619 B, 4,217.2 µs | 99,794 B, 6,499.3 µs | 133,248 B, 1,002.1 µs | 75,665 B, 2,344.1 µs | 74,945 B, 500.7 µs | 65,985 B, 487.8 µs | 53,479 B, 2,377.2 µs |
| 24000 items | 3,984,446 | 582,362 B, 16,855.8 µs | 397,973 B, 26,055.2 µs | 532,177 B, 4,039.5 µs | 300,225 B, 9,269.7 µs | 274,845 B, 2,001.4 µs | 203,794 B, 1,789.8 µs | 198,649 B, 8,943.5 µs |
| prose.txt | 1,624,203 | 671,390 B, 12,632.1 µs | 575,421 B, 45,141.6 µs | 629,084 B, 5,037.9 µs | 573,814 B, 15,356.5 µs | 643,561 B, 3,102.4 µs | 547,488 B, 4,802.3 µs | 511,061 B, 11,762.6 µs |
| git | 4,899,632 | 2,628,349 B, 50,412.5 µs | 2,470,733 B, 142,332.8 µs | 2,619,710 B, 43,504.2 µs | 2,453,554 B, 92,957.1 µs | 2,862,795 B, 7,750.6 µs | 2,535,412 B, 14,310.8 µs | 2,373,263 B, 37,061.0 µs |

Read it by the 4 KB row, which is a JSON answer, and the 1 MB row, which is the default `max_bytes`:

- **On a small body zstd 3 is about twice as fast as libdeflate's default and 3% larger, and next to libdeflate's `.fastest` it is the same speed and 10% smaller.** 4.9 µs and 745 B against 9.1 µs and 721 B, and 4.4 µs and 734 B (zstd 1) against 5.0 µs and 817 B. Against `std.flate` it is 4.8 times faster at the same size. A 4 KB answer is where the framework spends most of its compressions, so the gain on the request path is a few microseconds, not a factor.
- **On a megabyte it is 4.8 times faster than libdeflate's default and 13% smaller**: 487.8 µs and 65,985 B against 2,344 µs and 75,665 B. zstd 6 matches libdeflate's default on time (2.38 ms against 2.34) and writes 29% fewer bytes (53,479). Against `std.flate` .default (6.5 ms, 99,794 B) it is 13 times faster.
- **On a body that is not JSON the ratio gap closes and can reverse.** On the prose zstd 3 is still ahead on both: 4.8 ms against 15.4 ms, and 548 KB against 574 KB. On machine code (git), zstd 1 writes 17% more than libdeflate's default and zstd 3 3% more, at a twelfth to a sixth of the time. A response is text; the row is here for the static files nilo serves.
- **Level 1 is a good `.fastest`**: on a small body it writes the same bytes as level 3 (734 against 745) in 4.4 µs against 4.9.

The levels a file compressed once at load could use (one run each):

| body | level 3 | level 9 | level 12 | level 19 |
|---|---|---|---|---|
| 6000 items, 991,794 B | 65,985 B, 0.6 ms | 56,210 B, 3.7 ms | 39,349 B, 4.8 ms | 32,360 B, 223.1 ms |
| prose.txt, 1,624,203 B | 547,488 B, 4.9 ms | 495,246 B, 18.1 ms | 485,089 B, 30.1 ms | 446,551 B, 208.1 ms |

Level 12 is 5 to 30 ms a file and takes 40% off the level 3 bytes of JSON; level 19 is 46 times the time of level 12 for 18% fewer bytes. A static file is compressed once, at load, so 12 is cheap and 19 is a decision for a build that writes `.zst` siblings with the `zstd` CLI.

## Decoding: CPU a body

| body | out B | libzstd one-shot | libzstd stream | `std` zstd, destination as history | `std` zstd, own window | `std.flate` inflate | stream context B |
|---|---|---|---|---|---|---|---|
| 25 items | 4,093 | 2.3 µs | 2.4 µs | 29.8 µs | 29.8 µs | 5.3 µs | 112,404 |
| 40 items | 6,545 | 3.0 µs | 3.1 µs | 36.9 µs | 36.8 µs | 6.8 µs | 122,212 |
| 50 items | 8,172 | 3.4 µs | 3.6 µs | 42.2 µs | 42.2 µs | 7.7 µs | 128,720 |
| 250 items | 41,028 | 12.7 µs | 12.9 µs | 126.7 µs | 127.4 µs | 24.0 µs | 260,144 |
| 1000 items | 164,398 | 45.2 µs | 45.4 µs | 351.2 µs | 432.8 µs | 85.6 µs | 653,646 |
| 6000 items | 991,794 | 212.2 µs | 212.3 µs | 1771.7 µs | 1879.6 µs | 515.7 µs | 1,481,042 |
| 24000 items | 3,984,446 | 743.5 µs | 743.8 µs | 5438.4 µs | 5517.0 µs | 2074.8 µs | 2,586,400 |
| prose.txt | 1,624,203 | 967.5 µs | 965.9 µs | 11426.5 µs | 11796.3 µs | 3113.2 µs | 2,113,451 |
| git | 4,899,632 | 3374.9 µs | 3387.5 µs | 126399.6 µs | 127562.3 µs | 15480.2 µs | 2,586,400 |

- **libzstd decodes 2.3 times faster than `std.flate` inflates on a small body and 2.4 times on a megabyte, and 13 times faster than `std.compress.zstd` on a small body.** 2.3 µs against 5.3 µs (inflate) and 29.8 µs (std's zstd) for 4 KB; 212 µs against 516 and 1,772 for 1 MB.
- **std's zstd decoder is 8 to 37 times slower than libzstd on the same frame**: 8.4 times on 1 MB of JSON, 11.8 on the prose, 37 on the machine code (126 ms against 3.4). Its memory is the other half: it needs a buffer of `window_len + 128 KB`, 8,519,680 bytes at the RFC 9659 cap, to stream into anything, and in the mode where the destination is the history it needs the whole output as one fixed writer, which `c.bodyStream()` cannot give. libzstd's one-shot decoder needs 95,968 bytes whatever the frame says and no window; its streaming decoder is sized from the frame header (112,404 bytes for a 4 KB frame, 1.48 MB for a 1 MB one, 8.9 MB at the cap).
- **The streaming decoder costs the one-shot decoder's time plus 1% to 5%** on a small body (2.4 against 2.3 µs) and nothing measurable on a large one.
- **The amd64 Huffman loop (`huf_decompress_amd64.S`) is not worth its file.** With it linked and without it, decoding 1 MB of JSON took 210.2 and 212.4 µs, the prose 959.4 and 966.0, the machine code 3,314 and 3,372: 0.7% to 1.7% faster, within what the machine moved between two runs of the same code. `ZSTD_DISABLE_ASM` is set, which removes an assembly file from the build, the one place it was per architecture.

## What a context weighs

One-shot compression, bytes of the caller's memory, `Compressor.contextSize(.{ .level = L }, max_src)`:

| level | 4 KB | 64 KB | 1 MB |
|---|---|---|---|
| 1 | 73,744 | 304,144 | 582,672 |
| 3 | 90,128 | 664,592 | 1,303,568 |
| 6 | 90,128 | 1,057,808 | 3,662,864 |
| 9 | 106,512 | 1,057,808 | 13,100,048 |

**The window is bounded by `max_src`**: the context for a body of at most 4 KB at level 3 is 90 KB and for one of at most 1 MB it is 1.3 MB, and a level 9 context for 1 MB is 13 MB, which is why a pool sized for `max_bytes` takes the level into account.

**What a pooled compressor keeps resident is what the bodies it served touched.** One slot of a `CompressorPool` sized for 1 MiB at level 3 (1,306,624 bytes mapped, kept off transparent huge pages), after one body, `mincore` over the slot: 4 KB body, 90,112 resident; 16 KB, 249,856; 64 KB, 462,848; 256 KB, 634,880; 1 MB, 892,928. libdeflate's compressor is 229,376 after small bodies and 376,832 after a megabyte (ADR 248). So zstd at level 3 is smaller than libdeflate while the bodies are small (under about 16 KB) and 516 KB larger at the 1 MiB ceiling; sixteen threads, all having served a megabyte, hold 14.3 MB.

Decompression, bytes of the caller's memory:

| | bytes |
|---|---|
| `Decompressor.contextSize()`, one-shot, any frame | 95,968 |
| `StreamDecoder.sizeFrom`, a frame of 4 KB / 41 KB / 165 KB / 1 MB / 4 MB | 112,404 / 260,144 / 653,646 / 1,481,042 / 2,586,400 |
| `StreamDecoder.contextSize(.{})`, the largest frame RFC 9659 allows (8 MB window) | 8,877,856 |
| `std.compress.zstd.Decompress` with a window of its own | 8,519,680 |

A streaming compressor (`StreamCompressor`), 164,398 bytes of JSON written in 1,000-byte pieces:

| level | window | context B | output B | output B, flushed after every piece |
|---|---|---|---|---|
| 1 | 2^15 | 312,513 | 17,526 | 26,875 |
| 1 | 2^17 | 976,401 | 15,938 | 26,374 |
| 1 | 2^19 | 1,369,617 | 15,954 | 26,375 |
| 3 | 2^15 | 1,033,409 | 17,430 | 25,861 |
| 3 | 2^17 | 1,697,297 | 15,791 | 25,325 |
| 3 | 2^19 | 2,090,513 | 15,829 | 25,362 |
| 3 | 2^21 | 3,663,377 | 15,829 | 25,362 |

A flush after each 1,000-byte write is what every line arriving on time costs: 60% more bytes than letting the encoder fill its blocks (a block boundary a flush), and still 16% of the input. A window over 2^17 buys nothing on a stream of this size and costs most of the memory; level 1 at 2^15 is 312 KB.

## The stack a call writes

`zig build bench-zstd-stack`, the deepest byte painted below the caller, bodies of 4 KB, 58 KB and 888 KB. A fiber holds its stack at the high-water mark (ADR 062); every row is under one 4 KB page in every mode.

| call | ReleaseFast | ReleaseSafe | Debug |
|---|---|---|---|
| `Compressor.compress`, levels 1 to 12 | 1,728 to 2,104 | up to 2,104 | up to 2,584 |
| `Decompressor.decompress` | 1,112 to 1,232 | up to 1,248 | up to 1,616 |
| `StreamDecoder` read of a whole frame | 1,608 to 1,728 | up to 1,760 | up to 2,960 |
| `StreamCompressor` write, flush and finish | 2,816 | 2,800 | 3,456 |

For comparison libdeflate's `Pool.gzip` writes 2,272 to 2,624 bytes in ReleaseSafe and ReleaseFast, and `std.flate`'s 7,432 to 7,968.

## Binary size and libc

`zig build size-zstd`, stripped `ReleaseFast`, `-Dtarget=x86_64-linux-gnu`, four programs that differ only in which half of libzstd they call:

| program | bytes | over the control |
|---|---|---|
| control (no zstd) | 4,840 | |
| decompress only | 127,816 | +122,976 |
| compress only | 414,536 | +409,696 |
| both | 521,032 | +516,192 |

**A program that only decodes links no encoder**: the library is one archive of 22 objects, the linker takes only the members a symbol asks for, and `-ffunction-sections` lets it drop what is left. The encoder is 3.3 times the decoder because libzstd carries eight strategies; building without the three binary-tree ones (`ZSTD_EXCLUDE_BTULTRA_BLOCK_COMPRESSOR`, `BTOPT`, `BTLAZY2`) takes 57,344 off the encoder (414,536 to 357,192) and silently caps the useful levels at 12, which is not a default worth taking.

**No libc.** The program above is `statically linked` with no dynamic section on a `-gnu` target, and the library needs three symbols (`memcpy`, `memmove`, `memset`), which compiler_rt provides. `zstd/shim/string.h` stands in for the one libc header libzstd includes, `XXH_NO_STDLIB` removes xxhash's `stdlib.h`, and the allocation macros are defined to a null (`ZSTD_malloc(s)=((void*)0)`), so a path that asked for memory would fail rather than call anything: none does, because `nilo_zstd` only builds the `ZSTD_initStatic*` contexts in the caller's memory. `nm` over the archive shows no weak definition of any libc function, which is the trap `lib/utils.c` was in libdeflate (ADR 248). The Debug and ReleaseSafe tests link the same archive.

## Stage 2: a response and a static file through the App's own paths

What stage 1 measured is the module; this is the same bodies through `Pool.encodeAt` (what `Ctx.send` calls), one pinned thread, the request arena reset after every body, rounds as in `bench/compress_bench.zig`. `zig build bench-compress -Dzstd` and `-Dzstd -Dlibdeflate` (the zstd rows agree to 3% between the two), `zig build -Doptimize=ReleaseFast bench-compress-server -Dzstd` with `python3 bench/compress_rss.py ./zig-out/bin/nilo-bench-compress-server zstd`, `zig build bench-compress-stack -Dzstd -Dlibdeflate`. Same machine as above, **busy** (load average 2 to 3 from other sessions), at `33eff19` plus stage 1 and stage 2, uncommitted; `-Dtarget=x86_64-linux-gnu`, no `-Dcpu`.

**CPU and bytes a response, JSON, gzip at `.default` and zstd at `.default` (3), through the Pool:**

| body | `std.flate` | libdeflate | zstd |
|---|---|---|---|
| 4,091 B | 748 B, 25.0 µs | 727 B, 9.6 µs | 746 B, 5.3 µs |
| 8,178 B | 1,225 B, 47.4 µs | 1,180 B, 17.2 µs | 1,175 B, 7.7 µs |
| 41,028 B | 4,690 B, 262 µs | 4,028 B, 94 µs | 4,364 B, 26 µs |
| 164,398 B | 17,104 B, 1,129 µs | 13,314 B, 375 µs | 15,899 B, 97 µs |
| 991,794 B | 99,794 B, 6,985 µs | 75,665 B, 2,377 µs | 65,985 B, 495 µs |
| 3,984,446 B | 397,973 B, 27,866 µs | 300,225 B, 9,422 µs | 203,794 B, 1,819 µs |
| 19,986,580 B | 1,991,571 B, 137,404 µs | 1,501,171 B, 47,139 µs | 422,553 B, 5,936 µs |

- **zstd is 1.8 times faster than libdeflate on a 4 KB answer, 3.6 on 41 KB and 4.8 on a megabyte**, and 4.7, 10 and 14 times faster than `std.flate`. In bytes it is level with libdeflate at 4 to 8 KB (+2.6%, -0.4%), **8% larger at 41 KB and 19% larger at 164 KB** (libdeflate's level 6 finds more in a body that small), 13% smaller at a megabyte and 32% smaller at 4 MB. ADR 295's first draft said zstd was smaller than libdeflate's default; that holds from a megabyte up and not below 164 KB. The tie goes to zstd on time, which is the axis a request pays (ADR 017), not on bytes.
- **The levels `Level` names:** `.fastest` (1) 4.7 µs and 739 B on the 4 KB body against libdeflate's 5.3 µs and 813 B; `.best` (6) 11.6 µs and 688 B against libdeflate's 7, 10.0 µs and 727 B. A megabyte at 6 is 2.4 ms, which is why `.best` is 6 and not higher (ADR 211's `max_bytes` is a time).

**What the pool keeps resident** (sixteen executor threads, 8 KB JSON answered to 128 keep-alive connections, `bench/compress_rss.py`):

| build | pool mapping resident after the load | server Rss, load minus plain load |
|---|---|---|
| `std.flate` gzip (compressors on the heap) | - | 2,416,640 B |
| libdeflate gzip | 3,670,016 B | 5,308,416 B |
| zstd | 2,293,760 B (143 KB a thread) | 3,383,296 B |

The zstd pool maps 1,303,568 bytes a thread (20.9 MB for sixteen) at the default `max_bytes` and level 3 and keeps off huge pages; what is resident is what the bodies touched, 90,112 bytes after a 4 KB body and 892,928 after a megabyte (stage 1). A build with both `-Dlibdeflate` and `-Dzstd` holds both pools.

**Stack below `Ctx.send`'s caller** (`bench-compress-stack`, the whole `Pool.encodeAt` path including the choice and the borrow): ReleaseFast zstd 1,696 to 2,072 B, libdeflate 2,224 to 2,560 B, `std.flate` 7,528 to 7,816 B; Debug zstd 5,864 to 6,640 B, libdeflate 5,928 to 6,704 B, `std.flate` 13,392 to 14,288 B. A zstd response adds no stack a libdeflate one does not.

**Allocations:** `test "a zstd answer costs one allocation too, and it is the compressed body"` holds one allocation and no resize through `handleRequest` with `Accept-Encoding: gzip, deflate, br, zstd`, as the gzip test does.

**The load-time copy of a static file** is `zstd_load_level` (12): stage 1's rows above (1 MB of JSON, 4.8 ms, 39,349 B), a context allocated for the call and freed. Its size by file, from `zig build bench-zstd`: 1,319,952 B for a file up to 64 KB, 13,100,048 B for 1 MB and **50,848,784 B for 8 MB** (the default `max_file_bytes`), allocated for the call and freed before the next file, so it is a transient the process peaks at during `app.static`, once at start and once per file on a `follow` reload thread. **Bounding the window to 2^20 (`window_log`) caps it at 13,100,048 B for any size, and was taken (`zstd_load_window_log`)**: on the 4 MB JSON body it writes 114,779 B in 20.0 ms against 96,237 B in 18.2 ms at the RFC's 2^23, +19% bytes held for the life of the App, and a stylesheet or script bundle loses less. It was first left out on the reading that the held bytes are the cost that stays and the transient the cost that goes; it went in because the transient is paid at every start and every `follow` reload, four times over at the default ceiling, which is the peak a small machine has to plan for.

## The decision it moved

zstd is no longer refused. [ADR 295](../../docs/adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md) designs it for the server, the static files and `nilo_fetch` whole, and builds the module and the flag; the response side, the static files, the request bodies and `nilo_fetch` are wired (stage 2, above, and `fetch.md`). The row in [`docs/decided.md`](../../docs/decided.md) was written on the numbers of `http.md`'s "Which deflate is fastest" (zstd fastest at every size, +386 KB, no encoder in std); what is new is the caller (outpost's agent and server, both nilo programs), the measurement of the decoder (std's is 8 to 37 times slower and needs 8.5 MB), and that the +386 KB is paid only by a program that passes `.zstd = true` and then 123 KB for a decoder alone.

## Can it be pushed further

Yes. A run on a quiet machine would tighten the 5%. The machine-code body shows zstd 1 losing to libdeflate 6 on bytes, and nothing here tries `ZSTD_c_targetCBlockSize` or a trained dictionary for small JSON, which is where zstd is strongest (a dictionary for the 4 KB shapes would shrink them several times, and is the one feature the module does not offer because every context in it is dictionary-free). The stream's context at level 3 is 1 MB for a 2^15 window because the tables are sized by the level and not the window; a smaller `hashLog` would trade ratio for a smaller context, and has not been tried. HttpArena's dataset is not on this machine, so the arena's own `json-comp` bodies were not run; the shapes are the same generator.
