#!/usr/bin/env python3
"""Generates the QA event scripts (JSON arrays of Ribbon events) in this directory.

Run: python3 qa/scenarios/gen_scenarios.py   (writes s*.json next to this file)
Models a user who opens many apps, jumps between them, and changes layout often.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DISPLAY = {"x": 0, "y": 30, "w": 1920, "h": 1050}
SMALL = {"x": 0, "y": 30, "w": 1280, "h": 800}
BASE = {"x": 0, "y": 0, "w": 800, "h": 600}
APPS = ["Safari", "Slack", "Mail", "Figma", "Terminal", "Notes", "Music", "Calendar",
        "Xcode", "Messages", "Notion", "Finder", "Spotify", "Preview", "Photos"]


def F(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


def display(frame=DISPLAY, did=1):
    return {"type": "display", "id": did, "frame": frame}


def add(wid, floating=False, app=None, title=None):
    app = app or APPS[(wid - 1) % len(APPS)]
    return {"type": "window_added", "id": wid, "pid": 1000 + wid, "app": app,
            "title": title or "%s window %d" % (app, wid), "frame": BASE, "floating": floating}


def rm(wid):
    return {"type": "window_removed", "id": wid}


def focused(wid):
    return {"type": "window_focused", "id": wid}


def cmd(name, arg=None):
    e = {"type": "command", "name": name}
    if arg is not None:
        e["arg"] = arg
    return e


def resize(wid, w, h=600):
    return {"type": "window_resized", "id": wid, "frame": F(0, 0, w, h)}


def title(wid, t):
    return {"type": "window_title", "id": wid, "title": t}


def query():
    return {"type": "query"}


def cmds(*names):
    return [cmd(n) for n in names]


def repeat(events, n):
    return events * n


SCENARIOS = {}


def scenario(name):
    def deco(fn):
        SCENARIOS[name] = fn
        return fn
    return deco


@scenario("s01_eight_apps_close_focused")
def _():
    # Morning: opens 8 apps, hops around, closes a focused one, keeps hopping.
    ev = [display()] + [add(i) for i in range(1, 9)]
    ev += cmds("focus_left", "focus_left", "focus_left", "focus_left")  # now on 4
    ev += [rm(4)]                                                       # close focused -> expect 3
    ev += cmds("focus_right", "focus_right")                            # -> 5
    ev += [rm(6)]                                                       # close a non-focused? (6 is right of 5)
    ev += cmds("focus_left", "focus_right", "focus_right", "focus_right")
    ev += [query()]
    return ev


@scenario("s02_rapid_focus_spam")
def _():
    # Fifteen windows, then 40 rapid left/right key presses with a few OS clicks mixed in.
    ev = [display()] + [add(i) for i in range(1, 16)]
    seq = ["focus_left", "focus_left", "focus_right", "focus_left", "focus_left", "focus_left",
           "focus_right", "focus_right", "focus_right", "focus_right", "focus_right", "focus_left"]
    ev += repeat(cmds(*seq), 3) + cmds("focus_left", "focus_right", "focus_left", "focus_right")
    ev += [focused(7), focused(12), focused(3)]  # clicks on visible windows
    ev += cmds("focus_right", "focus_right", "focus_left")
    ev += [query()]
    return ev


@scenario("s03_stack_unstack_cycle")
def _():
    # Tries to group related windows (two terminals beside a browser), then pops them back out.
    ev = [display()] + [add(i) for i in range(1, 5)]
    ev += cmds("focus_left", "focus_left")          # focus 2
    ev += cmds("stack")                              # 2 under 1
    ev += cmds("focus_up", "focus_down", "focus_down")  # down past end is a no-op
    ev += cmds("stack")                              # already in col 0: no-op
    ev += cmds("unstack")                            # 2 back to its own column
    ev += cmds("unstack")                            # single window: no-op
    ev += cmds("cycle_width", "cycle_width", "cycle_width", "cycle_width", "cycle_width")
    ev += cmds("cycle_width_back", "cycle_width_back", "cycle_width_back")
    ev += cmds("move_right", "move_left", "move_left")  # moves column 2 left
    ev += cmds("focus_right", "stack", "focus_left", "stack")
    ev += [query()]
    return ev


@scenario("s04_fullwidth_toggle_twice_undo_chain")
def _():
    # Presses F to read a doc full width, presses F again, then undoes a long chain and redoes it.
    ev = [display()] + [add(i) for i in range(1, 6)]
    ev += cmds("focus_index")                         # no arg -> error plan
    ev += [cmd("focus_index", 2)]
    ev += cmds("toggle_full", "toggle_full", "toggle_full", "toggle_full")
    ev += cmds("cycle_width", "toggle_full", "toggle_full")
    ev += repeat(cmds("undo"), 10)
    ev += repeat(cmds("redo"), 10)
    ev += cmds("undo", "undo", "undo", "undo", "undo", "undo", "undo", "undo", "undo", "undo", "undo", "undo")
    ev += [query()]
    return ev


@scenario("s05_windows_close_while_stacked")
def _():
    # Three stacked windows in one column; the user closes them one by one.
    ev = [display()] + [add(i) for i in range(1, 6)]
    ev += cmds("focus_left")                          # focus 4
    ev += cmds("stack")                               # 4 under 3 -> col [3,4]
    ev += cmds("focus_left", "stack")                 # 2 -> col1 [1,2]? (2 stacks under 1)
    ev += [focused(3)] + cmds("stack")                # 3 stacks into col of 2
    ev += [rm(3)]                                     # close stacked (middle) window
    ev += [rm(4)]                                     # close focused bottom of stack
    ev += [rm(2)]                                     # empties a column
    ev += [query()]
    ev += cmds("focus_right", "focus_left")
    ev += [rm(5), rm(1)]
    ev += [query()]
    return ev


@scenario("s06_window_resized_drags")
def _():
    # The user drags window edges; some drags are tiny (echo of our own frames), some are real.
    ev = [display()] + [add(i) for i in range(1, 4)]
    ev += [resize(3, 942), resize(3, 944)]          # echo of our own frame (within 2px): ignored
    ev += [resize(3, 900), resize(3, 1000), resize(3, 1200)]  # drag wider in steps
    ev += cmds("cycle_width")                       # from px to next preset
    ev += [resize(3, 640)]                          # drag close to 0.333 preset: should snap
    ev += cmds("toggle_full", "toggle_full")
    ev += [resize(2, 420), resize(2, 300)]          # shrink focused-left window
    ev += cmds("focus_left", "toggle_full")
    ev += [resize(99, 500)]                         # unknown id
    ev += [query()]
    return ev


@scenario("s07_floating_dialogs")
def _():
    # Save/Preferences dialogs float over the ribbon; user moves through them.
    ev = [display()] + [add(i) for i in range(1, 4)]
    ev += [add(10, floating=True, app="Finder", title="Save As")]
    ev += [focused(10)]
    ev += cmds("focus_left")                        # from floating: re-enter ribbon
    ev += [focused(10)] + cmds("focus_right")
    ev += [add(11, floating=True, app="Safari", title="Preferences")]
    ev += [focused(11)] + cmds("toggle_float")      # tile the prefs window: appended at end
    ev += cmds("focus_left")
    ev += [focused(10), rm(10)]                     # dialog closes while focused
    ev += cmds("focus_left", "focus_right", "toggle_float")
    ev += [rm(11), query()]
    return ev


@scenario("s08_display_shrinks_midsession")
def _():
    # Six windows open, then the laptop goes from the external 1920 display to a 1280 one.
    ev = [display()] + [add(i) for i in range(1, 7)]
    ev += [cmd("focus_index", 1)] + cmds("cycle_width", "cycle_width")
    ev += [display(SMALL)]
    ev += cmds("focus_right", "focus_right", "focus_right")
    ev += [query()]
    ev += [display(DISPLAY)]                        # plugged back in
    ev += cmds("focus_left")
    ev += [query()]
    return ev


@scenario("s09_focus_index_edges")
def _():
    # Hotkeys 1..9 pressed beyond the number of columns, plus junk args.
    ev = [display()] + [add(i) for i in range(1, 4)]
    ev += [cmd("focus_index", 9), cmd("focus_index", 0), cmd("focus_index", -1)]
    ev += [cmd("focus_index", "2"), cmd("focus_index", 2.5), cmd("focus_index", "abc")]
    ev += [cmd("focus_index"), cmd("focus_index", None), cmd("focus_index", 1)]
    ev += [cmd("focus_index", 7), query()]
    return ev


@scenario("s10_commands_with_no_windows")
def _():
    # Hotkeys pressed on an empty desktop before anything is open.
    ev = [display()]
    ev += cmds("focus_left", "focus_right", "focus_up", "focus_down", "move_left", "move_right",
               "cycle_width", "cycle_width_back", "toggle_full", "stack", "unstack", "center",
               "toggle_float", "undo", "redo", "gather", "query_nothing_here")
    ev += [cmd("focus_index", 1), cmd("focus_window", 5)]
    ev += [query()]
    ev += [add(1), rm(1)]
    ev += cmds("undo", "focus_left", "toggle_float")
    ev += [query()]
    return ev


@scenario("s11_duplicate_and_unknown_ids")
def _():
    # Duplicate adds, removes of unknown or already-removed ids, events for ids never seen.
    ev = [display(), add(1), add(1), add(2)]
    ev += [rm(99), rm(1), rm(1)]
    ev += [focused(42), resize(42, 500), title(42, "ghost")]
    ev += [focused(2), title(2, "renamed")]
    ev += [cmd("focus_window", 42), cmd("focus_window"), cmd("focus_window", 2)]
    ev += [add(2, floating=True), query()]
    return ev


@scenario("s12_center_scroll_mode")
def _():
    # Same as a normal day but with scroll=center configured; run with --config.
    ev = [display()] + [add(i) for i in range(1, 9)]
    ev += cmds("focus_left", "focus_left", "focus_left", "focus_left", "focus_left")
    ev += cmds("center", "focus_right", "focus_right", "focus_left", "center")
    ev += [cmd("focus_index", 8), cmd("focus_index", 1), query()]
    return ev


@scenario("s13_undo_after_display_shrink")
def _():
    # Focus far right, change a width, the display shrinks, then undo.
    ev = [display()] + [add(i) for i in range(1, 6)]
    ev += [cmd("focus_index", 5), cmd("cycle_width")]
    ev += [display(SMALL)]
    ev += cmds("undo")
    ev += [query()]
    ev += cmds("redo")
    ev += [query()]
    return ev


@scenario("s14_gather_after_wake")
def _():
    # Mac sleeps and wakes with a different visible frame; the app calls gather.
    ev = [display()] + [add(i) for i in range(1, 5)]
    ev += [cmd("focus_index", 4)]
    ev += [display(SMALL), cmd("gather")]
    ev += [display(DISPLAY), cmd("gather")]
    ev += [query()]
    return ev


@scenario("s15_new_window_while_scrolled_far")
def _():
    # Ten windows, user parks on the first one, opens an 11th: where does it land?
    ev = [display()] + [add(i) for i in range(1, 11)]
    ev += [cmd("focus_index", 1)]
    ev += [add(11, app="Terminal", title="new shell")]
    ev += cmds("focus_right", "focus_left")
    ev += [add(12, app="Safari", title="New tab")]
    ev += [query()]
    return ev


@scenario("s16_min_size_clamp_treated_as_drag")
def _():
    # Four windows at 0.5 width. Window 2's app has a 1000px minimum width, so macOS
    # reports 1000 after we place it at 942. The user did not drag anything.
    ev = [display()] + [add(i) for i in range(1, 5)]
    ev += [cmd("focus_index", 2), resize(2, 1000)]
    ev += cmds("cycle_width_back")
    ev += [query()]
    return ev


@scenario("s17_undo_redo_chain_of_ten")
def _():
    # Ten mixed layout changes in a row, then undo all, redo all, then undo past the limit.
    ev = [display()] + [add(i) for i in range(1, 5)]
    ev += cmds("focus_left", "cycle_width", "move_right", "stack", "toggle_full",
               "unstack", "cycle_width_back", "move_left", "toggle_float", "center")
    ev += repeat(cmds("undo"), 10)
    ev += repeat(cmds("redo"), 10)
    ev += repeat(cmds("undo"), 3)
    ev += [query()]
    return ev


@scenario("s18_day_in_the_life")
def _():
    # Long mixed session: ~80 events of opening, switching, resizing and closing.
    ev = [display(), add(1, app="Safari", title="Docs"), add(2, app="Slack"), add(3, app="Mail")]
    ev += cmds("focus_left", "focus_left", "cycle_width", "focus_right")
    ev += [add(4, app="Figma"), add(5, app="Terminal"), add(6, app="Notes"), add(7, app="Music")]
    ev += cmds("focus_left", "focus_left", "focus_left", "focus_right", "stack")
    ev += [focused(3), focused(5)]
    ev += [add(8, app="Calendar"), add(9, app="Xcode"), add(10, app="Messages")]
    ev += [add(11, floating=True, app="Finder", title="Move to…")]
    ev += [focused(11), cmd("focus_left"), cmd("toggle_float")]
    ev += repeat(cmds("focus_right"), 3) + repeat(cmds("focus_left"), 4)
    ev += [rm(9), rm(5), cmd("toggle_full"), resize(4, 1100), cmd("toggle_full")]
    ev += cmds("undo", "undo", "redo")
    ev += [cmd("center"), cmd("focus_index", 2), add(12, app="Preview")]
    ev += cmds("focus_right", "focus_right", "unstack", "cycle_width", "move_left")
    ev += [rm(3), rm(12), rm(6)]
    ev += repeat(cmds("focus_left"), 5)
    ev += [display(SMALL)] + cmds("focus_right", "cycle_width")
    ev += [display(DISPLAY), query()]
    return ev


@scenario("s19_close_last_window_then_reopen")
def _():
    # Everything closed, then a new window opens: the first window must be focused and visible.
    ev = [display(), add(1), add(2), add(3)]
    ev += [rm(3), rm(2), rm(1)]
    ev += [query()]
    ev += [add(4), query(), add(5)]
    return ev


def replaced(old, new, app="TextEdit"):
    return {"type": "window_replaced", "old": old, "new": new, "pid": 1002, "app": app, "title": "%s tab %d" % (app, new)}


@scenario("s20_native_tab_switches")
def _():
    # A TextEdit tab group in the middle column at 2/3 width: clicking, opening and closing native tabs hands the column to
    # the tab now shown. Width, stack rows, Ribbon tab-group membership, undo and focus stay with the column.
    ev = [display(), add(1), add(2, app="TextEdit"), add(3), focused(2), cmd("cycle_width")]
    ev += [replaced(2, 12), replaced(12, 22), replaced(22, 2)]            # tab clicks
    ev += [add(9, app="TextEdit"), replaced(2, 9)]                        # a tab opened: its add arrived before the replace
    ev += [replaced(77, 78), replaced(9, 9)]                              # unknown old window, same window: nothing happens
    ev += [focused(1), cmd("focus_right"), cmd("stack")]                  # the tab group joins window 1 in a stack
    ev += [replaced(9, 19), replaced(1, 11)]                              # both rows of the stack switch tabs
    ev += cmds("toggle_tabs")                                             # the stack becomes a Ribbon tab group
    ev += [replaced(19, 29), replaced(11, 21), query()]
    ev += cmds("undo", "undo", "redo")
    ev += [replaced(29, 39), rm(39), query()]
    return ev


@scenario("s21_native_tab_in_the_pin")
def _():
    # The same TextEdit tab group pinned to the left edge: its tab switches keep the pin (side, width, focus), also across unpin/undo.
    ev = [display(), add(1), add(2, app="TextEdit"), add(3), focused(2), cmd("pin")]
    ev += [replaced(2, 12), replaced(12, 22)]                             # tab clicks in the pin
    ev += [add(9, app="TextEdit"), replaced(22, 9)]                       # a tab opened (its add came first): it joins the pin, not the ribbon
    ev += [focused(3), replaced(9, 19), query()]                          # a switch while the ribbon has the focus
    ev += cmds("unpin", "undo", "undo", "redo")
    ev += [replaced(19, 29), query()]
    return ev


# ---- minimal repros for suspected bugs (see qa/reports/mini-validation-1.md) ----

@scenario("r01_floating_focus_right_goes_left")
def _():
    # Dialog has focus; user presses Right. Expected: move toward the right (next column).
    return [display(), add(1), add(2), add(3), add(10, floating=True, app="Finder", title="Save"),
            focused(10), cmd("focus_right"), query()]


@scenario("r02_floating_focus_scroll_not_clamped")
def _():
    # Scrolled to the end, dialog focused, then both trailing windows close. Scroll should clamp.
    return [display(), add(1), add(2), add(3), add(4), add(5), add(6), add(10, floating=True),
            cmd("focus_index", 6), focused(10), rm(5), rm(6), query()]


@scenario("r03_floating_focus_display_shrink_scroll")
def _():
    # Scrolled far right, dialog focused, display shrinks. Column scroll should stay in range.
    return [display(), add(1), add(2), add(3), add(4), add(5), add(6), add(10, floating=True),
            cmd("focus_index", 6), focused(10), display(SMALL), query()]


@scenario("r04_focus_window_unknown_id_shows_map")
def _():
    # focus_window for an id we never saw: nothing changes, but the HUD should not flash.
    return [display(), add(1), add(2), cmd("focus_window", 77)]


@scenario("r05_toggle_float_tile_jumps_to_end")
def _():
    # Floating dialog is tiled from a column in the middle of the ribbon.
    return [display(), add(1), add(2), add(3), add(4), add(5), cmd("focus_index", 2),
            add(9, floating=True), focused(9), cmd("toggle_float"), query()]


@scenario("r06_min_size_echo_widens_column")
def _():
    # Window 2 has a 1000px minimum. The app reports 1000 after we place it at 942.
    return [display(), add(1), add(2), add(3), add(4), focused(2), resize(2, 1000), query()]


def main():
    for name, fn in SCENARIOS.items():
        events = fn()
        path = os.path.join(HERE, name + ".json")
        with open(path, "w") as fh:
            json.dump(events, fh, indent=1)
            fh.write("\n")
        print(path, len(events))


if __name__ == "__main__":
    main()
