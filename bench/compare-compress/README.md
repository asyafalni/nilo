# nilo's gzip against libdeflate, zlib-ng, zstd and brotli

The numbers and what they moved are in
[`bench/result/http.md`](../result/http.md#which-deflate-is-fastest-and-whether-brotli-or-zstd-would-beat-it).
This file says what is held equal.

## Run it

```
./run_all.sh
```

Needs Zig 0.16.0, git, python3, the network for four clones, and a checkout of
HttpArena at `~/development/HttpArena` for `data/dataset.json`. Everything is
cloned and built inside this directory, and `.gitignore` keeps it out of the
repository.

## What is held equal

- **The same bodies on every side.** `gen_bodies.py` writes `bench-N`, which is
  `bench/compress_bench.zig`'s body byte for byte, and `arena-N`, which is the
  arena's `json-comp` body built from its dataset the way the profile asks.
- **nilo's side is nilo's code.** `harness.zig` carries `Pool.gzip` and `reset`
  as they are in `http/compress.zig`, and its output matches
  `zig build bench-compress` byte for byte.
- **The same CPU flags.** The C libraries are built with `zig cc -O3 -DNDEBUG`
  for `x86_64_v3+aes+pclmul`, which is what nilo's HttpArena image targets.
- **Every output is checked** by decompressing it with the codec's reference
  decoder.
- **Thread CPU time, interleaved, pinned.** `CLOCK_THREAD_CPUTIME_ID` on one
  core under `taskset -c 1`, codecs taking turns, seven repetitions a run. On a
  busy machine this leaves out the time a thread waits for a core. Wall-clock
  time is what the server pays, and on a quiet machine the two agree.

## What cannot be held equal

- **brotli cannot be reset.** Every body creates and destroys an encoder, which
  is what using it would cost, so that cost is counted on purpose.
- **zstd's context grows** to the largest body it has seen, so its memory
  figure depends on the order the bodies came in.
- **The size probes are static musl programs**, `size/build_probes.sh`, and
  measure what a codec adds to a program that already has an allocator, not to
  a nilo server.
