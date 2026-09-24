# TLS

**nilo does not terminate TLS on the internet, and the option it does offer costs nothing in a build that never asked for it.** How to use it is the guide ([`guide/deploying.md#tls-without-a-proxy`](../guide/deploying.md#tls-without-a-proxy)); the listener option is the reference ([`reference/app.md`](../reference/app.md), the `tls` row). The code is the Engine's TLS connection loop (the only file allowed to name the library, ADR 001), the key/certificate check at `listen()`, and the fork `nevindra/tls.zig` pinned in `build.zig.zon`.

## How the pieces fit

```
                default build: no -Dtls, no -Dgrpc
internet ──► proxy (Caddy, ALB, Cloudflare) ──► nilo, plaintext HTTP/1.1
                                                 (ADR 027: still the recommendation)

                a build that passes .tls = true
client ──TLS 1.3 handshake──► nilo's listener
             │  record layer, state machine        ── on the executor
             └─ signature over the transcript       ── hopped to the blocking pool,
                                                        fiber parked (ADR 217)
          h2c or ALPN "h2" ──► a -Dgrpc listener, beside or instead (ADR 220, topic grpc)
```

## The rule in force

1. **nilo does not speak TLS as a server on the public internet, and a proxy in front is still the recommendation.** Every comparable server plugs into somebody else's audited implementation; Zig has none to plug into, and writing one is refused outright. [ADR 027](../adr/027-tls-is-terminated-in-front.md)
2. **HTTP/2 for browsers and for ordinary routes stays refused**, because a browser only negotiates it over TLS by ALPN. gRPC is the one exception, decided separately (see Beside this topic). [ADR 027](../adr/027-tls-is-terminated-in-front.md)
3. **TLS 1.3 is a listener option in a build that asked for it, and the default build contains none of it.** A dependant passes `.tls = true` to `b.dependency("nilo", …)` (`-Dtls` in this repository); the library is reached through `b.lazyDependency` inside that flag, so an unflagged build fetches and links nothing. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
4. **Without the flag, `.tls` is refused at `listen()` in one line**, the way a port already taken is, and never served as plain HTTP on a port the caller believed was encrypted. The same line refuses `.tls` on a unix socket. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
5. **A key that is not the certificate's own is refused at `listen()`, before the port is taken**, comparing the public key by scheme (the EC point, the RSA modulus, the Ed25519 bytes); a scheme the check has no prong for is accepted rather than refused. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
6. **The Engine is the only file that names the TLS library**, the same rule that makes it the only file that names zio; a TLS connection is a second fiber entry beside the plain one, never a branch inside it. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
7. **The handshake is bounded by `header_timeout_ms` and `write_timeout_ms`**, the same limits that bound a client that connects and says nothing. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
8. **The repository's own http test root always builds with TLS**, whatever flag was passed, so the feature is held by `zig build test` rather than by whoever remembers `-Dtls`. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
9. **A handshake's signature runs on the Engine's blocking pool, with the connection's fiber parked until it returns**; the rest of the handshake, which only waits on the socket, stays on the executor. [ADR 217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md)
10. **RSA-PSS's randomness is drawn on the fiber before the hop**, because the job may run on a thread with no `Io` to read it through; ECDSA and Ed25519 sign deterministically and draw nothing. [ADR 217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md)
11. **A `-Dtls` build costs one page per idle connection on every listener it has, TLS or not**, and the default build pays 2,760 bytes with no page; the 33 KB of record buffers a live TLS connection needs go back to the kernel at idle the same way the plain pair does. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
12. **A handshake costs about 300 µs of CPU with an ECDSA P-256 certificate and 2.6 ms with an RSA-2048 one**; a request on a connection already up costs about half a microsecond more either way. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md), [ADR 217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md)
13. **`Ctx.clientIp()` is the real address on a TLS listener**, since there is no proxy in front of it to hide it; the address-hiding half of ADR 027's consequences stands for every other deployment. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)

## Decisions

| ADR | What it decides |
|---|---|
| [027](../adr/027-tls-is-terminated-in-front.md) | nilo refuses to be a TLS server on the internet; a proxy in front is the answer |
| [212](../adr/212-tls-is-an-option-a-build-asks-for.md) | TLS 1.3 as a listener option behind `-Dtls`, the key/certificate check, and what it costs a build that asks and one that does not |
| [217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md) | The handshake's signature runs off the executor, on the blocking pool, to stop it holding every other connection on the same thread |

Beside this topic: [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md) (topic grpc, no page of its own) is the one exception to "no TLS, no HTTP/2": gRPC runs over h2c or over TLS with ALPN `h2`, needs neither, and is its own listener behind `-Dgrpc`; the Engine and the rule that only it may name a dependency are [`engine.md`](./engine.md) (ADR 001); the four trade axes every cost above is measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (topic principles, no page); the per-idle-connection floor a `-Dtls` build's extra page is added onto is [`memory.md`](./memory.md) (ADR 062).

## Open

- **A TLS listener that reloads its certificate without a restart.** Not built; the roadmap describes the shape (a second key pair swapped in under the acceptors, freed once the last handshake using the old one ends) and what the Engine does not yet count to make it safe.
- **Client certificates on a TLS listener.** The library supports `client_auth`; nothing in `Options.tls` names it yet, and the roadmap calls the second half a design question, whether a verified subject should be a typed argument the way `Session(T)` is.
- **Session resumption.** The library has no session tickets, so every connection pays a full handshake; the roadmap has the option shape once it does and the number to re-measure.
- **A ClientHello split across two records is refused rather than reassembled**, and there is no HelloRetryRequest for a client that does not offer X25519 first; both are open issues on the pinned fork's upstream.
- **Kernel TLS (`Ktls`)**, which would drop the 33 KB of record buffers and shorten each read and write by a syscall, is not taken: the roadmap says the buffers already cost nothing at idle, so the win is unmeasured.
- **The TLS pin is two commits ahead of upstream** (an RSA CRT signing fix and the `offload` option ADR 217 uses); the roadmap tracks moving back to upstream once both merge.
