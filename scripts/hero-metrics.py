#!/usr/bin/env python3
"""Summarise hero-stills metrics.json against the Phase 3 thresholds. Usage: hero-metrics.py <metrics.json>"""
import json, sys
rows = json.load(open(sys.argv[1]))
fails = 0
for r in rows:
    n = r["name"]; dark = n.endswith("-dark")
    checks = []
    if n.startswith("head"):
        lo, hi = (0.35, 0.60) if dark else (0.40, 0.65)
        checks = [("clip<=0.5%", r["clipped"] <= 0.005), (f"mean {lo}-{hi}", lo <= r["meanLuma"] <= hi),
                  ("std>=0.07", r["lumaStd"] >= 0.07), ("face>=0.25", r.get("faceSpread", 0) >= 0.25),
                  ("edge>=1.3", r["edgeContrast"] >= 1.3), ("bottom>=0.93", r.get("bottom", 1) >= 0.93)]
    elif n.startswith("buds"):
        # Shell clipping: near-neutral blown pixels only; the LED strip and its bloom are meant to glow.
        checks = [("shell clip<=1%", r.get("shellClipped", r["clipped"]) <= 0.01)]
    elif n.startswith("model"):
        checks = [("core-ring>=0.15", abs(r.get("coreLuma", 0) - r.get("ringLuma", 0)) >= 0.15)]
    bad = [c for c, ok in checks if not ok]
    fails += len(bad)
    vals = " ".join(f"{k}={r[k]:.3f}" for k in ["clipped", "shellClipped", "meanLuma", "lumaStd", "faceSpread", "edgeContrast", "bottom", "coreLuma", "ringLuma"] if k in r)
    print(f"{'FAIL' if bad else 'pass'} {n:28s} {vals}" + (f"  <- {', '.join(bad)}" if bad else ""))
print(f"{fails} failing check(s)")
