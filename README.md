# Ribbon

A calm, scrolling window manager for macOS. Your windows sit side by side on one ribbon;
you glide left and right instead of arranging. Built for brains that lose track easily:
zero setup, one modifier, a "you are here" map on every move, and undo for everything.

## Try it

```sh
make install      # builds core + app, installs ~/Applications/Ribbon.app, launches it
```

First launch asks for **Accessibility** (one switch in System Settings), which Ribbon needs to move your windows.
**Screen Recording** is optional: it makes swipes and glides smoother (Ribbon slides pictures of your windows; they stay
in memory and are never saved), and Ribbon needs a quit and reopen after you grant it.
If another window manager (Rectangle, Magnet, yabai, OmniWM…) or Stage Manager is on, Ribbon notices and offers to quit it (or keep both) in one quiet card.

### Install with your coding agent

No Xcode needed: Apple's Command Line Tools are enough. Paste this to Claude Code, Codex or any coding agent:

> Install Ribbon by following INSTALL.md at https://github.com/mosesgdev/useribbon-wm

The agent checks your Mac, shows you a plan, asks before it installs anything (Rust, a signing certificate) and stops
for the three things only you can do. `scripts/bootstrap.sh check` shows what your Mac has and lacks; `update` and
`uninstall` live in [INSTALL.md](INSTALL.md) too. By default each update needs the Accessibility switch redone;
`--signing local` makes a stable local certificate so it survives.

## The keys (⌃⌥ = Control + Option)

| | |
|---|---|
| ⌃⌥ ← → | glide between windows |
| ⌃⌥⇧ ← → | carry the window along |
| ⌃⌥ Tab | back to the last window (twice = toggle) |
| ⌃⌥ R | next width (25 · 33 · 50 · 66 · 75 · 100 %; Settings → "Simple" for ⅓ · ½ · ⅔ · full) |
| ⌃⌥ V | next height for a stacked window (⅓ · ½ · ⅔) |
| ⌃⌥ E | even out the heights of a stack |
| ⌃⌥ Home / End | first / last window (fn ← / → on a laptop) |
| ⌃⌥⇧ Home / End | carry the column to the start / end of the ribbon |
| ⌃⌥⇧⌘ 1…9 | go to window n, the nth column (the strip numbers them). Not set under Hyper (its ⇧ digits send windows to desktops): record your own in Shortcuts, or type "window 3" in the command bar |
| ⌃⌥ W / ⌃⌥⇧ W | nudge the column wider / narrower by 5 % of the screen |
| ⌃⌥ H / ⌃⌥⇧ H | nudge the window taller / shorter within its stack, by 5 % of the stack |
| ⌃⌥⇧ ↑ ↓ | move the window up / down within its stack (in a tab group: the tab) |
| ⌃⌥⌘ 1…6 | set the width directly: the 1st…6th step of the width list (25 · 33 · 50 · 66 · 75 · 100 %, or ⅓ · ½ · ⅔ · full in Simple). Not set under Hyper (every digit combination is taken there): record your own in Shortcuts, or use the command bar's "Width 66 %" |
| ⌃⌥ F | full width, again to restore |
| ⌃⌥ B | Focus mode: blur everything except the window you are in; again to leave (starts off after every launch). Settings → "Other windows": Normal / Dim / Blur. Clicking a blurred window still reaches it and focuses it, so the blur moves there |
| ⌃⌥ T | make tabs in one step: a lone window joins its left neighbour (right, if it is the first column) as a tab group; on a stack it makes tabs; on a tab group it goes back to a stack. Or drag a window by its title bar onto another window's title bar |
| ⌃⌥ Space | find anything (windows + actions) |
| ⌃⌥ Z | undo the last layout change |
| ⌃⌥ S / ⌃⌥⇧ S | stack into the left column / pop out |
| ⌃⌥ G | stack into the right column (the mirror of ⌃⌥ S) |
| ⌃⌥ 1…9 | go to desktop n (nine virtual desktops, like OmniWM) |
| ⌃⌥⇧ 1…9 | send the window to desktop n (you stay put) |
| ⌃⌥ D | back to the previous desktop (twice = toggle) |
| ⌃⌥ T | tabs / stack this column (a tab bar above one window; click a tab, or ↑ ↓ cycle) |
| ⌃⌥ Page Down / Up | next / previous tab (fn ↓ / ↑ on a laptop) |
| ⌃⌥⇧ T | float / tile this window |
| ⌃⌥ P | pause (windows go back where they were) |

Don't like a key? Open Show Shortcuts (menu bar or the command bar), click any shortcut, and press the one you want. Esc cancels, Delete clears it, and a small arrow resets it. Ribbon warns you if the combo is already taken.

A soft accent ring marks the focused window (Settings → Focus ring). Swipe with **three fingers** on the trackpad to scroll the ribbon: it follows your fingers, and on release the nearest column becomes the focused one. (If macOS also uses three fingers to switch Spaces, turn that off in System Settings → Trackpad → More Gestures.)

Each desktop is its own ribbon. Windows on other desktops are parked off-screen (not minimized, not on macOS Spaces); focusing one from ⌘Tab or the Dock switches to its desktop. The HUD shows `Desktop 3 · empty` so you are never lost, and the menu bar shows the active desktop number.

Minimize (yellow button) and hide (⌘H) take a window out of the ribbon and close the gap; Ribbon remembers its desktop and width. Bring it back from the Dock, by unhiding, or from the command bar (where it shows as *Minimized* / *Hidden*): it returns to the desktop it left, at its old width, next to the focused column.

**Always float these apps** (Settings, or "Always float <App>" in the command bar) keeps utilities like Calculator out of the ribbon. **Restarting Ribbon keeps your layout**: order, widths, stacks, desktops and focus come back (for up to a day) as long as the windows do. Settings also has "Center a window that doesn't fit on screen".

**Dim other windows** (Settings, or the command bar; off by default) darkens everything but the focused window, Subtle or Medium; the menu bar, Dock and Ribbon's own panels stay clear. **Drag a window by its title bar** onto another column: a soft glass marker shows what will happen (a bar = its own column there, a highlight = join that column as a stack or tab, middle third of the column); let go over nothing and it snaps back.

Drag a window's edge to resize it — the ribbon adopts that width (height too, inside a stack). Quitting puts every window back.

## How it's built

One process, one required permission (Accessibility), no private APIs beyond the universal `_AXUIElementGetWindow` and, optionally, MultitouchSupport (dlopen'd for three-finger scroll; the app works without it).

- `core/` — Rust. Pure layout state machine: events in, window frames out. Deterministic, 50+ unit
  tests and property tests (fuzzed with 30k+ random sessions). Exposed through a 4-function C ABI with JSON.
- `app/` — Swift. Accessibility (window discovery, observers, frame writes with read-back + glide
  animation), Carbon hotkeys, and the SwiftUI UI in Liquid Glass: ribbon-map HUD, command bar,
  onboarding, settings.
- `docs/` — design language (Dia/Arc-inspired, ADHD-first), Liquid Glass and AX notes.
- `qa/` — plan invariant checker, scenarios, QA reports (live dummy-window runs + Mac mini builds).

`make test` runs core tests + an FFI self-test for each edition the checkout can build. `Ribbon --snapshot <dir>` renders the UI to PNGs.
Ribbon is open-core: [EDITIONS.md](EDITIONS.md) says what the free and Plus editions are, where Plus code lives and how to add to it.

## Thanks

Ribbon stands on other people's work. The scrolling layout is the idea PaperWM and niri brought to Linux. On macOS,
[OmniWM](https://github.com/BarutSRB/OmniWM) gave Ribbon its model of nine virtual desktops per display, the geometric
rule for which display is "next to" another (Ribbon's is an independent, shorter take on OmniWM's `macOSAdjacentMonitor`),
and the idea of parking off-screen windows on the side that faces no other display.
The Accessibility recipes in [docs/ax-notes.md](docs/ax-notes.md) come from reading
[AeroSpace](https://github.com/nikitabobko/AeroSpace), [yabai](https://github.com/koekeishiya/yabai), OmniWM and Paneru.
Ribbon reimplements these ideas; it copies no code from them.

## License

The free edition of Ribbon is free software under the [GNU General Public License v3.0 or later](LICENSE). The Plus
edition's own code (`core/src/plus/`, `app/Sources/Ribbon/Plus/`) is not part of it: see [EDITIONS.md](EDITIONS.md).

## Releasing

Signed, notarized DMGs with Sparkle updates: see [RELEASING.md](RELEASING.md).
