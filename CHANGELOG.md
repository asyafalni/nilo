# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/todo.md`](./docs/todo.md), and what was refused or answered is in
[`docs/decided.md`](./docs/decided.md).

## Unreleased

### Breaking

- **`.min` and `.max` over an enum that sets `nilo_column` (a Postgres `ENUM`) are a compile error on the SQLite dialect**, because SQLite orders the column by the label's spelling and Postgres by the enum's declaration, so the same grouped Row named a different label on each with no error. Drop `nilo_column` from the enum so both store text, or read the first row with `.order` and `.limit = 1` ([ADR 181](docs/adr/181-the-marker-has-two-kinds-of-word.md)).
- **A `sql.Date` field refuses a column that does not arrive as `date` on a raw read inside a transaction and on a composed statement**, where an `int4` was read as a count of days since 2000. A domain over `date` still reads. Cast the column to `date` in the statement ([ADR 233](docs/adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)).
- **`nilo_jwt` verifies ES384 (`EC` keys on `P-384`) and EdDSA (`OKP` keys on `Ed25519`, RFC 8037) beside RS256 and ES256**, and the key and its curve still pick the algorithm, never the token's `alg`. `Key.Material` has a third case, `.okp = .{ .crv, .x }`, so an exhaustive `switch` over `key.material` needs one more arm; an `OKP` key that used to be skipped is now read; `key.algorithm()` follows the curve and is `""` for one with no branch (P-521, Ed448), and a token whose key is on such a curve is `error.CurveNotSupported`. `jwt.curves` is `P-256`, `P-384` and `Ed25519` ([ADR 111](docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).

- **`config.Reason` has a fifth tag, `too_many`, and `config.Failure` gains `entry`, `capacity` and `group`**, for a list setting that names more entries than it has room for. A `switch` over `Reason` with no `else` needs an arm for it ([ADR 289](docs/adr/289-a-setting-can-be-a-list-and-a-group-can-be-switched-on-by-presence.md)).

- **`fail.InFlight.read_request` is now `request_ops`**, one pointer to a read function and an allocate function, so a long `fail` message can be kept in the request arena. Only code that sets it by hand, such as a test fake, changes ([ADR 286](docs/adr/286-a-handler-may-answer-in-several-typed-statuses.md)).

### Added

- **`/metrics` publishes `nilo_session_rejected_total`**: session cookies and Bearer tokens that were sent and failed to open, so a wrong `session_secret` after a deploy shows as a climb rather than as a quiet hour. An expired one and a request that sent none are not counted, and the series appears once the first is seen. Nothing to change ([ADR 033](docs/adr/033-a-session-is-sealed-into-the-cookie.md)).

- **A handler may return a `union(enum)` whose arms are each a `nilo.Status(code, T)`**: each arm answers with its own status and body type, and the API document lists one response per arm, so a 400 carrying `{"error":"…","offset":12}` beside a 200 list stays a typed return. Two arms with one status, an arm that is not a `Status`, and `?` around the union are compile errors ([ADR 286](docs/adr/286-a-handler-may-answer-in-several-typed-statuses.md)).

- **`cors.deciding(decide, options)` asks a function of yours whether an origin is allowed, on each request that carries one**, for an allowlist that changes while the server runs (per-project allowed domains kept in a database). `decide` takes up to two services and the origin, and returns `bool`; an `Origin` that is not a well-formed origin is treated as none and never reaches it; a service it names that is not provided is refused at `listen()` ([ADR 088](docs/adr/088-an-origin-is-a-fact-about-the-deployment.md)).

- **`nilo_config` reads a list and a group switched on by presence.** `config.List(T, max)` is one variable with commas in it (`ALLOWED_ORIGINS=a,b`), with room for `max` entries fixed while compiling and no allocation, and a `?Struct` field is a group of `<FIELD>_*` variables that is null until one of them is set to something, after which its required fields are required (`SMTP_HOST` set makes `SMTP_PORT` required) and a blank variable inside it reads as not set. Two settings that would read the same variable (a plain `smtp_host` beside the group `smtp`) are a compile error naming both ([ADR 289](docs/adr/289-a-setting-can-be-a-list-and-a-group-can-be-switched-on-by-presence.md)).

- **`.tls = .unverified` on one `nilo_fetch` call (`Call` or `Begin`) skips the certificate check**, for a health or uptime check of an endpoint on a self-signed or expired certificate. It is a field of the call only, never of a `Target` or `Settings`; its connection is pooled apart from verified ones, a redirect to another origin is verified again, no server name is sent, and an IPv6 literal is `error.UnverifiedNeedsHostName` ([ADR 290](docs/adr/290-a-call-can-skip-the-certificate-check-and-only-that-call.md)).

- **`Body.buffered(buffer)` is the request body as a buffered `std.Io.Reader` over a buffer you own**, for `std.json.Reader` and line-at-a-time parsers such as NDJSON; a zero-length buffer is `error.EmptyBuffer`, so size it from the parser, never from the request. `Body.explain(err)` is public: it turns that reader's `ReadFailed` back into `BodyTooLarge`, `BodyTruncated` or `BadChunk` and passes any other error (`StreamTooLong`, `EndOfStream`) through. `Body.reader` stays unbuffered.

- **A handler can ask whether its client is still there**: `c.presence()` answers `.here`, `.half_closed` or `.gone` (`nilo.Presence`), `c.gone()` is the yes/no, `c.sleepUnlessGone(ms)` is `nilo.sleep` that returns early with `.gone`, `events.sleep(ms)` does the same inside an event stream, and `nilo.gone()` answers it from code with no Ctx (a blocking worker). A FIN after a keep-alive request is `.gone`; a FIN after `Connection: close` or HTTP/1.0 is `.half_closed` (the client may still be waiting for its response); for Events a FIN is always `.gone`. On HTTP/2 and gRPC a RST_STREAM or a connection reset is `.gone`, and a GOAWAY is not. The route is not cancelled: a handler that never asks runs as before, and `error.ClientGone` (answer: none written, logged as 499) is there to return. Nothing to change ([ADR 287](docs/adr/287-a-handler-can-ask-whether-its-client-is-still-there.md)).

### Changed

- **`cors.Origins.set` and `setSplit` refuse an origin with a space or a control byte in it** (`error.OriginNotAnOrigin`), which matched no browser's `Origin` and, echoed back, could not be written as a header. `setSplit` still trims the spaces around each entry ([ADR 088](docs/adr/088-an-origin-is-a-fact-about-the-deployment.md)).

- **A `nilo_s3` request waiting on a credential refresh stops at its route's deadline**, with `error.TimedOut`, or signs with the key it already holds if that is still good, while the refresh runs on to its own `fetch_timeout_ms` and is kept for the requests after it. Before, it waited out the whole fetch. Nothing to change ([ADR 105](docs/adr/105-a-route-can-say-how-long-it-has.md)).
- **CI runs `nilo_core`, `nilo_pw`, `nilo_jwt` and `nilo_proto`'s tests on Windows**, and Windows is now on record as supported for those four only; `config.Env`, `id.v7Now` and `nilo_cache`'s clock refuse it while compiling, and a server there runs under WSL2 ([`decided.md`](docs/decided.md)).
- **The `db.raw` first-run check says an outer-join column "may be NULL"**, and also flags a column read through an anti join (`LEFT JOIN … WHERE o.id IS NULL`), which is NULL on every row, including the `Right Anti` Postgres 16 and later write for it. A field it refuses over a `NOT NULL` key is fixed as before, with an optional field or a `coalesce` ([ADR 233](docs/adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)).
- **A SQLite migration step that times out on a lock names `busy_timeout_ms`**, the setting that applied, where it named `.lock_timeout_ms` and 5000 ms ([ADR 240](docs/adr/240-a-migration-waits-five-seconds-for-a-table.md)).
- **`id.v7Now` keys made one after another on one thread sort in the order they were made, inside a millisecond too**: the 12 bits after the version hold a counter (RFC 9562 §6.2, method 1), so rows inserted in a loop and read back by id come out in insertion order. A burst that uses up the counter runs the key's timestamp a millisecond ahead rather than breaking the order. A `v7Now` key carries 12 fewer random bits, the order is per thread, and `id.v7(entropy, ms)` is unchanged. Nothing to change ([ADR 143](docs/adr/143-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)).
- **`nilo_cache`'s shard lock spins on a read and yields its thread after 256 looks**, where it swapped on every look, and a write the shard refuses no longer takes the lock. Nothing to change ([ADR 109](docs/adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md)).
- **A JSON string is checked for UTF-8 a 32-byte block at a time whatever it holds**, where the check went a byte at a time after the first byte over `0x7f`, so a response in Japanese, Chinese, Arabic or Russian no longer pays for it. Which byte strings count as text is unchanged, and a differential test against `std.unicode.utf8ValidateSlice` holds it. Nothing to change ([ADR 096](docs/adr/096-a-byte-that-is-not-text-is-not-a-string.md)).

- **A `fail` message longer than 240 bytes is kept whole inside a request**, in the request arena up to 16 KiB, so a 400 that lists every problem reaches the client whole. Outside a request (work registered with `app.before`) it is still cut at 240 bytes, and a gRPC call is told the first KiB, since `grpc-message` is a header ([ADR 286](docs/adr/286-a-handler-may-answer-in-several-typed-statuses.md)).

- **`db.exec` and `tx.exec` read `$n` on SQLite the way `raw` does**: `$2` written before `$1` binds each value to the placeholder it names, where it bound by first appearance and could change no rows without an error. Every placeholder is written as `$1`, `$2`, … (or `?1`, `?2`, …) with none skipped, or every one as a bare `?`; a statement that mixes the two or skips a number, a `:name` placeholder, a `$3` given two values, or a value no placeholder names is `error.QueryFailed` with the reason in the Problem ([ADR 204](docs/adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).

- **A followed `nilo_fetch` redirect goes up to ten hops, where it stopped at three**, the default of Go's `net/http` and reqwest. The `.follow` buffer now bounds one URL and one Location rather than the whole chain, so ten redirects of ordinary length fit the 2 KiB `Client.get` uses. A longer chain or a loop is still `error.TooManyHttpRedirects` ([ADR 183](docs/adr/183-a-redirect-is-a-decision-with-a-name.md)).

- **Every non-2xx answer to a `nilo_s3` call leaves one `warn` line** naming the bucket, the method, the path and the status, and the `Code` when the body has one, including a bare 413 or 502 from a proxy, which failed with nothing in the log.

- **`testing.Live.start` returns once the App's boot work is over** (services started, `before` run, checks passed), not once the port is bound, so a test that seeds through a service right after it no longer races the boot ([ADR 244](docs/adr/244-a-handler-is-given-the-loop-it-runs-on.md)).

- **`Events.live()` also reads what `events.sleep` found**, so a loop that sleeps through `events.sleep` ends the moment the client closes, not on its next write. Nothing to change.

### Fixed

- **Reading the empty body of a `nilo_fetch` answer that has none (a 204, a 304, a HEAD's) no longer segfaults on aarch64.** The body was std's `Reader.ending`, which at 0.17.0 sits in read-only memory while a read writes its position; an `Exchange` now carries an empty reader of its own. Nothing to change ([ADR 176](docs/adr/176-an-answer-with-no-body-ends-at-its-head.md)).
- **`db generate` raises a Problem when the key moves onto a new column and the old key column is dropped in the same change**, where it added the new column as a plain one and left the table with no primary key. Write the key move as a step of its own ([ADR 123](docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
- **A `nilo_fetch` call under a route deadline stops queueing for a permit when the route's time runs out**, failing with `error.TimedOut` without dialling, where it waited for the permit and only then saw the deadline had passed. Nothing to change ([ADR 105](docs/adr/105-a-route-can-say-how-long-it-has.md)).
- **On HTTP/2, trailers a client sent for a stream the server had already answered and forgotten no longer end the connection**, which took every other call on it down with a gRPC client stream answered early. The block is decoded and ignored, as it already was for a reset stream, within the time a call's header block gets; a HEADERS on such a stream that does not end it is still a connection error. Nothing to change ([ADR 260](docs/adr/260-a-request-on-http2-runs-from-its-headers.md)).

- **A `nilo_fetch` body streamed from a `std.Io.File.Reader`, and so `putStream` from a file, no longer aborts in std's `Writer.defaultRebase`**: the framed body writer had no buffer, and a file reader whose `sendFile` answers `Unimplemented` asks its writer for room. A file now uploads 64 KiB at a time, 16 KiB at a time under a `stall_ms`, whose clock moves as each step reaches the socket; a copying reader written as a workaround can go.

## Released

Every tagged release has a page of its own, written for the person upgrading: what to do before deploying, and what is new. Every entry of a release, the whole account, is that tag's own `CHANGELOG.md`, which the page links to.

- **[v0.8.0](https://github.com/nevindra/nilo/releases/tag/v0.8.0)** ([every entry](https://github.com/nevindra/nilo/blob/v0.8.0/CHANGELOG.md)): Zig 0.17, and HTTP/2 as a framing of every request on the port HTTP/1.1 is on, with RPC as plain functions over gRPC, Connect and JSON. More mistakes refused while compiling (two path params by name, a JWT check with no issuer or audience, a `Str` handed to `spawn`), a connection ended after about 1,000 requests, and what services meet in production across `nilo_fetch`, `nilo_job`, `nilo_sql` and `nilo_s3`. Forty entries ask something of you, the page says which first.
- **[v0.7.0](https://github.com/nevindra/nilo/releases/tag/v0.7.0)** ([every entry](https://github.com/nevindra/nilo/blob/v0.7.0/CHANGELOG.md)): a long list of wrong results returned without an error, fixed, and what was missing when a log server was ported onto nilo. A failed statement that committed as success, a delete a search box could empty a table with, pages that repeated rows, a cache hit an old slot could forge, closed; routes per listener, a body limit from configuration, OpenTelemetry tracing and `nilo_proto`, Rooms shared by sockets and event streams, and a Row that reads a feed, a cursor and a column of another table. Seventy-one things to read before deploying, grouped by who meets them there.
- **[v0.6.0](https://github.com/nevindra/nilo/releases/tag/v0.6.0)**: nothing needed in front, and read line by line for what a stranger can do. HTTPS, gRPC, compression and a cross-site check behind an option or a flag; every executor accepting and a response flushed before the connection waits; a Row that carries its parent, its children or a sum; and what a client on the socket could forge, crash or read, closed. Eleven things to read before deploying, listed there.
- **[v0.5.0](https://github.com/nevindra/nilo/releases/tag/v0.5.0)** — the
  roadmap read back against the tree: a Row that says more about its own
  table and `sql.Schema` as the one value that reads it, `nilo.Verified` and
  `jwt.Keyring`, `fetch.Target`, `nilo.Text` and `nilo_check`, `nilo-dev`, a
  queue that wakes its workers. Seventy-nine entries; eight things to read
  before deploying, listed there.
- **[v0.4.0](https://github.com/nevindra/nilo/releases/tag/v0.4.0)** — one
  module, `nilo_job`, and the thirty-odd shapes a second port needed: a
  listing page in one statement, an order chosen from a closed set, a route
  answering once per key, a health page, and the two fixes that let the suite
  run on a Mac. Twelve things to read before deploying, listed there.
- **[v0.3.0](https://github.com/nevindra/nilo/releases/tag/v0.3.0)** — the
  release a real port wrote: migrations as a diff against a snapshot and the
  `db` command, deadlines and an allowance per route, a metrics page, sessions
  that expire, and eleven things to read before deploying, listed there.
- **[v0.2.0](https://github.com/nevindra/nilo/releases/tag/v0.2.0)** — 0.1.0 was
  an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and that server
  is one of its eight modules. Includes what to change when upgrading from
  0.1.0.
- **[v0.1.0](https://github.com/nevindra/nilo/releases/tag/v0.1.0)** — the first
  release, published as zfast.
