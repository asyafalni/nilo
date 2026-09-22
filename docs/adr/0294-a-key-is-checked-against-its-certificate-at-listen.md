# 0294 — A key is checked against its certificate at `listen()`, and a pair nilo cannot compare is not refused

**Status:** accepted
**Amends:** [ADR 0288](./0288-tls-is-an-option-a-build-asks-for.md)

## Context

[ADR 0288](./0288-tls-is-an-option-a-build-asks-for.md) shipped the TLS
listener and listed, among the things it did not do, the one failure that is
silent on the server's side: `listen()` reads the certificate and the key,
checks that each file parses, and never compares them. A certificate handed
somebody else's key passes both parses. The server binds, logs that it is
listening, and then fails every handshake at the signature the client
verifies — `curl` exit 35, nothing above debug in nilo's own log, and an
operator who reads the server for a reason finds a server that says it is
fine.

It is not an exotic mistake to make. `/etc/letsencrypt/live/` holds a
directory per name the machine has ever had a certificate for, each with a
`fullchain.pem` and a `privkey.pem` in it, and the two paths are usually
written into a unit file or a config by different steps. A renewal that
lands in `example.com-0001/` while the config still names `example.com/` is
the same mistake arriving on its own.

Both halves of the comparison are already in the process by the time the
option is honoured. `tls.zig` parses the chain into a `Certificate.Bundle`
and the key into a `PrivateKey`, and for an EC key it derives the key pair
there and keeps it, because a server signs with it on every handshake.

## Decision

**`listen()` compares the leaf certificate's public key against the one the
private key carries, and refuses the pair in one line when they differ.**

- **The check is nilo's, at `listen()`**, beside the refusals already there:
  before the port is taken, one line naming both files, and the two
  `openssl` commands that print the two public keys so the reader can see
  the difference rather than take the server's word for it. It returns
  `error.TlsCertificate`, which is what an unreadable certificate already
  returns; the error set does not grow.
- **What is compared is the public key, per scheme.** For an EC key, the
  uncompressed SEC1 point, which is byte for byte what the certificate
  carries. For RSA, the modulus — and not the exponent, which is 65,537 on
  very nearly every key ever issued and would pass two keys that share
  nothing. For Ed25519, the 32 bytes.
- **The leaf is the first certificate in the chain**, which is the order a
  PEM chain is written in, the order every issuer hands one out, and the
  order the handshake sends them.
- **A pair nilo cannot compare is not refused.** A signature scheme with no
  prong in the comparison is a key the library parsed and nilo has no
  opinion about, and the answer is that the pair is acceptable. The
  alternative is below; the short version is that a server which will not
  start is a worse failure than the one this fixes.
- **The comparison is a function of its own, and that is what is tested.**
  A mismatch is a runtime condition, so it cannot be a compile-error
  Refusal; and it cannot be a test that drives `listen()` either, for the
  reason the `.tls` refusal beside it is already tested with the line it
  prints left out. The test is `keyIsTheCertificates` against a second
  P-256 key that belongs to no certificate here
  (`http/testdata/tls/other-key.pem`) — the same curve, so what is caught
  is the key rather than the curve or the file format.

## What it costs, on [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes

**Allocations per request: unchanged.** The check runs once, at `listen()`,
on a pair that is already in memory. Nothing is added to the request path,
and nothing is kept.

**Memory per idle connection: unchanged.** There is no per-connection state;
the two 512-byte buffers the RSA prong compares through are a startup
frame that is gone before the first accept.

**Throughput and p99: unchanged.** One parse of the leaf certificate at
startup.

**Binary size.** `nilo-hello`, `ReleaseFast`, stripped,
`-Dtarget=x86_64-linux-gnu`, against the same binary built from the commit
before this one, in a scratch tree rather than quoted
([`bench/result/http.md`](../../bench/result/http.md) has the run):

| build | before | after | against before |
|---|---|---|---|
| no `-Dtls` | 968,144 | 968,144 | 0 |
| `-Dtls`, `.tls` never set | 1,547,728 | 1,538,352 | **−9,376** |

The default build pays nothing, and that is a property rather than a
measurement that came out at zero: every line of this is inside the
comptime `if (nilo_build.tls)` the Engine already had, so a build with no
module named `tls` never analyses it. The two binaries are byte-identical,
which is also what says the two trees are otherwise the same.

**The `-Dtls` build got 9,376 bytes smaller, and that number is the
inliner's rather than this change's.** It reproduced to the byte across two
interleaved rounds, and `.text` is where it moved: 1,376,221 to 1,367,149
in the unstripped pair. `keyIsTheCertificates` has no symbol in either
binary — it is inlined into the listener loop — and the certificate-loading
chain it sits beside (`CertKeyPair`, `Certificate.parse`, the RSA
namespace) is the same size in both, so nothing was dropped. The largest
matched move is `handshake_server.Handshake.serverFlight`, 22,598 to
21,140, which this change does not touch: one more call in the startup loop
shifted what LLVM folded, and the rest is spread thin. It was not chased
further, because the number worth holding is the row above it — **the
default build is unchanged to the byte** — and a shrink nobody asked for is
not a result to defend.

## What was rejected

**Leaving it to the library.** `tls.zig` could check inside
`CertKeyPair.fromFilePath`, and that is arguably where it belongs. Against
it: the pin has not moved since ADR 0288, a change there is somebody else's
release to make and nilo's to wait for, and the check is a few dozen lines
here. This is not an argument against the library doing it as well — if it
ever does, this becomes a check that always passes, which costs a startup
parse and no reader's attention.

**Refusing a pair nilo cannot compare.** The strict reading is that an
unknown scheme means the check did not run, so the pair is unverified and
should be refused. It was not taken because of which way each failure
points. The failure this ADR fixes is loud on the client and silent on the
server, and it is always a mistake. The failure the strict reading
introduces is a server that was serving yesterday and will not start today,
because the library learned a key type nilo's switch has not heard of — and
that one is loud on the server and is never the operator's mistake.

**Signing a probe and verifying it.** The general check: sign a fixed
message with the private key and verify it with the certificate's public
key, and every scheme is covered without a comparison per scheme. It needs
an RNG at startup and a verifier per scheme, so it is the same switch with
more in it, and it spends an ECDSA signature and verification on every
start. The comparison is what the mistake actually is.

**A test that stands the listener up with the mismatched pair.** Written,
run, and taken back out. It is the test that would hold the wiring rather
than the predicate, and it cannot exist: Zig's test runner counts every
`std.log.err` a test provokes and fails the step on the count, and
`std.testing.log_level` only decides whether the line is *printed* — the
count happens before the filter. So a test of a refusal that speaks is a
red step by construction, which is why `tlsRefusal` is tested as a decision
and its message separately. `http/test_root.zig` now says so.

**Checking the rest of the chain.** Whether the leaf's issuer is the next
certificate in the file is a different mistake, with a different message,
and it is one the client refuses with a reason the client prints. This is
about the key.

## Consequences

- **The deploying guide loses its workaround.** "`curl -k https://…` once
  after a deploy is the check until it is" was the honest advice while this
  was not caught, and it is now the server's job.
- **ADR 0288's list of what is not done loses a bullet**, and the roadmap
  entry under **Next** for `nilo_http` goes with it.
- **A deployment whose two files genuinely do not match now fails to
  start**, where it used to start and serve nothing. That is the point, and
  it is the same trade the missing-file refusal already made: a server that
  cannot do its job says so at startup rather than per client.
- **The three schemes in the switch are the three the library signs with.**
  A fourth arriving upstream is a pair this answers "acceptable" to, which
  is the safe direction, and a prong to add when somebody has a key of that
  kind.
