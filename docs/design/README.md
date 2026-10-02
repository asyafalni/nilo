# Design, one page a topic

**Each page here explains why one part of nilo works the way it does: how its pieces fit, the rules that hold today with the ADR behind each, and what is still open.**

**Guide:** [The nilo guide](../guide/README.md) · **Reference:** [The reference](../reference/README.md)

Start here to understand a part of nilo. Each page links into [`docs/adr/`](../adr/), where every rule has its full reasoning and the alternatives it beat. Every ADR's `**Topic:**` line links back to its page, and `zig build adr-check` fails if a page leaves out an ADR of its topic ([ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)).

## Foundations

- [nilo's design principles](principles.md): the four axes every change is measured against.
- [Layering](layering.md): which module a file goes in, and what that module may import.
- [Memory per request and per connection](memory.md): the arena, `Str`, and where a fiber waits.
- [Documentation tooling](docs-tooling.md): snippets that compile, the site, and these pages.
- [Testing](testing.md): the refusals, both optimize modes, and a test client.

## Serving a request

- [The engine](engine.md): the Bulkhead, zio behind it, accepting and handing out connections.
- [The HTTP/1.1 wire protocol](http1-protocol.md)
- [TLS](tls.md)
- [Lifecycle](lifecycle.md): boot, services, the loop, shutdown.
- [Deadlines](deadlines.md)
- [Routing](routing.md)
- [Typed handlers](typed-handlers.md)
- [Request input](request-input.md)
- [JSON](json.md)
- [Responses](responses.md)
- [Errors](errors.md)
- [Middleware](middleware.md)
- [CORS and the proxy in front](cors-proxy.md)
- [Cookies and sessions](cookies-sessions.md)
- [Rate limiting](rate-limiting.md)
- [Idempotency](idempotency.md)
- [Static files](static-files.md)
- [WebSockets](websocket.md)
- [OpenAPI](openapi.md)

## Modules

- [The clock, entropy, and a UUID](id-clock-entropy.md): `nilo_core`'s clock and `nilo_id`.
- [The in-process cache](cache.md): `nilo_cache`.
- [JWT verification](jwt.md): `nilo_jwt`.
- [Protobuf](proto.md): `nilo_proto`.
- [Outbound calls](fetch.md): `nilo_fetch`.
- [Jobs](job.md): `nilo_job`.
- [Object storage](s3.md): `nilo_s3`.

## SQL

- [The SQL runtime](sql-runtime.md): pools, Wires, transactions, the boot check.
- [The query builder](sql-query.md)
- [Raw statements](sql-raw.md)
- [SQL column types](sql-types.md)
- [Migrations](sql-migrations.md)

## Topics with a single ADR

A topic with only one decision has no page; the ADR is the page.

- config: [ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
- pw: [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)
- build-dependencies: [ADR 066](../adr/066-a-lazy-dependency-is-a-request.md)
- metrics: [ADR 079](../adr/079-the-route-table-is-the-registry.md)
- grpc: [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)
- tracing: [ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)
