# Ribbon UX and visual polish review, round 1

Reviewer: fresh-eyes product designer, ADHD user lens. Build: current host build deployed to VM `ribbon-test` via `vmstart`. Screenshots: `qa/reports/ux-review-1/` (numbered, absolute path `~/projects/ribbon/qa/reports/ux-review-1/`).

## How this was tested, and what was not

- **Live in VM:** window strip (held ⌃⌥, 02), focus ring, glide ⌃⌥→ (13), stack (14), undo with nothing to undo (15), empty desktop 3 (16), ⌃⌥Home/End toasts (05, 06), Settings General/Layout/Input/Apps (07–10), menu bar menu (12), conflict card via `RIBBON_EXTRA_CONFLICTS` (30).
- **Onboarding did not appear live.** `OnboardingController` only shows when `AXIsProcessTrusted()` is false, and the VM already trusts Ribbon. Judged from `Onboarding.swift` plus the `--snapshot` render (20, 21).
- **Command bar:** ⌃⌥Space did not open it through VNC. The FIFO `bar` did (03c). Typing "wid" did not reach the field (VNC focus), so the filtered state is not captured live. The snapshot render (24) is used instead, and it has a harness artifact (yellow block in the search field).
- **Shortcuts sheet:** did not appear from the FIFO `shortcuts` command or from Esc. The "Show Shortcuts" menu item was not clicked. The snapshot render (22) shows an empty list body, which looks like a harness limitation, so the rows are not judged. Chrome (title, "More", "Reset all", "Got it") is judged.
- **Dark mode:** `osascript` returned -1743 (Apple Events not authorised), so dark is judged only from snapshot renders (23, 25, 27). Live dark (31–33) was not confirmed. Those files are not dark captures.
- **Screenshot noise:** Screen Sharing banners ("Your screen is being controlled" / "Viewer has disconnected") and the purple Screen Sharing menu bar pill appear in many captures. They are not Ribbon UI. The desktop apps behind the windows (Terminal, Finder) are VM artifacts.
- Corner radii and pt values marked "approx." were read from the 1x/2x screenshots, not from the view code.

---

## Top 10 polish fixes (ranked by ADHD impact)

### 1. Settings panes are mostly empty space, and the window is taller than its content
Screenshots: 07, 08, 09, 10.
- The General, Layout, Input and Apps panes each end around y≈335 inside a window that runs to y≈550. That leaves about 200 pt of blank grey below every pane. The eye lands on a void, and the "where is the rest?" feeling is exactly what an ADHD user does not need.
- The Apps pane is the only one with more than four rows, and it still stops early.
- Fix: size the Settings window to content. Pane padding 20 pt top and sides, group rows 44 pt high (currently about 40), window content height ≈ 360 pt. Add one friendly sentence under each tab title (14 pt, secondary label colour), for example "Layout: how wide your windows sit and how they line up." Use that line to fill the space, not padding.

### 2. Conflict card: the recommended action looks disabled
Screenshot: 30.
- "Quit Fake Tiler" is pale grey with grey text. "Keep both" is the white, enabled-looking button. Visually the card recommends keeping both, which is the wrong default for a window fight. It may just be the non-key window style; check that before changing the colour.
- Copy is jargon-heavy (see copy audit).
- Fix: make "Quit Fake Tiler" the prominent tinted button (`.glassProminent`, accent), and make "Keep both running" a plain bordered button. Card width 360 pt, 16 pt padding, title 15 pt semibold, body 13 pt, 2 lines max. Keep the card below the menu bar and above the strip, but do not cover the focused window's title bar: 30 covers Doc 4's traffic lights.

### 3. Held ⌃⌥ strip HUD covers the bottom of the windows and its thumbnails are unhelpful
Screenshot: 02.
- The HUD is a 510 × 130 pt glass pill centred over the focused window's content. It hides about the bottom fifth of the window the user is reading. The thumbnails are identical generic icons in this VM, so the label "RibbonDummy — Doc 4 / 4 of 4" carries all the meaning.
- Fix: when a window is focused, dock the HUD to the screen bottom edge with 16 pt inset and cap height at 96 pt, so it does not sit over the content centre. Title line 13 pt semibold, position line 11 pt secondary: "Doc 4 · 4 of 4". Show app name only when titles collide.

### 4. Toasts: wallpaper bleed makes "First window / Last window" hard to read
Screenshots: 05, 06.
- The toast is the same glass HUD pill at bottom-centre. Behind it, the tint shifts with the windows underneath (purple in 05, cyan in 06, orange in 02). "First window" is 13 pt semibold on a mid-tone, which is roughly 3:1 contrast in the cyan frame. The text is the only signal, so this matters.
- The text is also not informative: "First window" tells you the position, not which window.
- Fix: add a 1 pt inner stroke at 14% white and a base fill of 72% white (light) / 60% black (dark) under the glass, so the material cannot drop below 4.5:1. Copy: "Doc 1 · first of 4" (the window title, then the position). For `undo` with nothing to undo, say "Nothing to undo" rather than silent failure (15 showed nothing).

### 5. Menu bar: three names for one thing, an unlabelled "1" and a cluttered menu
Screenshots: 12, 16.
- The same concept is called "ribbon map" (menu item, Settings toggle "Hold ^⌥ to show the ribbon map"), "Ribbon map" (HUD), and "the ribbon" elsewhere. Pick one.
- The menu-bar item shows a number (1 in 12, 3 in 16). It means the current desktop, but nothing says so. A user cannot tell it is a desktop number.
- The menu has five items and no key hints. "Show Ribbon Map" is the most useful item and it has no shortcut shown.
- Fix: menu items become "Show my windows  ⌃⌥ (hold)", "Shortcuts", "Pause for now", "Settings…  ⌘,", "Quit Ribbon  ⌘Q". Make the status item a 2-letter label on hover: "Desktop 1" (tooltip), and show the desktop number in the bar with a small "Desktop" caption on hover. Group the menu: [Show my windows, Shortcuts] / [Pause, Settings] / [Quit].

### 6. Command bar: the footer is inconsistent and the dark selected row loses its accent
Screenshots: 24 (light), 25 (dark), 03c (live).
- Footer reads "↵ Jump ↑↓ Move esc Close". "esc Close" is lower case in plain text, but every other key is a keycap elsewhere. "Jump" is an unexplained verb.
- Dark mode selected row is a desaturated slate (#3A3F5C in the render) that barely separates from the panel. Light mode uses a clear lavender. The two states look like different components.
- Window rows show generic app icons, so the only way to tell "Doc 1" from "Doc 2" is the title.
- Fix: footer as three keycap chips at 11 pt: [↵] Go  [↑][↓] Move  [esc] Close. Dark selected row: accent at 28% over the panel material, same as light. Window row shows app icon at 28 pt and title plus a secondary line with the desktop ("Desktop 2"), so position is readable without counting.

### 7. Shortcuts sheet: "Reset all" is nearly invisible and the sheet is much bigger than its content
Screenshots: 22, 23.
- "Reset all" in light mode is pale grey on white (about 1.4:1). In dark mode it is equally faint. It is a destructive action, so it should be readable.
- The sheet is 900 × 700 with a large empty body (in this render, the list is absent; the layout still reserves the space). The "More" pill floats alone in that space.
- Fix: "Reset all" to secondary label colour at 4.5:1 minimum, with a confirmation step. Size the sheet to content with max height 560 pt and a scroll for the rest. Put "More" directly under the last visible row, not at the window bottom.

### 8. Settings labels are technical and ambiguous: "Shortcut keys ^⌥ ⬍" and "Focus ring"
Screenshot: 07.
- "Shortcut keys" with a single popup showing `^⌥` does not say what the popup changes. It is the modifier chord that every shortcut starts with.
- "Focus ring" describes an implementation, not the effect.
- Fix: rename the row to "Hold these keys" with the sub-line "Ribbon starts with ^⌥." Rename "Focus ring" to "Highlight the window I'm in". The popup gets a 12 pt secondary subtitle listing the chord in words: "Control + Option".

### 9. Onboarding cheat sheet asks for four shortcuts at once
Screenshots: 21 (snapshot), 20 (ask step).
- Four shortcut rows, a headline, a sub-line, and a Start button, all in one card. For an ADHD user who has just granted a permission, this is the moment of maximum overwhelm, and "Change width" and "Move a window along" are not needed on first run.
- The ask step is good and calm (20). The cheat sheet is busier than the ask step and feels like a different product.
- Fix: show two rows on first run: "Glide left / right" and "Find anything". Add a line "More shortcuts: click the Ribbon menu." Row height 44 pt, key caps 22 pt high, label 14 pt. Keep "You're all set." and "Start".

### 10. Focus ring corner radius looks mismatched with the window
Screenshots: 02, 13.
- The focused window has a 3 pt indigo ring. At the top corners of 13 the ring's curve looks slightly larger than the window's own corner, with a faint gap. I could not measure this precisely from the screenshot, so treat it as a suspicion to verify at 2x.
- Fix: draw the ring with radius = window corner radius + 2 pt and inset 0, width 2 pt, colour accent at 85%. Concentric radii are the cheap fix. Reduce to 2 pt if it reads as harsh; the current saturation is high next to the warm orange and red windows.

---

## Copy audit

Voice rule used: calm, short, kind, human. No jargon. Say what it does for me.

| Where | Now | Problem | Rewrite |
|---|---|---|---|
| Menu | Pause Ribbon | "Pause" reads as a media control; no sense of duration | Pause for now |
| Menu | Resume Ribbon | Fine | Keep: Resume Ribbon |
| Menu | Show Ribbon Map | Jargon; "map" means nothing to most people | Show my windows |
| Menu | Show Shortcuts | Fine | Keep |
| Menu | Settings… ⌘, | "…" is a typographic ellipsis, mixed with "..." elsewhere | Settings…  ⌘, (consistent ellipsis) |
| Settings General | Shortcut keys | Ambiguous: it is a modifier chord | Hold these keys |
| Settings General | Hold ^⌥ to show the ribbon map | "ribbon map" jargon | Hold ^⌥ to see all your windows |
| Settings General | Focus ring | Implementation term | Highlight the window I'm in |
| Settings General | Open Ribbon at login | Acceptable | Start Ribbon when I log in |
| Settings Layout | Gap between windows: 12 pt | Units shown to the user | Space between windows: 12 pt |
| Settings Layout | New window width: Half | Fine | Keep |
| Settings Layout | New windows open: Right of the current one | Wordy | New windows appear to the right |
| Settings Layout | Center a window that doesn't fit on screen | Long and technical | Center windows that are too wide |
| Settings Input | macOS also uses three-finger swipes — switch it to four fingers so Ribbon and macOS stay out of each other's way. | Good intent, too long | macOS uses three-finger swipes too. Set macOS to four fingers so they don't fight. |
| Settings Input | Open Trackpad Settings | Fine | Keep |
| Settings Apps | Always float these apps | "Float" is jargon | Keep these apps out of the ribbon |
| Settings Apps | New windows of these apps open on top of the ribbon instead of in it. | Good, slightly long | Their new windows float over the ribbon instead of joining it. |
| Settings Apps | Add a running app | Fine | Keep |
| Command bar | Jump | Unclear verb | Go |
| Command bar | esc Close | Lower case, not keycap | [esc] Close |
| Command bar | No match for "x" | Blunt | Nothing matches "x" |
| Command bar | Float / Tile (in code) | Jargon | Keep out of ribbon / Put back in ribbon |
| Command bar | Pop out of stack | Fine | Take out of stack |
| Command bar | Stack into left column | Technical | Stack with the window on the left |
| Command bar | Cycle height | Technical | Change height |
| Command bar | Even out heights | Fine | Make heights equal |
| Command bar | Make narrower / wider | Fine | Keep |
| Command bar | Full width | Fine | Keep |
| Toast | First window / 1 of 4 | Position only, no identity | Doc 1 · first of 4 |
| Toast | Desktop 3 · empty (in code) | Flat | Desktop 3 is empty. Open a window to start. |
| Toast | Undo with nothing to undo (silent) | No feedback | Nothing to undo |
| Conflict card | Fake Tiler is also moving windows | Okay, but "moving" is vague | Fake Tiler is also moving your windows |
| Conflict card | Two window managers pull the same windows around. Quit Fake Tiler to keep the ribbon steady. | Jargon ("window managers") | That makes the ribbon jump. Quit Fake Tiler to keep things calm. |
| Conflict card | Keep both | Fine | Keep both running |
| Shortcuts | Everything starts with ^⌥. Try ^⌥ → first. Click any shortcut to record your own. | Good; "record" is dev-speak | Everything starts with ^⌥. Try ^⌥ → first. Click a shortcut to change it. |
| Shortcuts | Reset all | Unclear what gets reset | Reset to defaults |
| Shortcuts recorder | Press a shortcut, Esc to cancel, Delete to clear | Three instructions in one line | Press new keys · Esc cancels · Delete clears |
| Shortcuts recorder | Put every shortcut back to its default | Long tooltip | Restore defaults |
| Onboarding ask | Let Ribbon tidy your windows. | Good | Keep |
| Onboarding ask | Ribbon needs Accessibility access to move windows into one calm, scrolling row. Nothing leaves your Mac. | Good, reassuring | Keep |
| Onboarding ask | Opens System Settings. Come back here — Ribbon notices on its own. | Good | Keep |
| Onboarding cheat | You're all set. | Good | Keep |
| Onboarding cheat | Try it now: ^⌥ → | Fine | Keep |
| Onboarding cheat | Glide left / right | Vague | Glide along the ribbon |
| Onboarding cheat | Move a window along | Vague | Move this window along |
| Onboarding cheat | Change width | Fine | Resize this window |
| Onboarding cheat | Find anything | Good | Keep |
| Desktop-count note | Stage Manager is on | Jargon, no action | Stage Manager is on. Turn it off so windows don't fight the ribbon. |
| Desktop-count note | Ribbon works best with one Space per display | "Space" jargon | Ribbon works best with one desktop per display |
| Desktop tab | None. Every app tiles. | Slightly grim | No exceptions. Every app joins the ribbon. |
| Stop info | It runs in the background, so stop it from Terminal. | Points to the wrong tool for most users | Ribbon runs in the menu bar. Quit it from there. |
| Shortcut conflict | Some shortcuts are taken by another app: | Colon, sentence ends in a list | Another app uses some of these keys: |
| Empty state | Nothing here yet / Nothing to arrange | Fine | Keep |
| Errors | Oops | Vague, no next step | Keep only with a next step: "Oops. That window closed. Nothing lost." |

---

## Consistency table

Radii are from the code where it exists (marked "code") and from screenshots otherwise (marked "approx.").

| Surface | Material | Corner radius | Typography | Accent use |
|---|---|---|---|---|
| Window strip HUD (02, 26) | Glass pill, wallpaper-tinted | approx. 22 pt | Title 13 semibold, position 11 secondary | Indigo ring on selected thumbnail |
| Toast (05, 06) | Glass pill, wallpaper-tinted | approx. 20 pt; shorter than HUD | 13 semibold | None; text only |
| Command bar (24, 25) | Opaque-ish panel with glass selection | approx. 24 pt | 15 regular input, 15 rows | Lavender selection (light) / slate (dark) |
| Onboarding (20, 21) | Opaque white card, glass backdrop | 28 pt (code) | Display 26 (code), body 14 | Indigo prominent button (code: Theme.accent) |
| Onboarding cheat rows | Light grey inset | 18 pt (code) | Label 14 | None |
| Conflict card (30) | Glass card | approx. 18 pt | Title 15 semibold, body 13 | Buttons neutral; "Quit" grey |
| Shortcuts sheet (22, 23) | Opaque white / near-black | approx. 28 pt | Title 26 bold, sub 15 | "Got it" indigo; "More" lavender pill |
| Settings window (07–10) | Native macOS window | System (approx. 10 pt) | System 13 | System blue toggles (not Ribbon indigo) |
| Menu bar menu (12) | Native menu, glass tint | System | System 13 | None |

Inconsistencies to fix:
- Two blues. Settings uses macOS system blue for toggles, while onboarding, the command bar and the HUD use Ribbon indigo. Pick one accent, and let Settings use it via `.tint`.
- Radii do not form a scale. The HUD (~22), toast (~20), command bar (~24), card (~18) and sheet (~28) are five different values for one family. Use three: 28 for full sheets and onboarding, 20 for floating panels (HUD, command bar, conflict card, toast), 12 for inner rows and keycaps.
- Materials. The command bar and onboarding are opaque-ish; the HUD and toast are glass. Pick one rule: transient floating surfaces use glass with a base fill (see fix 4); persistent sheets use opaque.
- Dark selection. Command bar dark selection is desaturated; light is clear lavender.

---

## Stupidly smart ideas (small, no clutter)

1. **"Where was I?" via ⌃⌥Tab.** Keep a 5-entry focus history in the controller (`focus_window` already exists). ⌃⌥Tab jumps to the previous window, and holding it shows the last three in the HUD with their titles, so going back is one keystroke, not a hunt. Small: a ring buffer plus one command.
2. **Gentle nudge at 12+ windows.** When the ribbon has more than 12 windows, show one dismissible toast: "12 windows in your ribbon. Stack the old ones? ⌃⌥S". Show once per session, with "Don't remind me". The map already has `count` per desktop, so the check is trivial.
3. **Welcome on an empty desktop.** Switching to an empty desktop (16) currently shows nothing useful. Show a single calm line in the HUD: "Desktop 3 is empty. Open anything and it finds its place." with the ⌃⌥Space keycap. It answers the "where did everything go?" moment, which is a common ADHD stall.
4. **One-shot focus pulse.** When the focused window changes via a desktop switch, the ring fades in from 0.6 to 1.0 over 250 ms, once. It helps the eye find the active window after a jump. Respect Reduce Motion (the onboarding already reads `accessibilityReduceMotion`).

---

## Priority order for the next build

1. Settings window sizing and empty space (fix 1), because it is the most visible polish gap.
2. Conflict card action hierarchy (fix 2), because it is the one place where a wrong default is a real trap.
3. Toast contrast and copy (fix 4), because it is the only feedback channel most of the time.
4. Menu bar naming and desktop number (fix 5), because it sets the vocabulary for everything else.
5. Copy pass from the audit table, done in one sweep so the voice is consistent.
