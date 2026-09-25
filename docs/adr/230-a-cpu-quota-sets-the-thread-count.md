# A CPU quota sets the thread count

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Extends:** [ADR 010](./010-shared-services-need-a-lock-from-the-bulkhead.md), which set `threads` at one per core, and [ADR 211](./211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md), whose compressors are sized to the same number.
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md).
**Found by:** reading [dusty](https://github.com/lalinsky/dusty)'s `cgroup.zig`, which sizes its accept loops from the CPUs the process may use, against `threadCount` in `http/engine/zio.zig`, which read `std.Thread.getCpuCount()` and nothing else.

## Context

`threads = 0` meant one executor per core `getCpuCount` reports, and `getCpuCount` reads the affinity mask. A container's CPU limit is not in the mask: `docker --cpus=2`, a Kubernetes CPU limit and systemd's `CPUQuota=` are a quota the kernel's CFS bandwidth controller enforces per period, 100 ms by default, and a process inside one sees every core of the host. So nilo in a two-CPU container on a sixteen-core host started sixteen executors, and ADR 211 gave each a compressor. Sixteen threads spend two CPUs' worth of a period in its first 12.5 ms and are then held until the next one begins, whatever was half way through.

On the 9700X, the server on CPUs 0–7 and gcannon on 8–15, `/users/1` over 512 keep-alive connections, three interleaved pairs, the old count under a quota of two CPUs was 749–758K req/s with a **p99.9 of 71 ms**, and under four CPUs 1.48M with a p99.9 of 36 ms. Both tails are the throttle period showing through.

A second fault sat beside it. zio's executor id is a `u6`, so it runs at most 64 executors, and `ExecutorCount.exact` asserts that without a message. On a machine with more than 64 cores the default asked for more, and so did any `threads` past 64: a panic in ReleaseSafe and undefined behaviour in ReleaseFast.

## Decision

**With `threads` left at 0, a CPU quota sets the count: the quota rounded up, and one more, never past the cores the mask allows and never past 64.** No quota, or a quota as large as the machine, keeps one per core. The quota is the tightest of the process's own cgroup and every one above it, because a limit usually sits on a parent: a pod's, or a slice's. v2's `cpu.max` is read along the path in `/proc/self/cgroup`; a v1 host has `cpu.cfs_quota_us` over `cpu.cfs_period_us`. Anything unreadable is no quota, which is the count this replaces.

The one more is measured, not a margin. At this load an executor is not busy for the whole of its time (two threads on two unlimited cores used 1.37 of them), so a count equal to the quota leaves part of it unspent, and a thread past it fills the gaps. Swept on one CPU set with the count fixed by hand:

| quota | count = quota | **quota + 1** | quota + 2 | the old count |
|---|---|---|---|---|
| 1 CPU | 350K, p99.9 27 ms | **487–495K**, 32–33 ms | 462–470K, 56–58 ms | |
| 2 CPUs | 694–697K, 0.93–0.97 ms | **917–932K**, 9.9 ms | 900–909K, 35 ms | 748–758K, 70–71 ms |
| 4 CPUs | 1.27–1.31M, 0.53–0.59 ms | **1.56–1.57M, 0.46–0.49 ms** | 1.60–1.62M, 10–11 ms | 1.48–1.49M, 35–36 ms |

Quota plus one was the best count on throughput at every quota and, at four, on the tail as well. At two it trades a 1 ms tail for a third more throughput, and against the old count it is ahead on both. The new rule against the old, interleaved: **2 CPUs, 749–758K → 919–928K and a p99.9 of 71 ms → 10–11 ms; 4 CPUs, 1.48–1.49M → 1.53–1.56M and 36 ms → 0.45–0.53 ms**; no quota, 2.14M on both. zio has the same reader and is not used for this: it floors a quota at two before returning it, so one CPU and two arrive as the same number, and they want different counts.

**A count past 64 is held to 64**, whether it was `threads` or the default: the server runs the most it can, and the line that says it is listening gives the number.

**When the count is below the cores, startup says why**, on the line after the one that gives the count: `nilo runs 3 thread(s) of the 16 core(s) it can see: its CPU quota is 2.00, and a thread past the quota fills the time the others wait`. A number with no reason beside it is how sixteen threads on two CPUs went unnoticed.

## What it costs

Nothing on the memory or request axes: a few small files read once at startup, before the loop exists, with raw syscalls and stack buffers.

**5.7 KB of every stripped ReleaseFast binary**: `examples/hello` +5,680 B and `examples/rest` +5,200 B in [ADR 017](./017-the-trade-budget-has-four-axes.md)'s running total, and `nilo-hello` 979,112 → 984,792 bytes: about 2.2 KB for the reader and 3.6 KB for the log line, because every format string compiles to a function of its own. It was 29 KB as first written, with the quota an `f64` whose formatting came along for the one line; it is integer thousandths of a CPU now, and the cgroup path is copied rather than formatted.

## What was rejected

**zio's `ExecutorCount.auto`**, which reads the same files and was the first version of this change. Its floor of two is right for a count equal to the quota and wrong for one past it.

**The quota alone, Go's `GOMAXPROCS` rule.** The tail at two CPUs is ten times better than quota plus one, and a quarter of the throughput is gone to get it. A service that wants that trade sets `threads`.

**Refusing a `threads` past 64 at `listen()`, in words.** 2.9 KB of every binary for a message whose only advice is "set 64", which is what holding it to 64 does.

**Only the process's own cgroup**, which is what zio and dusty read. A limit set on a Kubernetes pod or a systemd slice is on a parent and would not be seen.

## Consequences

- The measurement is loopback, where part of a request's kernel work is charged to the client. On a real NIC more of it may land on the server's cgroup, which would make an executor busier and the one more cost more tail. **What would settle it:** the same sweep behind a real network, or HttpArena's CPU-limited profile.
- `bench/result/http.md` has the runs; a test in `http/engine/zio.zig` holds the rule and the parsing, and a quota on a parent slice was checked by hand with `systemctl --user set-property`.
