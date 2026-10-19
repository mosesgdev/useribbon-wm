# Ribbon live regression QA, session 2

Model: Haiku 5.5, live in macOS 27 VM, real keys + real mouse via VNC
Date: 2026-10-14
Build under test: commits a8c8d0c (fixes) and 9aefe79 (heights, edge adoption), on the host build deployed by `vmstart`.
Session: 4 dummy windows ("Doc 1".."Doc 4"). About 75 actions (keys, mouse drags, plan-log reads).
Screenshots: `/Users/moses/projects/ribbon/qa/reports/vm-haiku-2/` (numbered in run order; `undo-sweep-N.png` for the undo sweep).
Plan data read from `/tmp/hk.jsonl` in the VM. Pixel positions in the drag checks were measured from the screenshots (PIL, column scan).
Access note: `vssh` needed the sandbox disabled to reach the VM (192.168.64.3). Nothing on the host was launched.

## Verification

| item | result | evidence |
|---|---|---|
| P1-1 command bar: `wid`, ↓ (highlight on "Full width"), Enter runs Full width | **fixed.** Toast "Full width", Doc 1 went full width. One run. | 03 (highlight on Full width), 04 (full width, toast in plan) |
| P2-1 HUD caption names the window | **fixed.** "You're here: RibbonDummy — Doc 2 · 2 of 4". Map tiles still look identical (not a fix target in this round). | 06 |
| P2-2 stack edge message | **fixed inside a stack.** "Bottom of the stack" with a 2-window stack, "Top of the stack" at the top. **New issue** for single windows, see N-1. | 13, 15 |
| P2-3 carry gives feedback | **fixed.** "Moved" toast on ⌃⌥⇧←. Undo gives "Undid: move" and restores the layout. | 38, 39 |
| P2-4 "wid" no longer lists "Back to last window" | **fixed.** "wid" lists Make wider and Full width only. | 03 |
| P3-1 muted text legible | **looks fixed (visual check).** Row app names and the no-match line read clearly on glass. | 48, 49 |
| Heights: stack 2, ⌃⌥V ×3 | **pass.** Toasts "Height: ⅔", "Height: ⅓", "Height: ½" in that order (the cycle goes ½ → ⅔ → ⅓ → ½). Plan heights match the toasts (429/215 then 322/322). No overlap, 12 px gap kept. | 20, 21, 22, 23 |
| Heights: undo / redo | **pass.** "Undid: height", "Redid: height", plan restored each time. | 24, 25 |
| Mouse drag (a): right edge of a single window left ~150 px | **partial, see N-2.** The plan adopted a width (Doc 3 from 494 to 361 px, clamped to the 360 px floor, which is what the spec says). The window on screen stayed at 344 px, so the gap to Doc 4 was 29 px instead of 12. A re-layout (⌃⌥C) brought the window to 361 px. | 30 (gap), 31 (settled, pixel scan: orange ends at x=862, Doc 4 starts at 891), 32 (after ⌃⌥C, orange 332–693) |
| Mouse drag (b): bottom edge of top stacked window down ~120 px | **pass.** Dragged from y=364 to y=484. Plan adopted 429/215 (⅔ snap, within 24 px). Top window ends at y≈471, bottom starts at 483, no overlap, bottom window fills the rest. | 33 (before), 34 (after) |
| Mouse drag (c): janky? | **Minor.** No fighting or jump-back seen in the drags. Window shadow from the top stacked window falls over the bottom window's title bar (see P3-2). | 34 |
| Glide ⌃⌥←/→ | **pass.** Focus moves, caption and toast correct. | 06, 47 |
| Jump ⌃⌥1 | **pass.** | 11, 33, 46 |
| Tab ⌃⌥Tab | **pass.** Went back to the previous window. | 41 |
| Left edge no-op | **pass.** "That's the end of the ribbon" at column 0. | 47 |
| Width ⌃⌥R / ⌃⌥⇧R | **pass.** "Width: ½" from a custom 361 px width, then "Width: ⅓". | 42, 43 |
| Full width ⌃⌥F toggle | **pass.** "Full width", then "Back to ⅓". | 44, 45 |
| Command bar no match, Esc | **pass.** "No match for "zzq"…", Esc closes. | 49, 50 |
| Undo chain to empty | **pass.** Labels read "Undid: full width", "Undid: width", "Undid: height", "Undid: stack", "Undid: unstack". At the end: "Nothing to undo" repeatedly. | undo-sweep-2..13 |

## New findings

### P1 (wrong or broken)

None confirmed in this round.

### P2 (confusing UX)

**N-1. Stack-edge toasts also fire on a single, unstacked window (regression of the P2-2 fix).**
- Repro: start with Doc 3 focused as a single column (no stack). Press ⌃⌥↓. Toast "Bottom of the stack" (HUD shows the stack tiles, `36-single-down.png`). Press ⌃⌥↑. Toast "Top of the stack" (`37-single-up.png`).
- Same happened earlier after ⌃⌥⇧S unstacked Doc 2 (plan toast "Top of the stack" on a single window), and once on Doc 1 before any stack existed.
- Expected: no stack message when there is no stack (no toast, or "Stack windows first (⌃⌥S)"), as the spec wording implies.

**N-2. Width drag leaves the window narrower than the plan (until a re-layout).**
- Repro: Doc 3 is a single column at x=518, width 494. Real mouse drag of its right edge from x=1011 to x=861 at y=400. The plan follows during the drag (376 → 361 px in steps) and ends with Doc 3 w=361, Doc 4 at x=891. On screen the orange window ends at x=862 (width 344), so the gap to Doc 4 is 29 px, not the 12 px gap the layout promises.
- The mismatch stayed for at least 2 seconds (`30`, `31`). ⌃⌥C re-laid the ribbon, and the window jumped to 361 px (`32`, orange 332–693).
- Likely cause: the last drag step lands below the 360 px clamp floor and the plan's corrected 361 px frame is not applied to the window. This is one run, not a repeat. Please check the drag-end path for a width below the floor.

### P3 (polish)

**N-3. Undo of a mouse width drag is silent.** The first undo after the drag reverted the width to 494 px with no toast (`undo-sweep-5.png`, plan toast null). A drag is not a command in the spec, yet it gets an undo step with no label. Either give it a label ("Undid: resize") or skip the snapshot for drags.

**N-4. One ⌃⌥Z did nothing, not reproduced.** The first undo of the sweep came straight after Esc closed the command bar. The plan still showed Doc 3 at full width, and the next undo then undid the full-width toggle. Observed once; possibly a key swallowed right after the command bar closed.

**P3-2 (carried over, seen again).** A stacked window's shadow falls over the title bar of the window below it (`34-drag-b-bottom-edge.png`, the grey band on Doc 2's title bar). Minor.

**P3-3 (carried over, not re-checked).** "Undid: width" appears twice in a row with no direction. Still the same label text.

## Not tested

- Repeat of drag (a) and drag (b) after a fresh `vmstart`. The results are from one run each.
- Heights after a drag adoption followed by ⌃⌥V (only heights from ⌃⌥V were checked).
- Settings, onboarding, menu bar, pause.

## Verdict

The round-1 findings are fixed on the evidence I could collect. The command bar Enter now runs what is highlighted, the HUD caption names the window, the stack edge messages and carry feedback are in place, and the no-match text is readable. The new height feature works from the keyboard: three presses cycle ⅔ → ⅓ → ½, the plan and the screen agree, undo and redo work, and a real mouse drag of a stack boundary snaps to ⅔ and leaves no overlap. Two things need work before this is ready: the stack-edge message fires on single windows (N-1, a regression of the P2-2 fix), and a real mouse width drag left the window 17 px narrower than the plan until the next re-layout (N-2). Neither is P1, but N-2 means a dragged width is not reliably what the user sees. No P1 was reproduced.
