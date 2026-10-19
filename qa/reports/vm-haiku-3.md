# Ribbon live QA, session 3 (new features: window strip, glide, shortcuts sheet, command bar)

Model: Haiku 5.5, live in the macOS VM (ribbon-test), real keys and mouse via VNC
Date: 2026-10-14
Build under test: main HEAD `cd22b91` (HUD AppKit pointer handling, reading surface for shortcuts sheet and command bar), deployed by `make bundle` + `vmstart 5`.
Session: 5 dummy windows ("Doc 1".."Doc 5"), about 70 captures. Plan data read from `/tmp/hk.jsonl` in the VM.
Screenshots: `/Users/moses/projects/ribbon/qa/reports/vm-haiku-3/` (numbered in run order, `NN-name.png`).
No source was changed. Ribbon was not launched on the host.

Harness notes (not Ribbon bugs):
- macOS shows "Your screen is being controlled" and "Viewer has disconnected" banners in many captures (Screen Sharing).
- Option-letter combos are unavailable (known limitation), so ⌃⌥D could not be tested.
- VNC clicks have no human timing. Several chip and bar results below depend on click timing. Each such result is marked with its attempts.

## Verification

| item | result | evidence |
|---|---|---|
| 1a Hold ⌃⌥ about 0.5 s shows the strip | **pass.** Strip at bottom centre with five tiles, lens on the focused tile, caption "RibbonDummy — Doc 5 · 5 of 5". | 02 |
| 1a Release fades the strip | **pass.** Gone by the next capture 1.2 s later. The fade itself was caught mid-way in 07 (faint). | 03, 07 |
| 1b Click an off-screen tile to jump | **pass only when the keys are released first.** Hold ⌃⌥, hover tile 1, release, then click: plan focus moves to Doc 1, viewport goes to 0.0, Doc 1 on screen. **Fails while ⌃⌥ is held** (see P2-1). | 06 → 07 (pass), 04 → 05 (fail) |
| 1c Hover shows the title | **pass.** Hover on tile 1 changes caption to "RibbonDummy — Doc 1 · 1 of 5". Hovered tile gets a light fill. | 04, 06 |
| 1d Drag a tile to another slot changes map.columns | **pass on the second try.** Plan order went [1,2,3,4,5] to [2,1,3,4,5] with focus kept on Doc 1. The **first** drag attempt (same gesture) did nothing (plan unchanged). See P2-2. | 10 → 11 (pass), 08 → 09 (no change) |
| 1e Two desktops, click a desktop dot | **pass.** With Doc 1 moved to desktop 2 (`move_to_desktop 2`), the strip shows two dots and "Desktop 1" in the caption. Clicking dot 2 switches: plan `desktop` = 2, Doc 1 on screen. | 13, 14, 15 |
| 1f Strip looks polished (spacing, icons, lens, caption, glass) | **partial.** Spacing, lens and caption layout are calm and clear. Glass tint is muddy over bright windows, desktop dots are tiny, and all tiles show the same generic icon. See P3. | 02, 06, 13 |
| 2 Glide with the strip: no distracting flash | **pass.** Four glides in quick succession (⌃⌥→ ×2, ⌃⌥← and ⌃⌥→ at 0.25 s spacing) kept one panel up that updated in place. Edge message "That's the end of the ribbon" at the last column. No blink seen. | 17, 18, 19, 25 |
| 3a Shortcuts sheet opens (`shortcuts` FIFO) | **pass.** Two-column sheet, readable over the bright windows. | 27 |
| 3b Click a key chip: reads "Type shortcut…" | **pass when it starts, fails often.** Recording started in 3 of about 10 chip clicks (31, 39, 46). Most clicks showed only the hover fill (28, 30, 35, 37, 45). See P1-2. | 31, 39, 46 (pass). 28, 30, 35, 37, 45 (no recording) |
| 3c Record ⌃⌘K for an action, then it performs the action | **pass for "Glide left".** Recorded ⌃⌘K (row shows ⌃ ⌘ K, reset arrow appears, subtitle changes to "Most start with ^⌥"). After closing the sheet, ⌃⌘K glided to Doc 4 (left column). | 32, 42 |
| 3d Conflict: "Used by … — replace?" note | **not verified.** Recording "Glide left" then pressing ⌃⌥→ (used by Glide right) never showed the note. The key went to the global hotkey, recording ended silently, and the chip went back to ⌃⌘K. Seen on 2 attempts. | 47 (also 33, 40) |
| 3e Reset all restores defaults | **pass.** Glide left back to ⌃⌥←, subtitle back to "Everything starts with ^⌥", reset arrow gone, ⌃⌥← glides left. | 50, 52 |
| 3f Sheet closes (Got it, Esc) | **partial.** "Got it" closes it (44). Esc did nothing once the sheet had lost key focus (43). See P2-3. | 44, 43 |
| 4 Command bar opens (⌃⌥Space) | **pass for opening.** Panel is legible: field, window rows with app names and desktop tags, action rows with shortcut chips, footer hints. | 53, 55 |
| 4 Type "map" into the bar, run "Show ribbon map" | **fail.** The first typed letter closes the bar. This happened on each of 3 tries (`m`, then `map`). Clicking the field also closes it. Opening also failed on 2 of 4 presses. "Show ribbon map" could not be run. See P1-1. | 54, 56, 59, 62, 63 |
| 5 Glide ⌃⌥← / ⌃⌥→ | **pass.** Focus and viewport move, toast/caption correct. | 06, 07, 17, 18, 19, 42 |
| 5 Desktops ⌃⌥1..3 (by key) | **fail in this session, status unclear.** ⌃⌥1 and ⌃⌥2 did not switch desktops in 5 tries (the same keys did switch in round 2). The FIFO `switch_desktop 2` / `switch_desktop 1` does switch (plan `desktop` 1→2→1). See P1-3. | 16, 21, 23, 24, 26 |
| 5 Tab ⌃⌥Tab | **pass.** Focus goes back to the previous window (Doc 5). | 67 |
| 5 Move ⌃⌥⇧← | **pass.** Doc 5 moved left in the plan [2,3,4,5] to [2,3,5,4], "Moved" toast and "3 of 4" caption. | 68 |
| 5 Undo via FIFO | **pass.** "Undid: move", order restored to [2,3,4,5]. | 69 |
| 5 `./vmsmoke` | **ALL PASS (29 checks).** Includes check_plans.py: 35 plans, 0 problems. | terminal output |

## New findings

### P1 (broken)

**P1-1. The command bar closes on the first typed letter.**
- Repro: ⌃⌥Space (opens the bar, field focused). Type `m`.
- Result: the bar disappears at once and the letter does not appear in the field. Same with `map` typed as one string. Clicking inside the field also closes it.
- Also: ⌃⌥Space opened the bar on 2 of 4 presses. On the other presses nothing appeared.
- Round 2 typed "wid" and "zzq" into the bar and both worked on the earlier build, so this looks like a regression in `cd22b91`. Likely cause (unverified): the panel resigns key as soon as input reaches the app, and `CommandBar.windowDidResignKey` closes it (`app/Sources/Ribbon/UI/CommandBar.swift`, `windowDidResignKey`). Ribbon is not the active app when the bar opens from the hotkey.
- Screenshots: 53 (open), 54 (after "map": closed), 55 (open), 56 (after m/a/p: closed), 59 (after m: closed), 61 and 64 (not open after ⌃⌥Space), 62/63 (click in field: closed).

**P1-2. Shortcut recording is unreliable.**
- Repro: `echo shortcuts > /tmp/rb.fifo`, click the "←" chip of "Glide left", press ⌃⌘K.
- Result: the chip shows hover only and the key does nothing (28, 29). It worked on one try (31 → 32).
- When recording did start (46), pressing ⌃⌥→ ended recording silently, the chip reverted to its previous combo, and the key ran as a glide (47). No "Used by Glide right — replace?" note appeared in any run. The conflict path is therefore unverified.
- Also: a chip click that starts recording needs a hover of about 1 s before the press (39, 46 worked; 35, 37, 45 did not). A human click would not have that delay, so treat the rate as a lower bound until it is checked on a real mouse.
- Likely cause (unverified): `ShortcutStore.handle` uses a local key monitor, and the sheet can lose key status (`resignObserver` ends recording) when the Ribbon app is not active.

**P1-3. (Needs confirmation) ⌃⌥1..9 did not switch desktops by key.**
- Repro: with windows on desktops 1 and 2, press ⌃⌥2 (or ⌃⌥1). Plan `desktop` stayed the same (23, 24, 26; 16 and 21 also).
- The FIFO `switch_desktop` works, so the desktop logic itself is fine. The hotkey path is the suspect. The arrow combos and ⌃⌥Tab work, so the modifier path is fine.
- This may be a harness issue (digit key delivery over VNC). It must be checked on a real keyboard before it is ruled a bug. If it is real, it is P1.

### P2 (confusing or annoying)

**P2-1. Clicking a strip tile while ⌃⌥ is held does nothing.**
- Repro: hold ⌃⌥, move to an off-screen tile, click it while still holding. The plan does not change (focus stays, Doc 1 stays off-screen). Screenshot 05.
- Likely cause: holding ⌃ turns a left click into a secondary (right) click. `RibbonMapHUD.swift` overrides only `mouseDown` on the hosting view, so the click is ignored. There is no feedback at all.
- Workaround that works: release the keys with the pointer on the strip (the hover keeps it open), then click (06 → 07).
- Suggestion: accept clicks while the modifier is held, or show a hint that you release first.

**P2-2. First drag of a strip tile silently did nothing.**
- Repro: hold ⌃⌥, move onto tile 1, release, then mouse down on tile 1 and drag ~65 px right in steps. Plan order unchanged (08, 09).
- Same gesture, repeated with slower steps and a 1 s wait before the press: worked (10, 11).
- One failure, one success. Needs a repeat before it is called a bug.

**P2-3. Shortcuts sheet stops responding to keys after focus moves.**
- Repro: open the sheet, run a glide (⌃⌥→), press Esc. Nothing closes (43). "Got it" is greyed in several captures (28, 30, 35, 40) and works when clicked after a click on the title (44).
- Clicking the title first restores key focus. The first click on a chip is also swallowed in this state (see P1-2).
- Suggestion: make the sheet take key focus when it opens and when it is clicked, so Esc and chip clicks always reach it.

**P2-4. The strip covers the sheet's list.**
- The window strip is still up over the sheet after a glide, and sits on top of the "Resize" rows (Next width, Previous width) at the bottom of the left column (33).
- Suggestion: hide the strip while the shortcuts sheet is open.

### P3 (polish)

**P3-1. Glass tint is muddy over bright windows.** The strip picks up the colour of whatever is under it (pink, cyan, orange, green gradient). Captions read but look dirty (06, 08, 13, 40). Consider a more opaque or neutral backing.

**P3-2. Desktop dots are tiny and the inactive one is faint.** Active dot is 8 px, inactive 6 px at 0.4 opacity, and an empty desktop is a hollow ring that nearly disappears (13, 25, 45). Hard to read at a glance.

**P3-3. All tiles look the same.** RibbonDummy's windows share the same generic icon, so the tiles can only be told apart by position. This is a harness limit, but the icon area has not been checked with real apps.

**P3-4. Caption contrast.** "2 of 4 · Desktop 1" and "1 of 5" are small, low-contrast grey on the coloured glass (13, 40).

**P3-5. Plan shows `show_map: true` at start with no strip on screen.** The first plan line after `vmstart` had `show_map` true, but no strip was visible (01). It was False by the next call. Probably a stale flag; not confirmed.

## Not tested

- Command bar: running "Show ribbon map" and any action from the bar (the field would not accept typing).
- Strip drag and click with a real mouse, a real keyboard, or a second run after a fresh `vmstart`.
- Desktop switch by key on a real keyboard (P1-3).
- Conflict replace flow (P1-2 blocked it).
- ⌃⌥D back-to-last-desktop (Option-letter limitation).
- Light/dark appearance.

## ADHD UX verdict

The strip itself is calm once it is on screen: five tiles, one lens, a caption that says where you are, and a desktop dot row that stays out of the way until you use a second desktop. Glides do not flash it, and the glide-end message is clear. That is the part that should reach users first, and it mostly works.

Everything that asks the user to change something is not ready. The command bar cannot be typed into, so the fastest way to find a window is gone. Shortcut recording only worked on a lucky attempt, so the one place a user can fix their own muscle memory is unreliable. The sheet also ignores Esc after focus moves, and the strip covers the sheet. For someone who loses track of what they just pressed, a bar that disappears on the first letter and a sheet that silently drops a recording are the kind of small, unexplained failures that make the tool feel broken. Fix P1-1 and P1-2 before this goes to anyone who depends on the keyboard.
