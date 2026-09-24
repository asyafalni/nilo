# Design, one page a topic

**Each page here is one topic's rule as it holds today: how its pieces fit, each rule in force with the ADR that decided it, and what is still open.** Start here to understand a part of nilo; follow a page's links into [`docs/adr/`](../adr/) for why each rule won and what it beat. Every ADR's `**Topic:**` line links back to its page, and `zig build adr-check` refuses a page that leaves out an ADR of its topic ([ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)).

## The whole

- [nilo's design principles](principles.md): the four axes every change is put against.
- [Layering](layering.md): which module a file goes in, and what that module may import.
- [Memory per request and per connection](memory.md): the arena, `Str`, and where a fiber waits.
- [Documentation tooling](docs-tooling.md): snippets that compile, the site, and these pages.
- [Testing](testing.md): the refusals, both optimize modes, and a test client.

## Serving a request

- [The engine](engine.md): the Bulkhead, zio behind it, accepting and dealing connections.
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
- [Outbound calls](fetch.md): `nilo_fetch`.
- [Jobs](job.md): `nilo_job`.
- [Object storage](s3.md): `nilo_s3`.

## SQL

- [The SQL runtime](sql-runtime.md): pools, Wires, transactions, the boot check.
- [The query builder](sql-query.md)
- [Raw statements](sql-raw.md)
- [SQL column types](sql-types.md)
- [Migrations](sql-migrations.md)

## Topics that are one ADR

A topic with one decision has no page; the ADR is the page.

- config: [ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
- pw: [ADR 044](../adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)
- build-dependencies: [ADR 066](../adr/066-a-lazy-dependency-is-a-request.md)
- metrics: [ADR 079](../adr/079-the-route-table-is-the-registry.md)
- grpc: [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)
