#!/usr/bin/env python3
"""Generates the six UX-simulation persona event scripts (qa/ux-sim/<persona>.json).

Run: python3 qa/ux-sim/gen_personas.py
Each persona = scripted opening beats + a seeded random "tail" weighted to the persona's habits.
Random targets stand in for "whatever the user is looking at" (the sim has no focus oracle), so
click/close/move targets are drawn from the generator's live-window set.
Display frames are AX visible frames (top-left origin).
"""
import json
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))

DISPLAYS = {
    "A": {"x": 0, "y": 30, "w": 3840, "h": 1170},
    "B": {"x": 0, "y": 33, "w": 1512, "h": 949},
    "C": {"x": 0, "y": 25, "w": 2560, "h": 1415},
    "D": {"x": 0, "y": 25, "w": 1920, "h": 1030},
    "E0": {"x": 0, "y": 33, "w": 1512, "h": 949},   # laptop alone
    "E1": {"x": 0, "y": 25, "w": 2560, "h": 1415},  # external becomes main
    "F": {"x": 0, "y": 25, "w": 1920, "h": 1055},
}


def rect(d):
    return {"x": d["x"], "y": d["y"], "w": d["w"], "h": d["h"]}


class Gen:
    def __init__(self, seed, display):
        self.rng = random.Random(seed)
        self.ev = []
        self.live = []          # tiled ids the generator believes exist
        self.floating = []      # floating ids believed to exist
        self.next_id = 1
        self.display = display
        self.ev.append({"type": "display", "id": 1, "frame": rect(display)})

    def _id(self):
        i = self.next_id
        self.next_id += 1
        return i

    def add(self, app, title=None, floating=False):
        i = self._id()
        self.ev.append({"type": "window_added", "id": i, "pid": 2000 + i, "app": app,
                        "title": title or "%s window" % app, "frame": {"x": 0, "y": 0, "w": 900, "h": 700},
                        "floating": floating})
        (self.floating if floating else self.live).append(i)
        return i

    def remove(self, i):
        self.ev.append({"type": "window_removed", "id": i})
        for lst in (self.live, self.floating):
            if i in lst:
                lst.remove(i)

    def focus(self, i):
        self.ev.append({"type": "window_focused", "id": i})

    def cmd(self, name, arg=None):
        e = {"type": "command", "name": name}
        if arg is not None:
            e["arg"] = arg
        self.ev.append(e)

    def resize(self, i, w, h=700):
        self.ev.append({"type": "window_resized", "id": i,
                        "frame": {"x": 0, "y": 0, "w": w, "h": h}})

    def display_change(self, d):
        self.display = d
        self.ev.append({"type": "display", "id": 1, "frame": rect(d)})

    def pick(self, pool):
        return self.rng.choice(pool) if pool else None

    def tail(self, n, weights, apps):
        """Random persona habit tail: append events until the script has n events."""
        acts = list(weights.keys())
        w = [weights[a] for a in acts]
        while len(self.ev) < n:
            a = self.rng.choices(acts, w)[0]
            if a in ("focus_left", "focus_right", "focus_up", "focus_down", "center", "cycle_width",
                     "cycle_width_back", "toggle_full", "stack", "unstack", "move_left", "move_right",
                     "undo", "redo"):
                self.cmd(a)
            elif a == "focus_index":
                self.cmd("focus_index", self.rng.randint(1, max(1, len(self.live))))
            elif a == "click":
                t = self.pick(self.live + self.floating)
                if t is not None:
                    self.focus(t)
            elif a == "open":
                self.add(self.rng.choice(apps))
            elif a == "close":
                t = self.pick(self.live)
                if t is not None:
                    self.remove(t)
            elif a == "resize":
                t = self.pick(self.live)
                if t is not None:
                    self.resize(t, self.rng.randint(300, max(400, self.display["w"] - 100)))
            elif a == "toggle_float":
                t = self.pick(self.live + self.floating)
                if t is not None:
                    self.focus(t)
                    self.cmd("toggle_float")
            elif a == "unknown_id":
                self.focus(self.rng.randint(5000, 9999))
            elif a == "dup_add":
                t = self.pick(self.live)
                if t is not None:
                    self.ev.append({"type": "window_added", "id": t, "pid": 1, "app": "Dupe",
                                    "title": "dupe", "frame": {"x": 0, "y": 0, "w": 900, "h": 700},
                                    "floating": False})
        return self.ev


def write(name, events):
    path = os.path.join(HERE, name + ".json")
    with open(path, "w") as fh:
        json.dump(events, fh, indent=1)
    print("%-28s %3d events" % (name, len(events)))


def persona_a():
    g = Gen(101, DISPLAYS["A"])
    # Morning setup: Zed + terminal stacked, browser, docs, Slack
    g.add("Zed", "ribbon — SPEC.md")
    g.add("Terminal", "zsh — ribbon")
    g.cmd("stack")                       # terminal under editor
    g.focus(g.live[0]); g.cmd("focus_down"); g.cmd("focus_up")
    g.add("Chrome", "Layout docs")
    g.add("Chrome", "PR #41 review")
    g.add("Slack", "#ribbon-dev")
    g.cmd("focus_left"); g.cmd("focus_left"); g.cmd("focus_right")
    g.cmd("cycle_width"); g.cmd("cycle_width"); g.cmd("toggle_full"); g.cmd("toggle_full")
    g.cmd("focus_index", 1); g.cmd("focus_index", 4)
    g.resize(g.live[2], 1400)            # browser dragged to 1400
    g.cmd("center")
    g.cmd("undo")                        # mistake: undo the drag-width
    g.cmd("redo")
    g.add("Preview", "design.pdf", floating=False)
    g.cmd("unstack")                     # pop terminal out again
    g.cmd("move_left"); g.cmd("move_right")
    g.add("Terminal", "logs")
    g.cmd("stack")
    g.tail(118, {"focus_left": 14, "focus_right": 14, "focus_up": 5, "focus_down": 5, "click": 12,
                 "cycle_width": 6, "toggle_full": 3, "stack": 4, "unstack": 3, "resize": 4,
                 "undo": 4, "center": 2, "focus_index": 3, "move_left": 2, "move_right": 2,
                 "open": 4, "close": 2, "toggle_float": 1},
           ["Chrome", "Terminal", "Zed", "Slack", "Figma", "Notes"])
    return g.ev


def persona_b():
    g = Gen(202, DISPLAYS["B"])
    for app in ["Safari", "Mail", "Notes", "Messages", "Calendar", "Spotify", "Finder", "Preview",
                "Notion", "Slack", "Terminal", "Xcode"]:
        g.add(app)
    g.cmd("focus_index", 3); g.cmd("cycle_width"); g.cmd("undo")
    g.cmd("focus_index", 9)
    g.tail(132, {"open": 12, "close": 10, "focus_index": 10, "focus_left": 8, "focus_right": 8,
                 "click": 8, "undo": 10, "redo": 2, "cycle_width": 5, "toggle_full": 3, "stack": 3,
                 "unstack": 2, "center": 2, "resize": 2, "unknown_id": 1},
           ["Safari", "Mail", "Notes", "Messages", "Canvas", "Docs", "Figma"])
    return g.ev


def persona_c():
    g = Gen(303, DISPLAYS["C"])
    g.add("Figma", "Brand board")
    g.cmd("toggle_full")                 # full width for the canvas
    g.cmd("toggle_full")                 # back
    g.cmd("toggle_full")                 # full again
    picker = g.add("Color Picker", "Colors", floating=True)
    g.focus(picker)
    g.cmd("focus_left"); g.cmd("focus_right"); g.cmd("focus_right")
    g.cmd("center")
    g.focus(picker); g.cmd("toggle_full")  # full on a floating window: should it do anything?
    g.add("Figma", "Icon set")
    g.cmd("toggle_full")
    g.cmd("focus_left")
    p2 = g.add("Color Picker", "Shades", floating=True)
    g.focus(p2); g.cmd("focus_right"); g.cmd("focus_left"); g.cmd("focus_left")
    g.remove(p2)                         # picker closed
    g.cmd("toggle_full"); g.cmd("center")
    g.add("Notes", "Feedback"); g.cmd("cycle_width"); g.cmd("cycle_width")
    g.cmd("focus_index", 1); g.cmd("toggle_full")
    g.tail(118, {"toggle_full": 9, "focus_left": 10, "focus_right": 10, "center": 4, "click": 6,
                 "open": 6, "close": 3, "cycle_width": 4, "toggle_float": 5, "undo": 4, "redo": 2,
                 "stack": 2, "resize": 1, "focus_index": 2},
           ["Color Picker", "Figma", "Figma", "Notes", "Assets", "Browser"])
    return g.ev


def persona_d():
    g = Gen(404, DISPLAYS["D"])
    apps = ["Chrome", "Safari", "Docs", "Trello", "Gmail", "YouTube", "Reddit", "Twitter", "Notion",
            "GitHub", "Figma", "Slack", "Terminal", "News"]
    for i in range(25):                  # opens a tab-window every so often, rarely closes
        g.add(apps[i % len(apps)], "%s tab %d" % (apps[i % len(apps)], i))
        if i in (6, 13, 19):
            g.cmd("focus_index", 2)
        if i in (9, 17):
            t = g.pick(g.live[:-3])
            if t is not None:
                g.remove(t)
    for _ in range(30):                  # rapid focus_right spam
        g.cmd("focus_right")
    g.cmd("focus_index", 1)
    for _ in range(8):
        g.cmd("cycle_width")
    g.cmd("focus_index", 6)
    g.cmd("toggle_full"); g.cmd("undo"); g.cmd("cycle_width_back")
    g.tail(104, {"focus_right": 8, "focus_left": 6, "cycle_width": 8, "cycle_width_back": 2,
                 "focus_index": 3, "click": 6, "toggle_full": 2, "open": 3, "close": 1, "undo": 2},
           apps)
    return g.ev


def persona_e():
    # Laptop + external monitor: display frame changes mid-session with windows open.
    g = Gen(505, DISPLAYS["E0"])
    for app in ["Safari", "Xcode", "Terminal", "Slack", "Mail", "Figma"]:
        g.add(app)
    g.cmd("cycle_width")
    g.cmd("focus_index", 4)
    g.cmd("focus_right"); g.cmd("focus_right")
    g.display_change(DISPLAYS["E1"])      # external attached -> main, larger
    g.cmd("focus_left"); g.cmd("toggle_full"); g.cmd("center")
    g.add("Notes"); g.add("Calendar")
    g.cmd("focus_index", 8)               # far right on the big screen
    g.display_change(DISPLAYS["E0"])      # lid-only again: shrink while scrolled far right
    g.cmd("focus_right"); g.cmd("focus_left"); g.cmd("undo")
    g.display_change(DISPLAYS["E0"])      # same frame re-sent (gather-like)
    g.cmd("gather")
    g.display_change(DISPLAYS["E1"])      # re-attached
    g.cmd("focus_index", 1); g.cmd("cycle_width"); g.cmd("cycle_width")
    g.display_change(DISPLAYS["E0"])
    g.cmd("gather")
    g.tail(102, {"focus_left": 12, "focus_right": 12, "click": 8, "cycle_width": 5, "toggle_full": 3,
                 "undo": 5, "stack": 3, "unstack": 2, "center": 3, "focus_index": 4, "open": 3,
                 "close": 2, "resize": 2},
           ["Safari", "Xcode", "Slack", "Notes", "Calendar"])
    # swap display in the middle of the tail, then back
    g.display_change(DISPLAYS["E1"])
    g.tail(len(g.ev) + 15, {"focus_left": 10, "focus_right": 10, "click": 5, "cycle_width": 3},
           ["Safari", "Slack"])
    g.display_change(DISPLAYS["E0"])
    g.cmd("focus_right"); g.cmd("undo")
    return g.ev


def persona_f():
    g = Gen(606, DISPLAYS["F"])
    for app in ["Safari", "Xcode", "Slack", "Mail", "Notes"]:
        g.add(app)
    g.cmd("bogus_command")
    g.cmd("focus_index", 0); g.cmd("focus_index", 999); g.cmd("focus_index")
    g.focus(9999); g.remove(9998)
    g.resize(4242, 100)
    g.ev.append({"type": "window_added", "id": 1, "pid": 1, "app": "Dup", "title": "dup",
                 "frame": {"x": 0, "y": 0, "w": 9, "h": 9}, "floating": False})
    for _ in range(10):
        g.cmd("undo")
    for _ in range(10):
        g.cmd("redo")
    g.cmd("stack"); g.cmd("stack")
    g.tail(150, {"open": 8, "close": 8, "click": 10, "focus_left": 9, "focus_right": 9, "focus_up": 3,
                 "focus_down": 3, "stack": 6, "unstack": 5, "toggle_float": 8, "toggle_full": 4,
                 "cycle_width": 4, "cycle_width_back": 2, "undo": 6, "redo": 4, "dup_add": 3,
                 "unknown_id": 3, "resize": 3, "focus_index": 3, "center": 2, "move_left": 2,
                 "move_right": 2},
           ["Safari", "Xcode", "Dup", "Mail", "Notes", "Music"])
    return g.ev


def main():
    write("a_developer_ultrawide", persona_a())
    write("b_student_macbook", persona_b())
    write("c_designer_2560", persona_c())
    write("d_tab_hoarder", persona_d())
    write("e_display_swap", persona_e())
    write("f_chaos", persona_f())


if __name__ == "__main__":
    main()
