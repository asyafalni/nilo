#!/usr/bin/env python3
"""HttpArena json-comp score model per codec, from harness CSVs.
Score ranks by rps / bpr^2 (the field minimum cancels between entries).
bpr = mean compressed body over the profile's three bodies + 91 B of head
(nilo's published 1,346 B/resp minus its std-flate-6 mean body of 1,255 B).
rps scales as 1/T with T = (1-c) + c * t/t0, c = compression's share of
per-request CPU at std-flate-6 (0.78 from nilo's own json-comp vs json-tls
CPU per request on the board: 230 vs 49 us)."""
import sys, statistics, collections
HEAD = 91
med = collections.defaultdict(list); out = {}
for p in sys.argv[1:]:
    for line in open(p):
        if not line[:1].isdigit(): continue
        f = line.strip().split(',')
        med[(f[1], f[3])].append(float(f[5])); out[(f[1], f[3])] = int(f[4])
bodies = ['arena-25', 'arena-40', 'arena-50']
codecs = sorted({c for (_, c) in med}, key=lambda c: (c.rsplit('-',1)[0], int(c.rsplit('-',1)[1]) if c.rsplit('-',1)[1].isdigit() else 0))
def stats(c):
    t = statistics.mean(statistics.median(med[(b, c)]) for b in bodies)
    o = statistics.mean(out[(b, c)] for b in bodies)
    return t, o
t0, o0 = stats('std-flate-6')
b0 = o0 + HEAD
print(f"{'codec':15} {'body B':>7} {'B/resp':>7} {'cpu us':>8} {'x std6':>6} {'score c=.2':>10} {'c=.5':>6} {'c=.78':>6}")
for c in codecs:
    if c == 'std-reset-only' or not all((b, c) in med for b in bodies): continue
    t, o = stats(c)
    bpr = o + HEAD
    s = [(1 / ((1 - k) + k * t / t0)) * (b0 / bpr) ** 2 for k in (0.2, 0.5, 0.78)]
    print(f"{c:15} {o:>7.0f} {bpr:>7.0f} {t:>8.1f} {t/t0:>6.2f} {s[0]:>10.2f} {s[1]:>6.2f} {s[2]:>6.2f}")
