#!/bin/bash
# Stripped ReleaseFast static musl probes, the arena image's target and CPU.
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
cd $R/size
M=$R/build/musl
T="-target x86_64-linux-musl -mcpu=x86_64_v3+aes+pclmul -O ReleaseFast -fstrip"
mk() { # outname codec libc libs...
  name=$1; codec=$2; libc=$3; shift 3
  mkdir -p $name
  echo "pub const codec: enum { base, std_flate, libdeflate, zstd, brotli, libdeflate_brotli } = .$codec;" > $name/codec.zig
  cp probe.zig $name/probe.zig
  (cd $name && zig build-exe probe.zig $T $libc "$@" -femit-bin=probe >/dev/null)
  printf '%-22s %9d\n' $name $(stat -c %s $name/probe)
}
mk base-nolibc base ""
mk base-libc base -lc
mk stdflate-nolibc std_flate ""
mk stdflate-libc std_flate -lc
mk libdeflate libdeflate -lc $M/libdeflate.a
mk zstd zstd -lc $M/libzstd.a
mk brotli brotli -lc $M/libbrotlienc.a
mk libdeflate+brotli libdeflate_brotli -lc $M/libdeflate.a $M/libbrotlienc.a
