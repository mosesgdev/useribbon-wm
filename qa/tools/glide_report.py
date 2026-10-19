#!/usr/bin/env python3
"""Reads wsample output (stdin or a file) and reports each window move: how smooth it is on screen.

A move is a burst of position changes with less than --quiet ms between them. Per move:
  dur_ms       first change to last change
  steps        distinct positions the median window passed through (a smooth 140 ms glide at 60 Hz is ~8; at 100 Hz ~14)
  hz           steps per second while moving
  max_jump     the largest single step as a share of that window's travel (1.0 = it teleported)
  gap_ms_max   the longest pause between steps of one window inside the move
  tear_px      windows that end up moved by the same distance should move together; the largest spread of their
               displacements at any sample (0 = a rigid strip)
  teleports    windows that reached their target in one step (parked <-> on screen, or jumps)
Usage: wsample <pid> 6 | glide_report.py   or   glide_report.py samples.jsonl [--quiet 120]
"""
import json, sys, argparse, statistics

ap = argparse.ArgumentParser()
ap.add_argument("file", nargs="?")
ap.add_argument("--quiet", type=float, default=120.0)
ap.add_argument("--json", action="store_true")
a = ap.parse_args()
lines = (open(a.file) if a.file else sys.stdin).read().splitlines()
samples = [json.loads(l) for l in lines if l.startswith("{")]
if len(samples) < 2:
    print("no movement sampled"); sys.exit(0)

moves, cur = [], [samples[0]]
for s in samples[1:]:
    if (s["t"] - cur[-1]["t"]) * 1000 > a.quiet:
        moves.append(cur); cur = [cur[-1], s]          # the move starts from the last rest position
    else:
        cur.append(s)
moves.append(cur)

reports = []
for m in moves:
    if len(m) < 2: continue
    first, last = m[0]["x"], m[-1]["x"]
    ids = [i for i in last if i in first and last[i] != first[i]]
    if not ids: continue
    t0 = m[1]["t"]
    per, teleports = {}, 0
    for i in ids:
        xs = [(s["t"], s["x"].get(i)) for s in m if i in s["x"]]
        pos = [xs[0]]
        for t, x in xs[1:]:
            if x != pos[-1][1]: pos.append((t, x))
        travel = abs(last[i] - first[i])
        jumps = [abs(b[1] - a_[1]) for a_, b in zip(pos, pos[1:])]
        gaps = [(b[0] - a_[0]) * 1000 for a_, b in zip(pos[1:], pos[2:])]
        per[i] = dict(steps=len(pos) - 1, max_jump=max(jumps) / travel if travel else 0, gap=max(gaps) if gaps else 0,
                      start=pos[1][0], end=pos[-1][0], travel=last[i] - first[i])
        if len(pos) - 1 == 1: teleports += 1
    # rigid groups: windows with the same total displacement (within 4 px)
    groups = {}
    for i in ids: groups.setdefault(round(per[i]["travel"] / 4), []).append(i)
    tear = 0
    for g in groups.values():
        if len(g) < 2: continue
        for s in m:
            ds = [s["x"][i] - first[i] for i in g if i in s["x"]]
            if len(ds) == len(g): tear = max(tear, max(ds) - min(ds))
    steps = statistics.median(p["steps"] for p in per.values())
    dur = (max(p["end"] for p in per.values()) - t0) * 1000
    reports.append(dict(at=round(t0, 3), windows=len(ids), dur_ms=round(dur), steps=steps,
                        hz=round(steps / (dur / 1000), 1) if dur > 0 else None,
                        max_jump=round(max(p["max_jump"] for p in per.values()), 2),
                        gap_ms_max=round(max(p["gap"] for p in per.values())), tear_px=tear, teleports=teleports))

if a.json:
    print(json.dumps(reports))
else:
    for r in reports:
        print("  ".join(f"{k}={v}" for k, v in r.items()))
