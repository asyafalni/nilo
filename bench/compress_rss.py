#!/usr/bin/env python3
"""What response compression keeps resident on a running server (ADR 248).

Starts `bench/compress_server.zig`'s binary, waits for it, and reads
/proc/<pid>/smaps_rollup at three points: idle after start, after a load
that does not ask for gzip (the control), and after the same load asking
for it. The load is enough keep-alive connections that every one of the
server's sixteen threads serves some of them, so every compressor in the
pool has been used by the end.

    python3 bench/compress_rss.py ./zig-out/bin/nilo-bench-compress-server

Prints Rss, AnonHugePages and Private_Dirty in bytes at each point, and in
a libdeflate build the Rss of the pool's own mapping: the one area the
kernel marks `nh` (no huge pages) that is sixteen whole compressors long,
16 x 671,744 bytes at level 6. Other areas carry `nh` too, so it is found
by its shape. One fresh server per run, because RSS does not come back
down.

A borrow takes the lowest free slot and spans no wait, so a client that
cannot keep sixteen requests compressing at once uses fewer than sixteen
compressors: the growth under the gzip load is the slots this load used,
and the `nh` figure says how many pages of them.
"""
import http.client
import subprocess
import sys
import threading
import time

PORT = 8795
CONNECTIONS = 128
REQUESTS = 200


def rollup(pid):
    fields = {}
    with open(f"/proc/{pid}/smaps_rollup") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[2] == "kB":
                fields[parts[0].rstrip(":")] = int(parts[1]) * 1024
    return fields


def pool_rss(pid):
    """Rss of the libdeflate pool's mapping, or None in a build without one."""
    areas = []
    size = rss = 0
    with open(f"/proc/{pid}/smaps") as f:
        for line in f:
            head = line.split()
            if head and "-" in head[0] and not head[0].endswith(":"):
                start, end = head[0].split("-")
                size = int(end, 16) - int(start, 16)
            elif line.startswith("Rss:"):
                rss = int(line.split()[1]) * 1024
            elif line.startswith("VmFlags:") and " nh" in line:
                areas.append((size, rss))
    per = [(s, r) for s, r in areas if s % (16 * 4096) == 0 and 128 << 10 <= s // 16 <= 2 << 20]
    sizes = {s for s, _ in per}
    if len(per) != 1 or len(sizes) != 1:
        return None
    return per[0][1]


def drive(gzip):
    headers = {"Accept-Encoding": "gzip"} if gzip else {}
    errors = []

    def one():
        try:
            conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
            for _ in range(REQUESTS):
                conn.request("GET", "/json", headers=headers)
                r = conn.getresponse()
                body = r.read()
                coded = r.getheader("Content-Encoding")
                if (coded == "gzip") != gzip or not body:
                    errors.append(f"Content-Encoding {coded!r}, {len(body)} bytes")
                    return
            conn.close()
        except Exception as e:  # noqa: BLE001 - reported, not swallowed
            errors.append(repr(e))

    threads = [threading.Thread(target=one) for _ in range(CONNECTIONS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        sys.exit(f"load failed: {errors[0]} ({len(errors)} connections)")


def wait_up():
    for _ in range(200):
        try:
            c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=1)
            c.request("GET", "/json")
            c.getresponse().read()
            c.close()
            return
        except OSError:
            time.sleep(0.05)
    sys.exit("server did not come up")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    server = subprocess.Popen([sys.argv[1]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_up()
        time.sleep(0.5)
        points = [("idle", rollup(server.pid), pool_rss(server.pid))]
        drive(gzip=False)
        points.append(("plain load", rollup(server.pid), pool_rss(server.pid)))
        drive(gzip=True)
        points.append(("gzip load", rollup(server.pid), pool_rss(server.pid)))
        print(f"{'point':<12} {'Rss':>12} {'AnonHugePages':>14} {'Private_Dirty':>14} {'pool Rss':>10}")
        for name, f, pool in points:
            shown = "-" if pool is None else f"{pool:,}"
            print(f"{name:<12} {f['Rss']:>12,} {f.get('AnonHugePages', 0):>14,} {f['Private_Dirty']:>14,} {shown:>10}")
        print(f"gzip - plain {points[2][1]['Rss'] - points[1][1]['Rss']:>12,}")
    finally:
        server.terminate()
        server.wait()


if __name__ == "__main__":
    main()
