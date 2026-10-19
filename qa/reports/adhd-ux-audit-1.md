# Ribbon ADHD-friendliness audit, round 1

Reviewer: UX audit against the ADHD target (zero friction, calm, low cognitive load, no lost-window moments).
Scope: user-visible strings and flows in `app/Sources/Ribbon/UI/*.swift`, `App/Controller.swift`, `core/src/engine.rs` toasts, `Platform/Hotkeys.swift` labels, `Platform/Conflicts.swift`.
Method: source review only. No VM screenshots were taken this round. The live captures in `qa/reports/ux-review-1/` were reused where they are relevant, and `ux-review-1.md` (visual polish) is not repeated here. Items overlapping it are cross-referenced.

Effort: S = copy or one-line change, M = a few files or a behaviour change, L = design or flow rework.

---

## Top 5 (highest impact, low effort)

### 1. One vocabulary for tabs, stacks and columns (S)
Locations and current text:
- `core/src/engine.rs:725` toast `"Tab group: A + B"`. Also `Controller.swift:766` appends `" · ⌃⌥Tab to switch"`.
- `core/src/engine.rs:1008` and `:3974` (test): the **tabs** command (`toggle_tabs`) toasts `"Stacked"`, while the `stack` command also toasts `"Stacked"`. The same word means two things.
- `Controller.swift:769` `"Tabbed. ⌃⌥Tab to switch, or click a tab."`
- `core/src/engine.rs:1059` `"Own column"` (unstack). `Controller.swift:886` `"Moved X to its own column"`. `Controller.swift:893` `"No column there"`.
- `UI/CommandBar.swift:94` `"Make tabs / toggle tabs"`. `UI/TabBars.swift:292` `"Close tab group"`. `UI/CommandBar.swift:95-96` `"Add to tabs on the left"`. `Controller.swift:688` `"Make a tab group with X"`.

Proposed replacements (exact):
- Toast `engine.rs:725`: `"Tabs: A + B"`
- `engine.rs:1008` and `:1058` (stack): keep `"Stacked"`. For `toggle_tabs` produce `"Tabbed: A + B"`, not "Stacked".
- `Controller.swift:769`: `"Tabs are on. ⌃⌥Tab switches, or click a tab."`
- `engine.rs:1059`: `"Separated"`
- `Controller.swift:886`: `"Moved X out of the group"`
- `Controller.swift:893`: `"Nothing on that side"`
- `CommandBar.swift:94`: `"Group into tabs"`
- `TabBars.swift:292`: `"Ungroup tabs"`
- `CommandBar.swift:95`: `"Add to tabs on the left"` (keep). `Controller.swift:688`: `"Group with X as tabs"`

Why: "column", "stack", "tab group", "tabs" and "tabbed" are used for the same objects. A user who learns one word will not find the command under another. Fewer words means less to hold in working memory.
Note: the engine tests asserting these strings (`engine.rs` around 2819-2820, 3871-3994, 4267) must be updated in the same change.

### 2. Onboarding first screen: drop the metaphor and state the ask (S)
- `UI/Onboarding.swift:36`: current `"Ribbon needs Accessibility access to move windows into one calm, scrolling row. Nothing leaves your Mac."`
  Proposed: `"Ribbon needs Accessibility access to move your windows. Nothing leaves your Mac."`
- `UI/Onboarding.swift:41`: current `"Opens System Settings. Come back here — Ribbon notices on its own."` Keep; it is good.
- `UI/Onboarding.swift:54`: current `"Try it now: \(modifier.glyphs) →"`
  Proposed: `"Try it now: hold \(modifier.glyphs) and press →"`
- `UI/Onboarding.swift:64`: current `"Hold \(modifier.glyphs) to see your windows. Find anything shows the rest."`
  Proposed: `"Hold \(modifier.glyphs) to see all your windows. \(modifier.glyphs)Space finds anything."`

Why: "row", "ribbon" and "strip" are three names on one screen. The first screen is where the user decides whether to trust the app, so it should be the plainest. "Try it now: ⌃⌥ →" is a glyph puzzle for a user who has ADHD and is scanning.

### 3. Remove the optional Screen Recording ask from the "You're all set" screen (S)
- `UI/Onboarding.swift:66-72`: the `if !ScreenRecording.granted` block shows `"Optional: smoother swiping."` plus `"Turn on Screen Recording"` on the final screen, right after the Accessibility grant.
- `UI/SmoothSwipeCard.swift:22-23` already offers this, once, after the user's first real swipe (`Controller.swift:1081-1083`).

Proposed: delete the block at `Onboarding.swift:66-72`. Keep the card as the only place this is offered.
Why: the flow asks for two permissions in one sitting, on the screen whose job is to say "you're done". The second ask is a decision the user has not yet needed. Removing it leaves one decision (Start) on that screen.

### 4. The "Ribbon works best with one Space per display" alert is modal and uses a log-out step (S for copy, M to make it non-modal)
- `App/Controller.swift:256-261`: `NSAlert.runModal()` appears 1.5 s after launch. Copy: `"Ribbon works best with one Space per display"` / `"Turn on “Displays have separate Spaces” in System Settings → Desktop & Dock, then log out and back in. Until then windows may jump between displays."` Buttons: `"Open Desktop & Dock Settings"`, `"Not now"`.

Proposed copy (S):
- Message: `"Windows may jump between displays"`
- Informative: `"Turn on “Displays have separate Spaces” in Desktop & Dock. Settings → Input explains how."`
- Buttons: `"Show me"`, `"Later"`

Proposed behaviour (M): show this as a dismissable card or HUD toast, not a modal, so it cannot block the user's first minute. Keep the "log out" detail only in Settings (`Settings.swift:248` already has it).
Why: a modal at launch is an interruption at the worst moment. It also asks for a log-out, which is a large, delayed cost the user will defer and then forget.

### 5. Stop opening Settings and the swipe card right after a gesture (S)
- `App/Controller.swift:238-240`: on the first conflicting swipe, `SettingsWindow.show()` opens the whole Settings window unprompted. The user just swiped; a window now covers their work.
- `App/Controller.swift:1081-1083` plus `UI/SmoothSwipeCard.swift:22-23`: the smooth-swipe card appears 0.6 s after the first swipe, while the user is still in the flow.

Proposed:
- `Controller.swift:240`: replace `SettingsWindow.show()` with a non-activating toast: `"macOS also uses 3-finger swipes. Fix it in Settings → Input."` (Show Settings only when the user clicks it.)
- `Controller.swift:1083`: offer the card on the second session launch, or when the user has been idle for ~10 s. Do not offer it during or right after a gesture.

Why: the user should not lose their place. The "where did my window go?" feeling is strongest when a large window appears on top of the thing they were doing.

---

## Items 6-13 (ranked)

### 6. "Focus mode" is also "Dim other windows", "Dimming" and "Blur" (S)
- `UI/CommandBar.swift:99` `"Dim other windows"` and `:100` `"Focus mode"`.
- `UI/MenuBar.swift:14` `"Focus mode"`, `:59` tooltip `"Blur everything but this window (…)"`.
- `Platform/Hotkeys.swift:137` `"Focus mode (blur the rest)"`.
- `App/Controller.swift:1454` `"Dimming off"` / `"Dimming on"`. `Controller.swift:1480` `"Focus mode on"`.
- `UI/DimOverlay.swift:4` (comment) `"Other windows: Dim / Blur"`.

Proposed: one name everywhere, `"Focus mode"`. Its tooltip and menu subtitle: `"Dim everything except this window"`. Toasts: `"Focus on"` / `"Focus off"` (keep the `" — ⌃⌥B to leave"` tail, which is good). Remove the separate `"Dim other windows"` command, or rename it `"Dim the rest (no focus)"` if it is a real separate mode.
Why: four names for one state leads to "what is the difference?" and to searching for a feature by the wrong word.

### 7. Hotkey mnemonics: two "T"s and a "B" that does not mean anything (M)
- `Platform/Hotkeys.swift:144` `T` = tabs and `:145` `⇧T` = `"In or out of the ribbon"`. Same letter, distinguished only by Shift.
- `:137` `B` = focus mode. `:133` `V` = change height. `:170` `D` = back to last desktop.

Proposed: keep the keys (changing them breaks muscle memory), but make the Shortcuts sheet show the word: e.g. `"Tabs"` → `"Group into tabs (T)"`. Consider adding the letter to the title in the sheet rather than relying on the keycap. Longer term, an alias of `F` for focus is not possible (`F` is full width) — so the mnemonic cannot be fixed without a key change; record that as a decision, not a bug.
Why: a hard-to-remember hotkey is where ADHD users go back to the menu or give up. Showing the mnemonic in the sheet costs little.

### 8. Shortcuts sheet subtitle is three sentences (S)
- `UI/ShortcutsSheet.swift:92`: current `"Everything starts with \(glyphs). Try \(glyphs) → first. Click a shortcut to change it."`
  Proposed: `"Hold \(glyphs) and press → to try it. Click any shortcut to change it."`
- `:93` (when overrides exist): current `"Most start with \(glyphs). Click a shortcut to change it."` Keep.
- `:101` group names `"Ribbon"` (contains Pause and Focus). Proposed: rename the group `"Pause & focus"`; `"Oops"` is good, keep it.
Why: the sheet is opened by someone who is already lost. Lead with the one action to take.

### 9. Settings: "float" and "ribbon" jargon in user copy (S)
- `UI/Settings.swift:275`: `"Their new windows float over the ribbon instead of joining it."`
  Proposed: `"New windows from these apps open on top of the ribbon, not in it."`
- `Controller.swift:1051` toast `"Floating"` (`engine.rs:1051`, test `:2821`). Proposed: `"Out of the ribbon"`. Its opposite `"Back in the ribbon"` is already good.
- `UI/Settings.swift:65-69` subtitle `"Apps that should stay out of the ribbon."` Keep.
Why: "float" means nothing to most people. The Apps pane already uses plain words, so this should match.

### 10. Conflict card: "Keep it on" is ambiguous, and copy is jargon-heavy (S; cross-ref ux-review-1 item 2)
- `UI/ConflictCard.swift:35`: `"Keep it on"` (Stage Manager). Proposed: `"Leave it on"`.
- `Platform/Conflicts.swift:85`: `"Two apps moving the same windows makes the ribbon jump. Quit \(c.name) to keep things calm."` Proposed: `"\(c.name) also moves your windows, so the ribbon jumps. Quit it to keep things calm."`
- `Platform/Conflicts.swift:84`: `"It moves windows around too, so the ribbon jumps. Turn it off in Desktop & Dock to keep things calm."` Keep (clear).
- `ConflictCard.swift:38`: `"Keep both running"`. Proposed: `"Keep both"`.
Why: "Keep it on" reads as "keep Ribbon on" to a skimming user. Shorter buttons are easier to decide.

### 11. Engine: "That's the end of the ribbon" is cute but gives no next step (S)
- `core/src/engine.rs:1043` and `App/Controller.swift:1397` `endOfRibbon`: `"That's the end of the ribbon"`.
  Proposed: `"No window further \(dir)"` with `dir` = left or right; or simply `"Last window"`/`"First window"` to match the existing `focus_first`/`focus_last` toasts (`engine.rs:1054-1055`).
Why: the phrase does not say whether to turn around or give up. The position toasts already exist and are consistent with the HUD.

### 12. Trackpad error toast uses technical wording (S)
- `App/Controller.swift:509`: current `"Swipe to scroll isn't available: the trackpad sent no touch data."`
  Proposed: `"Swipe scrolling isn't available on this trackpad."`
- `App/Controller.swift:521`: current `"\(name) isn't responding. Ribbon will leave it alone until it recovers."` Keep; it is calm and says what Ribbon does.
Why: "touch data" is a developer detail. The user only needs to know that swiping is off and that it is not their fault.

### 13. Smooth-swipe card body is long (S)
- `UI/SmoothSwipeCard.swift:21-23`: heading `"Want silky swiping?"`, body `"Ribbon can slide pictures of your windows while your fingers move. It needs Screen Recording. Pictures stay in memory and are never saved."`
  Proposed body: `"Smoother swiping needs Screen Recording. Previews stay in memory and are never saved."`
Why: three sentences for one yes/no decision. The "why" is the key fact; the mechanism is not needed to decide.

---

## Not raised (checked, fine as is)
- `UI/HUDLogic.swift:183-184` `"Nothing to arrange"` / `"Open something and it'll find its place"`: calm and actionable.
- `UI/HUDLogic.swift:203` `"Desktop 3 is empty"` / `"Open a window to start"`: good.
- `UI/CommandBar.swift:165` placeholder `"Find a window or action"`: good.
- `UI/CommandBar.swift:197` footer `Go / Move / Close` with keycaps: good. Its polish is in ux-review-1 item 6.
- `Controller.swift:1480-1482` `"Focus mode on — ⌃⌥B to leave"`: good; the way out is named. Use it as the model for other toasts.
- `Platform/Conflicts.swift:84` and `Controller.swift:521`: calm and specific.
- Undo, redo and "Nothing to undo" (`engine.rs:1389`) give a clear escape hatch. Keep.

## Cross-references
- Visual items (Settings height, conflict button styling, HUD placement, toast contrast, menu bar naming, shortcut sheet "Reset all" contrast) are in `qa/reports/ux-review-1.md` and are not repeated.
- Items 2, 5 and 10 touch the same files as ux-review-1 items 2, 8 and 9. Land copy changes together with those visual fixes to avoid a second pass over the same strings.
