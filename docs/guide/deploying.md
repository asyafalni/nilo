# Deploying

## When it won't start

Everything that can stop a server before the socket opens says so in one line, in
words, with the fix in it:

```
error: port 8787 is already in use — something else is listening on 127.0.0.1:8787.
Stop it, or pass `.port = …` to listen() with a free one.

error: service *main.Db was never registered, but 4 routes need it
("/users", "/users/:id", "/admin/stats", …) — call app.provide() before app.listen()

error: nilo: static directory "public" could not be opened (FileNotFound) —
the path is relative to the working directory the server runs in

warning: std.log will block the event loop. Add to your root source file:
pub const std_options_debug_io = nilo.debug_io;

warning: nilo was built in Debug and this program in ReleaseSafe, which is legal
and slow. Pass the mode through: b.dependency("nilo", .{ .target = target,
.optimize = optimize }) — in the test step too, which is the one that usually
gets missed.
```

That line is the whole answer, so it is also the last thing on the screen:
`listen()` stops the process there rather than returning an error, which would
print a stack trace through nilo's own files on top of it. Which file inside the
engine noticed the port was taken is not your problem.

If you would rather handle it — a test, or a program that falls back to another
port — `tryListen()`, `tryRoute()` and `tryStatic()` are the same calls with the
error coming back as a value.

## Tuning

`listen()` takes the knobs that change how the server uses the machine:

```zig
try app.listen(.{
    .address = "0.0.0.0",     // IPv4 or IPv6 — "::" for every interface
    .port = 8080,
    .threads = 0,             // 0 = one per core
    .read_buffer = 16 * 1024, // also the ceiling on a request head (431 past it)
    .write_buffer = 4 * 1024,
    .reuse_address = true,
    .backlog = 4096,          // handshakes the kernel queues for accept; past it a SYN waits a second
    .shutdown_grace_ms = 10_000,
    .stop_on_signal = true,   // off if your program handles signals itself

    .header_timeout_ms = 10_000,  // first byte of a head to the blank line
    .idle_timeout_ms = 75_000,    // a connection between requests
    .body_timeout_ms = 30_000,    // any one read of a body
    .body_min_rate = 8 * 1024,    // bytes a second a body has to keep up
    .body_grace_ms = 10_000,      // before that rate is asked for
    .write_timeout_ms = 30_000,   // any one write to the client
    .request_deadline_ms = 0,     // a deadline every request starts with; 0 = none

    .max_connections = 10_000,    // held at once; 0 = no limit

    .max_body = 1024 * 1024,      // the most `c.body()` reads into the arena
    .trusted_proxies = &.{},      // which machines may say who they forward for
    .trusted_hops = 0,            // or, older: how many stand in front
});
```

`address` is an address to bind to, not a host name — nothing is resolved, so
which interface you land on is never a lookup's decision.

The two buffers are what a connection costs **while it is being served**, not
while it waits: a connection that has gone quiet gives both of them back, along
with its stack pages, and waits at the shallowest frame it ever has
([ADR 0071](../adr/0071-where-a-connection-waits-is-what-it-costs.md)). So size
them for the responses you send rather than for the connections you hold —
**an idle connection is 4,669 bytes whatever these two say.**

`threads = 1` makes handlers stop running at the same time, which removes the
reason for `nilo.Mutex` — and also removes the reason to have a machine with
more than one core. See [Services](./services.md). Whatever the count, a
connection is served by the thread it was dealt to, and a handler runs on
that one OS thread from its first line to its last, across every wait in
it — no work stealing between threads, because what stealing cost was a
second wakeup on every request of a server that is not busy
([ADR 0272](../adr/0272-a-connection-is-served-by-the-thread-it-was-dealt-to.md)).
Every thread also accepts: one fiber per thread sits in `accept` on the
listening socket, so how fast the server takes new connections grows with
`threads` rather than being what one fiber can do — about 43,000 a second,
which is where a server that closes connections after a few requests used
to stop ([ADR 0273](../adr/0273-every-executor-accepts.md)).

On the request path, a routed GET returning JSON with CORS installed makes
**one allocation** — the JSON body, and nothing else. A test holds it there.

## When a bound is hit

Every limit above is a number with a behaviour behind it, and during an
incident the behaviour is the half that matters: what the client saw, what the
log said, and what has to happen before the server takes that work again. One
row per bound, so the answer is a lookup rather than a read. The sections that
follow say why each one is shaped the way it is.

| Bound | Default | Past it | What lets it go again |
|---|---|---|---|
| `max_connections` | 10,000 | The connection is accepted and closed at once — nothing read, no status written, so the client usually sees a reset. The log says so once a minute with a running count | A held connection ends: a keep-alive one idles out, a WebSocket tab closes, a stream finishes |
| the process's descriptor limit (`ulimit -n`) | usually 1,024 | `accept` fails with `ProcessFdQuotaExceeded`; the loop waits — 5 ms, doubling to a second — and tries again, and the log says so once per shortage. Connections meanwhile wait in the kernel's backlog. `listen()` warned at startup if this was below `max_connections` ([ADR 0265](../adr/0265-an-accept-loop-that-is-out-of-descriptors-waits.md)) | A held connection ends |
| `backlog` | 4,096 | The kernel drops the SYN — no reset, no log line here — and the client's TCP retries it one second later, so the connection succeeds late. `ListenOverflows` in `/proc/net/netstat` is the only trace; `bench/burst.py` reads it ([ADR 0271](../adr/0271-a-backlog-is-sized-for-the-burst-not-the-load.md)) | An acceptor takes the next handshake; there is one per thread, so the queue drains at the rate all of them accept ([ADR 0273](../adr/0273-every-executor-accepts.md)) |
| `max_in_flight` | off | The head is read, then `503` with `Retry-After: 1` and `Connection: close` — one write of a constant, no queue. Counted under `<shed>` on the metrics page | A request inside its handler finishes |
| `header_timeout_ms` | 10,000 | A client partway through a head gets a `408` and the connection is closed. One that sent nothing is closed without a status — there is nothing to answer | Nothing to release: the connection is gone |
| `read_buffer` | 16 KiB | A head that does not fit is a `431`, and the connection is closed — send side first, so the `431` reaches a client that would otherwise see a reset ([ADR 0266](../adr/0266-a-refused-request-is-hung-up-on-with-a-fin.md)) | Nothing to release |
| `idle_timeout_ms` | 75,000 | A keep-alive connection that has asked for nothing is closed, no status | Nothing to release |
| `body_timeout_ms` | 30,000 | A read of the body that outlasts it fails the handler's `c.body()` with a `408`, and the connection is closed. `c.bodyStream()` sees the same read fail | Nothing to release |
| `body_min_rate` after `body_grace_ms` | 8 KiB/s after 10,000 | A body `c.body()` is assembling gets a deadline worked out from its announced length; too slow is a `408` however steady the bytes were. `c.bodyStream()` is not under it | Nothing to release |
| `max_body`, or `nilo.maxBody` on the route | 1 MiB | `c.body()` refuses with a `413` before reading past it. A body nobody read that is over it is not drained after the answer: the response goes out and the connection is closed rather than read to the end — send side first, so the `413` arrives ([ADR 0266](../adr/0266-a-refused-request-is-hung-up-on-with-a-fin.md)) | Nothing to release — the next request needs a new connection |
| `request_deadline_ms` | off | Every wait of the request — body reads, the write — is cut to it, and `c.overdue()` says so to a handler doing its own work; the failure is the wait's own (`408`, or the write given up), the same as `nilo.deadline(ms)` on one route. A stream, a WebSocket or a `bodyStream()` lets go of it ([ADR 0267](../adr/0267-a-deadline-every-request-starts-with.md)) | — |
| `write_timeout_ms` | 30,000 | One write to the client that outlasts it gives the response up: no status can be sent by then, the connection is closed, and the log says `gave up writing after 30000ms — the client stopped reading` rather than blaming the handler | Nothing to release |
| `shutdown_grace_ms` | 10,000 | A stop waits this long for requests inside their handlers. Idle connections are closed at once, not waited for. Past it the rest are cut off and the log says how many | — |
| `arena_keep` | 16 KiB | Not a refusal: a response assembled in `c.arena()` that is larger than this is built in memory the arena gives back after the request, so the next one faults it in a page at a time ([ADR 0096](../adr/0096-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)) | Raise it just past the largest response, and no further — it is held per connection |

Two things are true of every row. **A status goes out only when nothing has
been written yet**: a `408` or `413` reached mid-response cannot take back the
half that is already on the wire, so the connection is closed instead. And
**none of the deadlines bounds a request** — an hour-long stream, a WebSocket, a 4 GB upload through
`c.bodyStream()` are all fine — because each bounds one wait for the network
and nothing else, which is the next section.

## Deadlines

The four `_timeout_ms` knobs above bound how long the server waits on a client,
and they are on by default. Zero turns one off.

They are limits on one wait for the network, not on a request
([ADR 0023](../adr/0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)),
which is what makes them safe to leave on: a stream that runs for an hour, a
WebSocket, and a 4 GB upload are all requests, and none of them is hurried by
any of this. What gets cut off is a client that has stopped talking.

`header_timeout_ms` is the one that matters most, and it is the one that is not
per read: the whole head has that long from its first byte, so a client sending
one byte a second is caught rather than granted an extension every time. It ends
in a 408. An idle keep-alive connection that has asked for nothing is closed
without a status — there is nothing to answer.

`body_min_rate` is the same idea for a body, and it is the one to read twice
because **it is an admission policy rather than a safety net**. A per-read limit
cannot catch a client sending one byte every twenty-nine seconds — every byte
arrives on time — so a body nilo is assembling in the arena gets a deadline
worked out from the length the client announced: `body_grace_ms` plus what those
bytes need at `body_min_rate`. A megabyte has 138 seconds at the defaults, and a
client slower than 8 KiB/s is a 408 however honest it is
([ADR 0124](../adr/0124-a-buffered-body-arrives-at-a-rate.md)).

If your clients upload from places where that is not generous, lower the rate
rather than raising the timeout — `body_min_rate = 0` turns it off entirely and
leaves the per-read limit on its own. A chunked body announces no length, so it
is sized from `max_body`: the same worst case as a body that announced the
largest it may be. **`c.bodyStream()` is not touched by any of this** — nothing
is being held on the client's behalf there, and a long upload through it is a
request that lasts rather than a request that stalls.

`idle_timeout_ms` is the knob whose real units are memory: an idle connection
costs 4,669 bytes, so a server with many visitors and few of them active wants
this lower than the default.

A WebSocket has no read limit once the handshake is done — a chat tab with
nobody typing is working correctly. Its writes keep theirs, which is how the
server finds out the client is gone.

## How many connections at once

`max_connections` is the most this process holds at one time. Ten thousand by
default, and the arithmetic behind that number is the one measurement this
project keeps repeating: **an idle connection costs 4,669 bytes before it has
asked for anything**, so the default is around 45 MB of connections and no more.

That figure is a **floor, not a total**. A suspended fiber holds its stack at
its high-water mark, so a handler adds every byte of stack it ever touched, for
the life of the connection — an ordinary database route measures 17,022
([ADR 0063](../adr/0063-a-handlers-stack-is-per-connection.md)). Budget from
4,669 only for connections that are idle between requests; budget from what
your own handlers measure for the ones in flight.

That is the whole reason it exists. A server with no cap does not fail at a
number somebody chose — it keeps accepting until the machine runs out, and what
notices is the OOM killer, which takes the process down along with every request
that was being answered correctly. A cap turns "we ran out of memory" into "we
ran out of connections", which is a thing you can read in a log and set a number
for.

Past the limit, a connection is accepted and closed at once. No request is read
and no status is sent, so a client sees the connection go immediately — often as
a reset, since the request it sent was never read. That is on purpose:

- **Not "stop accepting".** Connections left in the kernel's backlog hang until
  something times out, and the load balancer in front cannot try another
  instance until it does. Closing tells it now.
- **Not a 503.** Writing to a client the server has just decided it cannot
  afford to serve is work an attacker gets to choose, and it would put a write —
  with a deadline on it — inside the accept loop, which is the one loop that must
  not stall.

The log says so once a minute for as long as it lasts, with a running total:

```
warning: nilo is holding its limit of 10000 connections, so new ones are being
closed unanswered (417 so far). Raise `.max_connections` in listen() if the
machine has the memory — an idle connection costs 4,669 bytes, plus whatever
stack the handler touches — or put fewer of them on this process.
```

It counts connections, not requests. One connection makes many requests in a
row, and a WebSocket is one connection for as long as the tab is open — a chat
server holding open tabs wants this raised, and multiplied by 5,183 first, which
is what an idle WebSocket costs.
`.max_connections = 0` turns it off, which is what nilo did before this
existed.

It is also what bounds file descriptors. A response that sends a file — a static
file over `max_file_bytes`, or a handler returning a `FileBody` — holds one open
for as long as the send takes, and there is one of those per request in flight
([ADR 0037](../adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)). So it is
a number that was already being multiplied rather than a second one to budget
for.

## How many requests at once

`max_in_flight` is the other unit: not sockets held but requests being
answered. It is off by default. Set it, and a request whose head arrives while
that many are already inside their handlers is answered `503` with
`Retry-After: 1` at once and the connection closed — no queue, no wait, one
write of a constant — so a balancer in front sends the retry to a replica with
room and the requests already running finish on time
([ADR 0197](../adr/0197-a-server-past-its-limit-says-so-at-once.md)).

```zig
try app.listen(.{ .max_in_flight = 256 });
```

Pick the number from `nilo_requests_in_flight` on the metrics page under real
load, not from a guess: 256 is right for a 40 ms handler and wrong for a 4 s
one, which is why there is no default. Shed requests are counted under
`<shed>` on the same page, apart from the routes they never reached.

This is different from `max_connections` on purpose. Over the connection limit
nothing is read and nothing is written, because the accept loop must not
stall; over the request limit the head is already read on a connection fiber,
and a 503 is something a balancer can act on where a reset is not.

## How big a body may be

`max_body` is the most `c.body()` will read into the request arena. Past it, a
413. A megabyte, the default, is a JSON body's worth on purpose: this body is
held whole, in memory, per request, so raising it raises what a handful of
concurrent clients can make the server hold.

`c.bodyStream()` has no such ceiling, because it holds nothing at all — it is
bounded by the buffer the handler passes in ([Requests](./requests.md)). An
endpoint taking files wants that one, not a bigger `max_body`.

This is the knob a reverse proxy in front cannot stand in for. A proxy can bring
the limit **down** — most already do — but nothing in front of nilo can raise a
limit inside it. An app taking uploads has to say so here.

**One route can have its own number.** `listen()`'s is the server's, and an
import that takes fifty megabytes should not make the sign-in beside it take
fifty megabytes too:

```zig
try app.with(nilo.maxBody(50 << 20)).post("/import", importCsv);
```

It goes both ways — a route can say it takes *less* than `listen()` allows
([ADR 0194](../adr/0194-a-route-can-say-how-much-body-it-takes.md)).

## Who the client is

`c.peer()` is the address the connection came from. It is what the kernel says,
so it cannot be forged — and behind a proxy it is the proxy's address, which is
the same for every client.

`c.clientIp()` is the one to reach for, and by default it answers exactly what
`peer()` does. `X-Forwarded-For` is a header like any other: anyone can send one,
so a server that believed it without being told to would let every client claim
any address it liked. The things that read a client address — rate limits, audit
logs, blocklists — are precisely the things worth lying to.

**`trusted_proxies` is the one to use**: name the networks your proxies are on
and the count stops mattering.

```zig
try app.listen(.{ .trusted_proxies = &.{"private"} });
```

Each entry is a CIDR (`10.0.0.0/8`, `fd00::/8`), a bare address meaning that
host alone, or one of two names — `"private"` for the RFC 1918 ranges plus
carrier-grade NAT, link-local, unique-local v6 and the loopback, and
`"loopback"` for the loopback alone. The header is not read at all unless the
connection came from one of them; entries written by one of them are skipped
from the right; the first one left is the client. A rule that is not an address
stops the server at `listen()` with a sentence naming it
([ADR 0129](../adr/0129-a-proxy-is-trusted-by-which-one-it-is.md)).

The reason to prefer it over a count is that **a wrong count says nothing**.
Add a CDN in front of the load balancer and the number is one short from that
afternoon on — and the server goes on answering, with the load balancer's
address, or with whatever the client wrote in the header. Nothing logs and no
test turns red.

`trusted_hops` is the older shape and still works. It is how many proxies you
actually run:

```zig
try app.listen(.{ .trusted_hops = 1 });   // one Caddy, nginx or ALB in front
```

When both are set, the description wins.

Set it to the number of proxies, **not** to the number of entries you have seen
in a header. Each proxy appends the address it heard from, so the entries are
counted from the right — the rightmost was written by the proxy nearest this
server, and the leftmost is whatever the original client claimed.

That direction is the whole safety property. With one proxy in front, a client
sending `X-Forwarded-For: 1.2.3.4` arrives as `1.2.3.4, 203.0.113.9`. Counting
one from the right reads `203.0.113.9` — the address the proxy actually saw —
while the forgery sits to the left and is never looked at.

A header with fewer entries than there are hops means the chain is not the one
configured, so `clientIp()` falls back to `peer()` rather than reading the
closest thing to hand, which would be the forgery.

**`allowance.with` is the first thing in nilo that acts on this**, so getting
this wrong stops being an inconvenience and becomes an outage: leave
it at zero behind a proxy and every request looks like it came from the proxy,
one address spends the whole allowance, and everybody else gets a 429. nilo says
so in the log the first time it refuses a request that carried an
`X-Forwarded-For` and was counted against the connection's own address — see
[Middleware](./middleware.md#when-one-client-asks-too-often).

Requests-per-second figures now exist, on one quiet box:
[`bench/result/http.md`](../../bench/result/http.md) for nilo alone and
[`../comparison.md`](../comparison.md) against eight other servers. Read the
caveats in both — loopback, no TLS, no database, and a handler that touches
Postgres makes every row in them the same.

## Which build mode

**`ReleaseSafe`.** In `ReleaseFast` an integer overflow is undefined behaviour
instead of a loud crash, and a web server takes input from strangers — that is
exactly the code where the check earns its keep. `Debug` is for development;
nilo's own `Str` staleness trap only exists there.

## Debug info, and what a build costs

Half of a Zig release build is debug info. Measured on this repo, warm: 14.7s
with it and 7.4s without, and the binary goes from 6.0 MB to 0.8 MB. At runtime
it costs nothing measurable. What it costs is the file and the line on every
frame of a panic — so **keep it for anything you deploy**, which is also why the
mode recommended above is not the one where nilo turns it off. The full
decomposition is in [`../comparison.md`](../comparison.md).

`zig build -Doptimize=ReleaseFast` in this repo builds the benchmark binary,
whose only job is to be measured, and leaves debug info out of it. Nothing else
here does, and `-Dstrip=false` turns even that off. Your own `build.zig` decides
for your own binaries: pass `.strip = true` to the module if you want the
smaller, faster-to-build one and can give up the line numbers.

## Panics

Zig cannot recover from a panic: an integer overflow or an out-of-bounds index
takes the whole process down, every in-flight connection with it. There is no
`recover` middleware because there cannot be one — see
[ADR 0008](../adr/0008-no-recover-middleware.md).

Handler *errors* are a different thing and are already handled — see
[Errors](./errors.md). For the rest: run behind a supervisor that restarts, and
add

```zig
pub const panic = nilo.panic;
```

to your root file so the crash says which request caused it:

```
thread 589880 panic: integer overflow (while handling GET /boom/50)
```

That is the difference between a stack trace and a reproduction.

## Stopping

`listen()` returns when the server is stopped — Ctrl-C, a `SIGTERM` from whatever
is supervising the process, or `app.shutdown()` from anywhere:

```zig
try app.listen(.{});      // returns on Ctrl-C or SIGTERM
std.log.info("bye", .{}); // and this runs
```

What happens in between is the part that matters for a deploy. The server stops
accepting; requests already being answered are finished, and their responses go
out saying `Connection: close` so the client opens a fresh connection to whatever
replaced this process. Connections merely sitting idle between keep-alive
requests are closed at once — they are holding no work, and waiting on them would
put the whole grace period behind every open browser tab.

A handler that runs past `.shutdown_grace_ms` (10 seconds by default) is cut off,
with a line in the log saying how many were. Pressing Ctrl-C a second time skips
the waiting entirely.

A stream or a WebSocket is the case that needs your cooperation: `live()` goes
false when the stop begins, and a loop that checks it lets the deploy finish
instead of sitting out the whole grace period. See
[Streaming](./streaming.md#ending-on-purpose-and-otherwise).

Work that is not a request cooperates through the same grace period, and finds
out a different way: `nilo.sleep` fails with `error.Canceled` when it ends, and
`catch return` is the whole of what a ticker owes the deploy. See
[Work that is not a request](./background.md).

`app.shutdown()` is safe from any thread and from inside a handler, so an admin
endpoint that stops the server is an ordinary handler. The App is a service like
any other, so hand it to itself first:

```zig
fn quit(app: *nilo.App) []const u8 {
    app.shutdown();
    return "going down\n";
}

try app.provide(&app);          // …or `*nilo.App was never registered` at startup
try app.post("/admin/quit", quit);
```

## TLS, and the proxy in front

**nilo does not speak TLS unless the build asks for it, and a proxy in front
is still the recommendation** ([ADR 0028](../adr/0028-tls-is-terminated-in-front.md)).
Zig's standard library can be a TLS client and not a TLS server; the
alternatives were a one-person crypto dependency or a C toolchain in the
install story. The first of those is now an option, below, for the server
that has nothing in front of it. Everything else on this page is about the
server that does, which is most of them.

On Fly.io, Railway, Render, Cloud Run, a Kubernetes ingress, an ALB or
Cloudflare this changes nothing — every one of them terminates TLS before the
request arrives. Set `.trusted_proxies = &.{"private"}` and carry on.

On a bare VPS, the whole of it is a Caddyfile:

```
example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Caddy gets the certificate, renews it, redirects `:80`, and sends
`X-Forwarded-For`. The nginx equivalent needs the header said out loud:

```nginx
server {
    listen 443 ssl;
    server_name example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
        # A stream, a WebSocket and SSE all need this pair.
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

Either way, bind nilo to `127.0.0.1` so nothing reaches it except through the
proxy, and say `.trusted_proxies = &.{"loopback"}` so `clientIp()` reads the
address the proxy saw.

**Or take the port away entirely.** `.address = "unix:/run/nilo.sock"` listens
on a path instead, and then the answer to "who may connect" is the answer to
"who may write to that directory" — `proxy_pass http://unix:/run/nilo.sock;` in
nginx, `reverse_proxy unix//run/nilo.sock` in Caddy. `port` is not read. A
request that arrives that way has no client address of its own, so
`.trusted_proxies` is what `clientIp()` reads, and it is allowed to because
nothing remote can open a unix socket
([ADR 0130](../adr/0130-a-path-is-an-address-to-listen-on.md)).

One thing goes with this decision and is worth knowing before you need it: **HTTP/2 is not available for your routes.** Browsers only speak it over TLS, negotiated during the handshake, and the listener below offers only `http/1.1`. **gRPC is the exception**, because it runs over HTTP/2 without TLS: a build that asks for it serves unary calls on a listener of its own ([gRPC](./grpc.md)).

### TLS without a proxy

For the server with nothing in front of it: an internal tool on a VM, a
service on a private network whose policy says encrypted, a machine with one
port and a certificate and nobody who wants to run a second process. It is
TLS 1.3, on [ianic/tls.zig](https://github.com/ianic/tls.zig), and it has to
be built in ([ADR 0288](../adr/0288-tls-is-an-option-a-build-asks-for.md)):

```zig
// build.zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .tls = true });
```

The library is fetched and linked only behind that flag, so a build without it
is the build this page has described all along. With it, the listener takes
two PEM files:

<!-- compiles: body -->
```zig
try app.listen(.{ .tls = .{
    .cert = "/etc/nilo/fullchain.pem",
    .key = "/etc/nilo/privkey.pem",
} });
```

The certificate chain leaf first, the way every issuer hands it out, and the
key unencrypted; `certbot` and `step` both write exactly that. Paths are
relative to the directory the server is started in unless absolute. A
certificate that cannot be read stops the server before it takes the port,
in one line saying which file; a `.tls` on a build without the flag is
refused the same way rather than served as plain HTTP. So is a key that is
not the certificate's, which is the mistake the two files being in
different `letsencrypt/live/` directories makes: both files parse, so
without that check the server came up and failed every handshake with the
reason visible only to the client
([ADR 0294](../adr/0294-a-key-is-checked-against-its-certificate-at-listen.md)).
Rotation is a restart, which is the deployment this server already has.

What it costs, so that the choice is a choice ([ADR 0288](../adr/0288-tls-is-an-option-a-build-asks-for.md)
has the tables):

- **560 KB of binary**, before a certificate is loaded, in every build that
  passes the flag. The build that does not pays 2,760 bytes.
- **One page per idle connection**, on every listener of that build, TLS or
  not: 9,293 bytes against 5,191. A TLS connection's 33 KB of record buffers
  are not in that figure, because they go back to the kernel at idle the way
  the rest do.
- **About 300 µs of CPU per new connection with an ECDSA certificate, and 2.6 ms with an RSA-2048 one**, for the handshake: twenty times a plain accept for the first, and nine times that for the second, so an ECDSA P-256 certificate is the cheap choice where you pick the key. Half a microsecond per request either way on a connection kept alive. A service whose clients hold a connection does not notice; one whose clients connect per request pays the handshake per request, and that is the deployment a proxy with session resumption is for, because this listener has none. Build for the CPU you run on: without AES instructions in the target (`-Dcpu`), a request costs six times as much.
- **One certificate per listener**, no client certificates, and no reload
  without a restart. TLS 1.3 only, which every browser and client library of
  the last six years speaks.
- **The library has no audit.** ADR 0028's trust argument is unchanged, and a
  deployment choosing this is choosing an unaudited TLS stack over an audited
  one, on purpose, for a server that would otherwise have none. On the
  internet, put Caddy in front and leave this off.

`.tls` and a unix socket together are refused: the socket file's permissions
are already the access control, and there is nobody on the path to encrypt
against. The handshake is bounded by `header_timeout_ms`, because until it is
done a connection is a client that has not yet sent a request; a scanner that
connects and goes quiet, or speaks plain HTTP to the port, is dropped when
that runs out. `clientIp()` on this listener is the real address, since no
proxy is in the way.

### More than one address

A server answers on one address by default and on as many as you list
([ADR 0289](../adr/0289-a-server-answers-on-more-than-one-address.md)). The
case this exists for is the other half of the section above: HTTPS for the
people outside and cleartext for whatever is already inside.

<!-- compiles: body -->
```zig
try app.listen(.{
    .port = 8080,
    .also = &.{
        .{ .port = 8081, .tls = .{ .cert = "cert.pem", .key = "key.pem" } },
    },
});
```

An entry carries an address, a port and a certificate, and nothing else.
Everything else on `listen()` belongs to the server rather than to one of
its addresses: the buffers, the deadlines, the thread count, and
`max_connections`, which counts the sockets this process holds rather than
the sockets a port holds.

**A handler is not told which listener a request came in on**, and there is
no way to ask. A listener decides how the bytes are carried and nothing
above it does, so a route is a route on every address. A program that wants
two different surfaces gives them two route prefixes, which it could always
do.

Three things worth knowing before you reach for it:

- `boundPort()` answers for `port`, the first listener. An extra listener
  may ask for port 0 and the kernel will give it one, but nothing reports
  which.
- Two entries naming the same address are refused at `listen()`, naming
  both, rather than arriving as the kernel's `AddressInUse` — which reads
  as another process holding the port and sends you hunting for one.
- Each extra listener costs about **82 KB** of resident memory on a
  sixteen-thread server: one socket, and one acceptor fiber per thread
  parked in `accept` for the life of the server. Nothing per connection and
  nothing per request; an idle connection is exactly what it was.

## Knowing whether it is ready

A load balancer, Kubernetes, or the script that restarts the process all ask
the same question every second or so: *can this instance take traffic?*
`app.health` answers it:

<!-- compiles: body -->
```zig
try app.health("/healthz");
```

```
GET /healthz
200 {"status":"ok"}
503 {"status":"unavailable","waiting":[{"service":"sql.Db","why":"the database is not answering"}]}
503 {"status":"stopping"}
```

**Alive is not ready, and this route answers the second.** A route that says
`ok` because the process is up sends traffic to a server whose database is
down, and the application cannot write the honest version by hand because it
does not know what the pool knows. So the page asks each service that
declared `nilo_ready`, and the three modules that hold something answer:
`sql.Db` sends `SELECT 1` down the pool and says what came back, an `s3`
Store says whether it started, and a service with no hook — a config struct,
a cache — is assumed ready. A service of your own joins in with one function
([ADR 0192](../adr/0192-a-health-route-asks-the-services.md)):

<!-- compiles -->
```zig
const Mailer = struct {
    connected: bool = false,

    pub fn nilo_ready(self: *Mailer, scope: *nilo.AnyScope) ?[]const u8 {
        _ = scope;                       // an arena, for a reason with a number in it
        return if (self.connected) null else "the mail relay has not accepted a connection yet";
    }
};
```

Null is ready; a sentence is why not, and it goes on the page beside the
service's name. **The moment the server is told to stop, the page says
`stopping`**, which is how a balancer learns to drain this instance before its
listener closes rather than after — the other half of [Stopping](#stopping).
Every answer carries `Cache-Control: no-store`.

It is an ordinary route, like the metrics page: mount it where the balancer
can reach it and nothing else needs to, and keep it out of the
[logger](./middleware.md) if a line a second is noise. Nothing about it
touches a request that is not the probe.

## Knowing whether it is working

`app.metrics(.{})` puts a Prometheus page on `/metrics`: requests per route,
status classes, a latency histogram, exact status codes for the process, and
requests in flight. It is an ordinary route, so where you mount it and what you
`use` in front of it is what protects it — nilo puts no authentication on it.
See [Metrics](./metrics.md).

That is the *service* half. The *request* half — a request id you can tie a log
line to — is in [Errors](./errors.md), and the two answer different questions:
metrics tell you something is wrong, a request id tells you which request.

## What isn't here yet

`permessage-deflate`, and compression of a stream or an event stream. A
whole answer is compressed, per request ([Responses](./responses.md#compression)),
and a file is, once, at load ([Static files](./static-files.md#compression)).

Templates are a refusal rather than a backlog item: nilo is for building APIs
and services, and rendering pages is not what it is for. The reasoning is in
[`decided.md`](../decided.md#not-coming).

What is outstanding is listed with what it is waiting for in
[`../roadmap.md`](../roadmap.md); what has been refused, with the reason, is in
[`../decided.md`](../decided.md) and the ADR each entry names.
