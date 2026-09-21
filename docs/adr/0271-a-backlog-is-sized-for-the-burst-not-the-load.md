# 0271 — a backlog is sized for the burst, not the load

**Status:** accepted
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0265](./0265-an-accept-loop-that-is-out-of-descriptors-waits.md).
**Found by:** reading [actix-web](https://github.com/actix/actix-web)'s
`HttpServer::backlog` (1,024, "generally set in the 64–2048 range") against
`http/engine/zio.zig`, which passed nothing to `listen` and so took zio's
128 — and then by [HttpArena](https://github.com/MDA2AV/HttpArena), whose
paced profiles open 1,024 connections in one go and reported nilo 2–2.5%
short of the offered rate with `connect` errors in the log, on a server
that was never busy.

## Context

The listen backlog is how many completed handshakes the kernel holds for
`accept`. It is a queue capacity: the kernel allocates only for the
connections actually waiting in it, so a large one costs nothing on a quiet
server and a small one costs nothing until the moment it matters. That
moment is a burst — a balancer reconnecting every client at once after a
deploy, health checks landing together, a load generator opening its
thousand sockets in a loop — and what happens past the backlog is the worst
shape a failure can take. The SYN is **dropped**, not refused. The client's
TCP retries it after one second (`tcp_syn_retries` schedule), so the
connection succeeds, late, and nothing in the server's log says anything:
the accept loop was idle, no error was returned, no counter in the process
moved. The only trace is `ListenOverflows` in `/proc/net/netstat`, and a
p99 on connection setup that reads one second.

`bench/burst.py` opens a thousand sockets back to back against
`nilo-hello` and reads that counter before and after. At a backlog of 128,
on the two-core box, **623 of the thousand took the one-second retry** —
three runs, 623, 631, 623 — and the kernel counted 1,279–1,719 drops.
Median connect time 1,040–1,076 ms. That is the shape HttpArena's
`latency-10k` run had: `rate_ratio` 0.9755 at a load of 37% of one core,
where every healthy entry sits at 0.998, and eighteen to a hundred
`connect` errors a run under the eight-CPU profile, which is a SYN whose
retry was also dropped inside zrk's two-second timeout.

## Decision

**`Options.backlog: u31 = 4096`, threaded through to `listen` on both the
IP and the unix path.** 4,096 is `net.core.somaxconn` on a current Linux,
which is what Go's `net.Listen` uses, and the kernel caps the request at
that sysctl silently — so on an old kernel whose ceiling is 128 the option
says 4,096 and the socket gets 128, and the doc comment says so.

Not 1,024, which is where actix and the first draft of this ADR put it.
At 1,024 a burst of a thousand got through clean — zero drops, five runs —
and a burst of four thousand did not: two runs of five dropped 187 and
420. At 4,096 six runs of the four-thousand burst dropped nothing. The
difference costs nothing, and the profile the arena runs `limited-conn` at
is 4,096 connections reconnecting every ten requests.

| backlog | burst of 1,000 | burst of 4,000 |
|---:|---|---|
| 128 (zio's default) | 623 / 631 / 623 retried after 1 s | not run |
| 1,024 | 0 retried, five runs | 187 and 420 retried in two runs of five |
| 4,096 | 0 retried | 0 retried, six runs |

The full record, with the connect-time percentiles, is in
[`bench/result/http.md`](../../bench/result/http.md#what-a-listen-backlog-of-128-drops).

## What it costs

Nothing on any axis of ADR 0018. A backlog is a capacity; the kernel's
per-connection allocation happens only for a connection that is actually
waiting, and a waiting connection would otherwise have been dropped and
retried, which is not cheaper. No allocation in the process, no
per-connection byte, one more field in `Options`.

## Alternatives

**Leave zio's 128 and document the sysctl.** A paragraph nobody runs, and
the sysctl is not the bound — `somaxconn` is the ceiling, and a listener
that asks for 128 gets 128 under any ceiling.

**1,024, actix's number.** Refused by the four-thousand burst above. The
one argument for a smaller backlog — that a queue is a place for latency
to hide under sustained overload — is answered by `max_connections`, which
closes a connection past the cap the moment it is accepted (ADR 0197's
table), so the queue never holds work the server will not do.

**Match `max_connections`.** Tempting arithmetic, and wrong: the backlog
is about the rate of arrival over the accept loop's drain, not about how
many are held. A server holding a hundred connections still wants a burst
of a thousand to land cleanly.

**Read `somaxconn` and ask for exactly that.** One file read at startup
for a number the kernel clamps to anyway. The clamp does the same thing
for free.

## Consequences

- `http/bulkhead.zig`: `backlog: u31 = 4096`, between `reuse_address` and
  `threads`.
- `http/engine/zio.zig`: `.kernel_backlog = options.backlog` on both
  `listen` calls; the header's list of fields the Engine reads names it.
- [Deploying](../guide/deploying.md#tuning) shows it; the reference table
  in `docs/reference/app.md` gains a row.
- Not held by a test in the suite: a SYN drop needs a real listener and a
  burst the test process would have to generate against it.
  `bench/burst.py` is the regression check, the way `bench/fdlimit.py` is
  ADR 0265's — it opens `--conns` sockets at once, reads `ListenOverflows`
  before and after, and fails on a drop or a connect over half a second.
- HttpArena's next run is the measurement that matters, and the one this
  box cannot take: whether `limited-conn` (rank 81 of 130 at 451k req/s on
  an accept loop using eighteen cores of sixty-four) and the two
  `rate_ratio` shortfalls move. The prediction is on the record so it can
  be wrong in public.
