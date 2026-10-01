# A live test skips on a laptop and fails on CI

**Status:** accepted
**Topic:** [testing](../design/testing.md)

## Context

The tests in `sql/live.zig`, `sql/severed.zig` and `job/live.zig` need a Postgres, and with no URL they return `SkipZigTest`. That is right on the machine of somebody who cloned the repository to read it, and it is what keeps `zig build test-sql` a loop that needs nothing running. On CI it was the same code path: the workflow sets `DATABASE_URL`, and nothing noticed if it stopped. Losing the variable turned 124 tests green without running one, and a skip prints nothing a passing run is read for.

The other way a live suite failed to fail was a transaction a test forgot to end. It keeps its locks on the server, and the next statement that wants one, most often the next test's fixture `DROP TABLE`, waits for it. That wait has no bound on the client, since a statement is not a wait for a pooled connection, so the run hung at no CPU until somebody killed it.

## Decision

**`test-sql` fails before it runs anything when `$CI` is set and no URL is given.** `build.zig` reads `$CI`, which GitHub Actions and every other runner set, into `-Ddatabase-required`, and with no URL hangs a failing step naming both variables off `test-sql`. `-Ddatabase-required=false` is the way out for a runner with no Postgres on purpose. The skip itself is unchanged, so a laptop with no database still runs the loop.

**`test-s3` follows the same rule** through `-Ds3-required`, failing under `$CI` when `S3_ENDPOINT`, `S3_ACCESS_KEY` or `S3_SECRET_KEY` is missing, since `s3/live.zig` skips without all three; an audit found eleven live tests that losing one variable would have turned green. The s3 suite sat on `test`, which the macOS job runs with `$CI` set and no object store, so the suite is its own step, `test-s3-suite`, which `test` depends on, and `test-s3` is the suite plus the rule, which `test-all` depends on. `test-fetch` has the same silent skip and does not have the rule yet.

**Every connection a live test dials gives up on a lock after ten seconds, and loses an idle transaction after ten.** `build.zig` appends `options=-c lock_timeout=10s -c idle_in_transaction_session_timeout=10s` to the URL it compiles into `live_config`, unless the URL sets `options` itself. The server enforces both, so the bound holds for every harness and every connection, a replacement dialled mid-test included, without code in any of them.

**A test that ends with a connection still out fails, and says so.** `Live.close` asks the pool how many connections are in use and logs at `err` if any are, which is how a `defer` fails a Zig test: "the test ended with 1 of its pool's connections still out: a transaction or a stream it never closed".

This needed the URL to carry `options`, which `dialOpts` refused as something pg.zig's startup message had no room for. It has had room since the pin carried lalinsky's `2907296` ([ADR 043](./043-a-deadline-needs-a-connection-you-hold.md)), so `options` and `client_encoding=UTF8` are now handed to the server in the startup message.

## What it costs

Nothing a user's program runs: the three changes are in `build.zig` and the test harness, and carrying `options` is a map `Pool.init` copies once. A live test that waits on a lock for more than ten seconds on purpose now fails; none does.

## What was rejected

- **Counting skips in the build runner.** `zig build` reports skipped tests in its summary and has no switch to fail on one, and a skip for a reason other than a missing URL (a unix socket the proxy cannot stand in front of, a job test that runs in Debug only) is deliberate.
- **Reading `DATABASE_URL` inside the test and failing there.** The URL is a build input on purpose, so a given binary connects to one fixed place (`live.zig`'s header); the rule belongs where the URL is read.
- **A `SET` per connection in each harness.** Four harnesses and a connection pg.zig redials on its own would each need it, and a harness that forgot would be the one that hangs.
- **A `statement_timeout` for the live tests.** It would bound the leak too, and it would also cut off the deadline and cancellation tests, which sleep inside a statement on purpose.

## Consequences

- A CI job that runs `test-all` needs a database or `-Ddatabase-required=false`. The macOS job runs `test`, which builds no live test.
- A leaked transaction costs a failed test and at most ten seconds for the next one, where it cost the run.
