#!/usr/bin/env python3
"""check_plans.py invariants, but the display rectangle follows the event file's `display` events.

Usage: check_per_display.py events.json plans.jsonl [--default X,Y,W,H]
Plan line i corresponds to event i (ribbon-sim prints one plan per event). Python 3.9 compatible.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("cp", os.path.join(os.path.dirname(HERE), "check_plans.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)


def main():
    ev_path, plans_path = sys.argv[1], sys.argv[2]
    default = [float(v) for v in (sys.argv[4] if len(sys.argv) > 4 else "0,30,1920,1050").split(",")]
    events = json.load(open(ev_path))
    d = {"x": default[0], "y": default[1], "w": default[2], "h": default[3]}
    problems, n, ei = [], 0, 0
    for line in open(plans_path):
        if not line.startswith("{"):
            continue
        plan = json.loads(line)
        e = events[ei] if ei < len(events) else {}
        ei += 1
        if e.get("type") == "display":
            f = e["frame"]
            d = {"x": f["x"], "y": f["y"], "w": f["w"], "h": f["h"]}
        n += 1
        problems.extend(cp.check(plan, d, "%s#%d" % (os.path.basename(plans_path), ei)))
    for p in problems:
        print(p)
    print("checked %d plans, %d problems (display follows display events)" % (n, len(problems)))


if __name__ == "__main__":
    main()
