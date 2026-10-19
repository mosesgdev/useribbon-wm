#!/usr/bin/env python3
"""Pairs persona events with plans, runs the invariant checker, computes UX metrics and writes
a compact per-event trace (qa/ux-sim/out/<persona>.trace.txt) for reading.

Run: python3 qa/ux-sim/analyze.py   (after ribbon-sim has produced out/<persona>.plans.jsonl)
"""
import importlib.util
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
QA = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("check_plans", os.path.join(QA, "check_plans.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

PERSONAS = ["a_developer_ultrawide", "b_student_macbook", "c_designer_2560",
            "d_tab_hoarder", "e_display_swap", "f_chaos"]
# events the user caused directly (what "per command" means for metrics)
USER_TYPES = {"command", "window_focused", "window_added", "window_removed", "window_resized"}


def frame_map(plan):
    return {f["id"]: f for f in plan.get("frames", [])}


def fully_visible(f, d):
    return bool(f.get("on_screen")) and f["x"] >= d["x"] and f["x"] + f["w"] <= d["x"] + d["w"] \
        and f["y"] >= d["y"] and f["y"] + f["h"] <= d["y"] + d["h"]


def scroll_px(plan, d):
    """Scroll offset in px derived from map.viewport (fractions of content width)."""
    vp = plan.get("map", {}).get("viewport")
    if not vp or not d or vp["end"] - vp["start"] <= 1e-9:
        return None
    content = d["w"] / (vp["end"] - vp["start"])
    return vp["start"] * content


def scroll_shift(prev_fr, cur_fr):
    """Most common x-delta among windows present in both plans with unchanged width."""
    deltas = []
    for i, f in cur_fr.items():
        p = prev_fr.get(i)
        if p and p["w"] == f["w"] and p["x"] != f["x"] and p.get("on_screen") and f.get("on_screen"):
            deltas.append(f["x"] - p["x"])
    if not deltas:
        return 0
    return statistics.median(deltas)


def run(persona):
    events = json.load(open(os.path.join(HERE, persona + ".json")))
    plans = [json.loads(l) for l in open(os.path.join(HERE, "out", persona + ".plans.jsonl")) if l.startswith("{")]
    assert len(events) == len(plans), (persona, len(events), len(plans))

    display = None
    prev = None
    problems = []
    rows = []
    m = {"events": len(events), "user_events": 0, "cmd_events": 0,
         "changed_user": [], "changed_cmd": [], "changed_focus": [],
         "scroll_events": 0, "unneeded_scroll": 0, "big_scroll": 0,
         "focus_checked": 0, "focus_fully_visible": 0, "focus_too_wide": 0,
         "noop_show_map": 0, "map_inconsistent": 0, "min_col_frac": None, "min_col_px": None,
         "tiny_cols_plans": 0, "errors": 0, "focus_null_on_focus_event": 0,
         "frames_changed_no_scroll": 0}
    trace = []
    for idx, (ev, plan) in enumerate(zip(events, plans)):
        if ev["type"] == "display":
            display = {"x": ev["frame"]["x"], "y": ev["frame"]["y"], "w": ev["frame"]["w"], "h": ev["frame"]["h"]}
        d = display
        # invariant checks (same as check_plans.py) against the display in effect
        for p in cp.check(plan, d, "%s#%d" % (persona, idx)):
            problems.append(p)
        if plan.get("error"):
            m["errors"] += 1
        fr = frame_map(plan)
        changed = plan.get("changed", [])
        t = ev["type"]
        is_user = t in USER_TYPES
        is_cmd = t == "command"
        if is_user:
            m["user_events"] += 1
            m["changed_user"].append(len(changed))
        if is_cmd:
            m["cmd_events"] += 1
            m["changed_cmd"].append(len(changed))
        if t == "window_focused":
            m["changed_focus"].append(len(changed))
            if plan.get("focus") is None and plan.get("show_map") and False:
                pass
        # no-op flash: show_map on a command/focus that changed nothing
        pfi = prev.get("map", {}).get("focused_index") if prev is not None else None
        if (is_cmd or t == "window_focused") and plan.get("show_map") and not changed and fi == pfi:
            m["noop_show_map"] += 1
        # focus tracking metrics (tiled focus with a frame)
        f_id = plan.get("focus")
        if f_id is not None and f_id in fr and d:
            wide = fr[f_id]["w"] > d["w"]
            if wide:
                m["focus_too_wide"] += 1
            else:
                m["focus_checked"] += 1
                if fully_visible(fr[f_id], d):
                    m["focus_fully_visible"] += 1
                else:
                    problems.append("%s#%d: focus %s not fully visible after %s" % (persona, idx, f_id, t))
        # map consistency
        mp = plan.get("map", {})
        cols = mp.get("columns", [])
        fi = mp.get("focused_index")
        focused_cols = [i for i, c in enumerate(cols) if c.get("focused")]
        if fi is not None and focused_cols != [fi]:
            m["map_inconsistent"] += 1
            problems.append("%s#%d: map.focused_index=%s but focused columns=%s" % (persona, idx, fi, focused_cols))
        if f_id is not None and fi is not None and cols and fi < len(cols):
            ids_in_col = [w["id"] for w in cols[fi]["windows"]]
            if f_id not in ids_in_col:
                m["map_inconsistent"] += 1
                problems.append("%s#%d: focus %s not in focused column %s" % (persona, idx, f_id, ids_in_col))
        # column widths (only the tiled ones with frames)
        if d:
            for c in cols:
                if c.get("visible") and c.get("width_frac") is not None:
                    frac = c["width_frac"]
                    if m["min_col_frac"] is None or frac < m["min_col_frac"]:
                        m["min_col_frac"] = frac
            px = [f["w"] for f in plan.get("frames", [])]
            if px:
                mn = min(px)
                if m["min_col_px"] is None or mn < m["min_col_px"]:
                    m["min_col_px"] = mn
                if mn < 0.2 * d["w"] and any(f.get("on_screen") for f in plan.get("frames", [])):
                    m["tiny_cols_plans"] += 1
        # scroll tracking (viewport-derived px offset; display changes excluded)
        shift = 0.0
        if prev is not None and d and t != "display":
            ps, cs = scroll_px(prev, d), scroll_px(plan, d)
            if ps is not None and cs is not None:
                shift = cs - ps
            if abs(shift) > 1:
                m["scroll_events"] += 1
                # a single focus step should move about one column; more than one column + gaps is a jump
                col_px = max([f["w"] for f in list(frame_map(prev).values()) + list(fr.values())] or [0])
                if t == "command" and ev.get("name") in ("focus_left", "focus_right") and abs(shift) > col_px + 24:
                    m["big_scroll"] += 1
                    problems.append("%s#%d: JUMP %+d px for one %s (column ~%d px)" % (
                        persona, idx, shift, ev.get("name"), col_px))
                focus_move = t == "command" and ev.get("name") in ("focus_left", "focus_right", "focus_up", "focus_down")
                click = t == "window_focused"
                if (focus_move or click) and f_id is not None and f_id in frame_map(prev) \
                        and fully_visible(frame_map(prev)[f_id], d):
                    m["unneeded_scroll"] += 1
                    problems.append("%s#%d: UNNEEDED scroll %+d px: target %s was already fully visible" % (
                        persona, idx, shift, f_id))
            if t == "command" and ev.get("name") in ("focus_left", "focus_right", "focus_up", "focus_down") \
                    and abs(shift) <= 1 and changed:
                m["frames_changed_no_scroll"] += 1
        if d and prev is not None and idx and t == "command" and not changed:
            pass
        # tiny columns: record the triggering event
        if d and plan.get("frames") and any(f.get("on_screen") and f["w"] < 0.2 * d["w"] for f in plan["frames"]):
            m.setdefault("tiny_triggers", []).append((idx, t, ev.get("name", "")))
        prev = plan
        # trace line
        if ev["type"] == "display":
            desc = "display %s,%s %sx%s" % (ev["frame"]["x"], ev["frame"]["y"], ev["frame"]["w"], ev["frame"]["h"])
        elif ev["type"] == "command":
            desc = "cmd %s%s" % (ev["name"], "(%s)" % ev["arg"] if "arg" in ev else "")
        elif ev["type"] == "window_added":
            desc = "add %d %s%s" % (ev["id"], ev["app"], " FLOAT" if ev.get("floating") else "")
        elif ev["type"] == "window_removed":
            desc = "remove %d" % ev["id"]
        elif ev["type"] == "window_focused":
            desc = "click %d" % ev["id"]
        elif ev["type"] == "window_resized":
            desc = "resize %d w=%d" % (ev["id"], ev["frame"]["w"])
        else:
            desc = ev["type"]
        row = " ".join("%d@%d+%d%s" % (f["id"], f["x"], f["w"], "" if f.get("on_screen") else "(off)")
                       for f in sorted(plan.get("frames", []), key=lambda f: f["x"]))
        trace.append("#%03d %-26s focus=%s fidx=%s show=%s chg=%d%s shift=%s | %s" % (
            idx, desc, f_id, fi, "Y" if plan.get("show_map") else "n", len(changed),
            (" " + str(changed)) if 0 < len(changed) <= 6 else "", int(shift), row))
    with open(os.path.join(HERE, "out", persona + ".trace.txt"), "w") as fh:
        fh.write("\n".join(trace) + "\n")
    return m, problems


def summarize(m):
    def stat(xs):
        if not xs:
            return "n/a", "n/a"
        return "%.2f" % (sum(xs) / len(xs)), str(max(xs))
    avg_u, max_u = stat(m["changed_user"])
    avg_c, max_c = stat(m["changed_cmd"])
    avg_f, max_f = stat(m["changed_focus"])
    fv = m["focus_fully_visible"] / m["focus_checked"] * 100 if m["focus_checked"] else 100.0
    return {
        "events": m["events"], "user_events": m["user_events"], "commands": m["cmd_events"],
        "avg_changed_user": avg_u, "max_changed_user": max_u,
        "avg_changed_cmd": avg_c, "max_changed_cmd": max_c,
        "avg_changed_focus_click": avg_f, "max_changed_focus_click": max_f,
        "scroll_events": m["scroll_events"], "big_scroll": m["big_scroll"],
        "unneeded_scroll": m["unneeded_scroll"],
        "focus_fully_visible_pct": "%.1f" % fv, "focus_checked": m["focus_checked"],
        "focus_too_wide_skipped": m["focus_too_wide"],
        "noop_show_map": m["noop_show_map"], "map_inconsistent": m["map_inconsistent"],
        "min_col_frac": m["min_col_frac"], "min_col_px": m["min_col_px"],
        "tiny_col_plans": m["tiny_cols_plans"], "engine_errors": m["errors"],
        "focus_move_frames_changed_without_scroll": m["frames_changed_no_scroll"],
        "tiny_triggers": m.get("tiny_triggers", [])[:40],
    }


if __name__ == "__main__":
    allm = {}
    for p in PERSONAS:
        m, probs = run(p)
        allm[p] = summarize(m)
        allm[p]["invariant_problems"] = len(probs)
        with open(os.path.join(HERE, "out", p + ".problems.txt"), "w") as fh:
            fh.write("\n".join(probs) + ("\n" if probs else ""))
    with open(os.path.join(HERE, "out", "metrics.json"), "w") as fh:
        json.dump(allm, fh, indent=1)
    for p, s in allm.items():
        print(p, json.dumps(s))
