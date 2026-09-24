#!/usr/bin/env bash
# Unary gRPC throughput, nilo against grpc-go and tonic, the way HttpArena's
# `unary-grpc` profile drives it: h2load POSTing a 9-byte SumRequest to
# /benchmark.BenchmarkService/GetSum, 100 streams a connection, 5 seconds.
#
# The two controls are HttpArena's own entries (frameworks/grpc-go and
# frameworks/tonic-grpc at the commit in $ARENA), built as its Dockerfiles
# build them, and h2load is its docker/h2load.Dockerfile. Server and load
# generator are pinned to separate physical cores of a Ryzen 9700X: the server
# to cores 0-3 (CPUs 0-3,8-11), h2load to cores 4-7 (CPUs 4-7,12-15).
# Interleaved, every server once per round.
#
# Needs: docker, the images tagged arena-h2load, arena-grpc-go, arena-tonic,
# and server/ built with -Doptimize=ReleaseFast.
#
# Usage: ./throughput.sh [rounds] [connections...]   (default: 2 rounds, 256 1024)

set -u
cd "$(dirname "$0")"
rounds=${1:-2}
shift || true
conns="${*:-256 1024}"
server_cpus=0-3,8-11
load_cpus=4-7,12-15
req=$(mktemp)
python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex("00000000040801" "1002"))' > "$req"

start() {  # start NAME -> prints the port it answers gRPC on
  case $1 in
    nilo)
      # From the repository root, where its TLS listener finds the test certificate.
      (cd ../.. && NILO_THREADS=8 exec taskset -c $server_cpus spike/grpc/server/zig-out/bin/nilo-grpc) >/dev/null 2>&1 &
      echo 50051 ;;
    grpc-go|tonic)
      docker run -d --rm --name "tp-$1" --network host --cpuset-cpus $server_cpus "arena-$1" >/dev/null
      echo 8080 ;;
  esac
}

stop() {
  case $1 in
    nilo) pkill -x nilo-grpc; while pgrep -x nilo-grpc >/dev/null; do sleep 0.2; done ;;
    *) docker stop "tp-$1" >/dev/null ;;
  esac
  sleep 1
}

# A server left over from an earlier run would answer in place of this build.
if pgrep -x nilo-grpc >/dev/null; then echo "nilo-grpc is already running; stop it first" >&2; exit 1; fi

for round in $(seq "$rounds"); do
  for c in $conns; do
    for server in nilo grpc-go tonic; do
      port=$(start $server)
      sleep 2
      out=$(docker run --rm --network host --cpuset-cpus $load_cpus -v "$req:/req.bin:ro" arena-h2load \
        "http://127.0.0.1:$port/benchmark.BenchmarkService/GetSum" -d /req.bin \
        -H 'content-type: application/grpc' -H 'te: trailers' \
        -c "$c" -m 100 -t 8 -D 5 2>&1)
      rps=$(echo "$out" | awk '/^finished in/ {print $4}')
      ok=$(echo "$out" | awk '/^requests:/ {print $8, "ok,", $10, "errored"}')
      lat=$(echo "$out" | awk '/^time for request:/ {print "mean", $6, "max", $5}')
      printf "round %s  c=%-5s %-8s %12s req/s   %s   %s\n" "$round" "$c" "$server" "$rps" "$ok" "$lat"
      stop $server
    done
  done
done
rm -f "$req"
