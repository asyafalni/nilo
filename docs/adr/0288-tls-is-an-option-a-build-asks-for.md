# 0288 — TLS is an option a build asks for, and the default build never hears of it

**Status:** accepted
**Amends:** [ADR 0028](./0028-tls-is-terminated-in-front.md)

## Context

ADR 0028 decided that nilo does not speak TLS, on two arguments it kept
apart on purpose: a trust argument (a one-person Zig TLS library is a second
zio-shaped risk at a place where the failure mode is silent) and a memory
argument (record buffers would take the idle-connection figure from 8,767
bytes "to something like five times that"). It closed with the terms on
which it would be revisited: the standard library growing a TLS server, or a
Zig TLS library acquiring "the funding and the audits that rustls has".

Neither has happened. What has happened is smaller and was worth a look
anyway. The question that came back was not "is it audited" but "what does
it cost a server that does not switch it on, and what does it cost one that
does", because those are the two numbers the first decision guessed at and
the guess for the second was 38 KB.

**The library.** [ianic/tls.zig](https://github.com/ianic/tls.zig), on its
`zig-0.16.x` branch at `e04ae44`, is a TLS 1.3 client and server written on
`std.crypto` with no C in it. It was read and probed before this was
written: the record layer, the handshake state machine and the certificate
handling are a dozen files a reader can hold in their head; the handshake
takes no allocator, so it allocates nothing; `curl`, OpenSSL's `s_client`,
Python's `ssl` and the standard library's own `std.crypto.tls.Client` all
complete a handshake against it and read a response back, with an ECDSA
P-256 certificate and with an RSA one; and a server-side handshake costs
about 300 µs of CPU on the machine below. It has no tags, no audit, and a
short list of things it does not do, which are in the last section. What it
is not is unknown to this repository: **pg.zig already carries it**, as the
client half of a Postgres connection, so every `-Dsql` build that reaches a
database over TLS has been linking it since ADR 0075's table listed it.

**The constraint.** ADR 0028's memory argument was about the two claims that
distinguish nilo in a comparison table: one allocation per request, and a
flat, stated cost per idle connection. Whatever this decides may not move
either for a server that did not ask for TLS. That was the shape asked for
in the session that produced this ("our main is not disturbed, and the user
has to be aware of the trade-off"), and it is the shape ADR 0075 already
built for the drivers: a dependency that is a request, fetched and linked
only behind a flag.

## Decision

**TLS 1.3 is a listener option, in a build that asked for it, and the
default build contains none of it.**

- A dependent passes `.tls = true` to `b.dependency("nilo", …)`; in this
  repository that is `-Dtls`. The library is reached through
  `b.lazyDependency` *inside* that `if` (ADR 0075), so a build without the
  flag fetches nothing, links nothing, and has no module named `tls` to
  resolve. `zig build fetch-check -Dnetwork` holds that for the dependent
  under `bench/dependent/`, which still lands zio and nothing else.
- With it, `listen(.{ .tls = .{ .cert = "…pem", .key = "…pem" } })` serves
  HTTPS on the listener. The routes, the handlers, the `Ctx`, the
  middleware and the OpenAPI document see nothing different; a request is
  a request.
- **Without it, the same option is refused at `listen()` in one line**, the
  way a port that is taken is: what is missing, and what to pass. It is
  never served as plain HTTP on a port the caller believed was encrypted.
  The same line refuses `.tls` on a unix socket, whose file permissions are
  its access control, and a certificate that cannot be read, before the
  port is taken.
- **The Engine is the only file that names the library**, under the same
  rule that makes it the only file that names zio (ADR 0002). A TLS
  connection is a second fiber entry, `Conn.runTls`, beside the plain one
  and never a branch inside it; the reason is a measured page, below.
- **The handshake is bounded by `header_timeout_ms` and `write_timeout_ms`**,
  because until it is done a connection is exactly what those two limits
  exist for: a client that has connected and not yet said anything nilo can
  act on. The spike found this by not having it: a client that connected and
  went quiet held its fiber and 33 KB for ever.
- **The repository's own http test root always has TLS in it**, `-Dtls` or
  not, so the feature is held by `zig build test` and not by whoever
  remembers a flag (ADR 0033). The tests drive it with `std.crypto.tls.Client`,
  the standard library's own, on `std.Io.Threaded`, checking the certificate
  as a browser would; a test of the library talking to itself would show
  that its halves agree, which is not the question.
- **ADR 0028's recommendation stands for a server with a proxy in front.**
  What this changes is the answer for the server with nothing in front of
  it: an internal tool on a VM, a service on a private network whose policy
  says encrypted, a box with one port and a certificate. That server had
  "run a second process" as its only answer and now has two.

## What it costs, on ADR 0018's four axes

Measured on the code as shipped, ReleaseFast, stripped, `x86_64-linux-gnu`,
on a Ryzen 7 9700X, at commit `1264cac` plus this change. The run record
with the commands is in [`bench/result/http.md`](../../bench/result/http.md).

**Binary size.** The default build pays 2,760 bytes: an `Options` field,
the comptime `if`s around it, and the two refusal messages, one of which
exists precisely for that build. The build that asked pays 560 KB before it
has loaded a certificate, which is `std.crypto`'s X.509, the AEADs and the
key exchange pulled in by reference.

| build | `nilo-hello` | against `main` |
|---|---|---|
| `main` | 990,696 | |
| this change, no `-Dtls` | 993,456 | +2,760 B |
| this change, `-Dtls`, `.tls` never set | 1,568,208 | +577,512 B |

**Memory per idle connection**, at 10,000 connections, marginal equal to
average (`bench/mem.py`, ADR 0071's method):

| listener | build | bytes | against plain |
|---|---|---|---|
| plain | no `-Dtls` | 5,191 | |
| plain | `-Dtls` | 9,293 | +4,102 (one page) |
| TLS | `-Dtls` | 9,307 | +4,116 (the same page, and 14 bytes) |

Two things in that table are the decision's, and the third is not.

The first: **a TLS connection's 33 KB of record buffers are not in the
figure.** ADR 0028's "five times" assumed they would be held; they are
page-aligned, like the cleartext pair, and handed back with it at every
idle transition through the same `MADV_DONTNEED` (ADR 0071), with one extra
check, that no decrypted bytes are still waiting in them. `smaps` confirms
it: the slab mappings do not move between one idle TLS connection and one
idle plain one. What is left is a page of fiber stack, because the
handshake's frames were touched below the park and a suspended fiber holds
its high-water mark (ADR 0063). `@call(.never_inline, tls.server, …)` is
what keeps them below rather than in the frame that lives as long as the
connection: inlined, the spike measured 13,360 against 9,302.

The second: **a plain listener in a `-Dtls` build costs the same page**, and
that is the cost the constraint said may not be paid, paid by the build
that asked and by nobody else. The first form of the change was a branch in
`Conn.run` and it cost that page on a plain listener too; the two entries
are what took it back. What remains is the inliner: a second caller of the
handler changes what LLVM folds into the plain path, and the plain park sits
under 300 bytes short of a page boundary, so anything at all crosses it.
The account is in the last section but one, and the measurement that would
buy the page back is a roadmap row. It is not paid by a build without the
flag, which is the line that was drawn.

**Allocations per request: unchanged.** The record buffers are two
allocations per *connection*, at accept, beside the two the plain path
makes; the handshake takes no allocator; nothing on the request path
changed. `test "the request path stays inside its allocation budget"` is
what holds it.

**CPU, and therefore throughput.** Server CPU per operation, loopback,
client on other cores, three runs quoted as the band
(`bench/result/http.md` has the method), with `-Dcpu=native` and then the
baseline `x86_64` that has no AES instructions:

| | plain | TLS | ratio |
|---|---|---|---|
| per request, kept alive, `-Dcpu=native` | 3.0–3.5 µs | 3.5–4.0 µs | ~1.15 |
| per new connection, `-Dcpu=native` | 10–15 µs | 280–295 µs | ~20–29 |
| per request, kept alive, baseline x86_64 | 3.0–3.5 µs | 22–23 µs | ~6.5 |
| per new connection, baseline x86_64 | 15 µs | 325 µs | ~22 |

The request is cheap and the handshake is not, which is the shape TLS has
everywhere; what a deployment pays depends entirely on how often its
clients connect. A service whose clients hold a connection pays about 15%.
One whose clients connect per request pays twenty times an accept, and that
deployment wants session resumption, which the library does not have and a
proxy does. **Build for the ISA you run on**: the baseline row is what a
`-Dtarget=x86_64-linux-gnu` binary with no `-Dcpu` does on a machine that
has AES-NI, and it is six times slower per request than the same machine
with the instructions used. **How much that flag is worth was measured
later and is larger than this table suggests**: `std.crypto`'s AES-256-GCM,
which is what an OpenSSL client negotiates, is 71 MB/s a core without the
instructions and 5,133 with, and a server built `-Dcpu=x86_64_v3` (which
carries no `aes` and no `pclmul`) cannot hold 50,000 req/s of a 10 KB echo
on eight cores while one built `+aes+pclmul` does it at 9% of four. The run
is in [`bench/result/http.md`](../../bench/result/http.md), and it closes
the roadmap row this paragraph used to name.

## What was rejected

**Always on.** The 560 KB and the page would be paid by every build, which
is the constraint failed. And a library that has not been audited would be
on the path of every request whether or not the deployment wanted it.

**Linking OpenSSL or BoringSSL.** ADR 0028's reasons stand: it ends `zig
fetch` as the installation story and brings a C toolchain with it. The
library that made this possible is the one that brings nothing.

**A run-time switch with the library always linked.** Half the cost of
always-on for none of the benefit: the binary carries the code and the
choice moves to a config file. The flag is at build time because that is
where the cost is decided.

**Record buffers per request rather than per connection.** Would put two
allocations on the request path and fail the invariant; and the record
layer has to be whole across requests, since a record does not end where a
request does.

**Kernel TLS.** The library has a `Ktls` mode: after the handshake the
kernel does the record layer and the 33 KB of buffers go away, on Linux.
Not taken now because the buffers already cost nothing at idle, and what
kTLS would buy is the page and the per-request microsecond, both worth a
measurement before a platform-specific path. It is on the roadmap as a
measurement, not a plan.

**A copy of the library in the tree.** A fork is a fork to maintain. The
pin is a commit on a branch, because the library has no tags, and the
commit rather than the branch is what `build.zig.zon` names.

**A TLS-only Engine, or a branch in the plain one.** The branch was
measured and cost the page on the plain listener. A second Engine would
duplicate the accept loop for the sake of one spawn line.

## The page that is not TLS's

The finding that took longest, recorded because it will be met again by
anybody who adds a second caller to `handler`.

Instrumented at the park, the live stack of a plain connection on the
plain build is 2,618 bytes, one page. On the `-Dtls` build the same plain
connection parks at 2,890 to 3,018 bytes, two pages; a TLS connection at
3,994, two pages. The 272-byte difference on the plain path is not a TLS
frame: it is the plain path's own frames grown by what the inliner decided
once the handler had a second caller with a different argument shape. A
separate entry, `always_inline` on the handler, and keeping both entries'
argument lists identical were each tried; the third is what shipped, and it
left the difference at 272. **The plain park sits under 300 bytes short of
a page boundary**, which means any change to the plain path is one page per
idle connection away from being noticed, and the number to know is that
headroom rather than this change. `docs/roadmap.md` carries it as a
measurement outstanding, with the instrumentation named.

## What the library does not do yet, and what that costs a deployment

Recorded at the pin, `e04ae44`, so the next person can check whether any
of it has moved (`docs/roadmap.md` carries the rows).

- **A ClientHello split across records is refused**
  ([tls.zig#36](https://github.com/ianic/tls.zig/issues/36)). Every client
  tried sends it whole; one that does not gets a failed handshake rather
  than a slow one.
- **No HelloRetryRequest.** A client offering a key share for a group the
  server does not take is refused rather than asked again. Every client
  tried offers X25519 first, which the server takes.
- **No session tickets, so no resumption.** Every connection is a full
  handshake, and the 300 µs is paid every time. This is the row that
  decides whether a deployment's clients should be behind a proxy.
- **One certificate per listener, no selection by name.** A listener
  serving two names needs two listeners or one certificate with both names
  on it.
- **No client certificates wired through**, although the library has them;
  mTLS is a use case waiting for a caller.
- **A record's length is read before its content type is checked**, so
  plain HTTP sent to a TLS port is held as a record that never finishes
  rather than refused on sight. The header deadline is what ends it, which
  is why the deadline is not optional.
- **A certificate is read at `listen()` and never again.** Rotation is a
  restart, which for the server this is for is the deployment it already
  has.
- ~~**A key that is not the certificate's is not caught at `listen()`.**~~
  It is now: the leaf's public key against the one the private key carries,
  refused before the port is taken
  ([ADR 0294](./0294-a-key-is-checked-against-its-certificate-at-listen.md)).
  What it looked like while it was not caught, which is what put it on this
  list: both files parse, the server comes up, and every handshake fails on
  the client's side with nothing in the server's log above debug — tried,
  with the fixture's certificate and a fresh key, `curl` exit 35.

## Consequences

- **The trust argument is unchanged, and it is written where the option
  is.** The `Options.tls` doc comment, the deploying guide and the README
  say the same thing: a proxy in front is still the recommendation for a
  server on the internet, and this is for the server that has nothing in
  front of it and would otherwise have run one. A deployment choosing it
  is choosing an unaudited TLS stack over an audited one, on purpose, with
  the number beside it.
- **`Ctx.clientIp()` is the real address on a TLS listener**, because there
  is no proxy to hide it. The other half of ADR 0028's first consequence
  goes away for this deployment and stays for every other.
- **HTTP/2 does not follow.** The handshake offers `http/1.1` as its only
  ALPN protocol, and ADR 0028's refusal of HTTP/2 and gRPC stands as
  written.
- **A `-Dtls` Postgres build carries the library twice**, once as pg.zig's
  client at its own pin and once as nilo's server at this one. Two copies
  of the same code at two commits is a cost the binary pays and a fact the
  next person bumping either pin should know.
- **The Engine's contract grew by one type**: `Wake.RawLayer`, so the
  Bulkhead can hand a record layer's pages back without knowing what one
  is. The Bulkhead's `release_stack` gained a branch that a plain
  connection takes as one null check.
- **This ADR is where ADR 0028's reversibility clause was read under
  load**, and the reading is narrow: the argument about trust did not
  change, the argument about memory turned out to be a design choice
  rather than a property of TLS, and the answer is an option rather than a
  reversal. If the library is ever audited, or the standard library grows
  a server, the option's default is the thing to revisit, not this ADR.
