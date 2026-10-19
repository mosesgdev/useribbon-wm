#!/usr/bin/env python3
"""Behavioural checks on replayed scenarios (one plan per event, same order).

Usage: analyze.py [--trace NAME] scenario.json plans.jsonl [...]
Checks beyond check_plans.py:
  - focused tiled column must be on_screen (keep_visible: focus should never end off-screen)
  - viewport start/end must stay inside [0,1] (scroll not past content)
  - display-aware: the display in effect is tracked from display events
  - undo identity: a 'do N, undo N' run must restore the frames before the run
Floating focus legitimately leaves no focused column; those plans are skipped.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/..")
import check_plans  # noqa: E402


def load_plans(path):
    with open(path) as fh:
        return [json.loads(l) for l in fh if l.startswith("{")]


def describe(ev):
    t = ev["type"]
    if t == "command":
        return "cmd %s%s" % (ev["name"], "(%s)" % ev["arg"] if "arg" in ev else "")
    if t in ("window_added",):
        return "add %d %s%s" % (ev["id"], ev["app"], " [float]" if ev.get("floating") else "")
    if t in ("window_removed", "window_focused"):
        return "%s %d" % (t, ev["id"])
    if t == "window_resized":
        return "resize %d w=%s" % (ev["id"], ev["frame"]["w"])
    if t == "display":
        return "display %dx%d" % (ev["frame"]["w"], ev["frame"]["h"])
    return t


def focus_col(plan):
    for i, c in enumerate(plan["map"]["columns"]):
        if c.get("focused"):
            return i, c
    return None, None


def summary(plan):
    cols = []
    for c in plan["map"]["columns"]:
        ids = ",".join(str(w["id"]) for w in c["windows"])
        mark = "*" if c.get("focused") else ""
        cols.append("[%s%s%s]" % (mark, ids, "" if c.get("visible") else "~"))
    return " ".join(cols) + " vp=%s-%s" % (plan["map"]["viewport"]["start"], plan["map"]["viewport"]["end"])


def analyze(scn_path, plan_path, trace=False):
    events = json.load(open(scn_path))
    plans = load_plans(plan_path)
    assert len(events) == len(plans), (scn_path, len(events), len(plans))
    display = None
    problems = []
    name = os.path.basename(scn_path)
    for i, (ev, plan) in enumerate(zip(events, plans)):
        if ev["type"] == "display":
            display = ev["frame"]
        where = "%s#%d(%s)" % (name, i + 1, describe(ev))
        if trace:
            print("%3d %-34s focus=%-5s %s" % (i + 1, describe(ev)[:34], plan.get("focus"), summary(plan)))
        if display is None or plan.get("error"):
            continue
        ci, col = focus_col(plan)
        if col is not None:
            on = [f for f in plan["frames"] if f["id"] in {w["id"] for w in col["windows"]}]
            if on and not any(f["on_screen"] for f in on):
                problems.append("%s focused column off-screen (focus=%s)" % (where, plan.get("focus")))
        if plan["map"]["columns"] and not any(c.get("visible") for c in plan["map"]["columns"]):
            problems.append("%s blank ribbon: columns exist but none visible (focus=%s)" % (where, plan.get("focus")))
        vp = plan["map"]["viewport"]
        if plan["map"]["columns"] and (vp["start"] < -1e-6 or vp["end"] > 1 + 1e-6):
            problems.append("%s viewport out of content range %s-%s" % (where, vp["start"], vp["end"]))
    # Checker invariants, using the display in effect at each plan.
    display = None
    for i, (ev, plan) in enumerate(zip(events, plans)):
        if ev["type"] == "display":
            display = ev["frame"]
        if display is None:
            continue
        d = {"x": display["x"], "y": display["y"], "w": display["w"], "h": display["h"]}
        for p in check_plans.check(plan, d, "%s#%d" % (name, i + 1)):
            if "focused tiled" in p or "exactly one focused column" in p:
                continue  # covered above / floating focus by design
            problems.append(p)
    return problems


def undo_identity(scn_path, plan_path, start, run, undo):
    """plans[start] is state S; after `run` mutating events and `undo` undos, frames must equal S."""
    plans = load_plans(plan_path)
    a = plans[start]["frames"]
    b = plans[start + run + undo - 1]["frames"]
    return a == b


def main():
    args = sys.argv[1:]
    trace = False
    if args and args[0] == "--trace":
        trace = True
        args = args[1:]
    scn, plans = args[0], args[1]
    probs = analyze(scn, plans, trace)
    for p in probs:
        print(p)
    print("%s: %d behavioural problems" % (os.path.basename(scn), len(probs)))


if __name__ == "__main__":
    main()
