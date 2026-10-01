# A Postgres URL without `sslmode` is encrypted unless it stays on this machine

**Status:** accepted
**Topic:** [sql-runtime](../design/sql-runtime.md)
**Extends:** [ADR 051](./051-a-statement-that-is-a-constant-can-be-prepared-once.md) (`pgbouncer=true` turns `Opts.prepared` off), [ADR 115](./115-a-boot-dials-the-connection-its-work-needs.md) (`dialOpts` is the copy of pg.zig's URL parser)

## Context

`dialOpts` read a URL with no `sslmode` as plaintext. libpq's default is `prefer`, which encrypts whenever the server can, so a URL that worked from `psql` with TLS worked from nilo without it, and nobody had decided that. The password went down the socket in the clear, and no ADR said so.

Three neighbours of the same parser had the same shape of problem:

- **`pgbouncer=true` was dropped.** It is the one thing a URL says about a pooler that matters here. A pooler in transaction mode hands out a different server connection per transaction, so a statement prepared on one is missing on the next, and Postgres answers `26000` (*prepared statement does not exist*). `Opts.prepared = false` is the switch (ADR 051), but the URL that asked for it did not flip it.
- **`26000` was not handled.** pg.zig keeps its own table of what it prepared. Once the server forgot a statement, the table did not, so the connection went back to the pool and failed on every call that reached it.
- **`tcp_user_timeout` wrote the login timeout.** libpq means a socket option by it. pg.zig's parser stores the number in `auth.timeout`, the same field `connect_timeout` writes, and the later parameter won.

## Decision

**A URL with no `sslmode` is `require` for any host that is not this machine, and `disable` for one that is.** "This machine" is what the URL spells out: no host (pg.zig dials `127.0.0.1`), `localhost`, an address in `127.0.0.0/8`, `::1`, or a unix socket path. A name that only resolves to loopback is not looked up (a lookup at parse time is a network call, and its answer can change before the dial), so it gets `require`.

- **`require` encrypts and checks nothing else.** The server must offer TLS, or the connection is refused: pg.zig returns `SSLNotSupportedByServer`, and `Wire.open` logs one `warn` line saying the URL wants TLS, why, and that `sslmode=disable` connects without it knowingly.
- **`prefer` stays refused.** Anybody on the path can answer the `SSLRequest` with `N`, and the connection then carries the password in the clear while the URL looked encrypted. A default that a third party can turn off is the failure this module refuses, and it is why `dialOpts` already refuses `prefer` and `verify-ca` written out. pg.zig has no fallback and nilo adds none.
- **`verify-full` stays opt-in.** It is the safest, and it fails on every managed Postgres whose certificate chain is not in the system store, until a `sslrootcert` is given. A default that stops a working deployment on upgrade for a reason the URL does not show is not one a default can carry.
- **TLS is always in the build.** pg.zig links tls.zig whenever `-Dsql` is on (ADR 066), so there is no build in which `require` cannot be honoured and no "built without TLS" branch. `-Dtls` (ADR 212) is about the HTTP listener and does not change this.
- **An explicit `sslmode` wins over the default in both directions.** `sslmode=require` on `localhost` encrypts, `sslmode=disable` on a remote host does not. `sslrootcert` beside anything but `verify-full` is still refused, and the default counts as "not `verify-full`".

**`pgbouncer=true`, and `pool_mode=transaction` or `statement`, turn `Opts.prepared` off for that `Db`.** `Db.init` asks the Wire (`urlIsPooled`) because `planOf` is read from the first statement. A value that is not `true` or `false` (`pgbouncer=ture`) is refused, since reading it as "no pooler" would be a `Db` that fails on its first transaction. The cost is one Parse per call, the 12 µs ADR 051 measured, paid only by a URL that said it sits behind a pooler.

**`26000` is handled like a plan that went away: forgotten and sent once more.** `replanned` drops pg.zig's copy (`deallocate` removes it before it asks the server, and the server's own `26000` for a name it never had is the expected answer and is dropped), then the statement is prepared again and sent. The code alone is not enough, since `26000` also names a missing cursor or portal; the message must read *prepared statement … does not exist*. Inside a transaction the refusal has aborted it, so the answer is `RolledBack` and the plan is forgotten when the transaction ends, as for a stale result type.

**Once is enough.** The retry prepares and sends in the same call, so it fails only if the server connection changed between the halves of one call. That is what a transaction-mode pooler does on every call, no number of retries cures it, and the answer is `pgbouncer=true`. The second `26000` is reported with a line saying so, instead of retried.

**`tcp_user_timeout` is refused.** pg.zig has no way to set the socket option, and reading it as the login timeout made a URL that said one thing do another. `connect_timeout` (seconds) is the parameter that bounds the login. Nothing else was honoured by it, so refusing it costs a deployment one deleted parameter.

## What was rejected

**Reading a URL with no `sslmode` as libpq's `prefer`.** pg.zig does not do it, and building it here would mean an `SSLRequest`, a fall back to a second plaintext dial on `N`, and a downgrade that anyone on the path can trigger. It is the exact case the refusal of `sslmode=prefer` in `dialOpts` exists for.

**Plaintext by default, the position before this.** Cheapest, and the URL a developer copies from a managed database's dashboard without `sslmode` sent its password unencrypted.

**`require` for every host, loopback included.** A local development database and a sidecar on the same machine pay a TLS handshake per connection and about 33 KB of record buffers per pooled connection (`tls.input_buffer_len` 16,645 plus `output_buffer_len` 16,469 bytes, so 331 KB for a pool of ten) for a link no other machine can see. Most test databases do not have TLS on, and every developer's first run would fail on it.

**`verify-full` by default.** See above: safe, and breaks every managed database until a CA is configured.

**Looking the name up to decide whether it is loopback.** See above.

**Reading `tcp_user_timeout` as its libpq meaning.** Would need a socket option pg.zig does not expose, and reaching past it is a pg.zig patch for a parameter almost nobody sets on purpose.

## Consequences

- **Breaking: a URL to a remote host with no `sslmode` now requires TLS.** A server without it refuses the connection, and the `warn` line says how to opt out. The fix is one line: append `?sslmode=disable` (or `&sslmode=disable`) to a database that is meant to be plaintext, for example a Postgres in a compose network that the app reaches by its service name. `localhost`, `127.0.0.1`, `::1` and unix sockets are unchanged.
- **Breaking: `tcp_user_timeout` is refused.** Replace it with `connect_timeout=<seconds>`.
- **Costs per axis (ADR 017).** Allocations per request: none, the change is at connect time. Memory per idle connection: nothing on the HTTP side; each pooled Postgres connection to a remote host holds about 33 KB of TLS record buffers where it held none. Throughput: a remote database now pays record encryption on every byte; not measured here, and the rule for it is that a link that leaves the machine is the one that should be encrypted. Binary size: nothing, the TLS code was already linked.
- **A remote `verify-full` is still on the caller.** `require` proves the bytes are encrypted and not who the server is, so anybody able to answer on the address can still be the server. The guide says so beside the parameter.
- **A name that resolves to loopback gets `require`.** `db` in `/etc/hosts` needs `sslmode=disable`.
- **The reconnector does not log this refusal.** A dial that fails after startup (`connect_on_init = 0` and no boot work asking for one) fails inside pg.zig's background thread, and the first request that needs the pool sees `Disconnected`. `Wire.open` logs only when the dial happens in it.
- **The `26000` retry is not tested against a live pooler.** The recognition and the two code paths are unit-tested; the `Fake` Wire has no `replanned`.
