#!/usr/bin/env python3
"""Three overnight personas tailored to a 1920x1080 display (AX visible frame 0,30,1920,1050).

Reuses the Gen helper from qa/ux-sim/gen_personas.py (import only; does not write to ux-sim/).
Run: python3 qa/mini-overnight/gen_mini_personas.py   -> writes qa/mini-overnight/<name>.json
"""
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
QA = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("gp", os.path.join(QA, "ux-sim", "gen_personas.py"))
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)

DISP = {"x": 0, "y": 30, "w": 1920, "h": 1050}


def parent():
    """School portal + email + calendar + chat on one 1920 screen; mostly 2-3 windows visible."""
    g = gp.Gen(3101, DISP)
    g.add("Safari", "Schulportal - Elternbereich")
    g.add("Mail", "Inbox (14)")
    g.add("Calendar", "Week view")
    g.add("Messages", "Anna (Klasse 3b)")
    g.cmd("focus_left"); g.cmd("focus_right")
    g.cmd("cycle_width")                  # portal to 1/2 width
    g.cmd("focus_index", 2)
    g.resize(g.live[1], 1000)             # mail dragged wide
    g.cmd("center")
    g.add("Safari", "Elternbrief.pdf")
    g.add("Preview", "Elternbrief.pdf", floating=False)
    g.cmd("stack")                        # pdf under portal
    g.cmd("unstack")
    g.add("Notes", "Einkaufsliste", floating=True)
    g.cmd("toggle_float")
    g.tail(150, {"focus_left": 12, "focus_right": 12, "click": 14, "cycle_width": 5,
                 "focus_index": 4, "center": 3, "toggle_full": 2, "stack": 3, "unstack": 2,
                 "resize": 3, "undo": 3, "open": 4, "close": 4, "toggle_float": 2,
                 "move_left": 2, "move_right": 2, "focus_up": 2, "focus_down": 2},
           ["Safari", "Mail", "Messages", "Calendar", "Notes", "Preview"])
    return g.ev


def writer():
    """Writer with research tabs; toggles full width constantly and pulls references in."""
    g = gp.Gen(3202, DISP)
    g.add("Pages", "Draft - chapter 4")
    g.add("Safari", "JSTOR - article 1")
    g.add("Safari", "JSTOR - article 2")
    g.add("Safari", "Wikipedia - Ribbon WM")
    g.add("Notes", "Quotes", floating=True)
    g.cmd("toggle_full")                  # writer full width
    g.cmd("focus_right"); g.cmd("focus_right")
    g.cmd("toggle_full")
    g.cmd("cycle_width"); g.cmd("cycle_width_back")
    g.cmd("focus_index", 1); g.cmd("toggle_full")
    g.cmd("toggle_full")
    g.tail(150, {"toggle_full": 14, "focus_left": 10, "focus_right": 10, "click": 10,
                 "cycle_width": 4, "cycle_width_back": 2, "focus_index": 4, "undo": 5, "redo": 2,
                 "open": 6, "close": 5, "resize": 2, "toggle_float": 2, "center": 2,
                 "stack": 2, "unstack": 1, "unknown_id": 1},
           ["Safari", "Safari", "Preview", "Notes", "Pages", "Zotero"])
    return g.ev


def support():
    """Support agent: ~20 chat windows opened/closed every few seconds, plus keyboard hopping."""
    g = gp.Gen(3303, DISP)
    for k in range(20):
        g.add("Chat", "Ticket #%d" % (1000 + k))
    for _ in range(4):
        g.cmd("focus_right")
    g.cmd("focus_index", 1)
    g.tail(200, {"open": 16, "close": 16, "click": 12, "focus_left": 9, "focus_right": 9,
                 "focus_index": 6, "cycle_width": 2, "toggle_full": 1, "undo": 2,
                 "dup_add": 1, "unknown_id": 1, "center": 1, "resize": 1},
           ["Chat", "Chat", "Chat", "Browser", "Zendesk"])
    return g.ev


def main():
    for name, fn in [("g1_parent_school_mail_chat", parent),
                     ("g2_writer_research_fullwidth", writer),
                     ("g3_support_20_chat_windows", support)]:
        ev = fn()
        with open(os.path.join(HERE, name + ".json"), "w") as fh:
            json.dump(ev, fh, indent=1)
        print("%-30s %3d events" % (name, len(ev)))


if __name__ == "__main__":
    main()
