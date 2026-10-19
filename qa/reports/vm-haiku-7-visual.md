# VM visual QA 7: Ribbon main build

Build: `~/projects/ribbon` main (7010e54), `build/Ribbon.app` rebuilt with `make bundle` before the run.
Run: guest `ribbon-test`, Ribbon started manually in `~/rt-qa7` with `RIBBON_QA_NO_SCREEN=1`, 6 dummy windows, `smoothSwipeOffered` deleted first.
Screenshots: `~/projects/ribbon-scratch/visual-qa-7/`

| # | Surface | Verdict | Screenshot | Note |
|---|---------|---------|------------|------|
| 1 | Smooth-swipe card (`qa_swipe 400 300`, ~1.5 s) | PASS | `visual-qa-7/01-smooth-swipe-card.png` | Title, body and "Turn on" / "Not now" match; body wraps to 3 lines with no clipping; buttons aligned; text legible on the pale glass. |
| 2 | Shortcuts sheet subtitle | PASS (subtitle) / FAIL (layout) | `visual-qa-7/02-shortcuts.png` | Subtitle reads exactly "Hold ⌃⌥ and press → to try it. Click any shortcut to change it." The centred "More" pill overlaps the right edge of the "Move column right" key chips and cuts into the bottom of the left column (see defect 1). |
| 3 | Settings, Apps pane | PASS | `visual-qa-7/04-settings-apps.png` | Sentence reads exactly "New windows from these apps open on top of the ribbon, not in it." Rows and the "Add a running app" control are aligned. |
| 4 | Settings, Input pane | PASS (minor copy notes) | `visual-qa-7/05-settings-input.png` | No clipping. The Screen Recording description wraps to 4 lines, ending on a short "it on."; the footer also ends on a short "don't fight.". The "Turn on" text button is pale blue on light grey and reads low-contrast. |
| 5 | focus_left x8, then one more ("No more windows on the left" toast) | NOT VERIFIED (visual) | `visual-qa-7/06-focus-left-after-repeats.png` (focus on Doc 1 after 8 presses), `visual-qa-7/07-no-more-windows-left-toast.png` (captured too late) | The toast had already faded in both attempts. The string is confirmed in source: `app/Sources/Ribbon/App/Controller.swift:1397`. A retry was attempted but its capture did not write a file, and the screenshot budget is spent. |

## Defects

1. **Shortcuts sheet: "More" pill collides with the list (screenshot 02).** The pill is centred on the sheet's bottom edge at roughly x 932–1067 (in the 2000 px view), and the right-hand key chips of "Move column right" end at about x 935. The pill sits on top of the chips and cuts the left column's last visible row. The list should end above the pill, or the pill should be placed in the footer row.

## Non-visual observations

- The VNC channel itself triggers macOS notifications ("Viewer has disconnected", "Your screen is being controlled") in the menu bar area of screenshots 03–05. These come from the capture session, not from Ribbon. They are not Ribbon defects but may appear in any later VNC captures.
- Screenshot 01 shows the smooth-swipe card above the focused Doc 6 window's top-right; it does not overlap the traffic-light buttons.

## Not covered

- HUD for `focus_left` (not captured).
- Toast text as rendered (only confirmed in source).
- Contrast measured numerically (judgement by eye only).

Guest processes started for this run (Ribbon PID 1695, RibbonDummy) were stopped afterwards. No other guest processes were touched and the host `~/Applications/Ribbon.app` was not used.
