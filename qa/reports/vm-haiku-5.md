# Ribbon VM QA report (haiku-5)

Build: `main` at aa468a7 (clean tree), `build/Ribbon.app` + `app/.build/release/RibbonDummy`, deployed to VM `ribbon-test` (macOS 27.0). Host was not touched. Screenshots and helper scripts: `/Users/moses/projects/ribbon-scratch/vm/qa5/`.

Caveat for all screenshots: the VM's own "Viewer has disconnected" / "Your screen is being controlled" notification sits over the top-centre of the captures and hides part of the top of the screen (including the tab bar and any toast).

## Summary

| # | Item | Result | Evidence |
|---|------|--------|----------|
| 1 | Tabs (toggle to tabs / stack / tabs, next_tab, undo, look) | PASS | Plan log: "Tab group: RibbonDummy + RibbonDummy", "Stacked", "Tabs", "Undid: tabs"; `next_tab` cycles active 1 to 0. Tab-bar screenshot partly obscured. |
| 2 | Stack width floor (`--min-width 890` + normal window) | PASS | Plan: col1 width 890 for both 81 and 82 (`widths [890, 890]`), no overlap with col0 (ends x=110, col starts x=122), 0 plans in 5 s idle. Smoke also passes. |
| 3 | Stack height overflow | SKIP | `RibbonDummy` has only `--min-width`, no min-height option. |
| 4 | Width hotkeys 0.25 / 0.5 / 1.0 + undo | PASS | 25 % -> 241 px, 50 % -> 494 px, 100 % -> 1000 px; toasts "Width 25 %", "Width 50 %", "Width 100 %"; undo "Undid: width", redo "Redid: width"; sequence restored correctly. |
| 5 | Focus mode (`toggle_focus`, ⌃⌥B) | UNCLEAR | `qa_state` reports `overlay: blur` and a hole around the focused window. Blur renders correctly in two captures (3 windows, and 6 windows with a middle window focused). In a third capture (6 windows, focused window narrowed to 25 %), neighbour windows were pixel-identical to the unblurred state. |
| 6 | Dim (`otherWindows=dim`, `dimLevel`) | PASS | Medium dims the neighbour clearly; subtle is visibly lighter (mean RGB of neighbour region 158/32/56 medium vs 204/41/72 subtle). |
| 7 | Hold ⌃⌥ strip | UNCLEAR | Held ctrl+option via vncdo `keydown` for 1.5 s: no strip in the capture. Either not triggered by VNC modifier events or not shown in the VM. |
| 8 | Command bar (`bar`, type "tab") | UNCLEAR (input problem) | Bar opens with the window/action list. Typing "tab" produced "ta" only. Subsequent "b" and "e" did not register. Results for "ta" look right. Duplicate rows (see issue 3). |
| 9 | `vmsmoke` | 1 FAILED of 58 checks | Only failure: "swipe smoothness (3 pairs)", latency 1.24 frames (known flaky). `check_plans.py`: 291 plans, 0 problems. |
| 10 | Robustness: 2 seeds x 30 random commands | PASS | Final plan vs AX: 6/6 windows present, 0 frame mismatches > 4 pt, no off-screen windows, no `error` values except the expected one (below). |

## Details

### 1. Tabs
- `toggle_tabs` on focused window 44 with neighbour 43 creates a 2-window tab group (`tabBars: 1`, count 2, active 44). Toast: "Tab group: RibbonDummy + RibbonDummy".
- `toggle_tabs` again: stack, toast "Stacked", stacked frames 43 at (518,42,494x323) and 44 at (518,377,494x322).
- Again: tabs, toast "Tabs".
- `next_tab` moves active 1 -> 0 (plan `active` changes, toast "Tab 1 of 2 · RibbonDummy").
- `undo` from tabs returns to stack ("Undid: tabs"), as expected.
- Tab bar look: Safari-style pill row at the top of the column, grey inactive tabs with a small app icon and title, a white-ish active tab, legible text at about 12 pt. Looks clean and cheap-but-fine, not yet premium. The toast did not show in the capture (it fades before the capture, and the VM overlay covers the top band).
- Screenshots: `t1-tabs.png`, `t1-tabs-toast.png`, `t1-tabs-immediate.png`.

### 2. Stack width floor
- Stack of `Doc 3` (last window, min 890) with `Doc 2` (normal window): both windows at width 890 (col1 frame 122..1012). Left neighbour ends at x=110, so no overlap.
- Plan settles: 0 new plans in 5 s idle.
- Screenshot: `s2-stack.png`.

### 3. Stack height overflow
- Skipped: RibbonDummy has no min-height option.

### 4. Width hotkeys
- Verified with the JSON FIFO line `{"type":"command","name":"set_width","arg":<f>}` (see `/Users/moses/projects/ribbon-scratch/vm/qa5/cmd.sh`).
- 0.25 -> 241 px, 0.5 -> 494 px, 1.0 -> 1000 px (full width minus gap).
- Undo/redo: correct order, toasts "Undid: width" / "Redid: width".

### 5. Focus mode
- `toggle_focus` on: `chain2.overlay = blur`, `focusMode = true`, `dimHoles` contains the focused frame.
- Capture A (`f5-focus-on.png`, 6 windows, focused window narrowed to 25 %): neighbour windows pixel-identical to the focus-off capture (`f5-focus-off.png`). Desktop region tinted.
- Capture B (`f5-focus-on2.png`, 3 windows, focused right-most): neighbour Doc 1/2 clearly blurred, focused Doc 3 sharp with ring. Works.
- Capture C (`f5-mid-blur.png`, 6 windows, focused middle-left): blur on the right side, focused Doc 4 sharp. Works.
- So: the blur works in most cases, but one capture showed no blur while the state reported it. Not reproduced. Needs a host check to decide whether this is a race (overlay not yet ordered above neighbours) or a rendering issue in the VM.
- Toggled off afterwards (`overlay: off`).

### 6. Dim
- Set `defaults write com.makeautomation.ribbon otherWindows -string dim` and `dimLevel -string medium|subtle`, restarted, `overlay: dim`.
- Medium: `d6-dim-medium.png` (clearly dimmed). Subtle: `d6-dim-subtle.png` (lighter).
- Defaults were removed afterwards (`otherWindows`, `dimLevel`).

### 7. Hold ⌃⌥ strip
- Not shown. `h7-hold-strip.png` shows the normal layout with the VM notification. Could be VNC modifiers not triggering the hold, or the strip not showing in the VM. Needs a manual check on the host (out of scope for this run).

### 8. Command bar
- `bar` opens a centred "Find a window or action" panel: rows for windows (app icon, title, app name on the right) and actions (with shortcut chips), with a key-hints footer (Go / Move / Close). Clean, calm, well-spaced.
- Typing: the first click on the field closed the bar (VNC coordinates are 1:1 with the 1024x768 image here, not 2x). After reopening and clicking the field, "ta" produced filtered results ("Take out of stack", "Make tabs / toggle tabs", "Make a tab group with RibbonDummy" x2, "Previous tab"). "b" and "e" did not register afterwards, so the filter stayed at "ta". Possibly a VNC artifact, but a Ribbon focus bug is not ruled out. Screenshots: `b8-bar.png`, `b8-bar-tab3.png`, `b8-bar-crop.png`, `b8-bar-e-crop.png`.

### 9. vmsmoke
- Summary: `1 FAILED of 58 checks`. Failed: "swipe smoothness (3 pairs) latency 1.24 frames". Everything else PASS, including stack floor, focus mode on/off, undo, width keys, close layout, and check_plans.py (291 plans, 0 problems).
- Full log: `/Users/moses/projects/ribbon-scratch/vm/qa5/smoke.log`.

### 10. Robustness
- Seed 5 and seed 11, 30 random commands each (list in the robust.py run; includes set_width 0.25/0.5/1.0, focus, move, stack/unstack, toggle_tabs, tab_with, next_tab, cycle_width, undo, redo, toggle_focus).
- After each run: 6 plan windows = 6 AX windows; 0 frame mismatches > 4 pt; no windows off-screen; plan `on_screen` flags agree with AX.
- The only plan errors: `tab_with needs a direction: left or right` (3 occurrences), from the bare command in my list. Expected, not a bug.

## Top 5 issues (by user impact)

1. **Command bar drops keystrokes after the first two letters** (item 8). Repro: `bar`, click the field, type "tab". Field shows "ta"; "b" and "e" are not registered. Verify on the host with a real keyboard before filing; if it reproduces, search is effectively broken for multi-letter queries.
2. **Focus mode blur sometimes does not cover the neighbours** (item 5). Repro: 6 windows, narrow the focused window with `set_width 0.25`, then `toggle_focus`. `qa_state` says `overlay: blur`, but the neighbour windows are pixel-identical to the unblurred state. Not reproduced in two other captures. Likely a z-order or timing race in the overlay.
3. **Command bar shows duplicate, ambiguous rows** (item 8). "Make a tab group with RibbonDummy" appears twice. All dummy windows have the same app name, so rows are indistinguishable. Repro: 3+ windows of one app, `bar`, type "tab". Rows should show window titles.
4. **Toasts and tab-group labels use the app name, not the window title** (item 1). "Tab group: RibbonDummy + RibbonDummy" tells the user nothing. Repro: `toggle_tabs` on two windows of the same app.
5. **Swipe smoothness check fails** (item 9). `latency 1.24 frames` in one run of three pairs. Known flaky; listed here so it is not forgotten.

Also noted but not ranked: the hold ⌃⌥ strip did not appear (item 7, UNCLEAR), and the tab-bar toast could not be captured because the VM notification overlaps the top of the screen.

## UX / visual notes (ADHD-friendliness)

- **Calm baseline:** the tile layout, thin focus ring and command-bar footer are quiet. The command-bar panel is easy to scan, with clear icon/title/shortcut columns and a plain key-hint footer. Good.
- **Focus mode and dim are the strongest focus aids.** Dim medium is clearly readable (neighbour darker, focus sharp). Focus blur, when it works, reads well. The one rendering miss (issue 2) would undermine trust in the feature, so it matters more than its frequency suggests.
- **Toasts are the weakest link.** They are brief and in some captures not visible at all. For users who lose track easily, a confirmation that names what changed ("Tabs: Doc 3 + Doc 4") and stays on screen a little longer would help more than a generic label.
- **Tab bar:** Safari-like, legible, and not overwhelming. The inactive tabs are low contrast. Labels should show the window title (issue 4), since two identical "RibbonDummy" tabs give no cue about which is which.
- **Command bar:** keep one row per distinct window (title first), and never show two identical rows. Duplicated options add decision load, which is the opposite of the calm goal.
- **Width presets:** the 25 / 50 / 100 % toasts are short and clear. Good.
- **Overall:** nothing jumped or flashed in the captured states. The main ADHD risks are invisible feedback (toasts) and ambiguous choices (duplicate rows).

## Not covered / limits

- No host verification (per instructions).
- No strip screenshot (item 7).
- No height-overflow test (item 3).
- The VNC coordinate scale differs from the note in `vnc` (1:1 here); clicks were calibrated against the screenshot.
- No source changes; nothing committed.
