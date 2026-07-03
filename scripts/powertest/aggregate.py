"""Aggregate a passive-monitor log by the driver's phase marks.

Usage: python3 aggregate.py <monitor.log> <phases.log>

monitor.log lines: "epoch conterm% ws% onscreen"
phases.log lines:  "epoch phase-name"
"""
import sys

mon = [l.split() for l in open(sys.argv[1])]
ph = [(int(t), n.strip()) for t, n in (l.split(None, 1) for l in open(sys.argv[2]))]

for i, (t, name) in enumerate(ph[:-1]):
    end = ph[i + 1][0]
    xs = [(float(c), float(w)) for ts, c, w, *_ in mon if t + 2 <= int(ts) < end]
    if not xs:
        print(f"{name:36s} (no samples)")
        continue
    n = len(xs)
    ca = sum(x[0] for x in xs) / n
    wa = sum(x[1] for x in xs) / n
    cm = max(x[0] for x in xs)
    wm = max(x[1] for x in xs)
    print(f"{name:36s} n={n:2d}  conterm {ca:5.1f} (max {cm:5.1f})   ws {wa:5.1f} (max {wm:5.1f})")
