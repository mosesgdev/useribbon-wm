# Ribbon live QA, session 4 (features since round 3: first/last window, equalize heights, float rules, session restore, conflict card, minimize/hide, window strip drag, shortcuts sheet)

Model: Haiku 5.5, live in the macOS VM (ribbon-test), real keys, mouse and VNC; plan data read from the guest's plan logs.
Date: 2026-10-14
Build under test: main at `ae87626` (clean tree), deployed by `vmstart 5` (5 dummies "Doc 1".."Doc 5"). Later runs used the same build with extra environment variables noted below.
Screenshots: `/Users/moses/projects/ribbon/qa/reports/vm-haiku-4/` (numbered 01-71 in run order, `NN-name.png`).
Plan logs (in the guest): `/tmp/hk.jsonl` (run 1), `/tmp/hkA.jsonl` (session restore run A), `/tmp/hkB.jsonl` (run B), `/tmp/hkC.jsonl` and `/tmp/hkD.jsonl` (conflict runs), `/tmp/hkE.jsonl` (minimize, strip, shortcuts, regression).
No source was changed. Ribbon was never launched or driven on the host. All Ribbon processes ran in the VM. I quit the session's Ribbon and dummy processes before `./vmsmoke` (the smoke script starts its own); the VM itself was not stopped or rebooted.

Harness notes (not Ribbon bugs, but they limit what I could confirm):
- Each `vnc` call opens a new VNC connection. The guest's Screen Sharing banner ("Your screen is being controlled" / "Viewer has disconnected") appears at connection time and can take focus. Several focus-dependent results below (the command bar, the Settings menu) could be affected by this. Each such result is marked.
- vncdo has no scroll command (wheel button 5 did not scroll the Settings or shortcuts windows here) and no Page Down keysym. Digit combos (⌃⌥1..9) and Option-letter combos are still limited, as in earlier rounds.
- The guest's AppleScript (System Events) is not authorized over SSH, so focus state could not be queried.

## Verification

| item | result | evidence |
|---|---|---|
| 1a ⌃⌥Home "First window" | **pass when the strip is held.** Plan toast "First window"; caption "First window / 1 of 5". A plain tap showed no toast on screen (see P2-1). | 06 (held), 02 (tap, no toast on screen) |
| 1b ⌃⌥End "Last window" | **pass.** Caption "Last window / 5 of 5". | 04 |
| 1c End-of-ribbon toast when already there | **pass.** "That's the end of the ribbon" on a second End (and on a second Home). | 05, 07 |
| 2a Stack + `cycle_height` | **pass.** Doc 2 at 430 px, Doc 1 at 215 px (1/3, 2/3). Cycling on a single window says "Stack windows first". | 08 |
| 2b `equalize_heights` | **pass.** Heights 323/322 px. Second run says "Already even". | 09, 10 |
| 2c Equalize toast on screen | **not confirmed.** The toast is in the plan ("Heights evened out"), but the held capture showed the window title in the caption, not the toast. | 12, 13 (plan: 2 runs) |
| 2d Undo restores heights | **pass.** 215/430 px restored; plan "Undid: heights" (not on screen). | 11 |
| 3a Command bar: type "float" | **fail.** The first typed letter closes the bar. Reproduced 4 times, including one attempt with a 6 s wait after connecting. See P1-1. | 14→16, 18→19, 22→23 |
| 3b "Always float RibbonDummy" (bar row) | **not verified.** The row appears only in a typed search; with no query the bar shows 8 rows and it is not among them. Typing failed (3a). | 14 |
| 3c "Always float" via Settings | **not verified.** Settings opened (via the menu bar item), but the "Add a running app" control is below the bottom of the 1024×768 screen, and keyboard focus left the window while I tried to reach it. See P2-3. | 30, 33, 37 |
| 3d Floating mechanism (Float / Tile, not a rule) | **pass.** Focused Doc 5 floated ("Floating", leaves the ribbon), then tiled again ("Back in the ribbon", x=518). | 38, 39 |
| 3e "Stop floating RibbonDummy" tiles it again | **not verified** (requires 3a or 3c). The toggle path in 3d tiles correctly. | — |
| 3f Settings "Always float these apps" list | **partial.** Renders legibly with defaults (Calculator, Archive Utility, System Settings). No RibbonDummy rule was added, so add/remove was not exercised. | 30 |
| 4a Session restore (widths, stack, heights, focus, scroll) | **pass.** Run A layout before TERM and run B after restart have identical frames (x, y, w, h) and focus. Session file holds heights 1/3, 2/3, widths 0.5/0.5/0.5/1.0, focus 62, scroll 506. | 40, 41, 42 (A), 43 (B) |
| 4b Session file needs the env var | **observed.** Without `RIBBON_SESSION_FILE` nothing is written at TERM (the first run wrote no session file). | — |
| 5a Conflict card appears with `RIBBON_EXTRA_CONFLICTS="RibbonDummy=Fake Tiler"` | **pass.** "Fake Tiler is also moving windows", about 3 s after start. Legible and calm. | 45 |
| 5b "Keep both" dismisses it | **pass.** Card closes. | 46, 47 |
| 5c Dismissal remembered after restart | **fail.** The card came back on restart (run D). `dismissedConflicts` still holds only `debug:FakeTiler`, and the defaults plist was not modified after 12:55. Reproduced on a second "Keep both" in run D. See P1-2. | 48, 49 |
| 6a Yellow button closes the gap | **pass.** Doc 2 fills the column; Doc 3 goes to the Dock as a thumbnail. | 51 |
| 6b Dock thumbnail restores at the same width | **pass** (width 0.5, x=518). It comes back as its own column, not back in the Doc 2 stack. See P3-1. | 52 |
| 6c Bar shows "Minimized" tag | **pass.** Doc 3 greyed with "Minimized". The bar opened only on the third toggle (see P1-1). | 55 |
| 7a Hold ⌃⌥ shows the strip | **pass.** Four tiles, lens on Doc 2, "2 of 4". | 57 |
| 7b Click a tile while holding ⌃⌥ | **pass** (1 attempt). Doc 1 focused and on screen, viewport 0.0. Round 3's failure (P2-1) did not reproduce. | 58 |
| 7c Drag a tile to reorder | **pass** (1 attempt). Plan order [1,2,4,5] to [1,4,2,5], focus kept on Doc 2. | 59 |
| 8a Shortcuts sheet readable | **pass.** Two columns, legible over the bright windows. | 60 |
| 8b New first/last rows present | **pass.** "Go to first window" (⌃⌥↖) and "Go to last window" (⌃⌥↘) are listed. | 60 |
| 8c "Even out heights" row (Resize group) visible | **fail.** The Resize group (Next width, Next height, Even out heights, Full width, Center) is below the fold of the sheet, with no visible scroll cue. Wheel and keyboard scroll did not reveal it. See P2-2. | 60, 61 |
| 8d Record a shortcut (chip, then ⌃⌘K) | **pass on the second key press.** Chip shows "Type shortcut…". The first ⌃⌘K press did not record. The second did: Glide left shows ⌃⌘K, reset arrow visible. | 63, 64, 65 |
| 8e Recorded shortcut performs its action | **pass.** ⌃⌘K glided left (index 2 to 1). | 69 |
| 8f Conflict note ("Used by Glide right, replace?") | **not verified.** Recording ⌃⌥→ on Glide left did not show a note; the recorder stayed open and a Ribbon menu bar dropdown opened (not clicked by me). See P2-4. | 66 |
| 8g Esc cancels recording | **pass.** Chip keeps ⌃⌘K. | 67 |
| 8h "Reset all" | **pass.** Defaults restored (⌃⌥← glides left again). | 70, 71 |
| 9a Glide ⌃⌥→ / ⌃⌥← | **pass.** Index 1 to 2 to 1. | 72, 73 (plan) |
| 9b `switch_desktop 2` / `1` (FIFO) | **pass.** "Desktop 2 · empty", desktop 2, then desktop 1 with focus restored. | 74 (plan) |
| 9c Undo | **pass.** Reverts the last reorder. | plan |
| 9d `./vmsmoke` | **ALL PASS (29 checks).** `check_plans.py`: 36 plans, 0 problems. | terminal output |

## New issues

### P1 (broken, blocks a tested workflow)

**P1-1. The command bar closes on the first typed letter; it also opens unreliably.**
- Repro: `./vssh 'echo bar > /tmp/rb.fifo'` (or ⌃⌥Space). Type `f`.
- Result: the bar disappears, and the letter does not reach the field. Happened on every attempt (16, 19, 23). Opening also failed on some presses (20, 22, 53, 54). The bar showed only on the third toggle (55).
- Cause: not confirmed. A plausible cause is the Screen Sharing banner taking focus, which resigns the bar's key window (`CommandBar.windowDidResignKey`). Round 3 saw the same behaviour, and round 2 typed "wid" successfully, so it may be a regression. **This must be confirmed on a real keyboard and display before it is ruled a product bug.** If it reproduces there, it is P1, because the "float" and "Show ribbon map" paths both depend on typing.
- Screenshots: 14 (open), 16 (closed after `f`), 19 (closed), 23 (no bar).

**P1-2. "Keep both" is not remembered across a restart.**
- Repro: `RIBBON_EXTRA_CONFLICTS="RibbonDummy=Fake Tiler"` with `RIBBON_SESSION_FILE=/tmp/session.json`. Wait for the card (45). Click "Keep both" (46, 47). Quit (TERM). Restart with the same env.
- Result: the card is back (48). Reproduced on a second attempt (49). After "Keep both", `defaults read com.makeautomation.ribbon dismissedConflicts` still returns only `debug:FakeTiler` (the defaults plist was not changed after 12:55). The card closed on the click, so the in-session dismissal works. It is the stored value that does not change.
- Repro cause: not found. `keep()` writes `dismissed.union([c.key])` to `UserDefaults.standard` (`app/Sources/Ribbon/Platform/Conflicts.swift`). The key is `debug:RibbonDummy`. Next step: check whether the write happens in a debug build and whether the key is written or reverted.
- Impact: the user is asked the same question every time they start Ribbon. That is the nag this card was meant to stop.

### P2 (confusing or hard to use)

**P2-1. Toasts only show while the strip is held.**
- Repro: tap ⌃⌥Home (or ⌃⌥End) normally, then capture about 1 s later. The plan logs "First window" (`toast: "First window"`), but the screen shows no toast (02). The strip hides on key release, so the toast goes with it.
- Same for FIFO commands: equalize (09, 11) and undo (11) show their toasts in the plan, but none on screen.
- For a user with ADHD, a tap that gives no confirmation is the kind of "did it work?" moment that makes people press again. Suggestion: keep the toast on screen for about 1.5 s after a tap, or show it in a small transient HUD that does not depend on the strip.

**P2-2. The shortcuts sheet hides the Resize group at 1024×768.**
- The left column ends at "Float / tile" (60). Resize (including "Even out heights", "Next width", "Next height", "Full width", "Center") sits below the fold inside a scroll view with hidden indicators. My wheel and keyboard scroll attempts did not reveal it (61, and the Page Down attempt errored in vncdo).
- Impact: the new even-heights shortcut cannot be found by looking at the sheet. Suggestion: size the sheet to fit the screen height, or show a visible scroll cue (or a fade that is actually visible).

**P2-3. The Settings window is taller than the screen.**
- At 1024×768 the Settings window extends below the Dock (30, 33). The "Add a running app" control for "Always float these apps" sits under the Dock. Wheel scrolling did not move it, and Tab navigation moved focus to controls I could not see (37), so I could not add a float rule from Settings.
- Caveat: this may be partly a VNC focus issue. But the window size is a layout problem on a display this size.

**P2-4. Shortcut recording: a missed first press, and a menu bar dropdown during the conflict attempt.**
- The first ⌃⌘K press after clicking the chip did nothing (64). The second press recorded (65).
- Pressing ⌃⌥→ while recording Glide left did not show the "Used by Glide right" note (the conflict path stays unverified). The recorder stayed open, and a Ribbon menu bar dropdown opened (66). I did not click the status item. Cause not confirmed.
- Esc cancels cleanly (67).

### P3 (polish)

**P3-1. Dock restore does not return a window to its stack.** Doc 3 was in a stack with Doc 2. After minimize and restore from the Dock it returned as its own column at the same width (52). Width is kept; the stack membership is not. Probably by design, but it is surprising.

**P3-2. "Quit Fake Tiler" looks disabled in the conflict card** (45). The fake tiler is not running, so the button may be correctly disabled. A real conflict should show whether the button is active.

**P3-3. Minimized rows in the bar are low contrast.** "Doc 3" with the "Minimized" tag is greyed (55). It is readable but faint.

**P3-4. Strip tiles all show the same generic icon** (57, 58). Carried over from round 3 (P3-3). This is a dummy-app limit, so it is not confirmed for real apps.

**P3-5. Carried over from round 3: ⌃⌥1..9 desktop hotkeys.** Not retested. Digit combos cannot be sent reliably over VNC (harness limit). The FIFO `switch_desktop` works (74).

## Not tested

- Real keyboard and display: P1-1 and P2-4 need a real-keyboard check.
- "Always float RibbonDummy" and "Stop floating RibbonDummy", via the bar or Settings (blocked by P1-1 and P2-3).
- Conflict note for recording a duplicate shortcut (blocked by P2-4).
- The equalize and undo toasts on screen while the strip is held (the timing did not capture them, 12 and 13).
- ⌃⌥1..9 desktop hotkeys (digit limit).
- Light and dark appearance.

## ADHD UX verdict

What works is calm and clear. The strip's captions say where you are ("1 of 5", "Last window", "That's the end of the ribbon"). Equalize and undo do what they say. Session restore brings back the layout exactly, including the stack heights and focus, which is the kind of promise an ADHD user relies on. Minimize closes the gap, and the Dock thumbnail brings the window back at the same width. The minimized tag in the bar is clear. The strip drag and the click-while-held now work on the first try.

What breaks the trust is the feedback and the memory. Toasts disappear with the strip, so a tap gives no "First window" confirmation. The conflict card comes back after "Keep both" on every restart, which is exactly the repeated interruption it was meant to prevent. The shortcuts sheet hides the Resize group, including the new even-heights row, at this screen size. And the command bar, which is the fastest way to find a window or set a float rule, closes when you type. That last one may be the VNC harness, but it has to be checked on a real keyboard before anyone who depends on the keyboard uses it.

Fix P1-2 first (it is deterministic), then confirm P1-1 on hardware. Then make the toast survive the strip and fit the sheet to the screen.

## P1 and P2 summary

- P1-1 Command bar closes on the first typed letter and opens unreliably (VNC-reproduced, confirm on hardware).
- P1-2 "Keep both" is not remembered; the conflict card returns on restart (reproduced twice).
- P2-1 Toasts show only while the strip is held; taps and FIFO commands give no visible confirmation.
- P2-2 The shortcuts sheet hides the Resize group, including "Even out heights", at 1024×768.
- P2-3 The Settings window is taller than the screen; the "Add a running app" control is unreachable.
- P2-4 Shortcut recording: first press missed; ⌃⌥→ during recording opened a menu bar dropdown with no conflict note.
