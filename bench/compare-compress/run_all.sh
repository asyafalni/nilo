#!/bin/bash
# Reproduces every number in bench/result/http.md's codec comparison. Needs: zig 0.16.0 on PATH, git,
# python3, network for the clones, and ~/development/HttpArena for the
# dataset. Clones and builds inside this directory; .gitignore keeps them out.
set -eu
R="$(cd "$(dirname "$0")" && pwd)"
cd $R
[ -d libdeflate ] || git clone --depth 1 https://github.com/ebiggers/libdeflate.git
[ -d zstd ]       || git clone --depth 1 https://github.com/facebook/zstd.git
[ -d brotli ]     || git clone --depth 1 https://github.com/google/brotli.git
[ -d zlib-ng ]    || git clone --depth 1 https://github.com/zlib-ng/zlib-ng.git

python3 gen_bodies.py                       # bodies/*.json
./build_libs.sh                             # build/{gnu,musl}/lib*.a

T="-target x86_64-linux-gnu -mcpu=x86_64_v3+aes+pclmul"
G=build/gnu
LIBS="$G/libdeflate.a $G/libzstd.a $G/libzstddec.a $G/libbrotlienc.a $G/libbrotlidec.a"
zig build-exe harness.zig    -O ReleaseFast $T -lc $LIBS -femit-bin=harness
zig build-exe sweep.zig      -O ReleaseFast $T -lc $LIBS -femit-bin=sweep

# zlib-ng (optional)
mkdir -p bin; printf '#!/bin/sh\nexec zig cc %s "$@"\n' "$T" > bin/zcc; chmod +x bin/zcc
(cd zlib-ng && CC=$R/bin/zcc AR="zig ar" CFLAGS="-O3 -DNDEBUG -fno-sanitize=all" ./configure --static >/dev/null && make -j1 libz-ng.a >/dev/null)
zig cc $T -O3 -DNDEBUG -fno-sanitize=all -Izlib-ng -Ilibdeflate zng_bench.c zlib-ng/libz-ng.a $G/libdeflate.a -o zng_bench

# Timing: one core, thread CPU time, interleaved reps (7 each).
taskset -c 1 ./harness    > run.csv   2>&1
taskset -c 1 ./sweep      > sweep.csv 2>&1
taskset -c 1 ./zng_bench  > zng.csv   2>&1

# Resident memory: the pages each compressor touches, by mincore.
zig build-exe rss.zig        -O ReleaseFast $T -lc $G/libdeflate.a -femit-bin=rss
./rss

# Stack: the deepest byte one compression call writes below its caller.
zig build-exe stack.zig      -O ReleaseFast $T -lc $G/libdeflate.a -femit-bin=stack
./stack

python3 analyze.py run.csv            # per body: median, min, max, spread
python3 score.py sweep.csv zng.csv    # HttpArena json-comp score model

# Binary size: stripped ReleaseFast static musl probes.
size/build_probes.sh
(cd size/libdeflate-nolibc && zig build-exe probe.zig -target x86_64-linux-musl -mcpu=x86_64_v3+aes+pclmul \
    -O ReleaseFast -fstrip $R/build/musl/libdeflate.a -femit-bin=probe && stat -c '%n %s' probe)
