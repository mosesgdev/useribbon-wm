# Ribbon live QA 1

Date: 2026-10-13 (night, unattended). Build: `make bundle` (ok). Only RibbonDummy windows were managed
(`RIBBON_ONLY_PIDS` set to dummy pids every time). OmniWM Dev was quit at start and relaunched at end (pid 55897, running).
No product code was edited. Raw data: `/Users/moses/projects/ribbon-scratch/` (`plans.jsonl`, `results.jsonl`, `check_plans.out`, `ribbon*.log`, `frames`, `ax_ops`, `qa_step.py`).

## Harness limits (affect what could be verified)

- Screen Recording not granted to this host process: `screencapture` fails with "could not create image from display". No live HUD screenshots were possible.
- `osascript` / System Events times out (-1712). Window close and key posting were done with a small Swift AX helper (`ax_ops`) instead.
- Synthetic ⌃⌥→ / ⌃⌥← (CGEvent, two attempts) produced no plans. Hotkeys are inconclusive; this needs a manual key press.
- Ribbon writes nothing to `ribbon.log` (empty), so diagnostics come only from plans.

## Summary

| Item | Result |
|---|---|
| Initial tiling, 4 windows (gaps, focused visible) | PARTIAL: gaps/outer 12pt correct; QA 1 not moved on first apply (see B2) |
| Initial tiling, fresh relaunch (3 windows) | PASS (0 mismatches) |
| Command matrix, 29 commands: focus_right x3, focus_left x3, move_left/right, cycle_width x4, cycle_width_back, toggle_full x2, center, stack, focus_down/up, unstack, focus_index 1 and 9, undo x3, redo x2, toggle_float x2 | PASS on frames: plan vs AX within 4pt for every step (0 mismatches). Semantics: see B3 (undo covers focus) and B4 (float) |
| Width cycle wraps, toggle_full restores width | PASS (0.5→0.667→1.0→0.333→0.5; full→restore 0.333) |
| Stack / unstack / undo / redo consistency | PASS on layout (redo replays undo exactly) |
| Close a focused window (window_removed) | FAIL once (B1): focus went to QA 2 instead of left neighbor QA 4. PASS on a second close (focus to QA 4), so intermittent |
| Auto-close churn (2 managed dummies, one closes after 6s) | PASS: both removals re-tile, focus goes to left neighbor, both windows stay on screen |
| window_added (new windows) | PASS: new windows inserted to the right and focused |
| User resize (AX set QA 3 to 900px wide) | PASS: plan width becomes 900px, QA 4 reflows to x=2838 (=1926+900+12), 1 plan logged |
| Feedback loop after resize | PASS: 0 plans over 5s idle (also 0 after the matrix) |
| Hotkeys ⌃⌥→/← | INCONCLUSIVE: no plans from synthetic events (2 attempts) |
| HUD on screen (Liquid Glass, live) | NOT VERIFIED: Screen Recording not granted |
| HUD flat-glass snapshot (`Ribbon --snapshot`) | PASS on content: tiles, focused glow on tile 2, caption "Terminal · 2 of 5", off-viewport tiles faded |
| Command bar | SKIPPED (no fifo command opens it) |
| Quit: Ribbon exits, dummies restored on screen | PASS: all dummy windows on screen after quit (at original 600x532 size) |
| check_plans.py over 51 plans | 1 flagged (line 34, see B4) |
| Idle CPU / RSS | PASS: 0.0% CPU at idle (ps, repeated samples); RSS 49 MB at start, 58-61 MB after the session |

## Bugs (repro + evidence)

### B1 (P1) Closing the focused window can focus an unrelated window, not the left neighbor
Repro: 4 dummies tiled as [QA 2, QA 3, QA 4, QA 1], focus on QA 1 (rightmost). Run `ax_ops <pid> close "QA 1"`.
- Expected (SPEC: "focuses its neighbor (left, else right)"): focus QA 4.
- Actual: first plan after close has `focus: QA 2` (leftmost column), `changed` = all four; then the window_removed plan has QA 2 focused. Ribbon follows the OS's focus change for the closing window before it processes removal.
- Not reproduced on the second attempt (closing focused QA 2 in [QA 3, QA 4, QA 2] gave focus QA 4 correctly), so this depends on which window macOS raises during the close. Plan lines 36-37 in `plans.jsonl`.

### B2 (P1) Initial apply left the first window untiled
First launch with 4 dummies: plan 4 set QA 1 to x=-1901 (off-screen left), but AX still showed QA 1 at (100,468,600x532) on the first check and for ~1.4s after. A `gather` command fixed it. Not reproduced on the relaunch (3 windows, 0 mismatches).
- Suspect: the apply of a `changed` id is dropped if the window is not yet ready/observed when the plan is first applied. Ribbon log is empty, so no evidence beyond the AX comparison.

### B3 (P2, UX/spec) Undo steps are spent on focus moves
Undo stack entries include focus-only commands (`focus_index 9`, `focus_index 1`). After `unstack`, two focus jumps, then `undo`, the first undo reverted the focus jump, not the unstack; it took 3 undos to revert the unstack. The SPEC says undo is for "any layout change" and snapshots are "before each user command", so this is a spec ambiguity. Decide whether focus moves should be undoable.

### B4 (P2) toggle_float on the focused window leaves no focused column
After `toggle_float` on the focused QA 1: plan has `focus: null`, no column with `focused: true`, `focused_index: null`, and the HUD loses its focus indicator. This is the only check_plans.py violation (plan line 34: "map must have exactly one focused column"). The checker may also need a float exception. Floating back via toggle_float_2 re-inserts the window at the far right of the ribbon (unspecified in SPEC).

### B5 (P2) Quit restores the original window size, discarding user resize
After QA 3 was resized to 900px by the user, quit restored all dummies to their launch size (600x532). Probably intended ("puts every window back"), but the window is not restored to its last user size. Confirm intent.

## HUD

- Live Liquid Glass HUD: not verified (screen capture permission).
- Flat-glass snapshot `/Users/moses/projects/ribbon-scratch/shots/snapshot/hud.png`: tiles and focused glow on the second tile are correct, the caption "Terminal · 2 of 5" is correct, and the off-viewport tiles are faded. Also rendered: `commandbar.png`, `onboarding.png`, `onboarding-cheatsheet.png`, `shortcuts.png` (not reviewed). The snapshot forces flat glass, so it says nothing about refraction or translucency.
- Live HUD screenshots: `/Users/moses/projects/ribbon-scratch/shots/` is empty (the `--shot` captures all failed).

## Performance

- Idle CPU: 0.0% (ps, multiple samples, after the matrix and after user resize).
- RSS: 49 MB at start, 58-61 MB after ~60 commands plus churn. No growth check beyond that.
- Plan log idle stability: 0 new lines over 5s idle (after resize and after the matrix).

## Prioritized list

1. P1 B1: closing the focused window may focus a window other than the left neighbor (intermittent, follows OS focus change).
2. P1 B2: first window in a fresh 4-window launch not tiled until a later command (not reproduced on relaunch).
3. P2 B3: undo is spent on focus moves; spec ambiguity to decide.
4. P2 B4: floating the focused window leaves focus null and no focused column (checker violation).
5. P2 B5: quit restores launch size, discarding user resize (confirm intent).

Unverified and needing a human: real hotkeys (⌃⌥ arrows) and the live HUD look (glass, refraction, glow) on the real screen, plus the command bar.
