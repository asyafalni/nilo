# 0265 — an accept loop that is out of descriptors waits

**Status:** accepted
**Applies:** [ADR 0018](./0018-the-trade-budget-has-three-axes.md),
[ADR 0197](./0197-a-server-past-its-limit-says-so-at-once.md).
**Found by:** reading [dusty](https://github.com/lalinsky/dusty)'s accept loop
(`src/server.zig`, `Accept failed: …; retrying`) against nilo's.

## Context

`max_connections` defaults to 10,000. `ulimit -n` defaults to 1,024 on most
Linux shells, and a container inherits whatever its runtime set. The accept
loop in `http/engine/zio.zig` read:

```zig
const stream = server.accept(.{ .timeout = … }) catch |err| {
    if (err == error.Timeout) continue;
    return err;
};
```

and zio's `AcceptError` carries `ProcessFdQuotaExceeded`,
`SystemFdQuotaExceeded` and `SystemResources`. So a server that reached its
thousandth connection on a default shell did not refuse the thousand-and-first
the way ADR 0197's table says — it **returned from `listen()`**, ran the
shutdown path, and logged `nilo stopped` as if asked. Well short of its own
cap, on a condition that clears the moment any connection closes.

The zio bump to v0.18.0 the day before had fixed the sibling of this —
`ConnectionAborted`, a client that gave up while still in the backlog, which
the same `return err` also turned into a shutdown. That fix landed inside
zio's `accept`. This one cannot: running out of descriptors is the caller's
condition to wait out, and zio is right to report it.

## Decision

**Three errors from `accept` are a pause, not a failure.**
`ProcessFdQuotaExceeded`, `SystemFdQuotaExceeded` and `SystemResources` put
the loop to sleep — 5 ms the first time, doubling to a cap of one second —
and it tries again. The first failure of a run is one `warn` line naming the
error, the connections held against the cap, and the two things to change
(`ulimit -n` / `LimitNOFILE=`, or `.max_connections`); the recovery is one
`info` line. Every other error still returns, because every other error is
the listener's own.

**`listen()` reads `RLIMIT_NOFILE` and says so when it is short.** If the
soft limit is below `max_connections` plus a small headroom for the
descriptors that are not connections, one `warn` line at startup puts the
two numbers side by side, with the hard limit — which is how far
`ulimit -n` may be raised without root — and the `LimitNOFILE=` spelling.

## What it costs

Nothing on any axis of ADR 0018. The backoff is on the error path of a loop
that is otherwise unchanged; the rlimit read is one syscall at startup, before
the first accept. No allocation, no per-connection byte, no bytes of binary
worth measuring.

## Alternatives

**Raise the soft limit ourselves.** `setrlimit` up to the hard limit is one
call and what nginx's `worker_rlimit_nofile` does. Refused for now, because
the limit is a policy the person running the process set by leaving it
there, and a server that silently grants itself 65,536 descriptors is a
server that has made a decision about the machine on somebody's behalf. The
warning gives them the number; if it turns out nobody ever wants the
warning and everybody wants the raise, that is a one-line change and a new
ADR.

**Refuse to start.** The default `max_connections` is above the default
`ulimit -n`, so refusing would stop every server that changed neither — which
is every server on its first run. The bound is meant to be the machine's
memory, not the shell's default.

**Return, as before, and document the ulimit.** A paragraph nobody runs.
The failure it leaves is a server that stops under load with a clean log
line, which is the worst shape a failure can take: nothing to grep for.

**Sleep a fixed interval.** 5 ms doubling to a second is what dusty does and
what Go's `net/http` does (`5ms … 1s`); a fixed short sleep is a spin under a
sustained shortage, a fixed long one is latency under a brief one.

## Consequences

- `http/engine/zio.zig`: `accept_backoff_min_ms`, `accept_backoff_max_ms`,
  the three-arm `switch` in the accept loop, `warnIfDescriptorsShort` before
  it.
- [Deploying](../guide/deploying.md#when-a-bound-is-hit) gains a row for the
  descriptor limit, between `max_connections` and `max_in_flight`.
- `docs/reference/app.md`: `max_connections` names the warning.
- Not held by a test in the suite: driving `accept` into `EMFILE` needs a
  real listener and an `rlimit` on the test process. `bench/fdlimit.py` is
  the regression check, the way `bench/shutdown.py` is ADR 0098's: it starts
  a server under `ulimit -n 64`, opens more connections than that, closes
  them, and asks whether the server still answers.
