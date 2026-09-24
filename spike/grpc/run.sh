#!/usr/bin/env bash
# What does a real gRPC client put on the wire, and what does it do when the
# server asks it for less? ADR 0297 needed both before it could say what a
# gRPC connection would cost nilo, and neither is written down anywhere a
# reader can trust: the RFC says what a client *may* do, not what grpc-go,
# grpc-js, grpcio and tonic *do*.
#
# probe/ is a gRPC server written at the frame level. It answers every unary
# call with an empty message and grpc-status 0 after a fixed 20 ms, so calls
# overlap, and writes one JSON report per connection. Each client makes 32
# calls, 16 at a time, on one channel, three ways:
#
#   t4096  the default HPACK table, to see what a client would put in it
#   t0     SETTINGS_HEADER_TABLE_SIZE=0, to see whether it stops
#   max1   SETTINGS_MAX_CONCURRENT_STREAMS=1, to see whether it queues,
#          opens a second connection, or fails
#
# The OpenTelemetry Collector runs with its default otlp exporter (grpc-go
# underneath, but with its own compression, deadline and concurrency), fed
# twenty traces over OTLP/HTTP. Needs Docker.
#
# Against nilo rather than the probe: build server/ and start it from the
# repository root (its TLS listener reads the suite's test certificate), then
# run a client command from cmd_for below by hand. It answers on the probe's
# port, 50051. throughput.sh is the throughput half, against grpc-go and tonic.
#
# Usage: ./run.sh [go|js|py|rs|otel ...]   (default: all five)

set -u
cd "$(dirname "$0")"
clients="${*:-go js py rs otel}"

go build -o bin/probe ./probe && go build -o bin/goclient ./clients/go || exit 1

cmd_for() {
  case $1 in
    go) echo "./bin/goclient -n 32 -c 16" ;;
    js) (cd clients/js && [ -d node_modules ] || npm install --silent >/dev/null) && echo "node clients/js/client.mjs" ;;
    py) echo "uv run -q --no-project --with grpcio==1.84.0 python clients/py/client.py" ;;
    rs) (cd clients/rs && cargo build --release -q) && echo "clients/rs/target/release/rsclient" ;;
  esac
}

probe() {  # probe TAG FLAGS... -- then runs "$client" against it
  local tag=$1; shift
  rm -f "r-$tag.jsonl"
  ./bin/probe -out "r-$tag.jsonl" "$@" >/dev/null 2>&1 & local p=$!
  sleep 0.4
  eval "$client" 2>&1 | tail -1
  sleep 0.5; kill "$p"; wait "$p" 2>/dev/null
  echo "== $tag"; python3 summary.py "r-$tag.jsonl"
}

otel() {
  local tag=$1; shift
  rm -f "r-$tag.jsonl"
  ./bin/probe -out "r-$tag.jsonl" "$@" >/dev/null 2>&1 & local p=$!
  docker run -d --rm --name nilo-grpc-spike --network host \
    -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml:ro" otel/opentelemetry-collector:0.161.0 >/dev/null
  sleep 3
  local span='{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"spike"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"x","kind":2,"startTimeUnixNano":"1","endTimeUnixNano":"2"}]}]}]}'
  local pids=()
  for _ in $(seq 20); do
    curl -s -o /dev/null -X POST -H 'content-type: application/json' http://127.0.0.1:14318/v1/traces -d "$span" & pids+=($!)
  done
  wait "${pids[@]}"
  sleep 3
  docker stop nilo-grpc-spike >/dev/null
  sleep 0.5; kill "$p"; wait "$p" 2>/dev/null
  echo "== $tag"; python3 summary.py "r-$tag.jsonl"
}

for c in $clients; do
  if [ "$c" = otel ]; then
    otel otel-t0 -table 0
    otel otel-t4096 -table 4096
    continue
  fi
  client=$(cmd_for "$c") || exit 1
  probe "$c-t4096" -table 4096
  probe "$c-t0" -table 0
  probe "$c-max1" -table 4096 -max-streams 1
done
