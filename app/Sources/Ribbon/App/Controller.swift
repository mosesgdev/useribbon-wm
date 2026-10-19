import AppKit
import ApplicationServices

/// Glue: tracker events -> engine -> plans -> frame applier + HUD. Everything here runs on the main actor.
@MainActor
final class Controller {
    var settings = RibbonSettings.load()
    /// One ribbon (engine with its nine desktops) per display, keyed by display UUID.
    final class DisplayState {
        var info: DisplayInfo
        let engine: Engine
        var desktop = 1, lastDesktop = 1
        var parkedFloats: Set<UInt32> = []     // floating windows parked because their desktop is inactive
        init(info: DisplayInfo, engine: Engine) { self.info = info; self.engine = engine }
    }
    var states: [String: DisplayState] = [:]
    var focusedUUID = ""
    var home: [UInt32: String] = [:]               // window -> display holding it (kept after removal: a returning window goes back)
    private var origin: [UInt32: String] = [:]             // window -> display it was taken from by a disconnect
    private var screenSeq = 0
    private let warp = MouseWarp()
    var focusedState: DisplayState { states[focusedUUID] ?? states.values.first! }
    private var engine: Engine { focusedState.engine }
    private var display: (id: UInt32, frame: CGRect) { (focusedState.info.id, focusedState.info.visible) }
    let tracker = WindowTracker()
    let applier = FrameApplier()
    private let stab = StabilityState()
    private let restore = Restore()
    private let hud = HUDController()
    let shortcutStore = ShortcutStore()
    private let bar: CommandBarController
    private let shortcuts = ShortcutsPanel()
    private let hotkeys = HotkeyCenter()
    private let hold = ModifierHold()
    private let menu = MenuBar()
    private let updater = Updater()
    let ring = FocusRing()
    private let tabs = TabBarController()               // tab bars of tabbed columns
    private let appIcons = AppIconCache()               // app icons by process: the tab bars and the strip never ask the system per frame
    let dim = DimOverlay()                      // "Other windows: Dim / Blur" and Focus mode
    let pinFeature = PinState()                      // what the pinned column keeps here (empty in the free edition)
    private var ringPhase = RingVisibility()            // ring + cutout hide while a window is dragged
    private var focusSession = FocusSession.follow      // Focus mode: a session choice, never saved (off at launch)
    private let dragger = WindowDragger()               // title-bar drag to reorder
    private let trackpad = TrackpadScroller.shared
    private let onboarding = OnboardingController()
    private let planLog = PlanLog()
    private let session = SessionStore()
    private var pendingSession: SessionFile?
    private let conflicts = ConflictMonitor()
    private let smoothCard = SmoothSwipeCard()
    private let spacesCard = SpacesCard()
    private var fifo: CommandFIFO?
    var paused = false
    var started = false
    var focusedByEngine: UInt32?
    private var reconcileSeq = 0
    private var lastReconciled: [UInt32: Reconcile.Attempt] = [:]
    private var refusalTimes: [UInt32: [Date]] = [:]
    private var recentEngineFocus: [UInt32: Date] = [:]   // ids the engine focused within the last 0.5s
    private var plannedOnScreen: [UInt32: Bool] = [:]     // last planned on_screen per window
    private var resizeSeq: [UInt32: Int] = [:]     // per-window quiet timer for user resize drags
    private var moveSeq: [UInt32: Int] = [:]       // per-window debounce for user drags
    private var focusSeq = 0                       // newest OS focus event wins the debounce
    private var focusOrder: [UInt32] = []             // most recently focused first (command bar ordering)
    private var floatHome: [UInt32: CGRect] = [:]     // where those floating windows were before parking
    private var floatKnown: [UInt32: Bool] = [:]      // floating or tiled, as the core last laid it out: kept when a window is added again
    private var floatFrames: [UInt32: CGRect] = [:]   // where a window last floated, for the next time it leaves the ribbon
    private var floatRules = FloatRules.load()       // the "Always float" list the open windows were last matched against
    private var pidOf: [UInt32: pid_t] = [:]
    private var wantFocus: UInt32?                    // window picked in the command bar from the shelf: focused once it is back
    private var removedAt: [pid_t: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    var ringFocus: UInt32?                        // window the focus ring frames (engine/OS focus)
    private var focusAskedAt = 0.0                        // when a plan last asked for a window's focus
    var plannedFrame: [UInt32: CGRect] = [:]      // last planned frame per tiled window
    private var plannedLX: [UInt32: Double] = [:]         // ... and its logical x (the ribbon's own coordinate, parking ignored)
    private var liveUntil: [UInt32: Date] = [:]           // ring follows the real frame while the user drags/resizes
    private var liveResize = false                        // a user resize is being followed: ring, dim and tab bars move with it, nothing eases
    private var dragWarm: (uuid: String, plan: Plan)?     // a ribbon's plan, read when the mouse went down on a title bar
    var scrolling = false                         // a three-finger scroll is in progress
    private var lastScrollHUD = Date.distantPast
    /// Window px per pad width of finger travel, as a multiple of the screen width: 1 = the full pad moves one screen.
    private static let scrollGain = 1.0
    private let pacer = FramePacer()
    private var predictor = SwipePredictor()
    private let predictLayers = ProcessInfo.processInfo.environment["RIBBON_NO_PREDICT"] == nil
    private var swipeDx = 0.0                             // viewport px not yet handed to the core (summed between display frames)
    private var swipeMap: RibbonMap?                      // newest map of the swipe, shown at ~30 Hz
    private var lastSwipeUI = 0.0
    // Snapshot swipe (needs Screen Recording): the overlay slides images while the real windows stay put until release.
    let snapshots = SnapshotStore()
    private let overlay = SwipeOverlay()
    var commit = CommitMachine()
    private var gotFirstDx = false
    var snapMode = false                          // the current/last swipe runs on the overlay (else direct mode)
    private var snapSeq = 0
    private var statsFinger = 0.0, statsRef: (id: UInt32, x0: Double)?   // QA: finger-derived position check
    // Keyboard navigation through the overlay (see `overlayNav`).
    private var tiledSet = TiledSet()                      // the windows each display's ribbon lays out, to notice one opening, closing, floating or tiling
    private var navLayouts: [String: NavLayout] = [:]     // per display: its tiles as of the last plan applied
    private var nav: NavMove?                             // the keyboard move on the overlay, if one is on screen
    private let overlayNavOn = ProcessInfo.processInfo.environment["RIBBON_DIRECT_NAV"] == nil   // env: QA can force the AX glide
    private var navWrites: (targets: [UInt32: SwipeWriter.Target], gen: Int)?     // real-window writes of a keyboard move, not yet sent
    private var navWriteTimer = false
    private static let navWriteDelay = 0.03                // a couple of frames: the overlay is on screen before the windows move
    private var lastInputAt = 0.0                         // last keyboard plan or touch: captures wait until it is quiet
    // Pictures: when the next sweep fires, the focus pair whose pictures are taken while the overlay is up, the live follower.
    private var sweep = SweepClock()
    private var pairSeq = 0
    private var freshening = Set<UInt32>()                // tiles that take a new picture while the overlay is up (the focus pair)
    private var pendingFresh = Set<UInt32>()              // ... whose picture arrived while their glide still ran: swapped in at the landing
    private var liveRunning = false
    private static let focusPairDelay = 0.12              // the new focus has been applied and painted by then; the overlay is still up

    /// A keyboard move that the overlay animates: what travels with the tiles (tab bars) and how the layers are kept afterwards.
    private struct NavMove {
        var uuid: String
        var bars: [TabBar]
        var visible: CGRect
        var signature: String
        var lead: UInt32?
    }

    init() {
        bar = CommandBarController(store: shortcutStore)
        rebuildStates()
    }

    private static let fallbackDisplay = DisplayInfo(uuid: "fallback", id: 1, name: "Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                     visible: CGRect(x: 0, y: 0, width: 1440, height: 900))

    private func makeState(_ info: DisplayInfo) -> DisplayState {
        let e = Engine(config: liveEngineConfig)
        e.onPlanJSON = { [planLog] in planLog.append($0) }
        _ = e.handle(.display(id: info.id, frame: info.visible))
        return DisplayState(info: info, engine: e)
    }

    /// Fresh engines for every connected display (nothing carried over).
    private func rebuildStates() {
        let infos = Screens.all().isEmpty ? [Self.fallbackDisplay] : Screens.all()
        states = Dictionary(uniqueKeysWithValues: infos.map { ($0.uuid, makeState($0)) })
        if states[focusedUUID] == nil { focusedUUID = infos[0].uuid }
    }

    private var infos: [DisplayInfo] { states.values.map(\.info).sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) } }
    private var primaryUUID: String { Screens.all().first?.uuid ?? focusedUUID }

    /// The display under the pointer (nearest one when it sits in a gap).
    private func mouseState() -> DisplayState {
        DisplayGeometry.nearest(to: Screens.mouseAX(), in: infos).flatMap { states[$0.uuid] } ?? focusedState
    }

    func state(of id: UInt32) -> DisplayState? { home[id].flatMap { states[$0] } }

    private func otherInfos(than st: DisplayState) -> [CGRect] { states.values.filter { $0 !== st }.map(\.info.frame) }

    func setFocusedDisplay(_ uuid: String) {
        guard states[uuid] != nil, uuid != focusedUUID else { return }
        focusedUUID = uuid
        menu.setDesktop(focusedState.desktop)
    }

    func launch() {
        Screens.focusedProvider = { [weak self] in self.flatMap { Screens.screen(uuid: $0.focusedUUID) } }
        pendingSession = session.load()
        session.provider = { [weak self] in self?.sessionSnapshot() }
        conflicts.onPending = { [weak self] c in self?.menu.setClash(c.map(ConflictCopy.title)) }
        menu.onConflict = { [weak self] in self?.conflicts.reshow() }
        bar.contextProvider = { [weak self] in self?.contextItems() ?? [] }
        bar.targetProvider = { [weak self] in self?.barTarget() }
        hud.model.icon = { [weak self] id in
            self?.tracker.windows[id].flatMap { self?.appIcons.icon(pid: $0.pid) }
        }
        tabs.icon = { [weak self] id in self?.tracker.windows[id].flatMap { self?.appIcons.icon(pid: $0.pid) } }
        tabs.onSelect = { [weak self] id in self?.selectTab(id) }
        tabs.onCycle = { [weak self] id, dir in
            guard let self, let u = self.home[id] else { return }
            self.selectTab(id)
            self.apply(self.states[u]!.engine.handle(.command(dir > 0 ? "next_tab" : "prev_tab")), on: u)
        }
        tabs.onAction = { [weak self] in self?.tabAction($0) }
        // Only Ribbon writing this very window holds a drag back; other windows gliding (a key pressed a moment ago) do not.
        dragger.canStart = { [weak self] id in
            guard let self else { return false }
            return !self.paused && self.started && !self.scrolling && !self.commit.overlayUp && !self.applier.isWriting(id) && self.plannedOnScreen[id] == true && self.tracker.windows[id]?.floating != true
        }
        dragger.liveFrame = { [weak self] id in self?.tracker.liveBounds(id) }
        dragger.warm = { [weak self] p in self?.warmDragLayout(at: p) }
        dragger.plannedFrame = { [weak self] id in self?.plannedFrame[id] }
        dragger.layoutFor = { [weak self] id in self?.dragLayout(for: id) }
        dragger.onEnd = { [weak self] id, outcome in self?.dragEnded(id, outcome) }
        menu.onTogglePause = { [weak self] in self?.togglePause() }
        hold.modifier = settings.modifier
        hold.isEnabled = { [weak self] in guard let self else { return false }; return self.settings.holdToShow && self.started && !self.paused && !self.bar.isOpen && !self.shortcuts.isOpen }
        hud.isSuppressed = { [weak self] in self?.bar.isOpen == true || self?.shortcuts.isOpen == true }
        hud.setSize(settings.stripSize)
        hold.onShow = { [weak self] in
            guard let self else { return }
            self.hud.hold(map: self.engine.handle(.query).map, focus: self.focusedByEngine)
        }
        hold.onHide = { [weak self] in self?.hud.release() }
        hold.start()
        menu.onShowMap = { [weak self] in self?.showMap() }
        hud.onCommands = { [weak self] cmds in
            guard let self, self.started, !self.paused else { return }
            for c in cmds { self.send(.command(c)) }
        }
        // The pill's hints name the keys in force, recorded overrides included; "" (no hint) when cleared.
        hud.keyText = { [weak self] cmd in
            guard let self, let hk = Hotkeys.table.first(where: { $0.action == .command(cmd) }) else { return HUDController.presetKey(cmd) }
            return self.shortcutStore.keys(for: hk).joined()
        }
        menu.onShortcuts = { [weak self] in self?.showShortcuts() }
        menu.onToggleFocus = { [weak self] in if self?.started == true, self?.paused == false { self?.toggleFocusMode() } }
        menu.onSettings = { SettingsWindow.show() }
        menu.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
        updater.onPending = { [weak self] on in self?.menu.setUpdatePending(on) }
        menu.setUpdatesAvailable(updater.start())
        menu.onQuit = { [weak self] in self?.quit() }
        hotkeys.onAction = { [weak self] in self?.perform($0) }
        hotkeys.onReregistered = { [weak self] in guard let self else { return }; self.menu.setShortcutConflicts(self.hotkeys.failures) }
        shortcutStore.onChange = { [weak self] in self?.registerHotkeys() }
        shortcutStore.suspendHotkeys = { [weak self] in self?.hotkeys.suspend() }
        shortcutStore.resumeHotkeys = { [weak self] in guard let self else { return }; self.hotkeys.resume(); self.menu.setShortcutConflicts(self.hotkeys.failures) }
        registerHotkeys()
        applier.onRefused = { [weak self] id, frame in
            MainActor.assumeIsolated { self?.send(.windowRefused(id, frame)) }
        }
        bar.windowsProvider = { [weak self] in self?.windowItems() ?? [] }
        bar.desktopsProvider = { [weak self] in self?.desktopItems() ?? [] }
        bar.onAction = { [weak self] in self?.run($0) }
        restore.installSignalHandlers { [weak self] in self?.quit() }
        startStabilityWatch()
        tracker.onEvent = { [weak self] in self?.trackerEvent($0) }
        tracker.placedFrame = { [weak self] id in self?.plannedFrame[id] }
        observers.append(Screens.observe { [weak self] in self?.screenChanged() })
        wirePin()
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        pacer.onTick = { [weak self] now in self?.swipeTick(now) }
        applier.swipe.onSettled = { [weak self] in MainActor.assumeIsolated { SwipeStats.shared?.overlayHidden(); self?.qaFinalError(); self?.scheduleReconcile(); self?.refreshRing(animated: false) } }
        trackpad.onTouch = { [weak self] in MainActor.assumeIsolated { self?.touchedDown() } }
        trackpad.onBegin = { [weak self] t in MainActor.assumeIsolated { self?.swipeBegan(contactTime: t) } }
        trackpad.onScroll = { [weak self] d in MainActor.assumeIsolated { self?.scrolled(d) } }
        snapshots.onImage = { [weak self] id, img in self?.pictureArrived(id, img) }
        overlay.floaterSource = { [weak self] in self?.floaterTiles() ?? [] }
        snapshots.onBackdrop = { [weak self] img in
            guard let self else { return }
            self.refreshCurtain(animated: false)      // a fresh wallpaper slice
            if self.overlay.isUp { if !self.scrolling { self.overlay.setBackdrop(img, soft: self.snapshots.softBackdrop) } }      // a texture swap mid-swipe would hitch; the store keeps it for the next one
            else if !self.scrolling, !self.commit.overlayUp, let sc = Screens.screen(uuid: self.focusedUUID) { self.overlay.warm(backdrop: img, soft: self.snapshots.softBackdrop, on: sc) }
        }
        trackpad.onEnd = { [weak self] v in MainActor.assumeIsolated { self?.scrollEnded(v) } }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRing() }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let pid { self?.appIcons.forget(pid: pid) } }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackpad.restart() }
        })
        fifo = CommandFIFO { [weak self] in self?.qaLine($0) }

        if AXIsProcessTrusted() { begin() }
        else {
            onboarding.show(modifier: settings.modifier) { [weak self] in
                LoginItem.enableOnce()
                self?.begin()
            }
        }
    }

    // MARK: lifecycle

    private func registerHotkeys() {
        hotkeys.register(shortcutStore)
        menu.setShortcutConflicts(hotkeys.failures)
        syncFocusMenu()
    }

    private func begin() {
        started = true
        replay(tracker.start())
        updateTrackpad()
        updateWarp()
        conflicts.start()
        // Once: macOS's own three-finger swipe would fire together with Ribbon's. Point at the setting; never change it.
        let d = UserDefaults.standard
        if settings.threeFingerScroll, !d.bool(forKey: SystemSwipe.noticeShownKey), SystemSwipe.conflicts(fingers: settings.swipeFingers) {
            d.set(true, forKey: SystemSwipe.noticeShownKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.hud.show(map: self.engine.handle(.query, log: false).map, focus: self.focusedByEngine,
                              toast: "macOS also uses \(settings.swipeFingers)-finger swipes · fix it in Settings → Input", linger: 4500)
            }
        }
        noteSharedSpaces()
    }

    /// Pointer teleport on/off: the setting, else on when the displays touch only at a corner (or not at all).
    private func updateWarp() {
        let on = settings.mouseWarp ?? DisplayGeometry.warpDefault(infos)
        warp.configure(enabled: on && started && !paused, displays: infos)
    }

    /// One friendly note when there are several displays but macOS shares one Space across them.
    private func noteSharedSpaces() {
        guard states.count > 1, !Screens.separateSpaces, !UserDefaults.standard.bool(forKey: "separateSpacesNoteShown") else { return }
        UserDefaults.standard.set(true, forKey: "separateSpacesNoteShown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.spacesCard.show { Screens.openSpacesSettings() }
        }
    }

    /// Fresh engine state from a list of windows (focused last so it ends up focused). Each window goes to the ribbon of the
    /// display holding its centre; windows off every display go to the display under the pointer.
    private func replay(_ windows: [ManagedWindow]) {
        // A fresh engine knows only desktop 1: bring parked floating windows back first.
        for (id, home) in floatHome { tracker.elements[id]?.setFrame(home) }
        floatHome = [:]
        let focusedBefore = focusedUUID
        rebuildStates()
        if states[focusedBefore] != nil { focusedUUID = focusedBefore }
        home = [:]; origin = [:]
        let mouse = mouseState()
        var last: [String: Plan] = [:]
        for w in windows {
            if let el = tracker.elements[w.id] { restore.remember(w, element: el) }
            var w = w
            if let o = restore.original(w.id) { w.frame = o }
            let st = states[DisplayGeometry.route(w.frame, in: infos, fallback: mouse.info).uuid] ?? mouse
            home[w.id] = st.info.uuid
            last[st.info.uuid] = st.engine.handle(added(w, on: st))
        }
        for w in windows { pidOf[w.id] = w.pid }
        if let saved = pendingSession, !windows.isEmpty {   // first discovery after launch: put each display's ribbon back
            pendingSession = nil
            for u in states.keys.sorted() {
                guard let st = states[u], let slice = saved.slice(for: u, primary: primaryUUID) else { continue }
                let live = windows.filter { home[$0.id] == u }.map { LiveWindow(id: $0.id, pid: $0.pid, key: sessionKey($0), title: $0.title) }
                if let r = slice.restoreEvent(live: live) {
                    _ = st.engine.handle(.restoreSession(r.session))
                    last[u] = st.engine.handle(.command("gather"))
                }
            }
        }
        if let f = windows.last, let h = home[f.id] { focusedUUID = h }
        for (u, plan) in last { apply(plan, on: u, showMap: false) }
        menu.setDesktop(focusedState.desktop)
        // Apps sometimes ignore the first placement; one silent gather re-emits every frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started, !self.paused else { return }
                for u in self.states.keys.sorted() { self.apply(self.states[u]!.engine.handle(.command("gather")), on: u, showMap: false) }
            }
        }
    }

    private func togglePause() {
        if paused {
            paused = false
            started = true
            menu.setPaused(false)
            replay(tracker.start())
            updateTrackpad()
            updateWarp()
        } else {
            paused = true
            updateTrackpad()
            updateWarp()
            ring.hide()
            dim.hide(); tabs.hideAll(); dragger.cancel(); ringPhase.reset()
            hidePinChrome()
            menu.setPaused(true)
            applier.cancelAndWait()
            restore.restoreAll(displays: infos.map(\.frame), fallback: display.frame)
            restore.forgetAll()
            tracker.stop()
            hud.hideNow()
        }
    }

    func quit() {
        session.flush()
        applier.cancelAndWait()
        restore.restoreAll(displays: infos.map(\.frame), fallback: display.frame)
        restore.discardFile()
        NSApp.terminate(nil)
    }

    // MARK: events

    private func trackerEvent(_ e: TrackerEvent) {
        guard !paused else { return }
        switch e {
        case .added(let w, let takesFocus):
            if let el = tracker.elements[w.id] { restore.remember(w, element: el) }
            pidOf[w.id] = w.pid
            snapshots.markBackdropDirty()       // what the backdrop leaves out changes
            // A window coming back (un-minimized, un-hidden, re-listed) returns to its own ribbon; a new one opens on the
            // display under the pointer, wherever the app put it.
            let st = home[w.id].flatMap { states[$0] } ?? mouseState()
            home[w.id] = st.info.uuid
            origin[w.id] = nil
            apply(st.engine.handle(added(w, on: st, takesFocus: takesFocus)), on: st.info.uuid)
            focusPicked()
        case .removed(let id, let reason):
            snapshots.markBackdropDirty()
            if let pid = pidOf.removeValue(forKey: id) { removedAt[pid] = Date() }
            forgetLive(id)
            // Minimize/fullscreen keep the first-seen frame so quitting still restores the real original.
            if reason.forgetsOriginal { restore.forget(id) }
            // A minimized window is shelved by the core (desktop + width), not forgotten.
            send(reason == .minimized ? .windowMinimized(id) : .windowRemoved(id))
            if reason == .terminated || reason == .destroyed { origin[id] = nil }
        case .replaced(let old, let w):
            // A native tab group shows another of its windows: the new one takes over the old one's column (place, width, height,
            // stack or tab group, desktop, focus) and is written in place. The old one lives on as a hidden tab and keeps its display.
            guard let uuid = home[old], let st = states[uuid] else { trackerEvent(.added(w, takesFocus: tracker.takesFocus(w))); return }
            let plan = st.engine.handle(.windowReplaced(old: old, w))
            // The ribbon never knew the old window: the new one is simply new.
            guard plan.map.desktops.contains(where: { $0.windows.contains(w.id) }) else { trackerEvent(.added(w, takesFocus: tracker.takesFocus(w))); return }
            QALog.note("ribbon: native tab switch \(old) -> \(w.id) (\(w.app))")
            // Its add came first and may have gone to another display (the pointer's): that copy goes, and the add's slot and queued write
            // with it. The keyboard stays on the new tab: dropping the copy must not hand it to a neighbour.
            if let prev = home[w.id], prev != uuid, let ps = states[prev] {
                var gone = ps.engine.handle(.windowRemoved(w.id))
                gone.focus = nil
                apply(gone, on: prev)
            }
            applier.drop(w.id)
            resizeSeq[w.id, default: 0] += 1    // its resize since the add was AppKit fitting it to the group: no width to learn
            plannedOnScreen[w.id] = nil; plannedFrame[w.id] = nil; plannedLX[w.id] = nil
            if let el = tracker.elements[w.id] { restore.replace(old, with: w, element: el) }
            pidOf[old] = nil; pidOf[w.id] = w.pid
            home[w.id] = uuid; origin[w.id] = origin.removeValue(forKey: old)
            carryLiveState(from: old, to: w.id)
            apply(plan, on: uuid)
            focusPicked()
            // The core leaves the focus alone when the old tab did not have it. If the new one has the keyboard (another app was in
            // front and opened it, or the user clicked a tab of a group the ribbon is not on), the ribbon follows like for any focus move
            // (the core ignores it when the focus is there already; a column's lead is not its focused row, so that is not asked here).
            if tracker.focusedWindowID() == w.id { osFocused(w.id) }
        case .appHidden(let pid):
            removedAt[pid] = Date()
            for (id, s) in tracker.shelved where s.window.pid == pid && s.hidden { forgetLive(id) }
            for u in states.keys.sorted() { send(.appHidden(pid), on: u) }
        case .appShown(let pid, let front, let takesFocus):
            if takesFocus, let f = front, let h = home[f] { setFocusedDisplay(h) }
            for u in states.keys.sorted() { send(.appShown(pid, front: front.flatMap { home[$0] == u ? $0 : nil }, takeFocus: takesFocus), on: u) }
            focusPicked()
        case .focused(let id):
            snapshots.markDirty(id)
            osFocused(id)
        case .resized(let id, let f):
            // The tracker delivers at most one of these per display frame while a window is resized (the newest frame).
            scheduleReconcile()
            if !applier.isEcho(id: id, frame: f) {
                liveUntil[id] = Date().addingTimeInterval(1)
                guard let st = state(of: id) else { refreshRing(animated: false); return }
                var plan = st.engine.handle(.windowResized(id, f))
                // Never write the window the user is dragging: that would fight the mouse. The others follow it at once, one
                // position write per frame (a glide per event would restart before it got anywhere), and the ring, dim and
                // tab bars follow without easing. Snapshots and the reconcile wait for the quiet after the last event.
                plan.changed.removeAll { $0 == id }
                plan.jump = true
                liveResize = true
                apply(plan, on: st.info.uuid, showMap: false)
                liveResize = false
                settleResize(id, plan: plan, on: st.info.uuid)
            }
        case .moved(let id):
            let starting = dragger.active == nil
            if dragger.windowMoved(id) {   // a mouse drag: handled until the button comes up; only the drop indicator shows meanwhile
                if starting { applier.drop(id) }       // a write still queued for the grabbed window must not land mid-drag
                liveUntil[id] = Date().addingTimeInterval(1)
                if ringPhase.visible { ringPhase.dragStarted(); ring.hide(duration: 0.08); dim.hide() }
                break
            }
            // Moved by something other than Ribbon (the user, the app itself): the ring takes the real frame at once, no glide.
            if dragger.active == nil, !applier.isBusy, id == ringFocus { liveUntil[id] = Date().addingTimeInterval(1); refreshRing(animated: false) }
            dragged(id)
        case .title(let id, let t):
            snapshots.markDirty(id)
            send(.windowTitle(id, t))
        }
    }

    /// Once resize events stop for 250ms, the resize is over: learn the width the user chose for this app (the core may have
    /// snapped it to a preset), and put the window on the plan's frame if the user left it elsewhere (the core clamped or
    /// snapped the size). A frame that already matches is left alone. The frame is the core's as it stands then, not the resize's:
    /// a plan in between (a native tab took the window's place, a key scrolled) has moved it, and the stale one would pull it back.
    private func settleResize(_ id: UInt32, plan: Plan, on uuid: String) {
        resizeSeq[id, default: 0] += 1
        let seq = resizeSeq[id]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.paused, self.resizeSeq[id] == seq, let st = self.states[uuid] else { return }
                if let frac = plan.map.columns.first(where: { $0.windows.contains { $0.id == id } })?.widthFrac {
                    AppWidths.learn(bundleID: self.bundleID(of: id), frac: frac)
                }
                var p = st.engine.handle(.query, log: false)
                guard let want = p.frames.first(where: { $0.id == id })?.cg, let have = self.tracker.elements[id]?.frame ?? self.tracker.windows[id]?.frame,
                      abs(want.minX - have.minX) > 2 || abs(want.minY - have.minY) > 2
                        || abs(want.width - have.width) > 2 || abs(want.height - have.height) > 2 else { return }
                self.liveUntil[id] = nil
                p.changed = [id]; p.focus = nil
                self.apply(p, on: uuid, showMap: false)
            }
        }
    }

    /// Echo guard plus a 120ms debounce: when a window closes, macOS focuses a sibling before we see the destroy
    /// notification; waiting lets the removal arrive first so the engine's neighbour rule decides.
    private func osFocused(_ id: UInt32) {
        let arrived = Date()
        recentEngineFocus = recentEngineFocus.filter { arrived.timeIntervalSince($0.value) < 0.5 }
        if recentEngineFocus[id] != nil, id != focusedByEngine { return }   // echo of an older engine focus; clicks elsewhere pass
        if isPinRaiseEcho(id, arrived: arrived) { return }       // our own raise of a held window, not the user focusing it
        focusSeq += 1
        let seq = focusSeq, pid = tracker.windows[id]?.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.paused, seq == self.focusSeq, self.tracker.windows[id] != nil else { return }
                if let pid, let r = self.removedAt[pid], r > arrived { return }
                self.noteFocus(id)
                if let h = self.home[id] { self.setFocusedDisplay(h) }
                self.send(.windowFocused(id))
            }
        }
    }

    /// Once things are quiet, compare every visible window's ACTUAL size with the plan. Cell-increment apps (terminals) and
    /// fixed-size windows never land exactly on what we write, and a user drag's last event may be swallowed as an echo.
    /// Whatever the window really is becomes the column width, so neighbours always sit one gap away from the real frame.
    private func scheduleReconcile() {
        reconcileSeq += 1
        let seq = reconcileSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.paused, self.reconcileSeq == seq, !self.applier.isBusy, !self.scrolling, !self.commit.overlayUp else { return }
                self.raisePinned(); self.refreshCurtain(animated: false)      // the glide is over: nothing of the ribbon may stay above the pin
                for (id, want) in self.plannedFrame.sorted(by: { $0.key < $1.key }) where self.plannedOnScreen[id] == true {
                    guard let live = self.tracker.liveFrame(id), self.tracker.windows[id]?.floating != true else { continue }
                    // A window clipped by the display edge (or sliding there) is sized by macOS/the app, not by the user: never adopt it.
                    guard Reconcile.eligible(planned: want, live: live, display: self.display.frame) else { continue }
                    guard abs(live.width - want.width) > 1.5 || abs(live.height - want.height) > 1.5 else { self.lastReconciled[id] = nil; continue }
                    // One attempt per distinct (live size, planned width): no write loops, yet a changed plan (a column widened by a
                    // sibling's floor) lets a still-mismatched window be reported again.
                    guard Reconcile.shouldRefuse(last: self.lastReconciled[id], live: live.size, plannedWidth: want.width) else { continue }
                    let now = Date()
                    guard !Reconcile.throttled(self.refusalTimes[id] ?? [], now: now) else { continue }
                    self.refusalTimes[id] = (self.refusalTimes[id] ?? []).filter { now.timeIntervalSince($0) < Reconcile.burstWindow } + [now]
                    self.lastReconciled[id] = Reconcile.Attempt(live: live.size, plannedWidth: want.width)
                    self.send(.windowRefused(id, live))
                    return   // the new plan reschedules and the next window is checked against the re-laid frames
                }
            }
        }
    }

    // MARK: stability (unresponsive apps, periodic check, sleep/wake)

    private func startStabilityWatch() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)   // no AX call waits for the 6 s default
        AXHealth.shared.onChange { [weak self] pid, change in
            MainActor.assumeIsolated { self?.appHealthChanged(pid, change) }
        }
        tracker.onLiveFrames = { [weak self] pid, frames in self?.checkDrift(frames) }
        stab.timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicCheck() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for (name, wake) in [(NSWorkspace.didWakeNotification, true), (NSWorkspace.screensDidWakeNotification, true), (NSWorkspace.activeSpaceDidChangeNotification, false)] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemChanged(wake: wake) }
            })
        }
    }

    private static let checkEvery = 5.0

    /// Swiping was just switched on. If the pad is in use over the next 10 s (pointer or scroll events) but MultitouchSupport
    /// delivered no frame at all, say so and show the feature as unavailable instead of failing silently.
    private func watchTrackpad() {
        guard !stab.watchingTrackpad else { return }
        stab.watchingTrackpad = true
        let activity = ActivityFlag()
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { _ in activity.set() }
        let before = trackpad.receivedFrames
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                if let monitor { NSEvent.removeMonitor(monitor) }
                guard let self else { return }
                self.stab.watchingTrackpad = false
                guard self.settings.threeFingerScroll, self.started, !self.paused, activity.value, self.trackpad.receivedFrames == before else { return }
                TrackpadScroller.stalled = true
                self.trackpad.stop()
                self.hud.show(map: self.engine.handle(.query).map, focus: self.focusedByEngine,
                              toast: "Swipe scrolling isn't available on this trackpad.", linger: 4500)
            }
        }
    }

    private func appHealthChanged(_ pid: pid_t, _ change: Quarantine.Change) {
        switch change {
        case .quarantined:
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "An app"
            NSLog("ribbon: \(name) (pid \(pid)) is not answering Accessibility; leaving it alone until it recovers")
        case .unresponsive:   // hung for a while, not a hiccup: say why its windows stopped following the ribbon
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "An app"
            NSLog("ribbon: \(name) (pid \(pid)) is still not answering")
            guard started, !paused else { return }
            hud.show(map: engine.handle(.query).map, focus: focusedByEngine,
                     toast: "\(name) isn't responding. Ribbon will leave it alone until it recovers.", linger: 4500)
        case .recovered:
            NSLog("ribbon: pid \(pid) answers again")
            if started, !paused { tracker.rescan(pid, delays: [0.1]) }
        }
    }

    /// Wake, screens awake or a Space change: apps are briefly slow or have moved windows. Forget failure counts, then check
    /// twice (the first reading makes a window a suspect, the second corrects it).
    private func systemChanged(wake: Bool) {
        if wake { AXHealth.shared.reset(); trackpad.restart() }
        stab.suspects = []
        curtainInvalidate(); snapshots.markBackdropDirty()      // every Space can have its own wallpaper
        refreshCurtain(animated: false)
        for d in [0.6, 2.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in MainActor.assumeIsolated { self?.periodicCheck() } } }
    }

    private func mayCheck() -> Bool {
        Reconcile.mayCheck(started: started, paused: paused, writing: applier.isBusy, scrolling: scrolling, overlayUp: commit.overlayUp,
                           mouseDown: NSEvent.pressedMouseButtons != 0)
    }

    /// Every ~5 s: every app is re-listed off the main thread (vanished and missed windows) and its frames come back to `checkDrift`.
    private func periodicCheck() {
        // Safety net, idempotent: a changed wallpaper or appearance drops the slices; the curtain is placed and the pin raised again.
        if curtainWallpaperChanged() { snapshots.markBackdropDirty() }
        SnapshotStore.refreshPermission()      // keyboard moves use it without a swipe ever reading it at touch-down
        followLive()                           // typing or terminal output in the focused window keeps its picture fresh
        refreshCurtain(animated: false)
        raisePinned()
        guard mayCheck() else { return }
        tracker.checkAll()
    }

    /// Windows that sit away from the plan on two checks in a row go back; a window an app resized on its own goes through the
    /// existing refused-size reconcile. Skips the check while the user drags or we animate (the result may be stale by then).
    private func checkDrift(_ live: [UInt32: CGRect]) {
        guard mayCheck() else { return }
        // Only windows planned on screen: parked ones (off-viewport columns, inactive tabs) are left alone, as is a window under the mouse.
        let planned = plannedFrame.filter { live[$0.key] != nil && plannedOnScreen[$0.key] == true && $0.key != dragger.active
                                            && !stab.floats.contains($0.key) && tracker.windows[$0.key]?.floating != true }
        let r = Reconcile.drifted(planned: planned, live: live, previous: stab.suspects)
        stab.suspects = stab.suspects.subtracting(live.keys).union(r.suspects)
        if !r.fix.isEmpty {
            NSLog("ribbon: \(r.fix.count) window(s) drifted from the plan, putting them back")
            applier.rewrite(r.fix.compactMap { id in plannedFrame[id].map { (id: id, rect: $0, onScreen: plannedOnScreen[id] ?? true) } },
                            elements: tracker.elements)
        }
        if planned.contains(where: { id, want in plannedOnScreen[id] == true && Reconcile.sizeDrifted(planned: want, live: live[id]!) }) { scheduleReconcile() }
    }

    // MARK: drag to reorder

    /// A managed window moved. Our own writes are ignored; otherwise wait until the user stops dragging.
    private func dragged(_ id: UInt32) {
        guard !applier.isBusy, plannedOnScreen[id] != false else { return }   // parked windows move only by our hand
        moveSeq[id, default: 0] += 1
        scheduleSettle(id, seq: moveSeq[id], after: 0.3, retries: 5)
    }

    /// Settles once the user stops dragging; if our applier is still busy then, tries again shortly instead of dropping it.
    private func scheduleSettle(_ id: UInt32, seq: Int?, after delay: Double, retries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.paused, self.moveSeq[id] == seq else { return }
                if self.applier.isBusy {
                    if retries > 0 { self.scheduleSettle(id, seq: seq, after: 0.15, retries: retries - 1) }
                    return
                }
                self.dragSettled(id)
            }
        }
    }

    private func dragSettled(_ id: UInt32) {
        liveUntil[id] = nil
        guard plannedOnScreen[id] == true, let frame = tracker.elements[id]?.frame, var st = state(of: id) else { return }
        // Dropped on another display: the window joins that display's ribbon and is then placed by where it landed.
        if let drop = DisplayGeometry.display(containing: CGPoint(x: frame.midX, y: frame.midY), in: infos),
           drop.uuid != st.info.uuid, let dst = states[drop.uuid] {
            transfer(id, to: dst, takeFocus: true, toast: "Moved to \(dst.info.name)")
            st = dst
        }
        // Nearest column by the centre of its planned frame; floating windows are not in any column.
        let plan = st.engine.handle(.query)
        let cols = plan.map.columns
        func centerX(_ i: Int) -> Double {
            plan.frames.first { $0.id == cols[i].windows[0].id }.map { $0.x + $0.w / 2 } ?? .infinity
        }
        guard let own = cols.firstIndex(where: { $0.windows.contains { $0.id == id } }),
              let target = cols.indices.min(by: { abs(centerX($0) - frame.midX) < abs(centerX($1) - frame.midX) })
        else { return }
        if target == own {
            send(.command("gather"), on: st.info.uuid)
        } else {
            send(.command("focus_window", arg: Int(id)), on: st.info.uuid)
            send(.command("move_to_index", arg: target + 1), on: st.info.uuid)
        }
    }

    private func noteFocus(_ id: UInt32) { focusOrder.removeAll { $0 == id }; focusOrder.insert(id, at: 0); ringFocus = id }

    private func bundleID(of id: UInt32) -> String? {
        tracker.windows[id].flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier }
    }

    /// A shelf row chosen in the command bar wins over the app's own idea of its front window.
    private func focusPicked() {
        guard let id = wantFocus, tracker.windows[id] != nil else { return }
        wantFocus = nil
        command("focus_window", Int(id))
    }

    /// Drops the per-window live state of a window that left the ribbon (closed, minimized or hidden).
    private func forgetLive(_ id: UInt32) {
        plannedOnScreen[id] = nil; plannedFrame[id] = nil; plannedLX[id] = nil
        applier.swipe.forget(id)
        if ringFocus == id { ringFocus = nil }
        for st in states.values { st.parkedFloats.remove(id) }
        floatHome[id] = nil
        focusOrder.removeAll { $0 == id }
    }

    /// A tab switch hands the per-window live state of the tab that went away to the one now shown in its place.
    private func carryLiveState(from old: UInt32, to new: UInt32) {
        if ringFocus == old { ringFocus = new }
        if focusedByEngine == old { focusedByEngine = new }
        if wantFocus == old { wantFocus = new }
        focusOrder = focusOrder.compactMap { id -> UInt32? in id == old ? new : (id == new ? nil : id) }
        if let home = floatHome.removeValue(forKey: old) { floatHome[new] = home }
        for st in states.values where st.parkedFloats.remove(old) != nil { st.parkedFloats.insert(new) }
        if stab.floats.remove(old) != nil { stab.floats.insert(new) }
        lastReconciled[old] = nil; refusalTimes[old] = nil
        forgetLive(old)
        snapshots.markDirty(new)
    }

    /// A window_added event for `st`. A window that sits on another display (or off every display) is translated onto `st`,
    /// which matters for floating windows: the core leaves those where they are. `takesFocus` false: an app in the background
    /// opened it, so it joins the ribbon without focus or scrolling.
    private func added(_ w: ManagedWindow, on st: DisplayState, widthHint: Double? = nil, takesFocus: Bool = true) -> Event {
        var w = w
        if !st.info.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) {
            let from = DisplayGeometry.nearest(to: CGPoint(x: w.frame.midX, y: w.frame.midY), in: infos)?.visible ?? st.info.visible
            w.frame = DisplayGeometry.translated(w.frame, from: from, to: st.info.visible)
        }
        let bundle = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier
        // A window Ribbon already laid out keeps what it was (a resume, a move to another display, a Space or full-screen round
        // trip); the "Always float" list decides only for a window it has never seen.
        if let known = floatKnown[w.id] { w.floating = known } else if FloatRules.matches(bundleID: bundle, app: w.app, rules: floatRules) { w.floating = true }
        return .windowAdded(w, widthHint: widthHint ?? AppWidths.hint(bundleID: bundle), takeFocus: takesFocus)
    }

    // MARK: session restore and float rules

    private func sessionKey(_ w: ManagedWindow) -> String {
        SessionFile.key(bundleID: NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier, app: w.app)
    }

    /// The layout to persist, or nil when there is nothing worth saving (paused, not started, restore still pending, no windows).
    private func sessionSnapshot() -> SessionFile? {
        guard started, !paused, pendingSession == nil else { return nil }
        let now = Date()
        let parts = states.keys.sorted().compactMap { u -> (uuid: String, file: SessionFile)? in
            guard let core = states[u]?.engine.handle(.snapshot, log: false).session else { return nil }
            let file = SessionFile.make(from: core, identify: { [tracker] id in
                tracker.windows[id].map { SessionWindow(id: id, pid: $0.pid, key: self.sessionKey($0), title: $0.title) }
            }, now: now)
            return file.desks.isEmpty && file.pin == nil ? nil : (u, file)   // a display holding only its pin still counts
        }
        return SessionFile.combine(parts, primary: primaryUUID, now: now)
    }

    /// The focused window as the bar names it in its footer: the one its window actions will change.
    private func barTarget() -> BarTarget? {
        guard !paused, let id = barWindow(), let w = tracker.windows[id] else { return nil }
        var width = column(of: id).map { $0.map.columns[$0.col].widthFrac }
        let held = heldBarTarget(of: id)             // in a column held outside the ribbon: that column's share of the whole display
        if let held { width = held.width }
        return BarTarget(id: id, title: w.title.isEmpty ? w.app : w.title, app: w.app, icon: NSRunningApplication(processIdentifier: w.pid)?.icon,
                         width: width, pinned: held != nil, tag: held?.tag)
    }

    /// The window the bar acts on: the ribbon's focus, or, while the pin has focus (the ribbon has none then), the pin's shown window.
    private func barWindow() -> UInt32? {
        focusedWindow(on: focusedState) ?? heldFocusedWindow()
    }

    /// "Send to Desktop n" for the other desktops, saying what is there.
    func sendRows(_ map: RibbonMap) -> [BarItem] {
        map.desktops.filter { !$0.active }.map { d in
            let send = BarAction.commandArg("move_to_desktop", d.index)
            return BarItem(id: "send-desk-\(d.index)", title: "Send to Desktop \(d.index)",
                           subtitle: d.count == 0 ? "Desktop \(d.index) is empty" : "Joins \(d.count) window\(d.count == 1 ? "" : "s") there", icon: nil,
                           symbol: "arrow.right.doc.on.clipboard", action: send, keys: BarModel.keys(for: send, store: shortcutStore))
        }
    }

    /// "Always float <App>" / "Stop floating <App>" for the focused window's app.
    private func contextItems() -> [BarItem] {
        guard !paused, let id = barWindow(), let w = tracker.windows[id] else { return [] }
        // A window held outside the ribbon has rows of its own, and the ribbon-only ones (float rule, tab group with a neighbour,
        // move column) are left out.
        if let rows = heldContextRows(of: id) { return rows }
        let bundle = bundleID(of: id)
        let on = !FloatRules.matches(bundleID: bundle, app: w.app, rules: FloatRules.load())
        var items = [BarItem(id: "float-rule", title: on ? "Keep \(w.app) out of the ribbon" : "Let \(w.app) join the ribbon", subtitle: "",
                             icon: nil, symbol: "rectangle.on.rectangle",
                             action: .floatApp(id: FloatRules.ruleID(bundleID: bundle, app: w.app), name: w.app, on: on))]
        items += ribbonWindowFeatureRows(of: id)
        // One step to a tab group with a neighbour, or a swap with it, named after it; only the sides that have a column.
        if let (_, c, _, map) = column(of: id) {
            for (dir, side) in [(-1, "left"), (1, "right")] where map.columns.indices.contains(c + dir) {
                guard let first = map.columns[c + dir].windows.first else { continue }
                // Same app on both sides (or as you): name the window by its title so the two rows differ.
                let app = first.app.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}"))
                let sameApp = app == w.app.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}"))
                    || map.columns.indices.contains(c - dir) && map.columns[c - dir].windows.first?.app == first.app
                let title = first.title.trimmingCharacters(in: .whitespaces)
                let other = sameApp && !title.isEmpty ? (title.count > 28 ? String(title.prefix(27)) + "…" : title) : app
                items.append(BarItem(id: "tab-with-\(side)", title: "Make a tab group with \(other)", subtitle: (side == "left" ? "On the left" : "On the right") + (sameApp ? " · \(app)" : ""), icon: nil,
                                     symbol: "rectangle.topthird.inset.filled", action: .commandArg("tab_with", dir), about: first.id))
                let move = BarAction.command(dir < 0 ? "move_left" : "move_right")
                items.append(BarItem(id: "move-\(side)", title: "Move column \(side)", subtitle: "Swap places with \(other)", icon: nil,
                                     symbol: dir < 0 ? "arrow.left.to.line.compact" : "arrow.right.to.line.compact", action: move,
                                     keys: BarModel.keys(for: move, store: shortcutStore), about: first.id))
            }
            items += sendRows(map)
        }
        return items
    }

    private func setFloatRule(id: String, name: String, on: Bool) {
        let rules = FloatRules.load()
        FloatRules.save(on ? FloatRules.adding(FloatRule(id: id, name: name), to: rules) : FloatRules.removing(id: id, from: rules))
        floatRulesChanged()
        guard started, !paused else { return }
        hud.show(map: engine.handle(.query, log: false).map, focus: focusedByEngine,
                 toast: on ? "\(name) floats, out of the ribbon" : "\(name) is back in the ribbon")
    }

    /// The "Always float" list changed (command bar or Settings): every open window of an app that was added floats, every one
    /// of an app that was taken off tiles again (except windows that cannot be resized, which always float). One undo step per
    /// display. While paused only the remembered states change; the windows follow when Ribbon resumes.
    private func floatRulesChanged() {
        let new = FloatRules.load()
        guard new != floatRules else { return }
        let old = floatRules
        floatRules = new
        let live = started && !paused
        var change: [String: (on: [UInt32], off: [UInt32])] = [:]
        let windows = tracker.windows.merging(tracker.shelved.mapValues(\.window)) { open, _ in open }   // minimized ones come back that way
        for (id, w) in windows.sorted(by: { $0.key < $1.key }) {
            let bundle = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier
            let (was, now) = (FloatRules.matches(bundleID: bundle, app: w.app, rules: old), FloatRules.matches(bundleID: bundle, app: w.app, rules: new))
            guard was != now, now || !w.floating else { continue }
            if !live { floatKnown[id] = now }   // live, the plans below note it (and place what floats out)
            let uuid = home[id] ?? focusedUUID
            if now { change[uuid, default: ([], [])].on.append(id) } else { change[uuid, default: ([], [])].off.append(id) }
        }
        guard live else { return }
        for (uuid, ids) in change {
            guard let st = states[uuid] else { continue }
            for (list, on) in [(ids.on, true), (ids.off, false)] where !list.isEmpty {
                apply(st.engine.handle(rawJSON: "{\"type\":\"command\",\"name\":\"set_floating\",\"arg\":{\"ids\":\(list),\"floating\":\(on)}}"),
                      on: uuid, showMap: false)
            }
        }
    }

    /// Window events go to the ribbon holding the window; everything else to the focused display's.
    func send(_ event: Event, on uuid: String? = nil) {
        var target = uuid ?? focusedUUID
        if uuid == nil, event.type.hasPrefix("window_"), let id = event.id, let h = home[id] { target = h }
        guard let st = states[target] else { return }
        apply(st.engine.handle(event), on: target)
    }

    /// Floating windows have no frame in the plan, so desktop switches park/unpark them here: remember where each one was,
    /// slide it to the sliver past its display's edge, and put it back when its desktop returns. `homes`: where a window that
    /// only now floats goes back to (not where its column was parked).
    private func parkFloating(_ plan: inout Plan, _ st: DisplayState, homes: [UInt32: CGRect] = [:]) {
        let now = Set(plan.floatingParked), tiled = Set(plan.frames.map(\.id))
        for id in now.subtracting(st.parkedFloats) {
            guard let f = homes[id] ?? tracker.elements[id]?.frame else { continue }
            floatHome[id] = f
            let r = DisplayGeometry.parked(CGRect(x: st.info.visible.maxX - 1, y: f.minY, width: f.width, height: f.height),
                                           home: st.info.visible, homeFrame: st.info.frame, others: otherInfos(than: st))
            plan.frames.append(PlanFrame(id: id, x: r.minX, y: r.minY, w: r.width, h: r.height, onScreen: false))
            plan.changed.append(id)
        }
        for id in st.parkedFloats.subtracting(now) {
            guard let home = floatHome.removeValue(forKey: id), !tiled.contains(id) else { continue }   // tiled while parked: the plan places it
            plan.frames.append(PlanFrame(id: id, x: home.minX, y: home.minY, w: home.width, h: home.height, onScreen: true))
            plan.changed.append(id)
        }
        st.parkedFloats = now.filter { floatHome[$0] != nil }
    }

    /// Off-viewport windows are parked on the side of their display that does not bleed onto another display.
    private func parkOffScreen(_ plan: inout Plan, _ st: DisplayState) {
        let others = otherInfos(than: st)
        guard !others.isEmpty else { return }
        for i in plan.frames.indices where !plan.frames[i].onScreen {
            let r = DisplayGeometry.parked(plan.frames[i].cg, home: st.info.visible, homeFrame: st.info.frame, others: others)
            plan.frames[i].x = r.minX; plan.frames[i].y = r.minY
        }
    }

    /// `uuid` = the display whose engine produced the plan (default: the focused one).
    func apply(_ original: Plan, on uuid: String? = nil, showMap: Bool = true, skipMoves: Set<UInt32> = []) {
        var plan = original
        if let err = plan.error { NSLog("ribbon core: \(err)") }
        guard !paused, let st = states[uuid ?? focusedUUID] else { return }
        let isFocused = st.info.uuid == focusedUUID
        if !isFocused { plan.focus = nil }   // a ribbon you are not on never takes the keyboard
        let (floatOut, homes) = noteFloating(original, st)   // before parkFloating: reads where parked floats were
        parkFloating(&plan, st, homes: homes)
        stab.floats.formUnion(plan.floatingParked)
        parkOffScreen(&plan, st)
        if !skipMoves.isEmpty { plan.changed.removeAll { skipMoves.contains($0) } }
        if dragWarm?.uuid == st.info.uuid { dragWarm = (st.info.uuid, original) }   // the press focused the window: the plan moved on, the warm one with it
        if let d = dragger.active { plan.changed.removeAll { $0 == d }; applier.drop(d); dragger.invalidate() }   // never write the window under the mouse
        let departing = ringFocus                        // who had the focus until this plan
        overlayNav(&plan, st, skipMoves: skipMoves)      // a sideways slide goes through the overlay: the moves leave the plan
        if nav?.uuid == st.info.uuid { overlay.raise(plan.focus ?? focusedByEngine) }       // the focused window is on top when two pass each other
        notePin(plan, st)                                // the tab bars are clipped beside this plan's pin
        updateTabBars(plan, st)
        st.desktop = plan.map.desktop
        if isFocused { menu.setDesktop(plan.map.desktop); parkKeyboardFocusIfEmpty(plan, st) }
        if let f = plan.focus { focusedByEngine = f; recentEngineFocus[f] = Date(); noteFocus(f); focusAskedAt = CACurrentMediaTime() }
        let glide = glideMoves(plan, st)   // reads the previous plan: before notePlanned
        let grew = plan.frames.contains { f in plannedFrame[f.id].map { abs($0.width - f.w) > 1 || abs($0.height - f.h) > 1 } ?? true }
        let before = plannedFrame
        notePlanned(plan)
        forgetUntiled(original, st)
        if tiledSet.changed(Set(plan.frames.map(\.id)), on: st.info.uuid) { snapshots.markBackdropDirty() }       // a window opened, closed, floated or tiled
        // First tabbed column ever: say how to switch, once.
        if let t = plan.toast, t.hasPrefix("Tab group:") { plan.toast = t + " · \(settings.modifier.glyphs)Tab to switch"; plan.showMap = true }
        if plan.map.columns.contains(where: \.tabbed), plan.toast?.hasPrefix("Tab") != false, plan.toast?.hasPrefix("Tab group:") != true, !UserDefaults.standard.bool(forKey: "tabsHintShown") {
            UserDefaults.standard.set(true, forKey: "tabsHintShown")
            plan.toast = "Tabbed. \(settings.modifier.glyphs)Tab to switch, or click a tab."
            plan.showMap = true
        }
        var raiseAfter: (@MainActor () -> Void)?
        if plan.frames.contains(where: { $0.isPinned && $0.onScreen }) {
            let gliding = !glide.isEmpty
            raiseAfter = { [weak self] in self?.raisePinnedAfterFocus(gliding: gliding) }
        }
        SwipeStats.shared?.navMark("apply_pre")          // QA: where the main thread spends the time between the key and the first frame
        applier.apply(plan, elements: tracker.elements, glide: glide, before: before, visible: st.info.visible, afterFocus: raiseAfter)
        if case let out = floatOut.filter({ $0.id != dragger.active }), !out.isEmpty { applier.rewrite(out, elements: tracker.elements) }
        SwipeStats.shared?.navMark("apply_applier")
        if !glide.isEmpty {
            startGlideClock(st)
            if NavGate.offersPermission(glided: true, permitted: SnapshotStore.permitted, enabled: overlayNavOn) { offerSmoothMoves() }
        }
        session.touch()
        scheduleReconcile()
        refreshRing()
        SwipeStats.shared?.navMark("apply_ring")
        if let f = plan.focus {      // active/inactive title bars differ: the arriving and the departing window are pictured again
            snapshots.markDirty(f)
            if let old = departing, old != f { snapshots.markDirty(old) }
            refreshFocusPair([f] + (departing.map { $0 == f ? [] : [$0] } ?? []))
        }
        scheduleSnapshots()
        if grew { scheduleSnapshots(after: 0.15) }      // a window that opened or changed size has no picture to slide yet: take one soon
        followLive()
        if isFocused && showMap && plan.showMap { hud.show(map: plan.map, focus: plan.focus ?? focusedByEngine, toast: plan.toast) }
        SwipeStats.shared?.navMark("apply_end")
    }

    /// Switching to an empty desktop parks every window, but macOS keeps keyboard focus on the parked one. Hand it to Finder
    /// (not managed, so the activation cannot bounce back into a focus event).
    private func parkKeyboardFocusIfEmpty(_ plan: Plan, _ st: DisplayState) {
        let d = plan.map.desktop
        defer { st.lastDesktop = d }
        guard d != st.lastDesktop, plan.focus == nil, plan.map.focusedIndex == nil,
              plan.map.desktops.first(where: { $0.active })?.windows.isEmpty ?? true else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }

    private func notePlanned(_ plan: Plan) {
        for f in plan.frames { plannedOnScreen[f.id] = f.onScreen; plannedFrame[f.id] = f.cg; plannedLX[f.id] = f.logicalX }
    }

    /// A window the core no longer lays out (it floats now) keeps no planned frame. The drift check, the focus ring, the dim
    /// cutout and drag to reorder all read one as "a tile lives here": they pulled a floated window back into its old column.
    /// Parked floats keep theirs (their own writes must not read as the user moving them).
    private func forgetUntiled(_ plan: Plan, _ st: DisplayState) {
        for id in Floating.stale(plannedFrame.keys, plan: plan, keep: { home[$0] != st.info.uuid || st.parkedFloats.contains($0) }) {
            plannedFrame[id] = nil; plannedOnScreen[id] = nil; plannedLX[id] = nil
            lastReconciled[id] = nil; refusalTimes[id] = nil; stab.suspects.remove(id)
        }
    }

    /// Notes which windows of this display float. One that just left the ribbon gets a window-sized frame instead of the
    /// full-height column it had (returned to write now, or, parked on another desktop, as the home it comes back to); one that
    /// just joined it leaves its floating frame behind for the next time it floats.
    private func noteFloating(_ plan: Plan, _ st: DisplayState) -> (write: [(id: UInt32, rect: CGRect, onScreen: Bool)], homes: [UInt32: CGRect]) {
        let parked = Set(plan.floatingParked)
        var write: [(id: UInt32, rect: CGRect, onScreen: Bool)] = [], homes: [UInt32: CGRect] = [:]
        let (floated, tiled) = Floating.changes(&floatKnown, plan: plan)
        for id in tiled { floatFrames[id] = floatHome[id] ?? tracker.serverFrame(id) }
        for id in floated {
            let rect = Floating.frame(remembered: floatFrames[id], original: restore.original(id), visible: st.info.visible)
            if parked.contains(id) { homes[id] = rect } else { write.append((id, rect, true)) }
        }
        return (write, homes)
    }

    /// Keyboard moves slide: every window of the plan that keeps its size and only moves (or parks / appears at an edge) rides
    /// the strip on the display link, all on one clock (`SwipeWriter.glide`). Everything else jumps through `FrameApplier`:
    /// size changes, desktop switches, new windows, pinned frames, Reduce Motion, a swipe or the snapshot overlay in progress.
    /// A plan that resizes a window the user can see glides nothing: the neighbours that made room for it, or fill the room it
    /// leaves, move in the same step as its edge (they overlapped it for the length of a glide).
    /// A lone window (a snap back, forced to `jump`) still glides, from where the user left it.
    /// Reads the previous plan, so it runs before `notePlanned`.
    private func glideMoves(_ plan: Plan, _ st: DisplayState) -> [UInt32: StripMove] {
        guard started, !scrolling, !commit.overlayUp, !liveResize, plan.changed.count == 1 || !plan.jump,      // a live resize: neighbours follow the edge at once
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return [:] }
        let frames = Dictionary(plan.frames.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let resized = plan.changed.contains { id in
            guard let f = frames[id], let old = plannedFrame[id] else { return false }
            return StripMove.resizesVisibly(old: old, wasOn: plannedOnScreen[id] == true, new: f.cg, nowOn: f.onScreen)
        }
        if resized { return [:] }
        let byHand = plan.changed.count == 1 ? plan.changed.first : plan.focus   // windows the user may have moved themselves
        var out: [UInt32: StripMove] = [:]
        for id in plan.changed {
            guard let f = frames[id], !f.isPinned, var old = plannedFrame[id], var lx = plannedLX[id],
                  let el = tracker.elements[id], el.pid != 0, !AXHealth.shared.isQuarantined(el.pid) else { continue }
            let on = plannedOnScreen[id] == true
            if id == byHand, on, !applier.swipe.isGliding(id), let live = tracker.serverFrame(id),      // the window server's: no round trip to the app
               abs(live.minX - old.minX) > 2 || abs(live.minY - old.minY) > 2 { old = live; lx = live.minX }
            if let m = StripMove.make(old: old, oldLX: lx, oldOn: on, new: f.cg, newLX: f.logicalX, newOn: f.onScreen, visible: st.info.visible, gliding: applier.swipe.rides(id)) { out[id] = m }
        }
        return out
    }

    /// The display link of the display being moved drives the glide (`swipeTick` steps the writer). The focus ring is not
    /// re-placed per frame (that costs several ms each): it animates to the final frame on its own curve, which fits the glide.
    private func startGlideClock(_ st: DisplayState) {
        let u = st.info.uuid
        pacer.start(uuid: u) { Screens.screen(uuid: u) }
    }

    // MARK: focus ring

    /// Puts the ring around the focused window, or hides it (no focus, paused, window gone or parked off screen,
    /// or another app in front).
    /// `curtain`: false while a direct-mode swipe or glide runs, where it is called at frame rate: windows move within the
    /// curtain's order, never across it, and the window list is not free (it is placed again at settle).
    private func refreshRing(animated: Bool = true, curtain: Bool = true) {
        let animated = animated && !liveResize
        defer {
            refreshDim(animated: animated)
            if curtain { refreshCurtain(animated: animated) }
            if !swipeUIUp, !navUI, swipeBars == nil { for (u, b) in lastBars { tabs.update(b.bars, display: u, visible: b.visible, ribbonArea: ribbonArea(u, b.visible), dimmed: overlayStyle.isOn, animated: false) } }
        }
        // Under the overlay (a keyboard move, a snapshot swipe) the real ring waits at the final place, at full opacity, and the
        // overlay's own ring travels above it; in direct mode it follows the real window through the swipe.
        guard settings.focusRing, started, !paused, !scrolling || commit.overlayUp || !snapMode, ringPhase.visible, let id = ringFocus, let w = tracker.windows[id],
              frontOrActivating(w.pid), let frame = ringFrame(id) else {
            ring.hide(); return
        }
        let covered = commit.overlayUp
        ring.show(windowID: id, axFrame: frame, animated: animated && !applier.swipe.isSettling && !covered, fadeIn: !covered)
    }

    /// The window's app is in front, or is about to be: a plan asked for its focus a moment ago while the overlay covers the display,
    /// so the ring and the dim are placed under the overlay now and are there when it fades, not once the activation has landed.
    private func frontOrActivating(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || (commit.overlayUp && CACurrentMediaTime() - focusAskedAt < 1)
    }

    private func ringFrame(_ id: UInt32) -> CGRect? {
        if let t = liveUntil[id], t > Date() { return tracker.elements[id]?.frame }
        if let f = plannedFrame[id] {
            guard plannedOnScreen[id] == true else { return nil }
            // During a swipe/glide the ring follows where the window really is, not where it is headed.
            if scrolling || applier.swipe.isSettling, let p = applier.swipe.position(id) { return CGRect(origin: p, size: f.size) }
            return f
        }
        return tracker.liveFrame(id)   // floating windows are not in the plan
    }

    // MARK: tabs, dim, drag to reorder

    /// A swipe is on screen (fingers down, or the overlay still up): the tab bars ride with their tiles and the dim is drawn by the overlay.
    private var swipeUIUp: Bool { scrolling || (commit.overlayUp && !navUI) }
    /// A keyboard move is on the overlay: the ring and the tab bars travel with their tiles instead of stepping aside.
    var navUI: Bool { nav != nil }
    private var lastBars: [String: (bars: [TabBar], visible: CGRect)] = [:]
    /// The display whose ribbon tab bars ride with a swipe (see `rideBars`), from the first movement until the columns have landed.
    private var swipeBars: String?
    private func updateTabBars(_ plan: Plan, _ st: DisplayState, animated: Bool = true) {
        let animated = animated && !liveResize
        lastBars[st.info.uuid] = (plan.tabBars, st.info.visible)
        if swipeUIUp || navUI || swipeBars == st.info.uuid { return }       // the ride moves them with their tiles, and puts them where this plan has them when it lands
        tabs.update(plan.tabBars, display: st.info.uuid, visible: st.info.visible, ribbonArea: ribbonArea(st.info.uuid, st.info.visible), dimmed: overlayStyle.isOn, animated: animated)
    }

    /// A tab was clicked: show that window. Quiet (no map flash); the bar itself is the feedback.
    private func selectTab(_ id: UInt32) {
        guard !paused, let u = home[id], let st = states[u] else { return }
        setFocusedDisplay(u)
        apply(st.engine.handle(.command("focus_window", arg: Int(id))), on: u, showMap: false)
    }

    /// A tab's own menu, ✕ / detach button, drag or modifier-click. A pinned group's tabs reorder and pop out through the pin
    /// (it is not a ribbon column); the rest of what a tab can do is the same for both.
    private func tabAction(_ a: TabAction) {
        guard !paused else { return }
        if pinTabAction(a) { return }     // a held column's tabs reorder and pop out through it (it is not a ribbon column)
        switch a {
        case .popOut(let id): popOutTab(id)
        case .moveLeft(let id): shiftTab(id, by: -1)
        case .moveRight(let id): shiftTab(id, by: 1)
        case .reorder(let id, let to): moveTab(id, to: to, toast: nil)
        case .showAsStack(let id): focusThen(id, "toggle_tabs")
        case .closeGroup(let id): focusThen(id, "ungroup_tabs")
        case .keepOut(let id): focusThen(id, "toggle_float")
        case .command(let id, let name, let arg): focusThen(id, name, arg: arg)
        case .menuOpening(let id): tabs.menuContext = menuContext(for: id)
        }
    }

    /// Focus the tab's window first: `pin` and its siblings act on the focused column (or on the pin once it has focus).
    private func focusThen(_ id: UInt32, _ name: String, arg: Int? = nil) {
        guard let u = home[id], let st = states[u] else { return }
        setFocusedDisplay(u)
        _ = st.engine.handle(.command("focus_window", arg: Int(id)))
        apply(st.engine.handle(.command(name, arg: arg)), on: u)
    }

    private func column(of id: UInt32) -> (st: DisplayState, col: Int, row: Int, map: RibbonMap)? {
        guard let u = home[id], let st = states[u] else { return nil }
        let map = st.engine.handle(.query, log: false).map
        for (c, col) in map.columns.enumerated() { if let r = col.windows.firstIndex(where: { $0.id == id }) { return (st, c, r, map) } }
        return nil
    }

    private func shiftTab(_ id: UInt32, by d: Int) {
        guard let (_, c, r, map) = column(of: id), map.columns[c].windows.indices.contains(r + d) else { return }
        moveTab(id, to: r + d, toast: "Moved \(tracker.windows[id]?.title ?? "tab") \(d < 0 ? "left" : "right")")
    }

    /// Reorder inside the group: the window's slot among the column's other windows.
    private func moveTab(_ id: UInt32, to row: Int, toast: String?) {
        guard let (st, c, r, _) = column(of: id), r != row else { return }
        var plan = st.engine.handle(rawJSON: "{\"type\":\"command\",\"name\":\"move_window_to\",\"arg\":{\"id\":\(id),\"column\":\(c + 1),\"position\":\"into\",\"row\":\(row)}}")
        if let toast { plan.toast = toast } else { plan.showMap = false }
        apply(plan, on: st.info.uuid, showMap: toast != nil)
    }

    /// The window leaves the tabs for its own column right after the group (undoable).
    private func popOutTab(_ id: UInt32) {
        guard let (st, c, _, _) = column(of: id) else { return }
        setFocusedDisplay(st.info.uuid)
        var plan = st.engine.handle(rawJSON: "{\"type\":\"command\",\"name\":\"move_window_to\",\"arg\":{\"id\":\(id),\"column\":\(c + 1),\"position\":\"after\"}}")
        plan.toast = "Moved \(tracker.windows[id]?.title ?? "window") to its own column"
        apply(plan, on: st.info.uuid)
    }

    /// "Add to tabs on the left/right": the focused window joins the neighbouring column as a tab.
    private func addToTabs(_ dir: Int) {
        guard let id = focusedByEngine, let (_, c, _, map) = column(of: id), map.columns.indices.contains(c + dir) else {
            hud.show(map: engine.handle(.query, log: false).map, focus: focusedByEngine, toast: "Nothing on that side"); return
        }
        send(.command("tab_with", arg: dir))   // one core command, one undo step; its toast names the group
    }

    /// What the overlay shows now: Settings' choice, Focus mode on top, Reduce Transparency applied.
    private var overlayStyle: OverlayStyle {
        OverlayStyle.resolve(setting: OtherWindows(rawValue: settings.otherWindows) ?? .normal, session: focusSession,
                             level: DimLevel.from(settings.dimLevel), reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    /// Dim or blur everything below the focused window (same conditions as the ring, but independent of its setting).
    private func refreshDim(animated: Bool = true) {
        // A snapshot swipe in progress: the overlay covers the real dim and draws its own, so the panel stays as it is.
        if scrolling, snapMode, commit.overlayUp { return }
        let style = overlayStyle
        guard style.isOn, started, !paused, !scrolling, ringPhase.visible, let id = ringFocus, let w = tracker.windows[id],
              frontOrActivating(w.pid), let frame = ringFrame(id) else {
            dim.hide(); return
        }
        // The focused column's tab bar stays clear too (its glass would otherwise sit on blur).
        let bar = home[id].flatMap { lastBars[$0] }?.bars.first { $0.focused && $0.onScreen && $0.tabs.contains { $0.id == id } }?.cg
        // Under the overlay (a swipe has been released, or a keyboard move) it is placed for the new focus at full opacity,
        // so the overlay fades onto a dim that is already there.
        let covered = commit.overlayUp
        dim.update(style: style, displays: infos, focus: (id, frame), tabBar: bar, orderBelow: ring.windowNumber,
                   animated: animated && !applier.swipe.isSettling && !covered, fade: !covered)
    }

    /// The focused window's tab bar relative to the window, as the overlay's dim wants it: the cutout keeps the bar clear.
    private func dimBarRelative(_ id: UInt32, window: CGRect?, bars: [TabBar]) -> CGRect? {
        guard let window, let bar = bars.first(where: { $0.focused && $0.onScreen && $0.tabs.contains { $0.id == id } }) else { return nil }
        return bar.cg.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    /// The columns on screen as the drop rule sees them, from the core's current plan of the window's own ribbon: the visible
    /// columns and the pinned one (frames and tab bar from the plan's pinned entries), and where the dragged window sits.
    private func dragLayout(for id: UInt32) -> WindowDragger.Layout? {
        guard let st = state(of: id) else { return nil }
        // The plan read at the press, if nothing was applied since; else ask the core.
        let plan = dragWarm.flatMap { $0.uuid == st.info.uuid ? $0.plan : nil } ?? st.engine.handle(.query, log: false)
        let l = DropLayout.build(from: plan, dragging: id)
        return WindowDragger.Layout(columns: l.columns, usable: st.info.visible, gap: CGFloat(settings.gap), source: l.source, pinSource: l.pinSource,
                                    display: st.info.uuid)
    }

    /// The mouse went down at `p`. When that is on the title bar of a window Ribbon manages, read its ribbon's plan now: the
    /// drag's first move (if this turns into one) then builds the drop layout without a round trip to the core.
    private func warmDragLayout(at p: CGPoint) {
        dragWarm = nil
        guard started, !paused, !scrolling, dragger.active == nil,
              let id = plannedFrame.first(where: { plannedOnScreen[$0.key] == true && $0.value.contains(p) && p.y < $0.value.minY + 2 * DropRule.titleBand })?.key,
              let st = state(of: id) else { return }
        dragWarm = (st.info.uuid, st.engine.handle(.query, log: false))
    }

    /// The mouse came up after a title-bar drag.
    private func dragEnded(_ id: UInt32, _ outcome: WindowDragger.Outcome) {
        liveUntil[id] = nil
        dragWarm = nil
        ringPhase.dragEnded()
        // However it ends (drop, snap back, nothing), the ring fades back in at the window's final planned frame.
        defer { ringPhase.settled(); refreshRing(animated: false); raisePinned() }
        guard !paused, let st = state(of: id), let frame = tracker.liveBounds(id) else { return }
        // Dropped on another display: the existing path moves it into that ribbon, placed by where it landed.
        if let drop = DisplayGeometry.display(containing: CGPoint(x: frame.midX, y: frame.midY), in: infos), drop.uuid != st.info.uuid {
            dragSettled(id)
            return
        }
        switch outcome {
        case .tiny:
            refreshRing(animated: false)
        case .snapBack:
            var plan = st.engine.handle(.query, log: false)
            plan.changed = [id]; plan.focus = nil; plan.jump = true
            apply(plan, on: st.info.uuid, showMap: false)
        case .drop(let t):
            // A ribbon column by number (position: before, after, into or tabs), or the pin (`pin: true`, position into or tabs).
            guard let json = DropTarget.moveEvent(t.moveArg(id: id)) else { return }
            apply(st.engine.handle(rawJSON: json), on: st.info.uuid)
        }
    }

    // MARK: three-finger scroll

    private func updateTrackpad() {
        let live = started && !paused
        if settings.threeFingerScroll, live {
            trackpad.fingerCount = settings.swipeFingers; trackpad.start(); watchTrackpad(); SwipeTap.shared.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in MainActor.assumeIsolated { if let self, !self.scrolling, !self.paused { self.hud.prewarm(map: self.engine.handle(.query, log: false).map, focus: self.focusedByEngine) } } }
        } else {
            trackpad.stop(); SwipeTap.shared.stop()
            if scrolling || !live { scrolling = false; swipeDx = 0; endOverlay(); let now = CACurrentMediaTime(); applier.swipe.cancelSettle(at: now); applier.swipe.step(at: now); pacer.reset(); landBars() }
        }
        // The overlay and the pictures only need Screen Recording: keyboard moves glide on them whether or not swiping is on.
        if live { if SnapshotStore.permitted, let sc = Screens.screen(uuid: focusedUUID) ?? Screens.focused { overlay.prewarm(on: sc); preparePacer(); scheduleSnapshots(after: 0.8) } }
        else { overlay.teardown(); snapshots.dropAll() }
    }

    /// The frame pacer follows the display being swiped (a 120 Hz and a 60 Hz screen each tick at their own rate); the link is
    /// built ahead of the gesture (when the fingers rest, and wherever the overlay is prewarmed, so a first keyboard move does not
    /// build it too) and only paused between swipes.
    private func preparePacer() { let u = focusedUUID; pacer.prepare(uuid: u) { Screens.screen(uuid: u) } }
    private func startPacer() { let u = focusedUUID; pacer.start(uuid: u) { Screens.screen(uuid: u) } }

    /// The contacts qualified as a swipe (`t`: device time of that frame): set up the gesture before the first movement arrives.
    private func swipeBegan(contactTime t: Double) {
        guard started, !paused, settings.threeFingerScroll, !scrolling else { return }
        let now = CACurrentMediaTime()
        scrolling = true
        snapMode = SnapshotStore.permitted && ProcessInfo.processInfo.environment["RIBBON_DIRECT_SWIPE"] == nil   // env: QA can force the fallback path
        SwipeStats.shared?.gestureBegan(contactTime: t, mode: snapMode ? "snapshot" : "direct")
        SwipeStats.shared?.mark("main_began", now)
        statsFinger = 0; statsRef = nil; gotFirstDx = false
        predictor.reset()
        lastSwipeUI = now + 0.1      // the map HUD (heavier than a layer move) joins a moment after the first movement, at 30 Hz
        if snapMode { beginOverlayGesture() } else { applier.swipe.cancelSettle(at: now) }
        if !snapMode { raisePinned(force: true) }
        beginBarRide()
        SwipeStats.shared?.mark("overlay_ready")
        startPacer()
        SwipeStats.shared?.mark("pacer_started")
    }

    /// Fingers moved `d` pad widths (+ = right). Natural direction: the ribbon follows the fingers like dragged
    /// content, so the viewport offset moves the opposite way. Only accumulates; the display-paced tick does the work.
    private func scrolled(_ d: Double) {
        guard started, !paused, settings.threeFingerScroll else { return }
        if !scrolling { swipeBegan(contactTime: CACurrentMediaTime()) }
        swipeDx += -d * display.frame.width * Self.scrollGain
        startPacer()
        if !gotFirstDx {   // the first movement does not wait for the next display tick
            gotFirstDx = true
            let now = CACurrentMediaTime()
            if snapMode, commit.overlayUp { feedOverlay(now); swipeFollow(landed: false) }
            else if !snapMode { feedCore(now); applier.swipe.step(at: now); swipeFollow(landed: false) }
        }
    }

    /// One display frame of a swipe. Snapshot mode: the finger movement goes to the core and its frames to the overlay layers
    /// (no AX at all); direct mode: to the writer, latest wins. Ring/HUD follow at ~30 Hz.
    private func swipeTick(_ now: Double) {
        // Motion is sampled at the time the frame reaches the screen, not when this callback happens to run: a late callback is then
        // not a bigger step, and the display link's own cadence is the glide's. The fallback timer has no target.
        let frameAt = pacer.targetTimestamp ?? now
        if commit.overlayUp {
            if swipeDx != 0, scrolling { feedOverlay(now, target: pacer.targetTimestamp); swipeFollow(landed: false) }
            if !scrolling, commit.phase == .settling || commit.phase == .fading {     // the last pixels settle under the fade too
                let moving = overlay.isSettling
                if moving { SwipeStats.shared?.overlayFrame(now) }
                let landed = overlay.step(at: frameAt, interval: pacer.frameInterval ?? 1.0 / 60)
                if nav != nil {
                    if moving || commit.phase == .settling {
                        SwipeStats.shared?.navMark("first_tick", now); SwipeStats.shared?.navMark(pacer.targetTimestamp == nil ? "tick_timer" : "tick_link", now)    // QA: link or fallback timer
                        navFollow(now, landed: !overlay.isSettling)
                    }
                } else { swipeFollow(landed: !overlay.isSettling) }
                if landed { swapFreshPictures(); act(commit.springFinished(at: now)) }      // step is true at once when nothing needs to glide
            }
            if applier.swipe.active { applier.swipe.step(at: frameAt) }   // a keyboard glide begun before the overlay still lands under it
            act(commit.tick(at: now))
            if now - lastSwipeUI >= 1.0 / 30, scrolling {
                lastSwipeUI = now
                if let map = swipeMap { let h0 = CACurrentMediaTime(); hud.show(map: map, focus: focusedByEngine); SwipeStats.shared?.hudCall(ms: (CACurrentMediaTime() - h0) * 1000) }
            }
            if !scrolling, !commit.overlayUp, !applier.swipe.active { pacer.stop() }
            return
        }
        if swipeDx != 0 { feedCore(now) }
        applier.swipe.step(at: frameAt)
        followVeil(now)
        swipeFollow(landed: false)
        followRing()
        if now - lastSwipeUI >= 1.0 / 30, scrolling || applier.swipe.isSettling {
            lastSwipeUI = now
            refreshRing(animated: false, curtain: false)
            if scrolling, let map = swipeMap { hud.show(map: map, focus: focusedByEngine) }
        }
        if !scrolling, !applier.swipe.active { pacer.stop(); restVeils(animated: true); landBars(); refreshRing(animated: false) }
    }

    /// Direct mode, every display frame of a swipe or a glide: the ring goes where its window really is (the full refresh, which
    /// also decides whether it shows at all, runs at 30 Hz).
    private func followRing() {
        guard !snapMode, scrolling || applier.swipe.isSettling, let id = ringFocus, plannedOnScreen[id] == true, ring.isUp(for: id),
              let p = applier.swipe.position(id) else { return }
        ring.follow(axOrigin: p)
    }

    /// Direct mode: only windows that actually move, and only those within one column of the viewport, are handed to the writer.
    private func feedCore(_ now: Double) {
        let dx = swipeDx; swipeDx = 0
        var plan = engine.handle(.scrollBy(dx))
        parkOffScreen(&plan, focusedState)
        if let err = plan.error { NSLog("ribbon core: \(err)") }
        let disp = display.frame
        let moving = plan.frames.filter { f in
            guard let el = tracker.elements[f.id], el.pid != 0 else { return false }
            if let old = plannedFrame[f.id], plannedOnScreen[f.id] == f.onScreen, abs(old.minX - f.x) < 0.5, abs(old.minY - f.y) < 0.5 { return false }
            return f.onScreen || f.logicalX.map { SwipeRange.inDirectRange(lx: $0, w: f.w, display: disp) } ?? true
        }
        notePlanned(plan)
        for f in moving {
            guard let el = tracker.elements[f.id] else { continue }
            applier.swipe.post(f.id, el: el, rect: f.cg, onScreen: f.onScreen, at: now)
        }
        if plan.showMap { swipeMap = plan.map }
    }

    /// Fingers lifted (`v` pad widths per second, + = right): the core snaps to a column (it stays the source of truth for
    /// where the ribbon settles); the windows (or the overlay's snapshots) glide there from where the fingers left them.
    private func scrollEnded(_ v: Double) {
        guard scrolling, started, !paused else { return }
        let now = CACurrentMediaTime()
        if snapMode, commit.overlayUp { endOverlayGesture(velocity: v, now: now); return }
        if swipeDx != 0 { feedCore(now) }
        scrolling = false
        let windowV = v * display.frame.width * Self.scrollGain
        var plan = engine.handle(.scrollEnd(velocity: -windowV))
        parkOffScreen(&plan, focusedState)
        var targets: [UInt32: SwipeWriter.Target] = [:], moves: [UInt32: StripMove] = [:]
        let pin = pinEdge(on: focusedUUID)
        for f in plan.frames {
            guard let el = tracker.elements[f.id], differsFromPlanned(f) || applier.swipe.position(f.id) != nil else { continue }
            targets[f.id] = SwipeWriter.Target(el: el, pid: el.pid, pos: f.cg.origin, onScreen: f.onScreen, posted: now)
            // Where the window is now: where the swipe last wrote it, else where it was planned (parked, out of the swipe's reach).
            guard !f.isPinned, let at = applier.swipe.position(f.id) ?? plannedFrame[f.id]?.origin else { continue }
            moves[f.id] = StripMove.release(origin: at, on: applier.swipe.isShown(f.id) ?? plannedOnScreen[f.id] ?? false, lxWas: plannedLX[f.id],
                                            new: f.cg, newLX: f.logicalX, newOn: f.onScreen, visible: display.frame, pin: pin)
        }
        applier.swipe.settle(to: targets, moves: moves, velocity: windowV, at: now)
        apply(plan, skipMoves: Set(plan.frames.map(\.id)))
        startPacer()
        // First swipe on the fallback path: offer the smooth one (once ever, after the gesture, never during it).
        if ProcessInfo.processInfo.environment["RIBBON_DIRECT_SWIPE"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.smoothCard.offerIfNeeded() }
        }
    }

    private func differsFromPlanned(_ f: PlanFrame) -> Bool {
        guard let old = plannedFrame[f.id], plannedOnScreen[f.id] == f.onScreen else { return true }
        return abs(old.minX - f.x) >= 0.5 || abs(old.minY - f.y) >= 0.5
    }

    // MARK: snapshot overlay

    private func beginOverlayGesture() {
        let tookOver = endNav()                  // fingers took over from a keyboard move: its ring goes, the tab bars ride on with the swipe
        snapshots.hold = true; lastInputAt = CACurrentMediaTime()
        let action = commit.begin()
        if action == .showOverlay {
            guard showOverlay() else { commit = CommitMachine(); snapMode = false; applier.swipe.cancelSettle(at: CACurrentMediaTime()); return }
        } else {
            // A swipe during the previous commit: carry on from where the snapshots are right now.
            if action == .resumeFromFade { overlay.resume() }
            alignCoreToOverlay()
            if tookOver { completeLayersForSwipe() }
        }
        // The ring is drawn with the tiles for the whole swipe (the real one waits under the overlay): it travels with its tile.
        if settings.focusRing, ring.windowNumber != nil, !overlay.hasRing, let focus = ringFocus {
            overlay.ring(from: nil, to: focus, now: CACurrentMediaTime())
        }
        // Other windows: Dim / Blur. The overlay covers the real dim panel, so it draws the dim itself (see `SwipeOverlay.setDim`).
        if dim.isShowing, !overlay.hasDim, let focus = ringFocus, case let style = overlayStyle, style.isOn {
            overlay.setDim(style, area: focusedState.info.visible, focus: focus,
                           bar: dimBarRelative(focus, window: plannedFrame[focus], bars: lastBars[focusedUUID]?.bars ?? []),
                           softened: { [snapshots] in snapshots.softened[$0] }, softBackdrop: snapshots.softBackdrop)
        }
        SwipeStats.shared?.mark("shown")
        // Captures are not started here: this is the frame the layers must already follow. Missing images are fetched when the
        // fingers touch down (above) and after the swipe; whatever arrives mid-swipe only replaces placeholders.
        SwipeStats.shared?.mark("snapshots_requested")
    }

    /// The core already sits at the previous swipe's final layout while the layers are still gliding there: put the core's
    /// viewport where the layers are (it stays the source of truth), and let the new swipe continue from it. It is set outright,
    /// not scrolled by the difference: past an end of the ribbon a scroll is resisted and the tiles would jump.
    private func alignCoreToOverlay() {
        overlay.freeze()
        let plan = engine.handle(.query, log: false)
        guard let f = plan.frames.first(where: { !$0.isPinned && $0.logicalX != nil && overlay.currentX($0.id) != nil }),     // the pin never moves
              let have = overlay.currentX(f.id), let want = f.logicalX else { return }
        if abs(have - want) >= 0.5 { _ = engine.handle(.scrollTo(f.id, x: have), log: false) }
    }

    /// A keyboard move stages only the tiles it can show; a swipe may drag the ribbon much further. When the fingers take over from
    /// one, the layers get the tiles of the swipe's reach too, where the (now aligned) core has them.
    private func completeLayersForSwipe() {
        guard let p = overlayPlan() else { return }
        let have = overlay.stagedRects
        extendLayers(add: p.specs.filter { have[$0.id] == nil })
    }

    /// The tiled windows of a plan as the overlay draws them, at their logical rects: tabbed columns show their active tab only
    /// (the others share its place and would be drawn on top of it), and the pin's edge is where ribbon tiles go beneath it.
    private func navLayout(of plan: Plan, display disp: CGRect) -> NavLayout {
        var hidden = Set<UInt32>()
        for c in plan.map.columns + (plan.map.pin.map { [$0.column] } ?? []) where c.tabbed {
            for (i, w) in c.windows.enumerated() where i != (c.active ?? 0) { hidden.insert(w.id) }
        }
        var specs: [SwipeOverlay.TileSpec] = []
        var shownPin: CGRect?
        for f in plan.frames {
            guard let r = f.logicalRect, !hidden.contains(f.id), let w = tracker.windows[f.id], tracker.elements[f.id] != nil, !w.floating else { continue }
            specs.append(.init(id: f.id, rect: r, pid: w.pid, pinned: f.isPinned))
            if f.isPinned, f.onScreen { shownPin = shownPin ?? r }          // the pinned window that shows (a tabbed pin shows one)
        }
        let bar = plan.tabBars.first { $0.isPinned && $0.onScreen }?.cg.offsetBy(dx: -disp.minX, dy: -disp.minY)
        let edge = overlayEdge(plan, shownPin: shownPin, bar: bar, display: disp)
        return NavLayout(desktop: plan.map.desktop, specs: specs, edge: edge, hidden: hidden)
    }

    private func overlaySignature(_ disp: CGRect, _ edge: PinEdge?, _ specs: [SwipeOverlay.TileSpec]) -> String {
        "\(disp)\(edge.map { "\($0)" } ?? "")" + specs.map { "\($0.id)@\($0.rect)" }.joined(separator: ",")
    }

    /// What the overlay would show now: the tiled windows of the focused display within reach, at their logical frames.
    private func overlayPlan() -> (screen: NSScreen, disp: CGRect, specs: [SwipeOverlay.TileSpec], edge: PinEdge?, signature: String)? {
        SwipeStats.shared?.mark("op_0")
        guard let screen = Screens.screen(uuid: focusedUUID) ?? Screens.focused else { return nil }
        SwipeStats.shared?.mark("op_screen")
        let disp = focusedState.info.frame
        let plan = engine.handle(.query, log: false)
        SwipeStats.shared?.mark("op_query")
        let layout = navLayout(of: plan, display: disp)
        let specs = layout.specs.filter { SwipeRange.inSnapshotRange(lx: $0.rect.minX, w: $0.rect.width, display: disp) }
        guard !specs.isEmpty else { return nil }
        return (screen, disp, specs, layout.edge, overlaySignature(disp, layout.edge, specs))
    }

    private func stage(_ p: (screen: NSScreen, disp: CGRect, specs: [SwipeOverlay.TileSpec], edge: PinEdge?, signature: String)) {
        overlay.stage(on: p.screen, displayAX: p.disp, backdrop: snapshots.backdrop, softBackdrop: snapshots.softBackdrop, tiles: p.specs, edge: p.edge, signature: p.signature,
                      image: tilePicture, realFrame: { [snapshots] in snapshots.frames[$0] }, softened: { [snapshots] in snapshots.softened[$0] },
                      icon: { NSRunningApplication(processIdentifier: $0)?.icon })
    }

    /// The picture a tile of this size shows (stale is fine, none is a placeholder).
    private func tilePicture(_ id: UInt32, _ size: CGSize) -> CGImage? {
        let img = snapshots.image(id, size: size)
        SwipeStats.shared?.snapshotUse(hit: img != nil)
        return img
    }

    /// Puts layers on the staged overlay for the tiles it lacks, takes those of closed windows off and parks the ones out of
    /// the move (see `SwipeOverlay.extend`); nothing is rebuilt.
    private func extendLayers(add: [SwipeOverlay.TileSpec], drop: Set<UInt32> = [], snap: [UInt32: Double] = [:]) {
        overlay.extend(add: add, drop: drop, snap: snap, image: tilePicture, realFrame: { [snapshots] in snapshots.frames[$0] },
                       softened: { [snapshots] in snapshots.softened[$0] }, icon: { NSRunningApplication(processIdentifier: $0)?.icon })
    }

    /// Fingers rest on the pad: build the (invisible) overlay now so the first movement only has to reveal it.
    private func touchedDown() {
        SnapshotStore.refreshPermission()      // off the critical path: CGPreflightScreenCaptureAccess costs milliseconds
        if started, !paused, settings.threeFingerScroll { preparePacer() }
        guard started, !paused, settings.threeFingerScroll, !scrolling, !commit.overlayUp, SnapshotStore.permitted,
              ProcessInfo.processInfo.environment["RIBBON_DIRECT_SWIPE"] == nil, let p = overlayPlan() else { return }
        if overlay.stagedSignature != p.signature { stage(p) }
        overlay.refreshFloaters()                                            // the windows the ribbon leaves where they are, as they are now
        if overlay.hasPlaceholders { requestSnapshots(forSwipe: true) }      // fingers rest: fetch what the layers still lack before they move
    }

    @discardableResult
    private func showOverlay() -> Bool {
        guard let p = overlayPlan() else { return false }
        SwipeStats.shared?.mark("plan_built")
        if overlay.stagedSignature != p.signature { SwipeStats.shared?.mark("restaged"); stage(p) }      // not staged (or the layout changed since): build it now
        SwipeStats.shared?.mark("stage_checked")
        overlay.raise(focusedByEngine)
        overlay.reveal(floatersMaxAge: 2)          // the fingers came to rest a moment ago: the floating windows were looked at then
        restVeils(animated: false)                          // the overlay draws its own dissolve; a direct glide's veil goes
        return true
    }

    /// What to picture on the focused display: every tile of its ribbon, nearest the display first, as many as the ledger keeps
    /// (see `SnapshotReach`), each at the display's scale (parked ones too: they slide in sharp). `managed`: every window the
    /// ribbon places, which the backdrop leaves out. `withFloaters`: the windows the ribbon leaves where they are are pictured too
    /// (they are drawn as tiles that stay put, and so are left out of the backdrop as well).
    private func snapshotWants(withFloaters: Bool = false) -> (wants: [UInt32: SnapshotStore.Want], order: [(id: UInt32, onScreen: Bool)], managed: Set<UInt32>, floaters: Set<UInt32>) {
        let plan = engine.handle(.query, log: false)
        let disp = focusedState.info.frame
        let scale = Double(Screens.screen(uuid: focusedUUID)?.backingScaleFactor ?? 2)
        let layout = navLayout(of: plan, display: disp)       // hidden tabs have no tile
        let onScreen = Dictionary(plan.frames.map { ($0.id, $0.onScreen) }, uniquingKeysWith: { a, _ in a })
        let managed = Set(plan.frames.filter { $0.logicalRect != nil && tracker.elements[$0.id] != nil && tracker.windows[$0.id]?.floating != true }.map(\.id))
        let picks = SnapshotReach.wanted(layout.specs.map { (id: $0.id, lx: $0.rect.minX, w: $0.rect.width, onScreen: onScreen[$0.id] ?? false) }, display: disp, limit: SnapshotLedger.defaultCapacity)
        let sizes = Dictionary(layout.specs.map { ($0.id, $0.rect.size) }, uniquingKeysWith: { a, _ in a })
        var wants: [UInt32: SnapshotStore.Want] = [:]
        for p in picks { wants[p.id] = .init(id: p.id, size: sizes[p.id] ?? .zero, scale: scale, maxAge: p.maxAge) }
        var order = picks.map { (id: $0.id, onScreen: $0.onScreen) }
        let floaters = withFloaters ? overlayFloaters(on: disp) : []
        for f in floaters {
            wants[f.id] = .init(id: f.id, size: f.rect.size, scale: scale, maxAge: 2)
            order.append((f.id, true))
        }
        return (wants, order, managed, Set(floaters.map(\.id)))
    }

    /// Any missing or stale images of windows in reach, all captured in parallel; they replace the cached image or placeholder as they arrive.
    private func requestSnapshots(forSwipe: Bool) {
        guard SnapshotStore.permitted, !scrolling, !commit.overlayUp else { return }       // never while something moves
        snapshots.hold = false
        let w = snapshotWants(withFloaters: true)
        snapshots.trim(alive: Set(tracker.windows.keys).union(w.floaters))
        snapshots.refresh(SnapshotOrder.sorted(w.order, focus: ringFocus ?? focusedByEngine).compactMap { w.wants[$0] }, excludingBackdropOf: focusedState.info.id, managed: w.managed,
                          floaters: w.floaters)
    }

    /// The windows on `disp` that the ribbon does not move (see `OverlayFloaters`), from the window server's stacking order and the
    /// windows every display's ribbon lays out right now.
    private func overlayFloaters(on disp: CGRect) -> [SwipeOverlay.FloaterSpec] {
        let tiled = Set(states.values.flatMap { $0.engine.handle(.query, log: false).frames.map(\.id) })
        return OverlayFloaters.pick(stack: WindowStack.current().entries, tiled: tiled, ownPID: ProcessInfo.processInfo.processIdentifier, display: disp)
    }

    /// What the overlay draws for them: each with its picture, when the store has a usable one.
    private func floaterTiles() -> [SwipeOverlay.FloaterTile] {
        overlayFloaters(on: focusedState.info.frame).map { .init(spec: $0, image: snapshots.image($0.id, size: $0.rect.size)) }
    }

    /// Cheap and debounced: once the keyboard and the fingers have been quiet for `delay`, refresh the stale images of what is in
    /// reach (the focused window first, a few at a time). Waits while anything is moving; never starts after movement began. A
    /// sooner request wins over a later one that is armed already (see `SweepClock`); the sweep itself still waits for the quiet.
    private func scheduleSnapshots(after delay: Double = 1.0) {
        guard started, !paused, SnapshotStore.permitted else { return }
        guard sweep.arm(after: delay, at: CACurrentMediaTime()) else { return }
        snapSeq += 1
        let seq = snapSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.snapSeq == seq else { return }
                self.sweep.fired()
                guard !self.paused, !self.bar.isOpen else { return }
                let quiet = CACurrentMediaTime() - self.lastInputAt
                if self.scrolling || self.commit.overlayUp || quiet < delay - 0.05 { self.scheduleSnapshots(after: max(delay < 0.5 ? 0.2 : 0.4, delay - quiet)); return }
                self.requestSnapshots(forSwipe: false)
                if let sc = Screens.screen(uuid: self.focusedUUID) { self.overlay.prewarm(on: sc); self.preparePacer() }
            }
        }
    }

    // MARK: pictures that match the live windows

    /// The focus moved: the window that got it and the one that lost it change their title bars (traffic lights, translucency).
    /// While the overlay is up their pictures are taken again, through the capture hold, and swapped in when the glide has landed,
    /// right before the fade, so the live windows do not pop in when it clears.
    private func refreshFocusPair(_ ids: [UInt32]) {
        guard SnapshotStore.permitted, commit.overlayUp, !ids.isEmpty else { return }
        pairSeq += 1
        let seq = pairSeq
        let set = Set(ids)
        freshening.formUnion(set)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusPairDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pairSeq == seq, !self.paused, !self.scrolling, self.commit.overlayUp else { return }
                let w = self.snapshotWants()
                self.snapshots.refresh(w.order.compactMap { set.contains($0.id) ? w.wants[$0.id] : nil }, force: set, managed: w.managed, through: set)
            }
        }
    }

    /// A picture arrived. The overlay takes it where it is due: a placeholder at once, a tile out of sight whenever, and a tile of
    /// the focus pair once its glide has landed (until then the new picture waits, so nothing swaps mid-motion).
    private func pictureArrived(_ id: UInt32, _ img: CGImage) {
        switch PictureSwap.verdict(overlayUp: overlay.isUp, focusPair: freshening.contains(id), hasPicture: overlay.hasPicture(id), moving: scrolling || overlay.isSettling) {
        case .wait: pendingFresh.insert(id)
        case .swap: overlay.setImage(id, img, softened: snapshots.softened[id], real: snapshots.frames[id], swap: true)
        case .normal: overlay.setImage(id, img, softened: snapshots.softened[id], real: snapshots.frames[id])
        }
    }

    /// The glide has landed: the focus pair's new pictures go in (the fade is next).
    private func swapFreshPictures() {
        guard !pendingFresh.isEmpty else { return }
        for id in pendingFresh { if let img = snapshots.images[id] { overlay.setImage(id, img, softened: snapshots.softened[id], real: snapshots.frames[id], swap: true) } }
        pendingFresh = []
    }

    /// While the user works (keys, clicks, pointer) the focused window's picture is taken again about every ¾ s, so a move that
    /// starts now slides the window as it is, with the text just typed, not as it was at the last quiet sweep. Runs from a plan or
    /// the periodic check until the user has been idle for ten seconds; never while anything moves.
    private func followLive() {
        guard !liveRunning, started, !paused, overlayNavOn, SnapshotStore.permitted else { return }
        liveRunning = true
        liveTick()
    }

    private func liveTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + LiveRefresh.every) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idle = Self.secondsSinceInput()
                guard self.started, !self.paused, SnapshotStore.permitted, LiveRefresh.keepsWatching(idle: idle) else { self.liveRunning = false; return }
                if !self.scrolling, !self.commit.overlayUp, !self.bar.isOpen, let id = self.ringFocus ?? self.focusedByEngine,
                   LiveRefresh.takes(idle: idle, age: self.snapshots.age(of: id)) {
                    let w = self.snapshotWants()
                    if var want = w.wants[id] {
                        want.maxAge = LiveRefresh.every - 0.05
                        self.snapshots.refresh([want], managed: w.managed)
                    }
                }
                self.liveTick()
            }
        }
    }

    /// Seconds since the last key, click or pointer move anywhere.
    private static func secondsSinceInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .keyDown)
    }

    /// Snapshot mode, per display frame while the fingers move: the core's frames go to the layers.
    private func feedOverlay(_ now: Double, target: Double? = nil) {
        let dx = swipeDx; swipeDx = 0
        SwipeStats.shared?.mark("feed_start")
        let c0 = CACurrentMediaTime()
        let plan = engine.handle(.scrollBy(dx))
        SwipeStats.shared?.coreCall(ms: (CACurrentMediaTime() - c0) * 1000)
        if let err = plan.error { NSLog("ribbon core: \(err)") }
        var xs: [UInt32: Double] = [:]
        for f in plan.frames { if let x = f.logicalX { xs[f.id] = x } }
        // Visual lead only (the core's position stays the truth): the layers go where the fingers will be when this frame shows.
        let lead = predictLayers ? predictor.offset(dx: dx, at: now, target: target) : 0
        if lead != 0 { for id in xs.keys { xs[id]! -= lead } }
        overlay.move(xs)
        SwipeStats.shared?.mark("layers_moved")
        if let stats = SwipeStats.shared {
            stats.firstMove(now); stats.overlayFrame(now)
            statsFinger += dx
            if statsRef == nil, let id = plan.frames.filter({ !$0.isPinned && $0.logicalX != nil }).map(\.id).min() { statsRef = (id, (xs[id] ?? 0) + statsFinger) }   // the pin never follows the fingers
            if let r = statsRef, let x = xs[r.id] { stats.position(layer: x, want: r.x0 - statsFinger, at: now) }
        }
        if plan.showMap { swipeMap = plan.map }
    }

    /// Release in snapshot mode: layers spring to the core's settled layout while the real windows are written once each,
    /// concurrently per app, under the overlay.
    private func endOverlayGesture(velocity v: Double, now: Double) {
        if swipeDx != 0 { feedOverlay(now) }
        scrolling = false
        let windowV = v * display.frame.width * Self.scrollGain
        var plan = engine.handle(.scrollEnd(velocity: -windowV))
        if let err = plan.error { NSLog("ribbon core: \(err)") }
        var finals: [UInt32: Double] = [:]
        for f in plan.frames { if let x = f.logicalX { finals[f.id] = x } }
        overlay.settle(to: finals, velocity: windowV, now: now, lazyClock: false)      // the fingers were moving the tiles: the glide carries on at once
        // The ring glides from the old focus to the new one under the same spring; the real ring is placed under the overlay by `apply`.
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if overlay.hasRing { overlay.ring(from: ringFocus, to: plan.focus ?? ringFocus, now: now, animated: animated) }
        if overlay.hasDim, let focus = plan.focus ?? ringFocus {
            overlay.setDimFocus(focus, bar: dimBarRelative(focus, window: plan.frames.first { $0.id == focus }?.cg, bars: plan.tabBars), now: now, animated: animated)
        }
        parkOffScreen(&plan, focusedState)
        var targets: [UInt32: SwipeWriter.Target] = [:]
        for f in plan.frames {
            guard let el = tracker.elements[f.id], differsFromPlanned(f) else { continue }
            targets[f.id] = SwipeWriter.Target(el: el, pid: el.pid, pos: f.cg.origin, onScreen: f.onScreen, posted: now)
        }
        let gen = commit.release()
        SwipeStats.shared?.released(now)
        applier.swipe.commit(targets) { [weak self] in
            MainActor.assumeIsolated { if let self { SwipeStats.shared?.writesDone(); self.act(self.commit.writesFinished(generation: gen, at: CACurrentMediaTime())) } }
        }
        apply(plan, skipMoves: Set(plan.frames.map(\.id)))      // focus, session, map; the moves are the commit above
        startPacer()
    }

    private func act(_ a: CommitMachine.Action) {
        switch a {
        case .startFade:
            overlay.fadeOut(duration: CommitMachine.fadeDuration) { [weak self] in self?.act(self?.commit.fadeFinished() ?? .none) }
        case .removeOverlay:
            if let n = nav {                                    // a keyboard move: the layers stay, ready for the next one
                overlay.keep(signature: n.signature)
                nav = nil; SwipeStats.shared?.navFinish()
            } else {
                overlay.hide()
            }
            snapshots.hold = false
            freshening = []; pendingFresh = []
            SwipeStats.shared?.overlayHidden()
            qaFinalError()
            swipeSettled()
        case .none, .showOverlay, .resumeFromFade: break
        }
    }

    /// QA (stats only): largest distance between where the plan put each on-screen window and where AX says it is.
    private func qaFinalError() {
        guard let stats = SwipeStats.shared else { return }
        var worst = 0.0
        for (id, want) in plannedFrame where plannedOnScreen[id] == true {
            guard let live = tracker.elements[id]?.frame else { continue }
            worst = max(worst, abs(live.minX - want.minX), abs(live.minY - want.minY))
        }
        stats.finalError(maxPx: worst)
    }

    /// The real windows are in place and the overlay is gone.
    private func swipeSettled() {
        scheduleReconcile()
        refreshRing(animated: false)
        scheduleSnapshots(after: 0.3)          // the windows have landed: what changed under the overlay is pictured before the next move
    }

    /// Tears the overlay down at once (pause, trackpad off).
    private func endOverlay() {
        endNav()
        landBars()
        overlay.hide()
        snapshots.hold = false
        freshening = []; pendingFresh = []
        commit = CommitMachine()
    }

    // MARK: keyboard moves on the overlay

    /// A command that only slides windows sideways (focus left or right, move a column, reveal) is animated by the overlay at
    /// display rate, like a swipe, instead of by seven AX steps per window: the layers are staged at the OLD layout (the ones kept
    /// from the last move when they still match), the real windows are written once under them at the new layout, the tiles spring
    /// there from where they are (a command mid-glide bends the motion), and the layers fade once everything has landed. The focus
    /// ring and the tab bars travel with their tiles. Called for every plan, early in `apply`, which also records the display's
    /// tiles for the next one; a move it takes over leaves `plan.changed`.
    ///
    /// Only the tiles the move can show are staged (on the display before, after or on the way, plus a column of margin), and a
    /// run of quick moves adds the few that come into reach to the layers it has: it never stages again and never hides mid-glide.
    /// Every tile that can be seen needs a real picture; one without (a window that just opened or changed size) sends the move
    /// down the AX road and gets captured, so no gray placeholder ever slides across the display.
    /// Anything that is no slide (a size or row change, a window that came or went, another desktop or display, a drag, Reduce
    /// Motion, Dim or Focus mode, no Screen Recording) takes the AX path; a glide in progress then lands and fades (`leaveOverlay`).
    /// The swipe setting is no part of it: the overlay only needs Screen Recording.
    private func overlayNav(_ plan: inout Plan, _ st: DisplayState, skipMoves: Set<UInt32>) {
        let uuid = st.info.uuid, disp = st.info.frame
        let new = navLayout(of: plan, display: disp)
        let old = navLayouts.updateValue(new, forKey: uuid)
        let now = CACurrentMediaTime()
        lastInputAt = now
        guard !plan.changed.isEmpty else {                      // nothing moves: a running animation carries on, its ring follows the focus
            if nav != nil, settings.focusRing, ring.windowNumber != nil, uuid == focusedUUID { overlay.ring(from: ringFocus, to: plan.focus ?? ringFocus, now: now) }
            return
        }
        let gate = NavGate(enabled: overlayNavOn, started: started, permitted: SnapshotStore.permitted, focusedDisplay: uuid == focusedUUID,
                           plain: skipMoves.isEmpty, idle: !scrolling && commit.phase != .gesture && dragger.active == nil, glides: !plan.jump,
                           undimmed: !overlayStyle.isOn, motion: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard gate.open, let old, let screen = Screens.screen(uuid: uuid) else {
            leaveOverlay(uuid)                                  // the AX path takes over from here
            return
        }
        // The layers: kept from the last move (they must still show the old layout) or still gliding (they are where they are).
        let stats = SwipeStats.shared
        let gliding = commit.phase != .idle
        let staged = overlay.stagedSignature != nil && overlay.stagedEdge == old.edge && overlay.displayAX == disp      // staged for this display
        let restage = !gliding && (!staged || !NavLayout.layersAgree(overlay.stagedRects, with: old))
        // An unresponsive app is left alone by the writer and catches up through the AX path when it answers again.
        guard !(gliding && !staged), !plan.changed.contains(where: { id in tracker.elements[id].map { AXHealth.shared.isQuarantined($0.pid) } ?? false }),
              let moves = NavLayout.slide(from: old, to: new, changed: plan.changed, display: disp, layers: restage ? [:] : overlay.stagedRects) else {
            stats?.navFallback("not a slide (\(plan.changed.count) windows changed)")
            leaveOverlay(uuid)
            return
        }
        let sizes = Dictionary(new.specs.map { ($0.id, $0.rect.size) }, uniquingKeysWith: { a, _ in a })
        guard let slide = moves.pictured({ id in (!restage && overlay.hasPicture(id)) || sizes[id].map { snapshots.hasPicture(id, size: $0) } == true }) else {
            stats?.navFallback("no picture yet")
            leaveOverlay(uuid)
            scheduleSnapshots(after: 0.15)                      // the next move finds it
            return
        }
        stats?.navBegin("keys \(slide.finals.count) tiles", at: now)
        snapshots.hold = true
        if restage {
            stage((screen, disp, slide.staging, old.edge, overlaySignature(disp, old.edge, slide.staging)))
            stats?.navMark("restaged")
        } else if !(slide.add.isEmpty && slide.drop.isEmpty && slide.snap.isEmpty) {
            extendLayers(add: slide.add, drop: slide.drop, snap: slide.snap)
            stats?.navMark("extended")
        }
        stats?.navMark("staged")
        var fresh = false                                       // the overlay is only just being shown
        switch commit.begin() {
        case .showOverlay: overlay.reveal(); fresh = true
        case .resumeFromFade: overlay.resume()
        default: break
        }
        stats?.navMark("revealed")
        if settings.focusRing, ring.windowNumber != nil { overlay.ring(from: ringFocus, to: plan.focus ?? ringFocus, now: now) } else { overlay.removeRing() }
        let lead = (plan.focus.flatMap { id in slide.staging.first { $0.id == id && !$0.pinned } } ?? slide.staging.first { !$0.pinned && abs((slide.finals[$0.id] ?? $0.rect.minX) - $0.rect.minX) >= 1 })?.id
        stats?.navStart(x: lead.flatMap { overlay.currentX($0) })
        overlay.settle(to: slide.finals, velocity: 0, now: now)
        stats?.navMark("tiles_moving")
        // The real windows go to their places under the overlay, once each.
        var targets: [UInt32: SwipeWriter.Target] = [:]
        for id in plan.changed {
            guard let f = plan.frames.first(where: { $0.id == id }), let el = tracker.elements[id] else { continue }
            applier.drop(id)
            targets[id] = SwipeWriter.Target(el: el, pid: el.pid, pos: f.cg.origin, onScreen: f.onScreen, posted: now)
        }
        plan.changed = []
        navWrites = (targets: (navWrites?.targets ?? [:]).merging(targets) { _, new in new }, gen: commit.release())
        // A window that moves before the overlay has reached the screen shows for a frame: the first write waits for it.
        if fresh {
            navWriteTimer = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.navWriteDelay) { [weak self] in MainActor.assumeIsolated { self?.flushNavWrites() } }
        } else if !navWriteTimer { flushNavWrites() }
        stats?.navMark("writes_posted")
        // What stays staged for the next move is what is on the layers now, at the places this move ends.
        let onLayers = Set(overlay.stagedRects.keys)
        nav = NavMove(uuid: uuid, bars: plan.tabBars, visible: st.info.visible, signature: overlaySignature(disp, new.edge, new.specs.filter { onLayers.contains($0.id) }), lead: lead)
        startPacer()
    }

    /// The plan is no slide the overlay can carry, or must not draw. A keyboard move on the overlay is never cut short: its tiles take
    /// the places they were heading for and the layers fade like after any landing, while the plan goes down the AX road under
    /// them. Layers kept for the next move no longer match what the plan does to the windows: they go.
    private func leaveOverlay(_ uuid: String) {
        if nav?.uuid == uuid { endNav(); overlay.land() }
        else if uuid == focusedUUID, !overlay.isUp, overlay.stagedSignature != nil { overlay.hide() }
    }

    /// A keyboard glide on the AX road without Screen Recording: once ever, a moment after it has landed, the card offers the smoother one.
    private func offerSmoothMoves() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.smoothCard.offerIfNeeded() }
    }

    /// Writes the real windows of the keyboard moves so far (the newest target of each), once, under the overlay.
    private func flushNavWrites() {
        navWriteTimer = false
        guard let w = navWrites else { return }
        navWrites = nil
        let gen = w.gen
        applier.swipe.commit(w.targets) { [weak self] in
            MainActor.assumeIsolated { if let self { SwipeStats.shared?.navMark("writes_done"); self.act(self.commit.writesFinished(generation: gen, at: CACurrentMediaTime())) } }
        }
    }

    /// Per display frame of a keyboard move: the tab bars follow their tiles (the ring is a layer of the overlay itself).
    private func navFollow(_ now: Double, landed: Bool) {
        guard let n = nav else { return }
        let c0 = CACurrentMediaTime()
        rideBars(uuid: n.uuid, bars: n.bars, visible: n.visible, landed: landed) { self.overlay.currentX($0) }
        if let stats = SwipeStats.shared, let lead = n.lead, let x = overlay.currentX(lead) { stats.navTick(x: x, cost: (CACurrentMediaTime() - c0) * 1000, at: now) }
    }

    /// The ribbon's tab bars ride with their columns for the length of a swipe and its landing, in both modes. They are panels
    /// above the overlay (and above the real windows), so they would otherwise hang where the columns were while the content slid
    /// beneath them.
    private func beginBarRide() {
        let u = focusedUUID
        swipeBars = lastBars[u]?.bars.contains(where: { !$0.isPinned }) == true ? u : nil
    }

    /// One display frame of a swipe: each bar goes to where its tile (snapshot mode) or its real window (direct mode) is now.
    /// `landed`: the columns are home, the bars go where the newest plan has them and the ride is over.
    private func swipeFollow(landed: Bool) {
        guard let u = swipeBars, let last = lastBars[u] else { return }
        if snapMode {
            rideBars(uuid: u, bars: last.bars, visible: last.visible, landed: landed) { self.overlay.currentX($0) }
        } else {
            rideBars(uuid: u, bars: last.bars, visible: last.visible, landed: landed) { id in
                (self.applier.swipe.position(id)?.x ?? self.plannedFrame[id]?.minX).map(Double.init)
            }
        }
        if landed { swipeBars = nil }
    }

    /// The swipe is over (or was cut short): the bars go where the newest plan has them.
    private func landBars() {
        if swipeBars != nil { swipeFollow(landed: true) }
        swipeBars = nil
    }

    /// Moves the ribbon bars of display `uuid` to where `x` says their active tab's tile is, or to the plan's own places once
    /// `landed`. Only the panels' frames change (see `TabBarController.update`); a bar whose tile is not on the overlay is out of sight.
    private func rideBars(uuid: String, bars: [TabBar], visible: CGRect, landed: Bool, x: (UInt32) -> Double?) {
        guard bars.contains(where: { !$0.isPinned }) else { return }
        let placed = landed ? bars : bars.map { $0.riding(at: x($0.active)) }
        tabs.update(placed, display: uuid, visible: visible, ribbonArea: ribbonArea(uuid, visible), dimmed: overlayStyle.isOn, animated: false, moving: !landed)
    }

    /// The keyboard move leaves the overlay (fingers took over, or the overlay was torn down): the ring goes, the bars stay put.
    /// True when there was a move.
    @discardableResult
    private func endNav() -> Bool {
        guard nav != nil else { return false }
        flushNavWrites()                                        // the windows still go where the plan put them
        nav = nil
        overlay.removeRing()
        SwipeStats.shared?.navFinish()
        return true
    }

    /// `qa_swipe <dx_total_px> <ms>`: feeds a synthetic three-finger swipe (120 Hz, a little contact noise, positive = viewport
    /// towards later columns) into the real trackpad pipeline, then prints SwipeStats when RIBBON_SWIPE_STATS is set.
    private func qaSwipe(dxTotal: Double, ms: Double) {
        let width = display.frame.width * Self.scrollGain
        let span = -dxTotal / width                      // finger travel in pad widths
        let x0 = span > 0 ? 0.15 : 0.85, hz = 120.0, n = max(2, Int(ms / 1000 * hz)), pre = 12   // pre: fingers rest ~100ms before moving, as they do on a real pad
        SwipeStats.shared?.reset("qa_swipe \(Int(dxTotal))px \(Int(ms))ms", fingersUp: CACurrentMediaTime() + ms / 1000 + Double(pre) / hz, touchDown: CACurrentMediaTime())
        SwipeStats.shared?.startSampling(ids: Array(tracker.elements.keys))
        let q = DispatchQueue(label: "ribbon.qa.swipe", qos: .userInteractive)
        let t0 = CACurrentMediaTime()
        var seed: UInt64 = 42
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.0016 }
        let timer = DispatchSource.makeTimerSource(queue: q)
        var i = 0
        timer.schedule(deadline: .now(), repeating: 1 / hz, leeway: .microseconds(100))
        timer.setEventHandler { [trackpad] in
            let t = t0 + Double(i) / hz
            if i <= n + pre {
                let x = x0 + span * Double(max(0, i - pre)) / Double(n)
                trackpad.process([(1, SIMD2(x + noise(), 0.4)), (2, SIMD2(x + 0.05 + noise(), 0.45)), (3, SIMD2(x - 0.05 + noise(), 0.5))], t)
                i += 1
            } else {
                trackpad.process([], t)
                timer.cancel()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) { SwipeStats.shared?.finish() }
            }
        }
        timer.resume()
    }

    /// Displays came, went or changed (macOS posts several notifications per change, so wait for it to settle).
    private func screenChanged() {
        if commit.overlayUp { endOverlay() }
        overlay.teardown()
        let now = CACurrentMediaTime()                          // a glide lands where it was going (the pacer that stepped it goes)
        applier.swipe.cancelSettle(at: now); applier.swipe.step(at: now)
        pacer.reset()
        landBars()
        snapshots.dropAll()
        curtainTeardown()
        screenSeq += 1
        let seq = screenSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { if let self, self.screenSeq == seq { self.reconcileDisplays() } }
        }
    }

    private func reconcileDisplays() {
        guard started, !paused else { return }
        let now = Screens.all()
        guard !now.isEmpty else { return }
        let connected = Set(now.map(\.uuid))
        let primary = now[0].uuid
        // New and returning displays get a ribbon first, so windows can move onto it; known ones just learn their new frame.
        for info in now {
            if let st = states[info.uuid] {
                st.info = info
                _ = st.engine.handle(.display(id: info.id, frame: info.visible))
            } else {
                states[info.uuid] = makeState(info)
            }
        }
        let live = home.filter { tracker.windows[$0.key] != nil }
        let result = DisplayGeometry.hotplug(homes: live, connected: connected, primary: primary, origins: origin)
        origin = result.origins
        let gone = states.keys.filter { !connected.contains($0) }
        if gone.contains(focusedUUID) { focusedUUID = primary }
        // Keyboard focus stays where it is: remember each target's focused window and give it back after the arrivals.
        var refocus: [String: UInt32] = [:]
        for m in result.moves where refocus[m.to] == nil {
            if let dst = states[m.to], let f = focusedWindow(on: dst) { refocus[m.to] = f }
        }
        for m in result.moves {
            if let dst = states[m.to] { transfer(m.id, to: dst, takeFocus: false, atEnd: true) }
        }
        for (u, f) in refocus where home[f] == u { apply(states[u]!.engine.handle(.windowFocused(f)), on: u, showMap: false) }
        for u in gone { states[u] = nil }
        for u in states.keys.sorted() { apply(states[u]!.engine.handle(.command("gather")), on: u, showMap: false) }
        if let st = states[focusedUUID] { menu.setDesktop(st.desktop) }
        updateWarp()
        noteSharedSpaces()
    }

    /// The focused window of a display's ribbon (the one the ring is on if it lives there, else the focused column's first).
    private func focusedWindow(on st: DisplayState) -> UInt32? {
        if let r = ringFocus, home[r] == st.info.uuid, tracker.windows[r] != nil { return r }
        let map = st.engine.handle(.query).map
        if map.pinFocused, let id = map.pin?.column.lead { return id }
        return map.focusedIndex.flatMap { map.columns.indices.contains($0) ? map.columns[$0].windows.first?.id : nil }
    }

    /// Takes a window out of its display's ribbon and puts it into another's, right of that ribbon's focused column
    /// (or at its end). Not an undo step: undo is per ribbon.
    private func transfer(_ id: UInt32, to dst: DisplayState, takeFocus: Bool, toast: String? = nil, atEnd: Bool = false) {
        guard let w = tracker.windows[id], let src = state(of: id), src !== dst else { return }
        let srcGone = Screens.all().first { $0.uuid == src.info.uuid } == nil
        let hint = src.engine.handle(.query).map.columns.first { $0.windows.contains { $0.id == id } }?.widthFrac
        var w2 = w
        if let f = floatHome[id] ?? tracker.elements[id]?.frame { w2.frame = f }
        for st in states.values { st.parkedFloats.remove(id) }
        floatHome[id] = nil
        if takeFocus { setFocusedDisplay(dst.info.uuid) }
        let out = src.engine.handle(.windowRemoved(id))
        if !srcGone { apply(out, on: src.info.uuid, showMap: false) }
        home[id] = dst.info.uuid
        var plan = dst.engine.handle(added(w2, on: dst, widthHint: hint))
        if atEnd, !w.floating, plan.map.columns.count > 1 { plan = dst.engine.handle(.command("move_to_index", arg: plan.map.columns.count)) }
        if !takeFocus { plan.focus = nil }
        plan.toast = toast
        apply(plan, on: dst.info.uuid, showMap: toast != nil)
    }

    // MARK: displays: focus and moves

    private static func endOfRibbon(_ dir: DisplayDirection) -> String { dir == .left ? "No more windows on the left" : "No more windows on the right" }

    /// The display to use for "other display" actions: the only other one, else right, left, below, above.
    private func otherDisplay() -> DisplayState? {
        let list = infos
        guard list.count > 1 else { return nil }
        if list.count == 2 { return list.first { $0.uuid != focusedUUID }.flatMap { states[$0.uuid] } }
        for d in [DisplayDirection.right, .left, .down, .up] {
            if let n = DisplayGeometry.adjacent(from: focusedUUID, d, in: list) { return states[n.uuid] }
        }
        return nil
    }

    /// Focus moves to another display's ribbon: on its column nearest the entry edge when we crossed there, else where it was.
    private func focusDisplay(_ dst: DisplayState, entering dir: DisplayDirection?) {
        let map = dst.engine.handle(.query).map
        let visible = map.columns.filter(\.visible)
        // A column pinned to the entry edge is the first thing there.
        let pinned = map.pin.flatMap { p in p.column.lead.map { (p.side, $0) } }
        var id: UInt32?
        switch dir {
        case .right?: id = pinned?.0 == .left ? pinned?.1 : visible.first?.windows.first?.id
        case .left?: id = pinned?.0 == .right ? pinned?.1 : visible.last?.windows.first?.id
        default: id = focusedWindow(on: dst)
        }
        setFocusedDisplay(dst.info.uuid)
        if let id {
            send(.command("focus_window", arg: Int(id)), on: dst.info.uuid)
        } else {
            hud.show(map: map, focus: nil, toast: "\(dst.info.name) · empty")
        }
    }

    private func moveFocusedWindow(to dst: DisplayState?) {
        guard let dst, dst !== focusedState, let id = focusedWindow(on: focusedState) else { return }
        origin[id] = nil
        transfer(id, to: dst, takeFocus: true, toast: "Moved to \(dst.info.name)")
    }

    /// Commands that need more than one ribbon: crossing displays at a ribbon's end, and moving windows between displays.
    private func command(_ name: String, _ arg: Int? = nil) {
        if featureCommand(name, arg) { return }      // a command only a Plus feature knows
        switch name {
        case "move_to_display_left", "move_to_display_right":
            let dir: DisplayDirection = name.hasSuffix("left") ? .left : .right
            guard let n = DisplayGeometry.adjacent(from: focusedUUID, dir, in: infos) else {
                hud.show(map: engine.handle(.query).map, focus: focusedByEngine, toast: "No display on the \(dir == .left ? "left" : "right")")
                return
            }
            moveFocusedWindow(to: states[n.uuid])
        case "add_tab_left": addToTabs(-1)
        case "add_tab_right": addToTabs(1)
        case "prev_tab_key": send(.command("prev_tab"))
        case "focus_previous":
            // Inside a tabbed column ⌃⌥Tab steps to the next tab; everywhere else it is "back to the last window".
            let m = engine.handle(.query, log: false).map
            let tabbed = m.pinFocused ? m.pin?.column.tabbed == true : m.focusedIndex.map { m.columns.indices.contains($0) && m.columns[$0].tabbed } ?? false
            if tabbed { send(.command("next_tab")) } else { send(.command(name)) }
        case "toggle_dim":
            let on = settings.otherWindows == OtherWindows.dim.rawValue
            UserDefaults.standard.set(on ? OtherWindows.normal.rawValue : OtherWindows.dim.rawValue, forKey: OtherWindows.key)   // settingsChanged applies it
            hud.show(map: engine.handle(.query, log: false).map, focus: focusedByEngine, toast: on ? "Dimming off" : "Dimming on")
        case "toggle_focus": toggleFocusMode()
        case "width_step": setWidthStep(arg ?? 0)
        case "focus_index": goToWindow(arg ?? 0)
        case "move_to_other_display": moveFocusedWindow(to: otherDisplay())
        case "focus_other_display": if let o = otherDisplay() { focusDisplay(o, entering: nil) }
        case "focus_left", "focus_right":
            let dir: DisplayDirection = name == "focus_left" ? .left : .right
            let plan = engine.handle(.command(name))
            if plan.toast == Self.endOfRibbon(dir), let n = DisplayGeometry.adjacent(from: focusedUUID, dir, in: infos), let dst = states[n.uuid] {
                focusDisplay(dst, entering: dir)
            } else {
                apply(plan)
            }
        case "focus_window":
            if let a = arg, let h = home[UInt32(a)] { setFocusedDisplay(h) }
            send(.command(name, arg: arg))
        default: send(.command(name, arg: arg))
        }
    }

    /// Settings' engine config, with Focus mode's centering on top (so rebuilt engines and new displays keep it).
    private var liveEngineConfig: EngineConfig {
        var c = settings.engineConfig
        if focusSession == .on { c.scroll = "center" }
        return c
    }

    /// Focus mode: blur everything but the focused window, on a hotkey; again to leave. Not saved.
    /// While it is on the focused column is kept in the middle of the screen; leaving keeps the view where it is.
    private func toggleFocusMode() {
        focusSession = focusSession.toggled(setting: OtherWindows(rawValue: settings.otherWindows) ?? .normal)
        let on = focusSession == .on
        let json = "{\"type\":\"command\",\"name\":\"set_scroll\",\"arg\":\"\(liveEngineConfig.scroll)\"}"
        for (uuid, st) in states { apply(st.engine.handle(rawJSON: json, log: false), on: uuid) }
        refreshDim()
        syncFocusMenu()
        var toast = on ? "Focus mode on" : "Focus mode off"
        if on, let hk = Hotkeys.table.first(where: { $0.id == "toggle_focus" }), let b = shortcutStore.effective(hk) {
            toast += " — \(shortcutStore.text(b)) to leave"
        }
        hud.show(map: engine.handle(.query, log: false).map, focus: focusedByEngine, toast: toast)
    }

    private func syncFocusMenu() {
        let hk = Hotkeys.table.first { $0.id == "toggle_focus" }
        menu.setFocusMode(focusSession.mode(setting: OtherWindows(rawValue: settings.otherWindows) ?? .normal) == .blur,
                          keys: hk.flatMap { shortcutStore.effective($0) }.map { shortcutStore.text($0) })
    }

    /// Width hotkeys: the nth step of the active width list (⌃⌥⌘1 = first). A step the list does not have says so.
    private func setWidthStep(_ n: Int) {
        let steps = settings.engineConfig.widthPresets
        guard steps.indices.contains(n - 1) else {
            hud.show(map: engine.handle(.query, log: false).map, focus: focusedByEngine, toast: "Only \(steps.count) width steps")
            return
        }
        send(.setWidth(steps[n - 1]))
    }

    /// Go to window n: the nth column, numbered as the strip numbers them. A number the ribbon does not reach says so
    /// (the core would land on the last column, which is not what a number key means).
    private func goToWindow(_ n: Int) {
        let map = engine.handle(.query, log: false).map
        guard n <= map.columns.count else {
            hud.show(map: map, focus: focusedByEngine, toast: map.columns.isEmpty ? "No windows here" : "Only \(map.columns.count) window\(map.columns.count == 1 ? "" : "s")")
            return
        }
        send(.command("focus_index", arg: n))
    }

    private func settingsChanged() {
        floatRulesChanged()   // the "Always float" list is not part of RibbonSettings
        let new = RibbonSettings.load()
        let old = settings
        guard new != old else { return }
        let liveBefore = liveEngineConfig
        settings = new
        if new.otherWindows != old.otherWindows {   // a new Settings choice wins over the session's
            focusSession = .follow; syncFocusMenu()
        }
        // Gap, default width, placement, scroll mode and width steps all go live over the layout as it is: stacks, tabs,
        // widths, floating windows and the pin stay where they are. (Replaying the windows here rebuilt every ribbon from
        // scratch and threw all of that away.) Before start or while paused the engines only take the values.
        let live = liveEngineConfig
        if live != liveBefore {
            for (uuid, st) in states {
                let plan = st.engine.setConfig(live, log: false)
                if started { apply(plan, on: uuid, showMap: false) }
            }
        }
        if new.otherWindows != old.otherWindows || new.dimLevel != old.dimLevel { refreshDim() }
        if new.modifier != old.modifier { shortcutStore.reload(); registerHotkeys(); hold.modifier = new.modifier }
        if new.threeFingerScroll != old.threeFingerScroll || new.swipeFingers != old.swipeFingers { updateTrackpad() }
        if new.mouseWarp != old.mouseWarp { updateWarp() }
        if new.focusRing != old.focusRing { refreshRing() }
        if new.stripSize != old.stripSize { hud.setSize(new.stripSize) }
    }

    // MARK: actions

    private func perform(_ a: HotkeyAction) {
        hold.keyPressed()
        switch a {
        case .commandBar: if started { hud.hideNow(); bar.toggle() }
        case .pause: if started { togglePause() }
        case .command(let name, let arg): if started, !paused { command(name, arg) }
        }
    }

    private func run(_ a: BarAction) {
        switch a {
        case .focusWindow(let id): if !paused { command("focus_window", Int(id)) }
        case .restoreWindow(let id): if !paused { wantFocus = id; tracker.unshelve(id) }
        case .command(let name): if !paused { command(name) }
        case .commandArg(let name, let n): if !paused { command(name, n) }
        case .pause: togglePause()
        case .shortcuts: showShortcuts()
        case .showMap: showMap()
        case .floatApp(let id, let name, let on): setFloatRule(id: id, name: name, on: on)
        case .setWidth(let f): if !paused { send(.setWidth(f)) }
        }
    }

    /// Summons the ribbon map on purpose (command bar, menu bar) so it can be clicked and dragged.
    private func showMap() {
        guard started, !paused else { return }
        hud.summon(map: engine.handle(.query).map, focus: focusedByEngine)
    }

    private func showShortcuts() { hud.hideNow(); shortcuts.show(store: shortcutStore) }

    private func windowItems() -> [BarItem] {
        guard !paused else { return [] }
        // Current column order from each engine's map, so the list reads left to right; the focused display comes first.
        let order = [focusedState] + states.values.filter { $0 !== focusedState }.sorted { $0.info.frame.minX < $1.info.frame.minX }
        let plans = order.map { ($0, $0.engine.handle(.query)) }
        let multi = states.count > 1
        // Most recently focused first; the current window goes last (you are already there).
        let rank = { (id: UInt32) in self.focusOrder.firstIndex(of: id) ?? Int.max - 1 }
        let windows = plans.flatMap { st, p in (p.map.columns.flatMap(\.windows) + (p.map.pin?.column.windows ?? [])).map { (st, $0) } }
            .sorted { rank($0.1.id) < rank($1.1.id) }
        // Where each window sits: "Column 3", "Column 3, below Notes", "Tab 2 in column 4". Every tab is a jumpable window of its own.
        var place: [UInt32: String] = [:]
        for (_, p) in plans {
            for (ci, c) in p.map.columns.enumerated() {
                for (k, w) in c.windows.enumerated() {
                    place[w.id] = c.tabbed ? "Tab \(k + 1) in column \(ci + 1)"
                        : c.windows.count < 2 ? "Column \(ci + 1)"
                        : k == 0 ? "Column \(ci + 1), top of the stack" : "Column \(ci + 1), below \(c.windows[k - 1].app)"
                }
            }
            for (id, s) in heldPlaces(p.map) { place[id] = s }
        }
        let ordered = windows.filter { $0.1.id != focusOrder.first } + windows.filter { $0.1.id == focusOrder.first }
        func item(_ id: UInt32, app: String, title: String, desktop: Int?, on st: DisplayState) -> BarItem {
            var sub = desktop.map { "\(app) · Desktop \($0)" } ?? place[id].map { "\(app) · \($0)" } ?? app
            if multi, st !== focusedState { sub = desktop == nil ? "\(st.info.name) · \(app)" : "\(st.info.name) · \(sub)" }
            return BarItem(id: "win:\(id)", title: title.isEmpty ? app : title, subtitle: sub,
                           icon: tracker.windows[id].flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon },
                           symbol: "macwindow", action: .focusWindow(id), app: app)
        }
        // Windows on other desktops come after, labelled with their desktop; picking one switches there.
        let elsewhere = plans.flatMap { st, p in
            p.map.desktops.filter { !$0.active }.flatMap { d in d.windows.map { (st: st, id: $0, desktop: d.index) } }
        }.sorted { rank($0.id) < rank($1.id) }
            .compactMap { e in tracker.windows[e.id].map { item(e.id, app: $0.app, title: $0.title, desktop: e.desktop, on: e.st) } }
        let shelf = plans.flatMap { $0.1.shelf }
        let shelved = BarModel.shelfItems(shelf) { s in
            self.tracker.shelved[s.id].flatMap { NSRunningApplication(processIdentifier: $0.window.pid)?.icon }
        }
        return ordered.map { item($0.1.id, app: $0.1.app, title: $0.1.title, desktop: nil, on: $0.0) } + elsewhere + shelved
    }

    /// "Go to Desktop n" for every other desktop that has windows.
    private func desktopItems() -> [BarItem] {
        guard !paused else { return [] }
        let store = shortcutStore
        return engine.handle(.query).map.desktops.filter { !$0.active && $0.count > 0 }.map { d in
            let action = BarAction.commandArg("switch_desktop", d.index)
            return BarItem(id: "desktop:\(d.index)", title: "Go to Desktop \(d.index)", subtitle: "\(d.count) window\(d.count == 1 ? "" : "s")", icon: nil,
                           symbol: "rectangle.stack", action: action, keys: BarModel.keys(for: action, store: store))
        }
    }

    // MARK: QA channel

    private func qaState() {
        guard let path = ProcessInfo.processInfo.environment["RIBBON_QA_OUT"] else { return }
        let displays = states.values.sorted { $0.info.frame.minX < $1.info.frame.minX }.map { st -> [String: Any] in
            let m = st.engine.handle(.query).map
            let i = st.info
            return ["uuid": i.uuid, "name": i.name, "frame": [i.frame.minX, i.frame.minY, i.frame.width, i.frame.height],
                    "desktop": m.desktop, "windows": m.columns.flatMap(\.windows).map(\.id), "pinned": m.pin?.column.windows.map(\.id) ?? []]
        }
        let chain2: [String: Any] = [
            "ring": ring.windowNumber != nil, "ringPhase": "\(ringPhase.phase)", "dim": dim.isShowing, "overlay": dim.debugKind, "focusMode": focusSession == .on, "dimHoles": dim.debugState.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] + ($0.hole.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []) },
            "curtain": curtainQA(),
            "tabBars": tabs.visibleCount, "tabModelWrites": tabs.modelWrites, "tabFrameMoves": tabs.frameMoves, "tabUpdateCalls": tabs.updateCalls, "tabUpdateMs": tabs.updateMs, "tabFrameMs": tabs.frameMs, "overlayRing": overlay.hasRing, "overlayDim": overlay.hasDim, "smoothCard": smoothCard.isShowing, "dragging": dragger.active.map { Int($0) } ?? -1,
            "tabs": states.values.flatMap { $0.engine.handle(.query, log: false).tabBars }.map { ["column": $0.column, "active": Int($0.active), "count": $0.tabs.count, "onScreen": $0.onScreen, "rect": [$0.x, $0.y, $0.w, $0.h]] }]
        let obj: [String: Any] = ["chain2": chain2, "focused": focusedUUID, "displays": displays, "home": home.map { ["\($0.key)": $0.value] },
                                  "warping": warp.isRunning, "warps": warp.warps, "origin": origin.map { ["\($0.key)": $0.value] }]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let line = data + Data("\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: line) }
    }

    private func qaLine(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        switch t {
        case "pause": if !paused { togglePause() }
        case "resume": if paused { togglePause() }
        case "shortcuts": showShortcuts()
        case "settings": SettingsWindow.show()
        case "bar": if started { hud.hideNow(); bar.toggle() }
        case "qa_bar_run": bar.model?.runSelected()
        case _ where t.hasPrefix("qa_type "):   // qa_type <text>: type into the open command bar
            bar.qaType(String(t.dropFirst(8)))
        case "quit": quit()
        case _ where t.hasPrefix("qa_warp "):   // qa_warp x y: act as if the pointer were there (AX coordinates)
            let v = t.split(separator: " ").dropFirst().compactMap { Double($0) }
            if v.count == 2 { warp.moved(at: CGPoint(x: v[0], y: v[1])) }
        case "qa_drag_end": dragger.qaFinish()
        case _ where t.hasPrefix("qa_tab "):   // qa_tab <popOut|moveLeft|moveRight|showAsStack|closeGroup|keepOut> <id>: a tab menu pick, without a pointer
            let a = t.split(separator: " ")
            guard a.count == 3, let id = UInt32(a[2]) else { break }
            let action: TabAction? = switch a[1] {
            case "popOut": .popOut(id); case "moveLeft": .moveLeft(id); case "moveRight": .moveRight(id)
            case "showAsStack": .showAsStack(id); case "closeGroup": .closeGroup(id); case "keepOut": .keepOut(id)
            default: nil }
            if let action { tabAction(action) }
        case "qa_state":   // one JSON line per call to $RIBBON_QA_OUT: displays, focused display, window homes, warp state
            qaState()
        case _ where t.hasPrefix("qa_swipe"):
            let a = t.split(separator: " ").dropFirst().compactMap { Double($0) }
            qaSwipe(dxTotal: a.first ?? 800, ms: a.count > 1 ? a[1] : 400)
        case _ where t.hasPrefix("qa_record "):   // qa_record <seconds> <path.mov>: the main display at 60 fps
            let a = t.split(separator: " ", maxSplits: 2).dropFirst()
            if a.count == 2, let s = Double(a.first!) { QARecorder.shared.record(seconds: s, to: String(a.last!)) }
        default:
            if t.hasPrefix("{") { apply(engine.handle(rawJSON: t)) }
            else {
                let parts = t.split(separator: " ")
                command(String(parts[0]), parts.count > 1 ? Int(parts[1]) : nil)
            }
        }
    }
}

/// Console lines for QA runs only (a native tab switch, ...): written while $RIBBON_PLAN_LOG or $RIBBON_QA_OUT is set, never in
/// everyday use.
enum QALog {
    static func enabled(_ env: [String: String]) -> Bool { env["RIBBON_PLAN_LOG"] != nil || env["RIBBON_QA_OUT"] != nil }
    static let on = enabled(ProcessInfo.processInfo.environment)
    static func note(_ line: @autoclosure () -> String) { if on { NSLog("%@", line()) } }
}

/// Appends every plan JSON line to $RIBBON_PLAN_LOG when set.
final class PlanLog {
    private let path = ProcessInfo.processInfo.environment["RIBBON_PLAN_LOG"]
    func append(_ json: String) {
        guard let path, let data = (json + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: data) }
    }
}

/// Reads lines from the named pipe at $RIBBON_CMD_FIFO when set (automated tests drive Ribbon through it).
final class CommandFIFO {
    private var source: DispatchSourceRead?
    private var buffer = ""

    init?(_ handler: @escaping @MainActor (String) -> Void) {
        guard let path = ProcessInfo.processInfo.environment["RIBBON_CMD_FIFO"] else { return nil }
        if access(path, F_OK) != 0 { mkfifo(path, 0o600) }
        let fd = open(path, O_RDWR | O_NONBLOCK)   // O_RDWR keeps the pipe open between writers
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [unowned self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &bytes, bytes.count)
            guard n > 0 else { return }
            buffer += String(decoding: bytes[..<n], as: UTF8.self)
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl]); buffer.removeSubrange(...nl)
                MainActor.assumeIsolated { handler(line) }
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
