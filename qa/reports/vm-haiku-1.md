# Ribbon live UX QA, session 1

Model: Haiku 5.5, live in macOS 27 VM, real key presses via VNC
Date: 2026-10-14
Session: 6 dummy windows ("Doc 1".."Doc 6"), 3 personas (Overwhelmed, Tinkerer, Searcher). About 75 key actions.
Screenshots: `/Users/moses/projects/ribbon/qa/reports/vm-haiku/` (named `p1-*`, `p2-*`, `p3-*`).
Plan data read from `/tmp/hk.jsonl` in the VM (`focused_index`, `toast`, `width_frac`) to confirm what the UI showed.

## Summary

| area | verdict | notes |
|---|---|---|
| Glide ⌃⌥←/→ and focus visibility | pass | Focused window fully on screen in every frame checked (p1-01, p1-03, p1-07). |
| Jump ⌃⌥1..9 | pass | 1→3→5→6 landed on the right column each time. |
| Back to last ⌃⌥Tab | pass | Bounced 1→6→1→6→1 as expected. |
| Position cue (ribbon map + caption) | issue (P2) | Caption says "RibbonDummy · 3 of 6" and never names the window. Map tiles are identical. |
| Edge no-op at end of ribbon | pass | Toast "That's the end of the ribbon" (p1-07). Left edge not tested. |
| Width cycle ⌃⌥R / ⌃⌥⇧R | pass | ½→⅔→Full→⅓ with correct "Width: …" toasts. |
| Full width ⌃⌥F toggle | pass | "Full width" / "Back to ⅓" toasts; restores width. |
| Stack / unstack ⌃⌥S / ⌃⌥⇧S | pass, with issue (P2) | "Stacked" / "Own column" toasts are correct. Edge message inside a stack is wrong (see P2-2). |
| Carry window ⌃⌥⇧←/→ | issue (P2) | Moves correctly but shows no feedback at all (no toast, no "Moved"). |
| Undo / redo ⌃⌥Z / ⌃⌥⇧Z | pass | Toasts name the undone command ("Undid: stack", "Redid: unstack"). Restored layout matches the plan. |
| Nothing to undo | not reached | Undo chain did not run out. Not verified. |
| Command bar open / type / filter | pass | Opens with a useful empty list. "doc 4" and "wid" filter correctly. |
| Command bar arrows + Enter | issue (P1) | Highlighted row and executed action disagree (see P1-1). Reproduced twice. |
| Command bar no-match | pass, minor contrast issue | "No match for "zzq". Try an app name, or "wider"." Muted text is faint on glass. |
| Esc closes command bar | pass | |
| Glass legibility, HUD | pass, with notes | Dark caption ink is readable on green, lavender, cyan, orange, and pink tints. Details below. |

## Findings

### P1 (wrong or broken)

**P1-1. Command bar Enter runs a different action than the highlighted row.**
- Keys: `⌃⌥Space`, type `wid`, `↓` (highlight moves to "Full width"), `Enter`.
- Expected: "Full width" runs. The window goes full width and the toast says "Full width".
- Observed: The toast says "Width: ⅔", which is "Make wider" (row 1). This happened on two separate runs. The highlight is on row 2 in both screenshots, so the highlight and the executed action disagree.
- Screenshots: `p3-07-wid-down.png` and `p3-14-wid-down-retest.png` (highlight on "Full width"), `p3-15-enter-retest.png` (after Enter).
- Caveat: I only have VNC key presses, so timing could play a part. Please reproduce by hand before fixing.

### P2 (confusing UX)

**P2-1. The position cue never says which window you are on.**
- Keys: `⌃⌥1`, then `⌃⌥←` (p1-03), or `⌃⌥⇧→` carry (p2-13).
- Observed: The caption is "You're here: RibbonDummy · 3 of 6" (`p1-03`, `p2-13`). All six windows share the app name, so the caption says nothing about which doc is focused. In `p2-13`, the focused window is Doc 1 (on the right, with its traffic lights lit), while the caption says "3 of 6" next to the centre window, which is Doc 3. The map tiles all show the same app icon with no title or colour, so the map cannot identify the window either.
- Expected: The caption includes the window title (for example "Doc 1 · 3 of 6"), and the map tile carries the window's identity (title, number, or tint).

**P2-2. Wrong end-of-ribbon message inside a stack.**
- Keys: `⌃⌥S` (stacks Doc 2 into Doc 1's column, `p2-09-stack.png`), then `⌃⌥↓`.
- Observed: Toast "That's the end of the ribbon" (`p2-10-down.png`). The focus is on the bottom of the stack, not the end of the ribbon. The ribbon is not at its end.
- Expected: a stack-scoped message, or no message. For example "Bottom of the stack."

**P2-3. Carry gives no feedback.**
- Keys: `⌃⌥⇧→` (`p2-13-carry.png`).
- Observed: The window moves, but `toast` is null and the HUD only shows the position caption. Nothing says that the window moved or that `⌃⌥Z` undoes it. The design voice calls for "Moved. ⌃⌥Z to undo."; SPEC's toast list has no move or carry entry.
- Expected: A short toast such as "Moved. ⌃⌥Z to undo." (matches the design doc).

**P2-4. Command bar "Back to last window" matches "wid".**
- Keys: `⌃⌥Space`, type `wid`.
- Observed: "Back to last window" is one of three results (`p3-07`). The match looks like a loose fuzzy hit on "window". It is not a useful result for "wid".
- Expected: Rank or filter the loose match out, or show it only when the query is related to it.

### P3 (polish)

**P3-1. Faint secondary text on glass.** The app name in the command bar rows ("RibbonDummy") and the no-match line are a light grey on tinted glass (`p3-01-cmdbar-open.png`, `p3-17-zzq.png`). They are readable but low contrast. The selected row is also only slightly darker than the rest.

**P3-2. HUD tint blends into the window it describes.** The HUD glass takes the colour of the window underneath. Over Doc 2 (cyan) or Doc 3 (orange) the HUD looks like part of that window (`p2-03-width.png`, `p3-10-enter-undo.png`). Legibility holds, but the HUD is harder to tell apart from the window.

**P3-3. Undo toast label does not say which direction was undone.** Two consecutive undos of full-width toggles both read "Undid: full width" (`p2-21-undo-more.png`, `p2-22-undo-more.png`). The label is accurate, but the user cannot tell which toggle was reverted. Consider including the result, e.g. "Undid: full width → ⅓". (Based on toast text only, not a visual check of each frame.)

**P3-4. Command bar bottom edge.** There is a dark strip along the bottom edge of the command bar panel (`p3-01-cmdbar-open.png`, bottom edge at y≈617). It may be a shadow or a rendering artifact. Not confirmed.

## ADHD fit

- **Orientation:** Mixed. The ribbon map shows where you are, and the traffic lights (lit on the focused window, grey elsewhere) are a clear cue. The caption, though, names the app and a position but not the window (P2-1), so when several windows share an app, the user has to read the traffic lights or the title bar to find the focus.
- **Cognitive load:** Low for gliding. The overall flow is simple: glide, jump, tab, command bar. The main load comes from the position caption (P2-1) and from the command bar Enter mismatch (P1-1), which makes the command bar feel unreliable.
- **Forgiveness:** Good. Undo labels name the command ("Undid: stack", "Redid: unstack"), restored layouts match the plans, and the edge no-op says so instead of failing silently. Gaps: carry gives no feedback (P2-3), and the stack-edge message is wrong (P2-2).

## Design

- **Dia/Arc-likeness:** The command bar is the strongest part. It is centred and floats above the windows, uses fuzzy matching with keyboard hints, and shows recent windows first. The ribbon map is a distinct element, not a copy of Dia.
- **Glass legibility:** The HUD caption (dark ink) and the command bar title text are readable across all the tints seen. The faint secondary text (P3-1) is the weak spot. Keep secondary text at a stronger contrast on glass.
- **Concrete suggestions (grounded in what was seen):**
  1. Put the window title in the HUD caption and command bar subtitle, e.g. "Doc 1 · 3 of 6".
  2. Give each map tile a title or number, or tint it with the window's colour, so the map can be read without the caption.
  3. Add a carry toast ("Moved. ⌃⌥Z to undo.") to match the design doc.
  4. Use stack-scoped copy for the bottom-of-stack edge.
  5. Raise contrast on the command bar's secondary text.

## Not tested

- Left edge of the ribbon (only the right edge was checked).
- "Nothing to undo" and "Nothing to redo" toasts (the undo chain did not run out).
- Settings, onboarding, menu bar, and pause (out of scope for this session).
