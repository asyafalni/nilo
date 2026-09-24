# gRPC is served over h2c, behind a flag, and HTTP/2 is built only as far as gRPC needs it

**Status:** accepted
**Amends:** [ADR 0028](./0028-tls-is-terminated-in-front.md) (its consequence "HTTP/2 goes with it", for gRPC only)
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md) (what a feature spends, and the number), [ADR 0063](./0063-a-handlers-stack-is-per-connection.md) (a handler's stack is the connection's), [ADR 0075](./0075-a-lazy-dependency-is-a-request.md) and [ADR 0288](./0288-tls-is-an-option-a-build-asks-for.md) (a feature a build asks for, and the default build never hears of), [ADR 0289](./0289-a-server-answers-on-more-than-one-address.md) (more than one listener), [ADR 0133](./0133-a-route-can-say-how-long-it-has.md) (a request's deadline)

## Context

ADR 0028 refused HTTP/2 and gRPC as a consequence of refusing TLS: browsers speak HTTP/2 only over TLS, negotiated by ALPN, so "no handshake, no ALPN, no HTTP/2, and no gRPC server either, since gRPC is HTTP/2". ADR 0288 later let TLS in behind `-Dtls` and said "HTTP/2 does not follow".

**For browsers the derivation still holds, and for gRPC it never did.** gRPC runs over h2c, HTTP/2 in plaintext with prior knowledge, which needs no TLS and no ALPN. That is how it is usually deployed inside a cluster, a mesh, or behind a load balancer that terminates TLS. And the answer ADR 0028 gives everything else, a proxy in front, does not reach it: a proxy turns a browser's HTTP/2 into HTTP/1.1 for nothing, but it cannot turn a gRPC call into a request nilo can serve without transcoding against the service's own schema.

**The callers are real and are not ones a nilo user gets to choose.** A service in an organisation whose contract between services is a `.proto` file. A receiver for OTLP, which the OpenTelemetry Collector sends as gRPC by default. A Kubernetes plugin (CSI, CRI, a device plugin), which is gRPC and nothing else. An Envoy external filter (`ext_authz`, `ext_proc`). In each of those the client is somebody else's library, and it speaks HTTP/2.

**What was looked at and does not serve:**

- **Connect and gRPC-Web** run over HTTP/1.1 and would cost the connection nothing. They do not reach a client nilo's user does not own: grpc-go, grpc-js, grpcio, tonic and the Collector all speak HTTP/2 only, and none falls back.
- **A Zig gRPC library.** `ziglana/gRPC-zig` at `ab34a77` was read. Its HPACK has no static table, no Huffman and one-byte lengths; its frames are written little-endian and read big-endian; it has no flow control and routes every call to the first handler. It is a sketch rather than a dependency.
- **A codec of nilo's own.** [`Arwalk/zig-protobuf`](https://github.com/Arwalk/zig-protobuf) implements proto3, runs Google's conformance suite, and generates service interfaces while stating that it "does not include a gRPC transport layer". The codec is solved and is the caller's to bring. The transport is what nobody had built.

**The constraint is ADR 0018's two hard rows**, and it is the one ADR 0288 met: a build that does not ask for gRPC may not move either of them by a byte, and a build that does states what it pays before it ships.

## What was measured before a line was written

In [`bench/result/http.md`](../../bench/result/http.md#what-a-grpc-client-puts-on-the-wire-and-what-a-stream-would-cost), taken with `spike/grpc/` against grpc-go 1.84.0, grpc-js 1.14.5, grpcio 1.84.0, tonic 0.14.6 and the Collector 0.161.0 at its defaults.

**The HPACK table can be zero, and every client measured agrees.** At the default 4,096 bytes a server's decoder keeps what the client inserts, 213 to 420 bytes for a library called by hand, and for the Collector a table that fills: it indexes `grpc-timeout`, a fresh value every call. With `SETTINGS_HEADER_TABLE_SIZE = 0`, all five sent a size update of 0 and kept nothing resident. The price is about 110 bytes more per call inbound and a Huffman decode of every header, which is CPU on the request path and not memory on the idle one.

**A stream is a fiber, and a fiber is 4,547 bytes plus the stack it touched.** That is what a request in flight on HTTP/1.1 already costs, so the idle figure does not grow with the streams a connection has served. What grows is the worst case of one connection: the cap times that figure, about 1.7 MB at 100 streams of ADR 0063's database route.

**A cap is honoured by queueing, and is not a guarantee.** At a cap of 1 all four libraries queued on the connection, opened no second one and failed no call. tonic, in some runs, sent requests before it had read the server's SETTINGS.

## Decision

**A listener may speak gRPC, over h2c or over TLS with ALPN `h2`, in a build that asked for it, and the default build contains none of it.**

- **A flag, the way TLS is.** A dependent passes `.grpc = true` to `b.dependency("nilo", …)`; in this repository it is `-Dgrpc`. The Engine names the gRPC connection loop only under a comptime `if` on `@import("nilo_build").grpc`, so a build without it links no HTTP/2 code, and a listener that asks for it there is refused at `listen()` with `error.GrpcNotBuilt` and a sentence saying which flag.
- **A listener of its own, not a protocol negotiated per connection.** `.grpc = true` on an `Options.also` entry, or on `Options` itself for a server that speaks nothing else. Every other listener is HTTP/1.1 exactly as before. With `.tls` on the same listener it offers `h2` in ALPN and nothing else, so a client that offers only `http/1.1` fails the handshake rather than reaching a connection that cannot read it; a TLS listener without `.grpc` still offers only `http/1.1`.
- **A method is a route.** `app.post("/package.Service/Method", handler)` registers it, and the handler is an ordinary one: `c.body()` is the message, unframed and inflated, and `c.send(200, "application/grpc", bytes)` is the answer. The connection turns each call into an in-memory HTTP/1.1 `POST` and hands it to `App.handleRequest`, then turns what came back into frames: a 200 is HEADERS, one length-prefixed message and `grpc-status: 0` in the trailers; any other status is a Trailers-Only answer whose code follows the status (404 is `NOT_FOUND`, 401 `UNAUTHENTICATED`, 503 `UNAVAILABLE`, and so on) and whose `grpc-message` is the `error` of nilo's own failure body. The call's metadata arrives as request headers and a route's own headers go back as metadata. Middleware, fail functions, deadlines, counters and the logger see a gRPC call as the request it became, and nothing among them had to learn a word of HTTP/2.
- **HTTP/2 is built only as far as gRPC needs it.** Frames, HPACK decoding with a table advertised at 0 and an encoder that never indexes, stream states, both flow-control windows, trailers, `RST_STREAM`, `GOAWAY` and `PING`, and `SETTINGS_MAX_CONCURRENT_STREAMS` stated at 100. Not server push, not priorities, not extended CONNECT, not h2c upgrade from HTTP/1.1, and not HTTP/2 for ordinary routes.
- **Unary calls only.** A call carries exactly one message; one with none or two is answered `INTERNAL` with a sentence saying so. Streaming waits for a caller, because a stream held open is the one shape that costs a fiber for its whole life, and every caller above is unary.
- **`grpc-timeout` is the request's deadline** (ADR 0133), carried into `App.handleRequest` rather than read by the route. `Options.limits.request_deadline_ms` no longer replaces a deadline the request already brought when that one is earlier (`Ctx.giveDefaultDeadline`); a route's own `nilo.deadline` still replaces it, as it replaces the default, because a route that names a number has said what it needs. A route that fails once the client's deadline has passed is answered `DEADLINE_EXCEEDED`, whatever status it failed with, unless it set `grpc-status` itself. More than eight digits, or a unit that is not one of `HMSmun`, is `INVALID_ARGUMENT`.
- **`grpc-encoding: gzip` is read**, because the Collector sends it on every call by default. Answers go uncompressed.
- **A hostile client is a test, not a hope.** Rapid reset (CVE-2023-44487) is held by a reset call counting against the cap until its route returns, and the connection sent away past 1,000 refused streams; a CONTINUATION flood by a cap of 64 KiB on one header block; an HPACK header list bomb by counting the list as it decodes and answering `RESOURCE_EXHAUSTED` past 16 KiB; SETTINGS and PING floods by 1,000 control frames in a row with no call between them; a zero window held open by the write deadline. Each is a test that the client doing it is cut off; the rapid reset and zero window tests were seen to fail with their guard loosened, and the ALPN test with the server offering `http/1.1`. `zig build fuzz -- --frames` throws generated connections at the listener, and `zig build test` replays its corpus.

## What was built differently from the proposal, and why

**The proposal had the Engine hand each stream a Reader and a Writer, and a gRPC method be a typed function reading its body through a door (`nilo_read`) that did not exist yet.** Both lost to translation once it was measured. Turning a call into HTTP/1.1 text and back costs 229 ns of a 973 ns call in process (`zig build profile`), which is the whole App's share, parsing included. In exchange nothing under `http/` other than the connection loop knows HTTP/2 exists, the App's core did not grow (`grpc.zig` sits outside `http_core` and reaches the App through `grpc.Host`, four function pointers the App fills in), and every route feature works on a gRPC call on the first day. The typed door stays [the roadmap entry it was](../roadmap.md#next); a zig-protobuf type decodes `c.body()` meanwhile, which is one line.

**The proposal's question 5 was whether the only stream open could run on the connection's own fiber, the way an HTTP/1.1 request does.** It cannot, for a reason no benchmark shows: a gRPC client puts every call on one connection, so a call run inline holds every other call, and the connection's own PINGs and window updates, behind it. The live test "two calls at once, the quick one is not held behind the slow one" is what holds it. The price is measured below, and the part of it that is not the fiber is in zio.

## What it costs

Measured on a Ryzen 7 9700X, Linux 7.2.5, Zig 0.16.0, zio v0.18.0; the runs are in [`bench/result/http.md`](../../bench/result/http.md#a-grpc-listener-built).

| axis | default build | a `-Dgrpc` build, HTTP/1.1 listener | a gRPC connection |
|---|---|---|---|
| memory per idle connection | nothing: 5,183 B marginal before and after | nothing: 5,183 B | 5,685 to 5,917 B, converged at 10,000 connections, against 5,322 for HTTP/1.1 on the same binary: under a page more |
| memory per call in flight | n/a | n/a | a fiber, 4,547 B plus the stack the route touched; the cap of 100 times that is one connection's worst case |
| allocations per call | nothing | nothing | 0 from the second call on a connection: a finished call's stream and 4 KiB of its arena are kept for the next. The first call on a connection allocates its stream |
| binary size, stripped `ReleaseFast` | +8 B hello, +112 B rest | +115,720 B hello, +52,432 B rest | the same |
| throughput, unary, h2load `-m 100`, four cores | nothing | nothing | 769k to 774k calls/s at 256 connections, against grpc-go's 589k to 591k and tonic's 902k; 556k to 567k at 1,024, against 578k to 583k and 851k to 856k |
| latency, same runs | nothing | nothing | mean 28 ms at 256 (tonic 27 ms, grpc-go 43 ms), 111 to 113 ms at 1,024 (97 ms, 159 to 163 ms). The worst call was the slowest of the three: 1.4 s at 256, 3.8 s at 1,024, against about 1.1 s for tonic |

h2load reports mean and maximum and no percentiles, so p99 is not on the record; the maximum is quoted because it is the one that is bad.

**The throughput gap is the scheduler, not the protocol.** Run inline on the connection's fiber, which the paragraph above refuses, the same build does 3.12M calls/s at 256 connections and 2.95M at 1,024, at 2.5 µs of CPU a call; with a fiber per call it is 4.4 to 4.7 µs and 0.87 to 0.95 context switches a call. On one executor the fiber costs 2.74 µs against 2.51 inline, so creating it is 0.23 µs. The rest is where zio puts it: every `spawn` is dealt round-robin to another executor (`getNextExecutor`) and that executor woken, so nearly every call crosses a thread twice. A spawn homed on the calling executor is proposed upstream as `Placement.here` in [zio#704](https://github.com/lalinsky/zio/issues/704), and it is the one lever that would close most of the gap; `docs/roadmap.md` carries it under Waiting on upstream.

## Consequences

- **ADR 0028's reasoning is narrowed rather than reversed.** HTTP/2 for browsers and for ordinary routes is still refused, and a proxy is still the answer. What moved is gRPC, because the premise that it needs TLS was never true.
- **One port cannot speak both.** HttpArena's gRPC and h2c profiles put HTTP/1.1 and h2c on one port, or want HTTP/2 for plain GET routes, so nilo enters none of them; that is the listener-of-its-own decision above, kept.
- **The Collector's gzip found a bug that was not gRPC's.** A deflate stream ending in an empty final block, which Go's writer produces on a flush and close, made `encoded.inflate` refuse a body exactly the size it announced. It was as true of an HTTP/1.1 body with `Content-Encoding: gzip`, and is fixed for both.
- **The frame fuzzer found one on its first run.** DATA on a stream already answered or reset drew an `RST_STREAM` every time, which RFC 9113 §5.1 says to ignore and which let a client make the server write a frame for every frame it sent, uncounted. It is ignored now, and the input is in the corpus.
- **The cap is nilo's number, stated, not a library's.** 100 makes a connection's worst case about 1.7 MB on a database route.
- **This is reversible the way ADR 0288 is.** The flag off is the build that existed before.
