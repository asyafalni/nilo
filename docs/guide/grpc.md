# gRPC

A gRPC method is a route. `app.post("/package.Service/Method", handler)` registers it, the handler reads the message with `c.body()` and answers with `c.send`, and a listener that speaks gRPC turns each call into that request and the answer back into what the client expects. Middleware, fail functions, deadlines, counters and the log see a call as the request it became.

It is for the callers you do not choose: a service whose contract is a `.proto` file, an OpenTelemetry Collector exporting OTLP, a Kubernetes plugin, an Envoy filter. Unary calls only, and it has to be built in ([ADR 0297](../adr/0297-grpc-is-served-over-h2c-behind-a-flag.md)).

## Turning it on

In your `build.zig`, ask the dependency for it:

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .grpc = true });
```

Then give it a listener of its own, beside the one that serves HTTP/1.1:

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

Port 50051 speaks HTTP/2 with prior knowledge (h2c), which is what every gRPC client sends to a plain address. Port 8080 is HTTP/1.1 exactly as before, and a request there to `/demo.Echo/Say` is an ordinary `POST`. A server that should speak nothing but gRPC puts `.grpc = true` on `listen()`'s own options instead.

A build that did not pass `.grpc = true` refuses the listener at `listen()` with a sentence naming the flag, and contains none of the HTTP/2 code: a program that never asks pays 8 to 112 bytes of binary.

## A method

The path is the one in the `.proto`: package, service and method, `/helloworld.Greeter/SayHello`. `c.body()` is the message with gRPC's five-byte prefix taken off, and gunzipped if the client sent `grpc-encoding: gzip`, which the Collector does on every call. `c.send(200, "application/grpc", bytes)` is the answer, framed on the way out.

The codec is yours. [zig-protobuf](https://github.com/Arwalk/zig-protobuf) generates a type for each message with an `encode` and a `decode`, and those are what a method calls on `c.body()` and before `c.send`. nilo reads and writes bytes and never looks inside them.

A call's metadata arrives as request headers, so `c.header("x-tenant")` reads it, and a header the route sets with `c.setHeader` goes back as metadata.

## When a call fails

A route that fails the ordinary way is answered with the gRPC status its HTTP status means, and the failure's message as `grpc-message`:

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

So `return fail.notFound("no order {d}", .{id})` is `NOT_FOUND` with that sentence, and nothing about the handler knows gRPC is involved. A code with no status of its own, `ALREADY_EXISTS` say, is a `grpc-status` header on a 200: `try c.setHeader("grpc-status", "6")`.

A path no route answers is `UNIMPLEMENTED`, and a message larger than `max_body` is `RESOURCE_EXHAUSTED`.

## Deadlines

A client's `grpc-timeout` is the request's deadline, the same one `nilo.deadline(ms)` gives a route ([deadlines](./deploying.md#deadlines)): every wait nilo owns is cut short by it, and `c.overdue()` answers for a loop of your own. A route that fails once the client's time is up is answered `DEADLINE_EXCEEDED` whatever it failed with, because that is what happened as far as the client can tell. `limits.request_deadline_ms` does not lengthen a deadline a call brought; a route's own `nilo.deadline` replaces it.

## Over TLS

A listener with both `.tls` and `.grpc` offers `h2` by ALPN and nothing else, in a build that also passed `.tls = true` ([TLS without a proxy](./deploying.md#tls-without-a-proxy)). A client that offers only `http/1.1` fails the handshake there, and a TLS listener without `.grpc` still offers only `http/1.1`.

## What it does not do

- **Streaming calls.** One message in, one out. A call that sends a second message is answered `INTERNAL`.
- **HTTP/2 for anything but gRPC.** A browser, or `curl --http2` to a plain route, still reaches nilo as HTTP/1.1; a proxy in front is still the answer for HTTP/2 there.
- **Both on one port.** A connection to a gRPC listener that does not open with HTTP/2's preface gets a 505, and an HTTP/1.1 listener refuses the preface as a request line it cannot read.
- **Compressed answers.** A client's gzip is read; the answer goes back uncompressed.

## What it costs

An idle gRPC connection costs under a page more than an HTTP/1.1 one, about 5.8 KB, and the HTTP/1.1 listeners of the same build cost what they did without it. A call in flight is a fiber, 4,547 bytes plus the stack the route touches, and a connection holds at most 100 at once, which it tells the client when it connects. From the second call on a connection, a call allocates nothing on the heap.

On four cores a unary call runs at about 770,000 a second against grpc-go's 590,000 and tonic's 900,000, and the slowest call is slower than either's. The difference is where the call's fiber is scheduled rather than HTTP/2, and it is written up with the rest of the numbers in [`bench/result/http.md`](../../bench/result/http.md#a-grpc-listener-built).
