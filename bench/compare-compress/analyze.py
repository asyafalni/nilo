#!/usr/bin/env python3
"""Median and spread per (body, codec) over the interleaved reps of one or
more harness CSV runs. Usage: analyze.py run1.csv [run2.csv ...]"""
import sys, os, statistics, collections
COL = os.environ.get('COL', 'cpu')  # cpu (thread CPU time) or wall

rows = collections.defaultdict(list)
size = {}
outb = {}
order_b, order_c = [], []
for path in sys.argv[1:]:
    for line in open(path):
        if line.startswith('#') or line.startswith('rep,') or line.startswith('EXIT') or ',' not in line:
            continue
        f = line.strip().split(',')
        rep, body, n, codec, out = f[:5]
        us = f[5] if len(f) == 6 or COL == 'cpu' else f[6]
        rows[(body, codec)].append(float(us))
        size[body] = int(n)
        outb[(body, codec)] = int(out)
        if body not in order_b: order_b.append(body)
        if codec not in order_c: order_c.append(codec)

print(f"{'body':15} {'in B':>9} {'codec':15} {'out B':>9} {'ratio':>6} {'median us':>11} {'min':>10} {'max':>10} {'spread':>7} {'n':>3} {'MB/s':>7}")
for b in order_b:
    for c in order_c:
        v = rows.get((b, c))
        if not v: continue
        med = statistics.median(v)
        spread = (max(v) - min(v)) / med * 100
        print(f"{b:15} {size[b]:>9} {c:15} {outb[(b,c)]:>9} {outb[(b,c)]/size[b]*100:>5.1f}% {med:>11.2f} {min(v):>10.2f} {max(v):>10.2f} {spread:>6.0f}% {len(v):>3} {size[b]/med:>7.0f}")
    print()
