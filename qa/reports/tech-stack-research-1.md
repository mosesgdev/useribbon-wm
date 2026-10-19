# Ribbon tech-stack research, round 1

Date: 2026-10-15. Research only. No code changed, nothing committed, nothing run on the Mac.

## 0. Method and limits

- Read: `README.md`, `SPEC.md` (sections on AX, swipe, restore, session), `docs/ax-notes.md`, `app/Sources/Ribbon/Platform/*` (grep plus `AXWindow.swift`, `Restore.swift`).
- Note: `~/projects/ribbon/CLAUDE.md` does not exist. There is no repo-level CLAUDE.md, so project rules come from README/SPEC/docs only.
- Web: AeroSpace (README, guide, `Workspace.swift`, `MacApp.swift` via GitHub), yabai (README, wiki), MacTile release notes, Chain landing page, OmniWM search results, Apple forums and Electron docs (via search snippets).
- Apple developer doc pages for `SCScreenshotManager` and `CGDisplayRegisterReconfigurationCallback` returned 404 or title-only to WebFetch. Statements about them below come from general knowledge and are marked as such.
- Not verified: anything about SkyLight/SLS calls on macOS 26, real latency numbers, Chain internals (vendor claims only), and the exact behavior of MultitouchSupport on Tahoe. No source found gives measured timings for AX writes.

## 1. What Ribbon already does (baseline)

Most of the "best-practice" AX tricks are already in the code:

- `AXWindow.swift`: `_AXUIElementGetWindow` via `@_silgen_name` for window ids (the one private API AeroSpace also uses).
- `AXWindow.swift` `setFrame`: size, then position, then size. Same order as AeroSpace `MacApp.swift` ("Set size and then the position. The order is important").
- `AXWindow.swift` `withoutEnhancedUI(pid:)`: sets `AXEnhancedUserInterface` false around writes, timeout 0.25 s. Same idea as AeroSpace's `disableAnimations` and MacTile v1.5.0.
- `AXUIElementSetMessagingTimeout` on app and window elements, 0.1 to 0.25 s. `SwipeWriter` sets it per window once.
- `SwipeWriter.swift`: CADisplayLink on the managed screen, per-target throttle, x-only writes during the swipe, no enhanced-UI toggle per frame.
- `Restore.swift`: first-seen frames mirrored to `~/Library/Application Support/Ribbon/originals.json` (debounced). Inherited after a non-clean exit. SIGTERM/SIGINT handled.
- `Session.swift`: layout snapshot restored on relaunch (SPEC section "Session restore").
- Wake: `Controller.swift:164` observes `NSWorkspace.didWakeNotification`. Screens: `Screens.swift:53` observes `didChangeScreenParametersNotification`.
- Tracker: per-app observers, `NSWorkspace` launch/terminate/activate/hide/unhide notifications.

Gaps I found (details in sections 3 and 5):

- No AX write queue per app. AX calls run on the main thread (`WindowTracker` uses 0.1 s timeouts "on the main thread"). AeroSpace runs one `Thread` + `CFRunLoop` per app. `docs/ax-notes.md` says "AX calls off the main thread (serial queue)", which does not match the code I read. Verify.
- Parked windows (other desktops, floating parked) are off-screen. A crash (SIGKILL, abort, or a Swift trap) leaves them parked until the next launch. Restore only runs at launch.
- No periodic reconciliation of live AX windows against `elements`.
- No detection of AX-unresponsive apps beyond timeouts.
- No Screen Recording permission today. Section 4 explains why the swipe-snapshot plan changes that.

## 2. How the best tools move windows

### 2a. AeroSpace (Swift, no SIP)

- Claims: "Doesn't require disabling SIP", "will never require you to disable SIP", and only one private API, `_AXUIElementGetWindow`. Source: https://github.com/nikitabobko/AeroSpace (README).
- Virtual workspaces: inactive windows are moved "outside the visible area of the screen, in the bottom right or left corner". Macos leaves a 1 px sliver. Each monitor needs free space in a bottom corner. On quit or detected crash, windows are put back. Source: https://nikitabobko.github.io/AeroSpace/guide (section 4).
- Threading: one `Thread` per app (`AxAppThread <name>`), `CFRunLoopRun()`, cancellable jobs per window (`setFrameJobs`), a non-cancellable job plus semaphore for termination writes. Source: https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/MacApp.swift (fetched). No `AXUIElementSetMessagingTimeout` in that file, and no retry logic. The README lists "thread-per-application to circumvent macOS blocking AX API" as a 1.0 item, so its status is unclear.
- Enhanced UI: `disableAnimations` flips `AXEnhancedUserInterface` off during the write and restores it in `defer`. The code cites yabai and Rectangle as the origin.
- AX notifications: subscribes per app to window created and focused-window-changed, per window to destroyed, (de)miniaturized, moved, resized. `refreshAndGetAliveWindowIds` re-reads the windows list and cancels jobs for dead windows (a periodic reconciliation).
- Known issues: windows "may randomly jump to the focused workspace" (#1216). Refactor #1215 (immutable tree) is aimed at it. Source: AeroSpace guide, "status" section.
- No animations by design ("visual effects like animations ... are non-goals"). Workspace switches are instant.

Impact on Ribbon: the thread-per-app model and the reconciliation loop are the two most relevant pieces. Hidden-corner parking is the same mechanism Ribbon already uses for other desktops.

### 2b. yabai (C, partial SIP-off for some features)

- README: "System Integrity Protection can be (partially) disabled for yabai to inject a scripting addition into Dock.app". The scripting addition gives control of the window server. Features that need it are not listed in the README. Source: https://github.com/asmvik/yabai
- Wiki: the SA is loaded with `sudo yabai --load-sa` via a sudoers entry pinned to the binary's SHA-256, which must be updated after each upgrade. Reloaded on `dock_did_restart`. Source: https://github.com/koekeishiya/yabai/wiki/Installing-yabai-(latest-release)
- Window animations: README says yabai needs Screen Recording permission "if and only if you want to enable window animations". So yabai's animation path does involve capture. Source: README.
- Supports Tahoe 26.0+ (Intel and Apple Silicon, per README table).
- Scope of what I did NOT verify: the exact SLS calls used for moves and animations on macOS 26, and whether any move works without the SA. My search found no SLSMoveWindow documentation.

### 2c. Other tools

- MacTile v1.5.0 (11 Mar, year not shown): "Temporarily disables AXEnhancedUserInterface during frame changes to suppress macOS window animations", credited to AeroSpace; also removed synchronous delays and changed the write order. The speedup comes from several changes together, so the flag alone is not proven. Source: https://github.com/yashas-salankimatt/MacTile/releases
- Chain (chainyourmac.com, vendor claims only): Rust engine as a small background process that the app restarts if it stops; native SwiftUI; "a vsync-locked spring that starts the instant you press the key"; Accessibility as the only permission; no SIP changes; macOS 13+ Apple silicon only. Source: https://chainyourmac.com. This is the closest architecture match to Ribbon (Rust core plus Swift app). Its claims are not independently checked.
- OmniWM (BarutSRB/OmniWM): Niri mode (scrolling columns) and Dwindle mode, per-workspace layout switch; trackpad gestures opt-in since 0.7.0; three or four finger column scroll since 0.7.6. Source: https://github.com/BarutSRB/OmniWM (via search snippets, not fetched). Nothing about its AX internals was found.
- Electron apps: AX attribute `AXManualAccessibility` is the documented way to enable accessibility in Electron without setting `AXEnhancedUserInterface`. Source: https://www.electronjs.org/docs/tutorial/accessibility . Apple forums thread reports `AXEnhancedUserInterface` = true (set by VoiceOver) breaks window positioning in tiling tools. Source: https://developer.apple.com/forums/thread/659755 (from search snippet).
- Not researched in depth: Amethyst, Rectangle, Loop, PaperWM.spoon, Hammerspoon, a Niri macOS port. Rectangle and Magnet are mentioned as AX-based in a secondary source only.

### 2d. Tricks summary (with status in Ribbon)

| Trick | Used by | Ribbon | Verdict |
|---|---|---|---|
| `_AXUIElementGetWindow` | AeroSpace, yabai, Ribbon | yes | keep |
| size, pos, size write order | AeroSpace, Ribbon | yes | keep |
| toggle `AXEnhancedUserInterface` around writes | AeroSpace, MacTile, Rectangle(?), Ribbon | yes | keep; see 3a for Electron |
| `AXUIElementSetMessagingTimeout` | Ribbon; AeroSpace does not | yes | keep; add failure counters |
| per-app AX thread/queue | AeroSpace | no | TRY (section 3b) |
| batching or skipping unchanged frames | Ribbon (`SwipeWriter` throttle) | partial | keep |
| `AXManualAccessibility` for Electron | Electron docs | no | TRY |
| SLS/CGS move or transform, SA injection | yabai | no | SKIP |
| hidden-corner parking | AeroSpace | yes (off-screen) | keep; align with corner rule |

Unverified: how much the enhanced-UI toggle actually speeds writes in Ribbon's target apps. Measure on a dummy window and on one Electron app (Slack, VS Code) before and after. Use the existing `qa/` harness if it can time writes.

## 3. Findings with recommendations

Impact: high/med/low on smoothness (S) and stability (St). Effort is my estimate. Risk covers private API, App Store, SIP, and OS-update breakage.

### 3a. AXManualAccessibility for Electron apps (S: med, St: low)

- What: set `AXManualAccessibility` = true on Electron app elements instead of toggling `AXEnhancedUserInterface`. Keep the toggle for native apps.
- Evidence: Electron docs (above) and the Apple forums thread (above). Unverified whether it changes write latency for Ribbon.
- Effort: small. Risk: public AX attribute, no SIP. Note that setting it turns on Electron's accessibility tree for that app, which costs CPU in the app.
- Recommendation: TRY. Measure first.

### 3b. Per-app AX serial queue or thread (S: med, St: high)

- What: one `Thread`/`CFRunLoop` or serial `DispatchQueue` per pid. All AX reads and writes for that app go there. A hung app then stalls only its own queue, not the main thread or the swipe.
- Evidence: AeroSpace `MacApp.swift` (above). Ribbon's `WindowTracker` runs AX reads on the main thread with 0.1 s timeouts, which can stack up when several apps hang.
- Effort: medium (touches `WindowTracker` and `FrameApplier`). Risk: none by API; concurrency bugs possible. Swift 6 `actor` per app is a fit.
- Recommendation: TRY. This is the best stability lever I found that is pure public API.

### 3c. Crash-time un-parking via a watchdog helper (St: high, S: none)

- What: a tiny helper (LaunchAgent or a second process started by Ribbon) that watches the Ribbon pid (kqueue `EVFILT_PROC` NOTE_EXIT, or a heartbeat file). When Ribbon disappears without a clean-exit marker, the helper reads `originals.json` and moves windows back via AX. Signal handlers should not call AX (not async-signal-safe), which is why the helper is a separate process.
- Evidence: AeroSpace guide says it restores windows "on quit, or when AeroSpace detects it is about to crash". Chain says its engine is restarted if it stops. Ribbon's own `originals.json` design supports this but only acts at next launch.
- Gap today: Ribbon's own README says "Quitting puts every window back, even after a crash" only at next launch. A crash now leaves other-desktop windows off-screen until the user relaunches.
- Effort: medium. Risk: a LaunchAgent is a new background item; the App Store route would need care (not an issue for direct distribution).
- Recommendation: ADOPT (a simple version: a helper or launchd `KeepAlive` that relaunches Ribbon, which then restores via `Restore`. Relaunch is cheaper than a full un-park helper and covers the same crash case.)

### 3d. Periodic AX reconciliation (St: med, S: low)

- What: every 1 to 2 s (off the swipe path), re-read `kAXWindowsAttribute` for each live app and reconcile with `elements`. Drop dead windows, register new ones. Cheap insurance against lost AX notifications (AeroSpace `refreshAndGetAliveWindowIds`).
- Evidence: AeroSpace `MacApp.swift`. Also AeroSpace issue #1216 (windows jump) shows the cost of tracking drift.
- Effort: small. Risk: extra AX load; cap it when an app is unresponsive.
- Recommendation: ADOPT.

### 3e. AX-unresponsive app detection (St: med)

- What: count consecutive AX failures per pid (`kAXErrorCannotComplete`, timeouts). After N failures, quarantine that app's windows (float them, stop writing) and show a HUD note. Retry with backoff.
- Evidence: timeouts are already set (Ribbon) but nothing reacts to them. AeroSpace has no retry logic (fetched source), so this is not a standard feature anywhere I looked.
- Effort: small to medium. Risk: none.
- Recommendation: TRY.

### 3f. Sleep, wake and displays (St: med)

- Current: `didWakeNotification` and `didChangeScreenParametersNotification` are used. Good.
- Suggested: also observe `willSleepNotification` and `screensDidSleepNotification` to pause writes, and `activeSpaceDidChangeNotification` (public, NSWorkspace) for space changes. Consider `CGDisplayRegisterReconfigurationCallback` (general knowledge: it fires in begin and end phases, with flags; work should be deferred to after the end phase; docs page not retrieved). Ribbon's `didChangeScreenParameters` already covers the end result, so this is low gain.
- Effort: small. Risk: none (public APIs).
- Recommendation: ADOPT the sleep/space observers. TRY `CGDisplayRegisterReconfigurationCallback` only if display-change bugs show up.

### 3g. SkyLight/CGS space notifications (St: low for Ribbon)

- SkyLight (`CGSRegisterNotifyProc`, SLS space APIs) is private. AeroSpace's guide notes Apple has no public Spaces API and that the public APIs are not Spaces-aware. Ribbon uses its own desktops, so it does not need Spaces.
- Recommendation: SKIP.

### 3h. Private SLS/CGS move, transform or animation (S: high if it worked, St: negative)

- What: `SLSMoveWindow`, `SLSSetWindowTransform`, and similar, which yabai uses through its scripting addition.
- Evidence: yabai README and wiki (SA needs SIP partially off and a sudoers entry). My search found no source confirming SLS transform calls work on macOS 26 without SA. Unverified.
- Recommendation: SKIP. It breaks the "one permission, no private APIs beyond two" promise in SPEC, and it has no public path.

### 3i. macOS native tiling (macOS 15/26) (S: n/a, St: n/a)

- Apple's Sequoia tiling is user-facing (drag to edge or corner, Option-drag, margins). Source (secondary): https://macmost.com/window-tiling-in-macos-sequoia.html and https://www.computerworld.com/article/3550352/how-to-use-window-tiling-with-macos-sequoia.html
- I found no public developer API for third-party apps to join or query native tiling. Not verified against Apple docs.
- Effort to integrate: n/a. Recommendation: SKIP integration. Consider a short onboarding note that native drag-to-edge tiling can fight Ribbon (SPEC already has a conflict check for other WMs; check whether it covers this).

### 3j. Animations (S: med)

- Core Animation vs CADisplayLink: Ribbon uses CADisplayLink on the managed screen for AX glide. Chain describes a vsync-locked spring. This is the right pattern. Impact of switching to CVDisplayLink or Metal: low, since the limit is AX write latency, not frame timing.
- AX glide (`Restore`, `FrameApplier`): the window moves in discrete AX writes, so frame smoothness is limited by how fast each app accepts writes. Enhanced-UI toggle (section 2d) is the lever here.
- Recommendation: KEEP. TRY a spring curve on CADisplayLink if the current easing feels off.

### 3k. Swipe snapshot overlay: Core Animation vs Metal (S: med)

- What: during a swipe, slide window images in a CALayer overlay, then commit real AX moves on release.
- Core Animation with `CALayer.contents` set to IOSurface-backed images is enough for a few dozen layers at 60 Hz. Metal is only worth it for many large, animated layers or custom compositing. General knowledge; not measured.
- Recommendation: ADOPT Core Animation for the overlay. SKIP Metal unless profiling shows CA composition as the bottleneck.

### 3l. ScreenCaptureKit: SCStream (live) vs SCScreenshotManager (still) (S: med, St: med)

- Important: capturing other apps' windows needs Screen Recording permission (TCC). SPEC promises "one process, one permission (Accessibility)". This change breaks that promise. Decide this explicitly before building. Mention this in onboarding copy and in the README.
- SCStream: continuous frames, GPU and CPU cost per window, a stream per display or per window. Good for live thumbnails, costly if many windows.
- SCScreenshotManager: one `CGImage` per call; available from macOS 14 (general knowledge, docs page not retrieved). Cheaper for a snapshot at gesture start.
- Recommendation: TRY SCScreenshotManager for a one-shot capture of the visible windows at swipe start (low overhead, no stream lifecycle). SKIP SCStream unless you need live frames during the swipe. Measure capture time per window on the target Mac before committing to the design.

### 3m. Trackpad input (S: med, St: med)

- MultitouchSupport: still the only route to raw 3/4-finger contacts without SIP changes, based on the community wrappers and Apple forum threads I found. Caveats: the framework path moved inside `Versions/` for some releases (Apple forums thread 653972; Ribbon dlopens the unversioned path, which works via the symlink on current macOS, to be verified on Tahoe). The struct layout is undocumented and was reverse-engineered. No Tahoe-specific source found.
- NSEvent scroll phases: good for two-finger scroll in a view you own. Not a global 3-finger source.
- NSPanGestureRecognizer: only for your own views; no global input. Not useful here.
- IOHID: raw HID reports, possibly usable, but needs Input Monitoring and is a larger, unverified path. Not researched in depth.
- Latency: no reliable published comparison found. Measure with timestamps from the MT callback to first AX write, on Tahoe.
- Recommendation: KEEP MultitouchSupport. ADD: a runtime self-check (if no frames arrive within N s after start, disable the feature and say so, which is partly already the case via "Not available on this Mac") and a symbol-presence check on each OS update. TRY IOHID only if MT breaks on Tahoe.

### 3n. Language and runtime (S: low, St: low)

- Rust core: the Swift app's cost is AX IPC to other apps, not Swift execution. Moving more logic to Rust would not reduce that. SKIP.
- Swift 6 strict concurrency: a real benefit for correctness (isolating AX per app, see 3b). TRY with the AX queue work, not as a standalone project.
- UI toolkit: SwiftUI and AppKit are the right tools (Liquid Glass is SwiftUI/AppKit). SKIP changing toolkit.

## 4. Things that could go wrong

- Screen Recording permission (3l) may hurt adoption more than any smoothness win. Decide first.
- Electron apps: enhanced-UI toggle and `AXManualAccessibility` both change app behavior; test with Slack, VS Code and Chrome.
- Any private call (`_AXUIElementGetWindow`, MultitouchSupport) can break on an OS update. Keep the feature-off path working.
- Hidden corner parking (AeroSpace style) leaves a 1 px sliver. Ribbon's off-screen parking may have the same issue; check on a multi-display setup.

## 5. Ranked top-5 next steps for Ribbon

1. **Decide the Screen Recording question (3l) before building the snapshot swipe.** Write the trade-off into SPEC and onboarding. Then prototype SCScreenshotManager timing on Tahoe (one-shot per window at swipe start).
2. **Per-app AX queue (3b)**, so a hung app cannot stall the main thread or the swipe. Pair with AX failure counters and quarantine (3e).
3. **Crash recovery (3c)**: relaunch-on-crash via launchd KeepAlive (or a small watchdog helper) so `Restore` un-parks windows without a manual relaunch. Test by killing Ribbon with SIGKILL while a window is parked on another desktop.
4. **Measure the enhanced-UI toggle and AXManualAccessibility (2d, 3a)** on a dummy window and one Electron app. Keep whichever is faster; document the numbers in `docs/ax-notes.md`.
5. **Periodic AX reconciliation (3d) plus sleep/space observers (3f)**, both small and public-API only.

Lower priority: Core Animation overlay (3k, ADOPT), MultitouchSupport self-check (3m), spring curve (3j).

## 6. Recommendation index

| Item | Verdict |
|---|---|
| Keep `_AXUIElementGetWindow`, size/pos/size, enhanced-UI toggle, timeouts | KEEP (already in code) |
| Per-app AX queue or thread (3b) | TRY |
| AXManualAccessibility for Electron (3a) | TRY |
| AX failure counters and quarantine (3e) | TRY |
| Crash recovery via relaunch or watchdog (3c) | ADOPT |
| Periodic AX reconciliation (3d) | ADOPT |
| Sleep/space observers (3f) | ADOPT |
| CGDisplayRegisterReconfigurationCallback (3f) | TRY if needed |
| SkyLight/CGS space notifications (3g) | SKIP |
| SLS move/transform/animation, SA injection (3h) | SKIP |
| Native macOS tiling integration (3i) | SKIP (add onboarding note) |
| Core Animation overlay (3k) | ADOPT |
| Metal overlay | SKIP unless profiling says so |
| SCScreenshotManager one-shot (3l) | TRY (after permission decision) |
| SCStream live capture (3l) | SKIP for now |
| MultitouchSupport with self-check (3m) | KEEP |
| IOHID trackpad path (3m) | SKIP unless MT breaks |
| Rust/Swift language change, UI toolkit change (3n) | SKIP |
| Swift 6 concurrency (3n) | TRY, with 3b |

## 7. Sources

- AeroSpace README: https://github.com/nikitabobko/AeroSpace
- AeroSpace guide: https://nikitabobko.github.io/AeroSpace/guide
- AeroSpace MacApp.swift: https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/MacApp.swift
- AeroSpace Workspace.swift: https://github.com/nikitabobko/AeroSpace/blob/main/Sources/AppBundle/tree/Workspace.swift
- yabai README: https://github.com/asmvik/yabai
- yabai wiki, install and SA: https://github.com/koekeishiya/yabai/wiki/Installing-yabai-(latest-release)
- MacTile releases: https://github.com/yashas-salankimatt/MacTile/releases
- Chain: https://chainyourmac.com
- OmniWM: https://github.com/BarutSRB/OmniWM
- Electron accessibility: https://www.electronjs.org/docs/tutorial/accessibility
- Apple forums, AXEnhancedUserInterface and tiling: https://developer.apple.com/forums/thread/659755
- Apple forums, MultitouchSupport path on Big Sur: https://developer.apple.com/forums/thread/653972
- M5MultitouchSupport: https://cocoapods.org/pods/M5MultitouchSupport
- Sequoia tiling (secondary): https://macmost.com/window-tiling-in-macos-sequoia.html
- Apple docs, not retrieved (404 or title only): SCScreenshotManager, CGDisplayRegisterReconfigurationCallback

Repo files read: `~/projects/ribbon/README.md`, `SPEC.md`, `docs/ax-notes.md`, `app/Sources/Ribbon/Platform/AXWindow.swift`, `Restore.swift`, `SwipeWriter.swift` (grep), `WindowTracker.swift` (grep), `App/Controller.swift:164`, `Platform/Screens.swift:53`.
