# Ribbon UX simulation 1 (six personas)

Scope: layout core only, via `core/target/release/ribbon-sim` (no GUI, no AX). Built from the current tree with
`cargo build --release`. Scripts: `qa/ux-sim/gen_personas.py` (events), `qa/ux-sim/analyze.py` (metrics, traces).
Plans and per-event traces: `qa/ux-sim/out/`. Minimal repros: `qa/ux-sim/repro_*.json`. No product code was edited.

## Metrics

| Persona (display) | events (commands) | changed per user event avg / max | visibly moved avg (plans with change) | focused window fully on-screen | scroll steps flush to entry edge | unneeded scrolls | no-op HUD flashes | min visible column | checker violations |
|---|---|---|---|---|---|---|---|---|---|
| A dev (3840x1200) | 118 (80) | 2.15 / 8 | 2.90 | 100% (53/53) | 21/21 | 0 | 28 | 326 px (3 plans, from a drag) | 0 |
| B student (1512x982) | 132 (70) | 3.04 / 12 | 2.87 | 98.7% (76/77) | 16/16 | 0 | 12 | 417 px | 0 |
| C designer (2560x1440) | 118 (76) | 1.94 / 6 | 2.59 | 100% (49/49) | 19/19 | 0 | 28 | 676 px | 0 |
| D tab hoarder (1920x1030) | 104 (70) | 2.96 / 23 | 2.85 | 100% (69/69) | 29/29 | 0 | 17 | 623 px | 0 |
| E display swap (1512 / 2560) | 121 (80) | 2.45 / 9 | 2.57 | 98.6% (70/71) | 34/34 | 0 | 16 | 316 px | 0 |
| F chaos (1920x1055) | 150 (101) | 0.95 / 6 | 2.24 | 100% (50/50) | 3/4 | 1 (f_chaos#81) | 69 | 623 px | 0 (2 intentional engine errors) |

Notes on the metrics:
- "Changed" is the `changed` list per user event (command, click, add, remove, resize). Focus moves that do not scroll
  changed 0 frames in every persona, as intended.
- "Visibly moved" excludes off-screen parking flips. Most of the high `changed` counts are parking reshuffles.
- "Focused window fully on-screen" counts plans where focus is a tiled window with a frame. Floating focus has no
  frame and is excluded. No focused window was wider than its display.
- "Scroll steps flush to entry edge": for focus_left/right that scrolled, the target must sit flush with the edge it
  entered from. All tiled steps did, so scrolling was minimal.
- "No-op HUD flashes": `show_map` true, `changed` empty, focused column unchanged.
- The `check_plans.py` invariants (no overlap, on-screen intersects display, off-screen slivers, single focused column,
  error-free) pass on all personas, including per-segment checks for E. F's two errors are the intended
  `bogus_command` and `focus_index` with no arg.
- `map.focused_index` and column `focused` flags were consistent with `focus` in every plan.

## Findings (ranked)

### P1-1: Undo/redo leave the focused window off-screen (no reveal after restore)
Repro A (no display change, 10 events): `qa/ux-sim/repro_undo_offscreen_focus.json`
`add 22, add 23, focus_left, add 25, add 26, focus_right, focus_left, toggle_full, remove 25, undo`
- Expected: after undo, focused window 26 is fully visible (the ribbon reveals it), as after every other focus change.
- Observed: focus=26, but its frame is `x=-737, w=738, on_screen=false`. The viewport restored from the snapshot
  (start 0.67) and nothing revealed the focused column. Same in B#117 (`persona b`).
- Repro B (display change, `repro_undo_after_display_swap.json`): undo leaves focus=5 at `x=-512`, so only about a
  third of it is on-screen. Same in E#21.
- Cause (likely): SPEC/README list reveal after focus, add, remove, move, width, resize and display, but not after
  undo/redo, which restore `scroll` from the snapshot as-is.
- Impact: the user presses ⌃⌥Z and their window vanishes off the left edge. This breaks "always know where you are".

### P2-1: Undo after a window close silently reverts an older layout change
Repro B (`qa/ux-sim/repro_undo_skips_close.json`): `add 22, add 23, add 25, toggle_full, remove 25, undo`
- Expected: undo reverses the most recent thing the user did. Either the close comes back, or the HUD says what happened.
- Observed: the close is not in the undo stack, so undo reverts `toggle_full`. Window 25 stays gone, nothing says so,
  and the layout jumps back. This is also seen in B#117.
- This follows the spec (removals are not layout changes), but the user's mental model is "undo my last action".

### P2-2: Floating dialog focus_right lands on the anchor (leftmost column), not the column to its right
Repro C (`qa/ux-sim/repro_floating_focus_right_goes_to_anchor.json`):
`display 1512x949, add 1 Safari, add 2 Mail, add 3 Notes, window_focused 1, add 10 floating, window_focused 10, focus_right`
- Expected: focus_right from a dialog steps right, to column 2 (Mail).
- Observed: focus=1 (Safari, the anchor, leftmost). This matches the documented "re-enter at anchor" rule, but it looks
  like the arrow went the wrong way. C#18 shows the same thing in the designer persona.
- Note: `qa/reports/qa-round-2.md` (P2-1) calls this a silent no-op. That is stale for the current build, which moves
  focus to the anchor. The direction problem is still there.

### P2-3: Edge no-op presses flash the ribbon map
Repro (`qa/ux-sim/repro_edge_noop_flashes_hud.json`): `display 1512x949, add 1 Safari, focus_left, focus_right, focus_up`
- Expected: a press that changes nothing shows no HUD (principle 2: the pill appears on every change).
- Observed: `show_map=true`, `changed=[]`, focus unchanged. Counts: A 28 of 80 commands, C 28, F 69 of 101, D 14 of
  focus_right spam. This is the designed "orientation feedback at edges" in the README, but for ADHD users the repeated
  flash reads as noise and conflicts with the spec's flash-on-change rule.

### P2-4: Floating focus_left scrolls a fully visible anchor away
Found only in `f_chaos` (not minimized): events #077 to #081, `focus_down`, `cycle_width_back`, `click 10`,
`toggle_float`, `focus_left`. The anchor (window 8, `x=331`, fully visible) ends at `x=966` after the ribbon scrolls
`-1455 px`, and window 2 ends at `-942`. Expected: no scroll for a visible anchor. Observed: a large scroll.
Not minimized. Reproduce by replaying `qa/ux-sim/f_chaos.json` up to event 81 and reading plans 77 to 81.

### P3-1: Dragged columns have no minimum width
Repro (`qa/ux-sim/repro_drag_tiny_column_3840.json`): `display 3840x1170, add 1 Zed, add 2 Terminal, window_resized 2 w=300`
- Observed: a 300 px column (7.8% of width, in A it was 326 px) and it is focused by the next focus_index.
- Expected: a floor or snap for drags that are much narrower than any preset. Tiny columns are unreadable on laptops too
  (E: 316 px on 1512 px).

### P3-2: Big jumps reshuffle invisible windows
D#61: `focus_index 1` after 25 windows. `changed` = 23, but only 4 are visibly moved. The other 19 are off-screen parking
flips (`x=1919`). Expected: few AX writes for a jump. Observed: about 23 writes, most of them invisible.

## UX improvement ideas (no new settings)
1. Reveal after undo/redo too. Run the same "scroll minimally to the focused column" step after undo and redo as after
   focus. This fixes P1-1 and makes the restored state match what the HUD shows.
2. Name what undo did. The HUD caption could say "Undid: Full width · Notes" (or "Closed windows aren't undone; undid
   Full width"). That makes the close-then-undo case (P2-1) legible without new rules.
3. Silence edge presses. At an edge, do a small bump on the edge column and skip the full HUD. Show the HUD only when
   something moved. This fixes P2-3 and keeps the orientation cue.
4. Step from floating windows relative to where the dialog sits. Use the tiled column under the dialog's on-screen
   centre (or its nearest neighbour), not the last-focused anchor. Then focus_right from a picker goes right, which is
   what the arrow says (P2-2).
5. Snap tiny drags and park off-screen windows cheaply. Drags narrower than the smallest preset snap to it (P3-1), so
   no column is unreadable. Parking can keep off-screen windows in place where possible, so a big jump moves about
   four windows, not 23 (P3-2).

## Not reproduced / out of scope
- The sim has no focus oracle, so click, close and move targets were random picks from the live set (documented in
  `gen_personas.py`). A real user would not be this random, so treat the focus-move numbers as shape, not habit.
- The sandbox blocked writes under `qa/ux-sim/` and `qa/reports/` until the sandbox was disabled for those commands.
  No writes outside those directories.
