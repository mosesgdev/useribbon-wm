# AX layer recipes (from AeroSpace / OmniWM / yabai / Paneru research)

- Enumerate: NSWorkspace apps with activationPolicy .regular → AXUIElementCreateApplication(pid) →
  kAXWindowsAttribute. Tile only role AXWindow + subrole AXStandardWindow, not minimized, not "AXFullScreen",
  not AXModal, size >= 100x100. Others: float/ignore. CGWindowID via
  `@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ e: AXUIElement, _ id: inout CGWindowID) -> AXError`
  (the only private symbol we use; stable for 10+ years, used by every WM).
- Observe: AXObserverCreate per pid; app element: kAXWindowCreated, kAXFocusedWindowChanged; per window:
  kAXUIElementDestroyed, kAXResized, kAXWindowMiniaturized/Deminiaturized. NSWorkspace launch/terminate/activate.
  Electron/Chrome windows appear late → rescan app at 100ms, 400ms, 1.2s after create/launch/focus-changed.
- Write frames: shrinking → size then position; growing → position then size; AeroSpace does size,pos,size.
  Disable AXEnhancedUserInterface on the app element during writes (restore after) — kills animated, janky moves.
  AXUIElementSetMessagingTimeout(appEl, 0.25). AX calls off the main thread (serial queue). Read back frames;
  apps may refuse sizes.
- Hide off-viewport: keep a sliver on-screen (macOS relocates fully offscreen windows); never minimize.
- Coordinates: AX = top-left origin of primary screen. axY = primaryScreen.frame.maxY - appKitRect.maxY.
  Primary = NSScreen.screens.first.
- Hotkeys: Carbon RegisterEventHotKey — no extra permission.
- Focus: AX kAXFrontmostAttribute=true on app element + kAXMainAttribute=true + kAXRaiseAction on window,
  then NSRunningApplication.activate(). No SLPS in v0.
- Quit: restore every window synchronously to an on-screen frame (original frame saved on first sight).

## Focus ring ordering
`NSPanel.order(.below, relativeTo: <CGWindowID of another app's window>)` works with public API: the panel lands
directly behind the target in the window server's order (checked with `CGWindowListCopyWindowInfo`). It must be on
the target's window level (`kCGWindowLayer`, normally 0). Order is not a binding: re-issue it whenever focus changes.

## Three-finger scroll: MultitouchSupport (private, optional)
`dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport")`, then `dlsym`:
`MTDeviceCreateList`, `MTRegisterContactFrameCallbackWithRefcon` (or `MTRegisterContactFrameCallback`), `MTDeviceStart(dev, 0)`
(`MTDeviceStop` to end). The callback runs on a private thread: `(device, touches*, count, timestamp, frame[, refcon])`.
Contact struct (64-bit): 96 bytes each; Int32 state at +20 (4 = touching), Float normalized x at +32, y at +36 (0...1),
velocity at +40/+44. Read with `loadUnaligned`, bounds-check the count and discard non-finite or out-of-range
positions. Devices may need a restart after wake. No permission prompt; Ribbon reads contacts only, it does not
suppress macOS's own three-finger gesture (turn that off in Trackpad settings if both fire).
