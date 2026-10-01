# gRPC

**A gRPC method is an ordinary route: a listener that speaks gRPC turns each unary call into a `POST` and the route's answer back into a gRPC response.**

**Reference:** [`listen` options (`grpc`, `also`)](../reference/app.md#listen-options) · **Design:** none; the decision is [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)

`app.post("/package.Service/Method", handler)` registers a method, the handler reads the message with `c.body()` and answers with `c.send`. Middleware, fail functions, deadlines, counters and the log all see a call as the request it became.

It is for callers you do not choose: a service whose contract is a `.proto` file, an OpenTelemetry Collector exporting OTLP, a Kubernetes plugin, an Envoy filter. It supports unary calls only, and it has to be built in ([ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).

## Turning it on

**Build with `.grpc = true` and give gRPC a listener of its own.** In your `build.zig`, ask the dependency for it:

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .grpc = true });
```

Then add a listener next to the one that serves HTTP/1.1:

<!-- compiles -->
```zig
fn serve(app: *nilo.App) !void {
    try app.post("/demo.Echo/Say", say);
    try app.listen(.{
        .port = 8080,
        .also = &.{.{ .port = 50051, .grpc = true }},
    });
}

fn say(c: *nilo.Ctx) !void {
    const message = try c.body();
    try c.send(200, "application/grpc", message.view());
}
```

Port 50051 speaks HTTP/2 with prior knowledge (h2c), which is what every gRPC client sends to a plain address. Port 8080 stays HTTP/1.1 exactly as before, and a request there to `/demo.Echo/Say` is an ordinary `POST`. A server that should speak only gRPC puts `.grpc = true` on `listen()`'s own options instead.

A build that did not pass `.grpc = true` rejects the listener at `listen()` with a message naming the flag, and contains none of the HTTP/2 code: a program that never asks for it pays 8 to 112 bytes of binary.

## Writing a method

**The route path is the one in the `.proto`: package, service and method**, such as `/helloworld.Greeter/SayHello`. `c.body()` is the message with gRPC's five-byte prefix removed, and gunzipped if the client sent `grpc-encoding: gzip`, which the Collector does on every call. `c.send(200, "application/grpc", bytes)` is the answer, framed on the way out.

You bring the codec. [zig-protobuf](https://github.com/Arwalk/zig-protobuf) generates a type for each message with an `encode` and a `decode`, and a method calls those on `c.body()` and before `c.send`. nilo reads and writes bytes and never looks inside them.

A call's metadata arrives as request headers, so `c.header("x-tenant")` reads it, and a header the route sets with `c.setHeader` goes back as metadata.

## Errors and gRPC status codes

**A route that fails the ordinary way is answered with the matching gRPC status**, and the failure's message as `grpc-message`:

| the route failed with | the client sees |
|---|---|
| 400, 415, 422 | `INVALID_ARGUMENT` (3) |
| 401 | `UNAUTHENTICATED` (16) |
| 403 | `PERMISSION_DENIED` (7) |
| 404 | `NOT_FOUND` (5) |
| 409 | `ABORTED` (10) |
| 412, any other 4xx | `FAILED_PRECONDITION` (9) |
| 413, 429 | `RESOURCE_EXHAUSTED` (8) |
| 503 | `UNAVAILABLE` (14) |
| 500 | `INTERNAL` (13) |

So `return fail.notFound("no order {d}", .{id})` becomes `NOT_FOUND` with that message, and the handler does not need to know gRPC is involved. For a code with no HTTP status of its own, such as `ALREADY_EXISTS`, set a `grpc-status` header on a 200: `try c.setHeader("grpc-status", "6")`.

A path no route answers is `UNIMPLEMENTED`, and a message larger than `max_body` is `RESOURCE_EXHAUSTED`. A request whose `content-type` is not `application/grpc` or `application/grpc+` and a subtype (`application/grpc-web` is another protocol) is a 415, and one that is not well-formed HTTP/2 (a pseudo-header twice, unknown or after a regular field, or no `:scheme`) has its stream reset with `PROTOCOL_ERROR`.

## Deadlines

**A client's `grpc-timeout` becomes the request's deadline**, the same one `nilo.deadline(ms)` gives a route ([deadlines](./deploying.md#deadlines)), counted from when the call's headers arrived and not from when its message was whole. Every wait nilo owns is cut short by it, and `c.overdue()` tells a loop of your own when time is up. A route that fails after the client's time is up is answered `DEADLINE_EXCEEDED` whatever it failed with, because that is what happened as far as the client can tell. `limits.request_deadline_ms` does not extend a deadline a call brought with it; a route's own `nilo.deadline` replaces it.

## gRPC over TLS

**A listener with both `.tls` and `.grpc` offers only `h2` by ALPN**, in a build that also passed `.tls = true` ([TLS without a proxy](./deploying.md#tls-without-a-proxy)). A client that offers only `http/1.1` fails the handshake there, and a TLS listener without `.grpc` still offers only `http/1.1`.

## What it does not do

- **Streaming calls.** One message in, one out. A call that sends a second message is answered `INTERNAL`.
- **HTTP/2 for anything but gRPC.** A browser, or `curl --http2` to a plain route, still reaches nilo as HTTP/1.1; for HTTP/2 there, put a proxy in front.
- **gRPC and HTTP/1.1 on one port.** A connection to a gRPC listener that does not open with HTTP/2's preface gets a 505, and an HTTP/1.1 listener rejects the preface as a request line it cannot read.
- **A gzip message beyond what its connection's budget has left.** The inflated copy of a gzip message is held to the room the connection has, which is `max_body` less what the other calls on it hold, and a call over it is answered `UNAVAILABLE`, which an OTLP exporter retries with backoff, with a message saying the budget is full. A call alone on its connection has all of it. **A Collector sending batches of a few MB side by side on one connection gets one at a time at the default budget**, and the rest are retried later rather than sent side by side; set its `sending_queue.num_consumers` to what the budget holds, or raise `max_body` ([the arithmetic](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md#what-the-budget-refuses-an-opentelemetry-collector)).
- **Compressed answers.** A client's gzip is read; the answer goes back uncompressed.

## What it costs

**An idle gRPC connection costs under a page more than an HTTP/1.1 one, about 5.8 KB**, and the HTTP/1.1 listeners of the same build cost what they did without it. A call in flight is a fiber, 4,547 bytes plus the stack the route touches, and a connection holds at most 100 calls at once, which it tells the client when it connects. From the second call on a connection onward, a call allocates nothing on the heap.

On four cores a unary call runs at about 770,000 a second, against grpc-go's 590,000 and tonic's 900,000, and the slowest call is slower than either's. The difference comes from where the call's fiber is scheduled, not from HTTP/2, and it is written up with the rest of the numbers in [`bench/result/http.md`](../../bench/result/http.md#a-grpc-listener-built).
