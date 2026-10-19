#!/usr/bin/env python3
"""Invariant checker for Ribbon plan logs (one plan JSON per line).

Usage: check_plans.py --display X,Y,W,H plans.jsonl [more.jsonl ...]
Python 3.9 compatible (runs on the Mac mini's system python).
"""
import argparse
import json
import sys


def overlaps(a, b, tol=1):
    return (a["x"] + a["w"] - tol > b["x"] and b["x"] + b["w"] - tol > a["x"]
            and a["y"] + a["h"] - tol > b["y"] and b["y"] + b["h"] - tol > a["y"])


def check(plan, d, where):
    errs = []
    if plan.get("error"):
        errs.append("engine error: %s" % plan["error"])
    frames = plan.get("frames", [])
    ids = [f["id"] for f in frames]
    if len(ids) != len(set(ids)):
        errs.append("duplicate ids in frames")
    right, bottom = d["x"] + d["w"], d["y"] + d["h"]
    vis = [f for f in frames if f.get("on_screen")]
    for f in frames:
        if f["w"] <= 0 or f["h"] <= 0:
            errs.append("non-positive size for %s" % f["id"])
        if f["y"] < d["y"] - 1 or f["y"] + f["h"] > bottom + 1:
            errs.append("window %s vertically outside display" % f["id"])
        if f.get("on_screen"):
            # partially visible neighbours ("peek") are fine; must intersect the display
            if f["x"] + f["w"] <= d["x"] or f["x"] >= right:
                errs.append("on_screen window %s does not intersect display" % f["id"])
        else:
            # must keep a sliver on this display, and not cover it
            if f["x"] + f["w"] < d["x"] + 1 or f["x"] > right - 1:
                errs.append("off-screen window %s lost its sliver (macOS may relocate it)" % f["id"])
            if d["x"] + 2 < f["x"] < right - 2:
                errs.append("off-screen window %s sits inside the viewport" % f["id"])
    for i in range(len(vis)):
        for j in range(i + 1, len(vis)):
            if overlaps(vis[i], vis[j]):
                errs.append("on_screen windows %s and %s overlap" % (vis[i]["id"], vis[j]["id"]))
    focus = plan.get("focus")
    if focus is not None and frames and focus not in ids:
        # floating windows may be focused without a frame; only flag if map doesn't know it
        known = {w["id"] for c in plan.get("map", {}).get("columns", []) for w in c.get("windows", [])}
        if focus in known:
            errs.append("focused tiled window %s has no frame" % focus)
    cols = plan.get("map", {}).get("columns", [])
    nfocus = sum(1 for c in cols if c.get("focused"))
    tiled_focus = plan.get("map", {}).get("focused_index") is not None
    if cols and (nfocus > 1 or (tiled_focus and nfocus != 1)):
        errs.append("map must have exactly one focused column (zero only when no tiled window is focused)")
    return ["%s: %s" % (where, e) for e in errs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--display", required=True, help="X,Y,W,H visible frame in AX coords")
    ap.add_argument("logs", nargs="+")
    a = ap.parse_args()
    x, y, w, h = [float(v) for v in a.display.split(",")]
    d = {"x": x, "y": y, "w": w, "h": h}
    problems, n = [], 0
    for path in a.logs:
        with open(path) as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line.startswith("{"):
                    continue
                n += 1
                try:
                    plan = json.loads(line)
                except ValueError as e:
                    problems.append("%s:%d: bad json (%s)" % (path, lineno, e))
                    continue
                problems.extend(check(plan, d, "%s:%d" % (path, lineno)))
    for p in problems:
        print(p)
    print("checked %d plans, %d problems" % (n, len(problems)))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
