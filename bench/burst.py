#!/usr/bin/env python3
"""Does a burst of connections get through, or does the kernel drop some?

The listen backlog is how many completed handshakes the kernel holds for
`accept`. Past it a SYN is dropped — not refused — and the client's TCP
retries it a second later, so what a person sees is a p99 on connection
setup of one second against an accept loop that was never busy. Until ADR
0271 nilo left it at zio's 128, and a benchmark opening a thousand sockets at
once found out. This is the regression check, the way `fdlimit.py` is
ADR 0265's.

    zig build -Doptimize=ReleaseFast
    python3 bench/burst.py --cmd ./zig-out/bin/nilo-hello --port 8787 --conns 1000

`--conns` sockets are put into non-blocking `connect()` back to back, then
polled until every one has finished connecting or `--deadline` seconds have
passed. What is reported is how long each connect took — the median, the
p99, the worst, and how many took longer than `--slow` seconds, which is a
retransmit — and the kernel's own count of what it dropped, read from
`/proc/net/netstat` before and after: `ListenOverflows` is a handshake that
completed with nowhere to go, `ListenDrops` is every drop at the listener.
Both are machine-wide counters, so run it on a quiet box.

The pass line is zero drops and nothing slow. Run it against a before and
an after, not against a number quoted from somewhere else.
"""

import argparse
import errno
import os
import select
import socket
import subprocess
import sys
import time


def netstat_tcpext():
    """The TcpExt counters from /proc/net/netstat, as a dict. Linux only."""
    try:
        with open("/proc/net/netstat") as f:
            lines = f.read().splitlines()
    except OSError:
        return {}
    out = {}
    for i in range(0, len(lines) - 1, 2):
        head, vals = lines[i].split(), lines[i + 1].split()
        if head[0] == "TcpExt:":
            out = dict(zip(head[1:], map(int, vals[1:])))
    return out


def burst(host, port, conns, deadline):
    """Open `conns` sockets at once; return a list of seconds-to-connect, one
    per socket, with None for the ones that never made it."""
    socks = []
    started = time.monotonic()
    for _ in range(conns):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setblocking(False)
        err = s.connect_ex((host, port))
        if err not in (0, errno.EINPROGRESS):
            s.close()
            socks.append(None)
            continue
        socks.append(s)

    took = [None] * conns
    pending = {s.fileno(): i for i, s in enumerate(socks) if s is not None}
    poller = select.poll()
    for fd in pending:
        poller.register(fd, select.POLLOUT | select.POLLERR | select.POLLHUP)
    while pending and time.monotonic() - started < deadline:
        for fd, ev in poller.poll(100):
            i = pending.pop(fd, None)
            if i is None:
                continue
            poller.unregister(fd)
            s = socks[i]
            if s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0 and not (ev & (select.POLLERR | select.POLLHUP)):
                took[i] = time.monotonic() - started
    for s in socks:
        if s is not None:
            s.close()
    return took


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cmd", help="the server to start; leave it out to hit one already running")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--conns", type=int, default=1000, help="sockets opened in one go")
    p.add_argument("--rounds", type=int, default=3, help="bursts, with a pause between")
    p.add_argument("--pause", type=float, default=1.0, help="seconds between bursts")
    p.add_argument("--deadline", type=float, default=5.0, help="seconds to wait for the last connect")
    p.add_argument("--slow", type=float, default=0.5, help="a connect over this took a retransmit")
    p.add_argument("--warmup", type=float, default=1.0)
    args = p.parse_args()

    server = None
    if args.cmd:
        server = subprocess.Popen(args.cmd.split(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(args.warmup)
    try:
        before = netstat_tcpext()
        worst_slow = 0
        for r in range(args.rounds):
            took = burst(args.host, args.port, args.conns, args.deadline)
            done = sorted(t for t in took if t is not None)
            lost = args.conns - len(done)
            slow = sum(1 for t in done if t > args.slow)
            worst_slow = max(worst_slow, slow + lost)
            if done:
                p50 = done[len(done) // 2]
                p99 = done[min(len(done) - 1, int(len(done) * 0.99))]
                print(
                    f"round {r + 1}: {len(done)}/{args.conns} connected, "
                    f"p50 {p50 * 1000:.1f} ms, p99 {p99 * 1000:.1f} ms, max {done[-1] * 1000:.1f} ms, "
                    f"{slow} took over {args.slow:g} s, {lost} never did"
                )
            else:
                print(f"round {r + 1}: nothing connected")
            time.sleep(args.pause)
        after = netstat_tcpext()

        deltas = {k: after.get(k, 0) - before.get(k, 0) for k in ("ListenOverflows", "ListenDrops")}
        print(f"kernel: ListenOverflows +{deltas['ListenOverflows']}, ListenDrops +{deltas['ListenDrops']}")
        ok = worst_slow == 0 and deltas["ListenDrops"] == 0
        print("\nPASS: every burst got through at once" if ok else "\nFAIL: the backlog dropped connections and the client had to retry")
        return 0 if ok else 1
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    sys.exit(main())
