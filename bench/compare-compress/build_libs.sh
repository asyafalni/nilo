#!/bin/bash
# Builds the C encoders (and, separately, their decoders, used only to check
# round trips) as static archives with zig cc. Same CPU as nilo's HttpArena
# image (x86_64_v3+aes+pclmul), -O3 -DNDEBUG (what CMake Release passes).
#   build/gnu/   x86_64-linux-gnu, linked by the timing harness
#   build/musl/  x86_64-linux-musl, linked by the static size probes
set -eu
R="$(cd "$(dirname "$0")" && pwd)"
lib() { # name, include flags, files...
  name=$1; shift; inc=$1; shift
  mkdir -p $B/$name; rm -f $B/$name/*.o
  for f in "$@"; do
    zig cc $CF $inc -c $f -o $B/$name/$(echo $f | tr '/' '_').o &
  done
  wait
  for f in "$@"; do [ -s $B/$name/$(echo $f | tr '/' '_').o ] || { echo "lib$name FAILED on $f"; exit 1; }; done
  rm -f $B/lib$name.a; zig ar rcs $B/lib$name.a $B/$name/*.o
  echo "built $B/lib$name.a"
}
for abi in gnu musl; do
  B=$R/build/$abi; mkdir -p $B
  CF="-target x86_64-linux-$abi -mcpu=x86_64_v3+aes+pclmul -O3 -DNDEBUG -fno-sanitize=all -ffunction-sections -fdata-sections"
  cd $R/libdeflate && lib deflate "-I. -mevex512" lib/*.c lib/x86/*.c
  cd $R/zstd/lib && lib zstd "-I. -Icommon" common/*.c compress/*.c
  cd $R/zstd/lib && lib zstddec "-I. -Icommon -DZSTD_DISABLE_ASM" decompress/*.c
  cd $R/brotli/c && lib brotlienc "-Iinclude" common/*.c enc/*.c
  cd $R/brotli/c && lib brotlidec "-Iinclude" dec/*.c
done
