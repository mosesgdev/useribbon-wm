# Multi-display checklist (PHL 3840x1200 main + built-in above-right)

Before you start: System Settings > Desktop & Dock > "Displays have separate Spaces" is on. Open Ribbon > Settings and
check "Move the pointer between displays at the edges" is on (it is by default for your corner-touching layout).

1. **Two ribbons.** With a few windows on the PHL, press the menu-bar desktop number's keys ⌃⌥2 then ⌃⌥1. Expect: only the display of the
   focused window switches desktops; the other display's windows stay put. The menu-bar number shows the focused display's desktop.
2. **Pointer teleport.** Push the pointer against the right edge of the PHL at any height. Expect: it lands on the built-in's left edge at
   about the same height fraction, never in a corner. Push left on the built-in's left edge: it returns to the PHL's right edge.
3. **Turn teleport off.** Untick the Settings toggle and repeat step 2. Expect: the pointer stops at the edge. Tick it again.
4. **New window follows the mouse.** Park the pointer on the built-in and open a new window (⌘N in Finder, or launch an app).
   Expect: it opens on the built-in, right of that ribbon's focused column, even if the app tried to open it on the PHL. Repeat on the PHL.
5. **Focus across.** On the PHL, press ⌃⌥→ until "That's the end of the ribbon" would show. One more ⌃⌥→: focus moves to the
   built-in's leftmost visible window, and the HUD, focus ring and toast appear on the built-in. ⌃⌥← from its left end returns to the PHL's rightmost window.
6. **Move a window across.** Focus a window on the PHL, press ⌃⌥⇧⌘→. Expect: it moves to the built-in (toast "Moved to Built-in ..."), keeps its
   width, takes focus; the PHL ribbon closes the gap. Press ⌃⌥⇧⌘← to send it back. (Undo does not reverse this; it is not an undo step.)
7. **Command bar.** ⌃⌥Space, type "other display": both "Move window to other display" and "Focus other display" are listed and work.
8. **Parked windows stay home.** Scroll a ribbon so some windows are off-screen, and switch to an empty desktop on one display. Expect: no
   sliver of a parked window shows on the other display. Parked windows reappear when you scroll back.
9. **Drag across.** Drag a window by its title bar from the PHL onto the built-in and let go. Expect: it joins the built-in ribbon near where you dropped it, with the toast.
10. **Unplug.** Disconnect the PHL (or the built-in is the only one left). Expect: all windows appear in the remaining display's ribbon, at the end, none lost.
    Reconnect it: windows that came from it move back (best effort; they land on desktop 1). Quit Ribbon from the menu: every window returns to its original place.
