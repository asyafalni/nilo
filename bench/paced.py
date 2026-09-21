#!/usr/bin/env python3
"""What a request costs the server when the server is not busy.

`wrk` asks how fast a server can go, and everything in `bench.sh` is that
question. Real servers spend almost all of their time nowhere near it, and
what they cost there is a different number: the wakeups, the timers, the
context switches a request pays when nothing amortises them. This client
offers a fixed rate rather than as much as it can — `--rate` requests a
second, spread round-robin over `--conns` keep-alive connections, one in
flight per connection — and reads the server's CPU out of `/proc/<pid>/stat`
over exactly the window the load was applied in. The figure that matters is
**µs of CPU per request**, with the voluntary context switches and minor
page faults per request beside it, since those are where the µs go.

    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/nilo-hello &
    python3 bench/paced.py --pid $! --port 8787 --path /health --conns 64 --rate 2000 --secs 10

It is the instrument behind ADR 0272 (a second context switch per request
at low load, from the scheduler's doze) and the idle-page reading in
`bench/result/http.md`. Python paces to about a hundred microseconds, so
keep `--rate` under ~10,000; the server's CPU is what is measured, not the
client's, and the client's own share of the box shows only in the latency
columns. `--warm` seconds run first and are discarded.
"""

import argparse, os, select, socket, sys, time

CLK = os.sysconf("SC_CLK_TCK")

def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    return int(parts[11]) + int(parts[12]), int(parts[7])  # utime + stime, minflt

def ctxt(pid):
    v = nv = 0
    for t in os.listdir(f"/proc/{pid}/task"):
        try:
            with open(f"/proc/{pid}/task/{t}/status") as f:
                for line in f:
                    if line.startswith("voluntary_ctxt_switches"): v += int(line.split()[1])
                    elif line.startswith("nonvoluntary_ctxt_switches"): nv += int(line.split()[1])
        except OSError:
            pass
    return v, nv

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--pid", type=int, required=True)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/health")
    p.add_argument("--conns", type=int, default=64)
    p.add_argument("--rate", type=float, default=2000)
    p.add_argument("--secs", type=float, default=10)
    p.add_argument("--warm", type=float, default=2)
    a = p.parse_args()

    req = f"GET {a.path} HTTP/1.1\r\nHost: x\r\n\r\n".encode()
    socks = []
    for _ in range(a.conns):
        s = socket.create_connection((a.host, a.port))
        s.setblocking(False)
        socks.append(s)
    fdmap = {s.fileno(): s for s in socks}
    poller = select.poll()
    for s in socks:
        poller.register(s.fileno(), select.POLLIN)

    interval = 1.0 / a.rate
    sent = got = 0
    latencies = []
    inflight = {}  # fd -> send time
    i = 0

    def run(secs, record):
        nonlocal sent, got, i
        start = time.perf_counter()
        nxt = start
        end = start + secs
        while True:
            now = time.perf_counter()
            if now >= end:
                break
            while now >= nxt and now < end:
                # next idle connection, round robin
                for _ in range(a.conns):
                    s = socks[i % a.conns]; i += 1
                    if s.fileno() not in inflight:
                        s.send(req); inflight[s.fileno()] = now; sent += 1
                        break
                nxt += interval
            wait = max(0.0, min(nxt - time.perf_counter(), 0.001))
            for fd, ev in poller.poll(wait * 1000):
                data = fdmap[fd].recv(65536)
                if not data:
                    raise SystemExit("server closed a connection")
                # small responses: one recv is one response
                n = data.count(b"HTTP/1.1 ")
                got += n
                t0 = inflight.pop(fd, None)
                if record and t0 is not None:
                    latencies.append(time.perf_counter() - t0)
        # drain
        t_end = time.perf_counter() + 0.5
        while inflight and time.perf_counter() < t_end:
            for fd, ev in poller.poll(50):
                data = fdmap[fd].recv(65536)
                got += data.count(b"HTTP/1.1 ")
                inflight.pop(fd, None)

    run(a.warm, False)
    sent = got = 0
    latencies.clear()
    c0, f0 = cpu_ticks(a.pid); v0, nv0 = ctxt(a.pid); t0 = time.perf_counter()
    run(a.secs, True)
    t1 = time.perf_counter(); c1, f1 = cpu_ticks(a.pid); v1, nv1 = ctxt(a.pid)
    secs = t1 - t0
    cpu_s = (c1 - c0) / CLK
    latencies.sort()
    p50 = latencies[len(latencies) // 2] * 1e6 if latencies else 0
    p99 = latencies[int(len(latencies) * 0.99)] * 1e6 if latencies else 0
    print(f"sent {sent} got {got} in {secs:.2f}s = {got / secs:,.0f} req/s (target {a.rate:,.0f}); "
          f"server CPU {cpu_s:.2f}s = {cpu_s / secs * 100:.1f}% = {cpu_s / max(got, 1) * 1e6:.1f} us/req; "
          f"ctxt switches vol {v1 - v0} nonvol {nv1 - nv0} = {(v1 - v0) / max(got, 1):.2f} vol/req; "
          f"minflt {(f1 - f0) / max(got, 1):.2f}/req; p50 {p50:.0f}us p99 {p99:.0f}us")

if __name__ == "__main__":
    main()
