# Benchmarks

The harnesses behind every number in [`result/`](./result/). How to measure without fooling yourself is in [`docs/history.md`](../docs/history.md#measuring); what a finished run owes is in [`CLAUDE.md`](../CLAUDE.md#a-benchmark-that-was-run-gets-written-down). `zig build --help` lists every step, including the ones below.

## Where a result goes

One file an area, each carrying what was run, the machine, the commit, the numbers, the decision they moved, and whether the number can be pushed further:

| file | area |
|---|---|
| [`http.md`](./result/http.md) | the server |
| [`sql.md`](./result/sql.md) | the database |
| [`fetch.md`](./result/fetch.md) | the way out |
| [`s3.md`](./result/s3.md) | the object store |
| [`cache.md`](./result/cache.md) | the cache |
| [`job.md`](./result/job.md) | the queue |
| [`build.md`](./result/build.md) | waiting on the build itself |

[`RESULTS.md`](./RESULTS.md) holds the older binary-size runs.

## The primary metric

```
zig build run -Doptimize=ReleaseFast   # the benchmark server (bench/main.zig): GET /users/:id, ~1 KB JSON
./bench/bench.sh       # wrk/oha against it, already running; `zig build run` alone is a Debug build
zig build profile      # where the time inside one request goes, in-process
zig build profile -- --routes <file>   # and matching on a real route table, `METHOD /pattern` a line
```

## Microbenchmarks

```
zig build bench-cache          # what a cache operation costs, and what an entry weighs
zig build bench-cache-hitrate  # what fraction of lookups it answers, against the best it could
zig build bench-compress       # what gzipping a JSON answer costs at each level, in µs and bytes
zig build bench-sql            # what a prepared statement is worth: SQLite always, Postgres if reachable
zig build bench-job            # what a claim and a push cost on job.Memory, SQLite, and Postgres if reachable
```

## Servers for a load generator

Each carries control routes beside the one being measured, so a figure has something standing next to it.

```
zig build bench-sql-server     # every request reads Postgres
zig build bench-fetch-server   # every request calls out
zig build bench-s3-server      # every request reads an object store
zig build bench-body-server    # every request reads a body
zig build bench-ws-server      # idle WebSockets, for what one costs
zig build bench-stream-server  # held-open streams, for what one costs
zig build bench-tls-server -Dtls   # the benchmark server over TLS; absent without the flag
zig build bench-echo-server -Dtls  # a 10 KB body echoed over TLS and in plain
zig build autobahn-server      # the echo server `bash bench/autobahn/run.sh` drives wstest at
```

## Scripts

```
python3 bench/mem.py --port … --path …          # memory per idle connection, any server
python3 bench/mem.py --port … --path … --hold   # the same for a stream nobody closes
python3 bench/mem.py --port … --path … --tls    # the same through TLS 1.3, against bench-tls-server
python3 bench/slowloris.py --port … --path …    # what a body that never finishes holds (VmData, not just VmRSS)
python3 bench/ws_idle.py both                   # memory per idle WebSocket, nilo and gws
python3 bench/paced.py --pid … --port … --rate …  # µs of CPU a request at a fixed rate: a server that is not busy (ADR 199)
python3 bench/shutdown.py --cmd … --port …      # does SIGTERM come back? (ADR 077)
python3 bench/fdlimit.py --cmd … --port …       # does a descriptor shortage take the server down? (ADR 194)
python3 bench/burst.py --cmd … --port …         # does a burst of connections get through? (ADR 198)
python3 bench/devloop.py --step dev-spa         # does a save the build never reads restart the server? It must not (ADR 190)
python3 bench/s3_setup.py                       # the bucket and objects the S3 server wants
python3 bench/compare-s3/drive.py               # nilo_s3 against Go, Rust and Bun; needs MinIO
bash bench/compare-cache/run.sh                 # nilo_cache against go-cache; needs Go
```
