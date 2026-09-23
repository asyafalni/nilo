# 0293 — a handshake's signature is computed off the executor

**Status:** accepted
**Applies:** [ADR 0288](./0288-tls-is-an-option-a-build-asks-for.md) (TLS is an option a build asks for), [ADR 0048](./0048-a-password-hash-is-gated-because-forgetting-is-silent.md) (a password hash runs on the blocking pool for the same reason).
**Found by:** HttpArena's `8gbit` column: a p50 of 101 µs, a p99 of 169 µs and a mean of 267 µs, against a field whose best mean is 81.5 µs. The mean was the tail: p99.9 at 46 to 68 ms, in a five-second run with 512 connections that are opened once.

## Context

A TLS 1.3 server handshake signs the transcript with the certificate's key. For the arena's RSA-2048 key that is 2.6 ms on the machine in `bench/result/` since the CRT change, and more on the arena's slower cores. Everything else in a handshake is tens of microseconds. The signature ran on the executor that accepted the connection, so every connection that executor serves waited behind it.

A burst of new connections is a burst of signatures. The paced client the arena uses, zrk, anchors each connection's schedule at its first request, after its own handshake, so a connection's handshake is never in its own latency. What is in it is the requests of the connections already open on the same executor, waiting behind everybody else's signature, timed from when they were due.

Two controls on this box said so before anything was changed, the arena's entry at 512 connections and 50K requests a second on 4 cores:

| run | mean | p99 | p99.9 |
|---|---|---|---|
| RSA-2048, 5 s | 942 to 1,135 µs | 35 to 45 ms | 72 to 95 ms |
| RSA-2048, 20 s | 289 µs | 132 µs | 56 ms |
| ECDSA P-256, 5 s | 234 to 248 µs | 172 to 377 µs | 35 to 38 ms |
| no TLS, 5 s | 62 to 89 µs | 52 to 325 µs | 10 to 16 ms |

The excess over the mean, summed over the requests, is the same at 5 s and at 20 s: a fixed cost at the start, not a rate. And a key that signs nine times faster takes most of it away.

## Decision

**The signature runs on the Engine's blocking pool, with the connection's fiber parked until it is done.** The rest of the handshake stays on the executor.

tls.zig had no seam for it. The fork nilo already pins, `nevindra/tls.zig`, gains a server option, `offload`, which is a function that runs a job and returns once it has finished. tls.zig does not learn about threads, and a caller that leaves it null gets the handshake it had. The Engine passes `zio.blockInPlace` behind it.

The randomness RSA-PSS needs for its salt is drawn before the hop, on the fiber, and the job signs with a CSPRNG seeded from it. The `std.Random` the handshake is given reads through the connection's `Io`, and the job may run on a thread that has none. ECDSA and Ed25519 sign deterministically here and draw nothing.

## What was rejected

**A faster RSA.** The 2.6 ms is `std.crypto.ff`'s constant-time exponentiation, several times OpenSSL's, and a fixed-width Montgomery ladder for 1024-bit primes is the lever under it. It would cut the CPU a handshake costs, which this does not. It is also constant-time arithmetic written by hand for a benchmark column, and the tail it would remove is removed here without it. It stays open in `bench/result/http.md`.

**Running the whole handshake on the pool.** The handshake reads and writes the socket, and the socket's waits belong to the executor. Only the signature is CPU with nothing to wait on.

**Waiting for upstream.** The roadmap carried this as waiting on a hook in tls.zig that nobody had asked for. nilo pins its own fork of tls.zig, so it was waiting on nobody.

## What it costs

`21890c6` plus ADR 0292, against the same plus this, the arena's own entry built from each, interleaved:

| axis | before | after |
|---|---|---|
| `8gbit` shape, 5 s: mean | 960 to 1,123 µs | **133 to 179 µs** |
| the same: p99 | 31 to 45 ms | **311 to 546 µs** |
| the same: p99.9 | 75 to 92 ms | 29 to 42 ms |
| the same: CPU per request | 24.1 to 24.9 µs | 23.9 to 24.5 µs, unchanged |
| `json-tls` shape, 4,096 connections: requests a second | 238K to 247K | 232K to 245K, unchanged |
| the same: mean latency | 31.5 to 34.4 ms | 13.7 to 13.9 ms |
| Memory per idle TLS connection, marginal from 2,000 to 5,000 | 9,280 B | 9,280 B, unchanged |
| The same, flat | | about 290 KB more, whatever the count; the pool's threads starting on the first handshake would account for it, and that was not checked |
| Allocations per request | 1 | 1, the handshake is not a request |
| Binary size, stripped `ReleaseFast`, `bench-tls-server -Dtls` | 1,606,608 B | 1,608,048 B, +1,440 |
| Binary size, a build without `-Dtls` | | byte-identical |

The p99.9 that is left is the start of the run. The same shape in cleartext shows 10 to 16 ms of it, so about half is the burst of new connections whatever they speak, and the rest is the handshake work still on the executor.

## Consequences

- The pin moves to the fork's commit with the option, and the fork is now two commits past upstream rather than one. Both are worth offering upstream. The roadmap's row for the CRT change is the place that says so.
- A handshake costs two wakeups more than it did, the hop to the pool and back. At 2.6 ms of signature that is not a number worth printing, and for an ECDSA key it is still the executor kept free.
