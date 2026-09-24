#!/usr/bin/env python3
"""Does the server survive running out of file descriptors?

Until ADR 194 it did not: `accept` failed with `ProcessFdQuotaExceeded`, the
accept loop returned on anything but a timeout, and `listen()` ended with a
clean "nilo stopping" in the log — at about a thousand connections on a
default `ulimit -n`, well short of `max_connections`. This is the regression
check, the way `shutdown.py` is ADR 077's.

    zig build bench-stream-server -Doptimize=ReleaseFast
    python3 bench/fdlimit.py --cmd ./zig-out/bin/nilo-bench-stream-server \\
        --port 8790 --path /health

The server is started under a descriptor limit of `--nofile` (64), and
`--conns` (200) connections are opened and held. The ones past the limit
cannot be accepted: they sit in the kernel's backlog, which is the correct
place for them. Then every held connection is closed, and one fresh request
is made. A server that answers it is a server that waited the shortage out;
one that does not — the process has exited, or the connect is refused — is
the failure this exists to catch.

`--nofile` is the process's soft limit, set with `prlimit` in the child
before `exec`, so nothing about the calling shell changes.
"""

import argparse
import os
import resource
import socket
import subprocess
import sys
import time


def one_request(host, port, path, timeout):
    """One request on a fresh connection; the status line, or None."""
    try:
        s = socket.create_connection((host, port), timeout=timeout)
    except OSError as e:
        return None, f"connect: {e}"
    try:
        s.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
        buf = b""
        while b"\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                return None, "closed before a status line"
            buf += chunk
        return buf.split(b"\r\n")[0].decode(errors="replace"), None
    except OSError as e:
        return None, f"read: {e}"
    finally:
        s.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cmd", required=True, help="the server to start")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/")
    p.add_argument("--nofile", type=int, default=64, help="the child's RLIMIT_NOFILE")
    p.add_argument("--conns", type=int, default=200, help="connections to open and hold")
    p.add_argument("--warmup", type=float, default=1.0)
    p.add_argument("--hold", type=float, default=2.0, help="seconds the shortage lasts")
    p.add_argument("--timeout", type=float, default=5.0)
    args = p.parse_args()

    def limited():
        resource.setrlimit(resource.RLIMIT_NOFILE, (args.nofile, args.nofile))

    server = subprocess.Popen(
        args.cmd.split(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        preexec_fn=limited,
        env={**os.environ, "PORT": str(args.port)},
    )
    held = []
    try:
        time.sleep(args.warmup)
        status, why = one_request(args.host, args.port, args.path, args.timeout)
        if status is None:
            print(f"the server never answered at all: {why}")
            return 2
        print(f"before the shortage: {status}")

        # Past the limit these connect — the kernel completes the handshake
        # from the backlog — and are never accepted. That is the shortage.
        for _ in range(args.conns):
            try:
                held.append(socket.create_connection((args.host, args.port), timeout=args.timeout))
            except OSError:
                break
        print(f"holding {len(held)} connections against a limit of {args.nofile} descriptors")
        time.sleep(args.hold)

        alive = server.poll() is None
        print(f"during it: the process is {'alive' if alive else 'GONE'}")

        for s in held:
            s.close()
        held.clear()
        # The backoff caps at a second; give it one and a half to notice.
        time.sleep(1.5)

        status, why = one_request(args.host, args.port, args.path, args.timeout)
        if status is None:
            print(f"after it: no answer — {why}")
        else:
            print(f"after it: {status}")
        ok = alive and status is not None and " 200 " in status
        print("\nPASS: the server waited the shortage out" if ok else "\nFAIL: the shortage took the server down")
        return 0 if ok else 1
    finally:
        for s in held:
            s.close()
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        err = server.stderr.read().decode(errors="replace")
        lines = [l for l in err.splitlines() if "descriptor" in l or "accept" in l]
        if lines:
            print("\nwhat the server said:")
            for l in lines[:6]:
                print("  " + l)


if __name__ == "__main__":
    sys.exit(main())
