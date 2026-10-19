import AppKit
import ApplicationServices

/// Why a window left management. Only `.destroyed`, `.released` and `.terminated` end its restore-on-quit memory.
enum RemovalReason {
    case destroyed, released, terminated, minimized, fullscreen
    var forgetsOriginal: Bool { switch self { case .minimized, .fullscreen: false; default: true } }
}

enum TrackerEvent {
    /// `takesFocus`: the user is with the window's app (see `Foreground`); false for a window an app in the background opened.
    /// `replaced(old, new)`: a native tab group showed another of its windows. The new one takes over the old one's place
    /// (if the ribbon never knew the old one, the new one is simply added: see `takesFocus(_:)`).
    /// `appShown(takesFocus:)`: as for `added`, false when the app was unhidden while the user is in another one.
    case added(ManagedWindow, takesFocus: Bool), removed(UInt32, RemovalReason), replaced(UInt32, ManagedWindow), appHidden(pid_t), appShown(pid_t, front: UInt32?, takesFocus: Bool), focused(UInt32), resized(UInt32, CGRect), moved(UInt32), title(UInt32, String)
}

/// Which window an AX element is. A notification hands over a fresh `AXUIElement` reference every time, and asking it for its
/// window number is a round trip to the app, at event rate while a window is dragged or resized. Elements compare equal
/// (`CFEqual`) to the one the tracker stored when it found the window, so the answer is looked up here instead. An entry lives
/// exactly as long as the tracker holds the element (managed or shelved) and goes with the window.
struct WindowIDCache<Key: Hashable> {
    private var ids: [Key: UInt32] = [:]
    private var keys: [UInt32: Key] = [:]

    subscript(key: Key) -> UInt32? { ids[key] }
    var count: Int { ids.count }

    mutating func remember(_ key: Key, _ id: UInt32) {
        if let old = keys[id], old != key { ids[old] = nil }
        ids[key] = id; keys[id] = key
    }
    mutating func forget(_ id: UInt32) { if let k = keys.removeValue(forKey: id) { ids[k] = nil } }
    mutating func removeAll() { ids = [:]; keys = [:] }
}

/// Latest value per key, delivered once per display frame. The first event of a burst is handled at once (a lone resize waits
/// for no frame; `note` says so) and starts the frame clock; later ones overwrite each other until the next `tick`, which hands
/// back the newest of each, oldest key first. The clock stops after a few quiet ticks, so an idle app runs no link.
struct FrameCoalescer<Key: Hashable, Value> {
    static var quietTicksBeforeStop: Int { 6 }
    private var latest: [Key: Value] = [:]
    private var order: [Key] = []
    private var quiet = 0
    private(set) var clockRunning = false

    /// True: handle this event now and start the clock. False: it is held for the next tick (latest wins).
    mutating func note(_ key: Key, _ value: Value) -> Bool {
        quiet = 0
        guard clockRunning else { clockRunning = true; return true }
        if latest.updateValue(value, forKey: key) == nil { order.append(key) }
        return false
    }

    /// One display frame: the held events, and whether the clock should stop (nothing arrived for a while).
    mutating func tick() -> (batch: [(key: Key, value: Value)], stop: Bool) {
        guard !order.isEmpty else {
            quiet += 1
            let stop = quiet >= Self.quietTicksBeforeStop
            if stop { clockRunning = false }
            return ([], stop)
        }
        quiet = 0
        let batch = order.compactMap { k in latest[k].map { (key: k, value: $0) } }
        latest = [:]; order = []
        return (batch, false)
    }

    /// A key that no longer exists (its window closed): whatever was held for it is dropped.
    mutating func discard(_ key: Key) { if latest.removeValue(forKey: key) != nil { order.removeAll { $0 == key } } }

    mutating func reset() { latest = [:]; order = []; quiet = 0; clockRunning = false }
}

/// Finds manageable windows and reports changes via AXObservers + NSWorkspace notifications.
/// Env RIBBON_ONLY_PIDS / RIBBON_ONLY_BUNDLES restrict management (live-QA safety).
@MainActor
final class WindowTracker {
    var onEvent: ((TrackerEvent) -> Void)?
    private(set) var windows: [UInt32: ManagedWindow] = [:]
    private(set) var elements: [UInt32: AXUIElement] = [:]
    /// Windows that left management but still exist: minimized, or hidden with their app (⌘H). Kept so the command
    /// bar can show them (icon, title) and bring them back through their AX element.
    private(set) var shelved: [UInt32: (window: ManagedWindow, element: AXUIElement, hidden: Bool)] = [:]
    private var hiddenPIDs: Set<pid_t> = []
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var running = false
    private var moveSeq: [UInt32: Int] = [:]     // debounce for moves of windows we do not manage
    private var needsSubscribe: Set<UInt32> = [] // windows whose AX subscriptions failed; retried on the next scan
    /// While the screen is locked AX lists no windows at all: a scan then would "close" every window and lose the layout.
    private var locked = WindowTracker.screenIsLocked()
    private var lockTokens: [NSObjectProtocol] = []
    /// Window enumeration runs on each app's own AX queue. One scan per app at a time; a request that arrives meanwhile reruns it.
    private var scanning: Set<pid_t> = []
    private var rescanFrames: [pid_t: Bool] = [:]
    /// Live frames of the managed windows of one app, read during a periodic check (main queue).
    var onLiveFrames: ((pid_t, [UInt32: CGRect]) -> Void)?
    /// Where Ribbon last put a window (the plan's frame): where its tab group sits when another tab is shown.
    var placedFrame: ((UInt32) -> CGRect?)?
    /// Native tab groups: a vanished window may only have become a hidden tab, so its removal can wait for the tab shown in its place.
    private var tabs = TabPairing()
    /// Destroyed windows waiting for their app's next window-server query (a burst of closes shares one).
    private var vanishing: [pid_t: [UInt32]] = [:]
    private var holdTimer: DispatchWorkItem?
    private let health = AXHealth.shared
    /// Window number of every element the tracker holds (see `WindowIDCache`).
    private var ids = WindowIDCache<AXUIElement>()
    /// Resize notifications of a drag come faster than the screen refreshes: one `.resized` per display frame, the newest.
    private var resizes = FrameCoalescer<UInt32, AXUIElement>()
    private let resizeClock = FramePacer()

    private let onlyPIDs: Set<pid_t>?
    private let onlyBundles: Set<String>?

    init() {
        let env = ProcessInfo.processInfo.environment
        func list(_ k: String) -> [String]? { env[k].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } }
        onlyPIDs = list("RIBBON_ONLY_PIDS").map { Set($0.compactMap { pid_t($0) }) }
        onlyBundles = list("RIBBON_ONLY_BUNDLES").map(Set.init)
        resizeClock.onTick = { [weak self] _ in self?.resizeTick() }
    }

    private func allowed(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, app.processIdentifier != getpid() else { return false }
        if let onlyPIDs, !onlyPIDs.contains(app.processIdentifier) { return false }
        if let onlyBundles, !onlyBundles.contains(app.bundleIdentifier ?? "") { return false }
        return true
    }

    // MARK: lifecycle

    /// Scans everything and returns the windows (focused one last). Further changes arrive via `onEvent`.
    func start() -> [ManagedWindow] {
        if running { stop() }
        running = true
        let saved = onEvent; onEvent = nil
        // Every app is enumerated on its own queue at once; a slow one is not waited for (it arrives through the normal event path).
        let group = DispatchGroup()
        var tickets: [ScanTicket] = []
        for app in NSWorkspace.shared.runningApplications where allowed(app) {
            guard attach(app), let t = beginScan(app.processIdentifier, frames: false, group: group) else { continue }
            tickets.append(t)
        }
        _ = group.wait(timeout: .now() + 1.5)
        for t in tickets { finishScan(t) }
        onEvent = saved
        let nc = NSWorkspace.shared.notificationCenter
        tokens = [
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.appAppeared(app) }
            },
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.detach(app.processIdentifier) }
            },
            nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.appHid(app) }
            },
            nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.appUnhid(app) }
            },
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.appActivated(app) }
            },
        ]
        let dnc = DistributedNotificationCenter.default()
        lockTokens = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = true }
            },
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.locked = false
                    for pid in self.observers.keys { self.rescan(pid, delays: [0.3, 1.2]) }
                }
            },
        ]
        let focused = focusedWindowID()
        return windows.values.sorted { a, b in (a.id == focused ? 1 : 0, a.id) < (b.id == focused ? 1 : 0, b.id) }
    }

    func stop() {
        running = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        lockTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lockTokens = []
        for pid in Array(observers.keys) { dropObserver(pid) }
        windows = [:]; elements = [:]; shelved = [:]; hiddenPIDs = []; needsSubscribe = []; scanning = []; rescanFrames = [:]
        ids.removeAll(); resizes.reset(); resizeClock.stop()
        tabs = TabPairing(); vanishing = [:]; holdTimer?.cancel()
    }

    /// Cheap periodic check: every managed app is re-enumerated (vanished and missed windows) and its windows' frames are
    /// reported through `onLiveFrames`. Apps that are not answering are skipped.
    func checkAll() {
        guard running, !locked else { return }
        for pid in observers.keys { scan(pid, frames: true) }
    }

    func isUnresponsive(_ pid: pid_t) -> Bool { health.isQuarantined(pid) }
    /// The window's live frame, or nil when its app is not answering (never blocks the main thread on a hung app).
    func liveFrame(_ id: UInt32) -> CGRect? {
        guard let el = elements[id], !health.isQuarantined(el.pid) else { return nil }
        return el.frame
    }

    /// The window's frame as the window server has it: one local call, no round trip to the app (and so no wait on a hung one).
    /// A drag reads this on its first move and when the button comes up; AX would cost two round trips each time.
    func serverFrame(_ id: UInt32) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The window's live frame for a drag: the window server's, else AX's.
    func liveBounds(_ id: UInt32) -> CGRect? { serverFrame(id) ?? liveFrame(id) }

    func focusedWindowID() -> UInt32? {
        guard let app = NSWorkspace.shared.frontmostApplication, allowed(app), !health.isQuarantined(app.processIdentifier) else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier).element(kAXFocusedWindowAttribute)?.windowID
    }

    /// Whether a window the ribbon is about to add takes the focus (see `Foreground`).
    func takesFocus(_ w: ManagedWindow) -> Bool { userIsWith(w.pid, window: w.id, "add \(w.id) (\(w.app))") }

    /// Whether the user is with the app of window `id`, or with the app at all when `id` is nil (see `Foreground`). Anything but
    /// "it is the front app" is logged with `what` it was asked for (and how long ago the app launched), so a quiet add or an ignored
    /// focus move can be traced.
    private func userIsWith(_ pid: pid_t, window id: UInt32?, _ what: @autoclosure () -> String) -> Bool {
        let why = Foreground.reason(appIsFront: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                                    systemFocused: systemFocus().map { $0.pid == pid && (id == nil || $0.window == id) } ?? false)
        if why != .front {
            let launched = NSRunningApplication(processIdentifier: pid)?.launchDate.map { String(format: ", launched %.2f s ago", -$0.timeIntervalSinceNow) } ?? ""
            NSLog("ribbon: focus: \(what()) \(why.map { "follows (\($0.rawValue))" } ?? "stays quiet")\(launched)")
        }
        return why != nil
    }

    /// The app and window the system says have the keyboard; nil when that app does not answer.
    private func systemFocus() -> (pid: pid_t, window: UInt32?)? {
        let system = AXUIElementCreateSystemWide()   // the process-wide timeout bounds this; setting one here would change it for every AX call
        guard let app = system.element(kAXFocusedApplicationAttribute), !health.isQuarantined(app.pid) else { return nil }
        AXUIElementSetMessagingTimeout(app, 0.1)
        return (app.pid, app.element(kAXFocusedWindowAttribute)?.windowID)
    }

    // MARK: apps

    private func appAppeared(_ app: NSRunningApplication, delays: [Double] = [0, 0.1, 0.4, 1.2]) {
        guard running, allowed(app) else { return }
        if observers[app.processIdentifier] == nil { attach(app); scan(app.processIdentifier) }
        rescan(app.processIdentifier, delays: delays)
    }

    /// Dock click, Spotlight, ⌘Tab: activating an app does not change its focused window, so no AX focus event follows.
    /// Report the app's focused (else main) window when we manage it, so the ribbon glides to it or switches desktop.
    /// This is also how a launched app's first window gets the focus when it was seen before the app became active (it joined
    /// quietly, and its focus move was ignored): an app still busy launching may not answer at once, so it is asked again shortly.
    private func appActivated(_ app: NSRunningApplication) {
        appAppeared(app, delays: [0.1, 0.4])
        reportFocus(of: app.processIdentifier, retries: [0.1, 0.3])
    }

    private func reportFocus(of pid: pid_t, retries: [Double]) {
        guard running, observers[pid] != nil, !health.isQuarantined(pid) else { return }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        let el = appEl.element(kAXFocusedWindowAttribute) ?? appEl.element(kAXMainWindowAttribute)
        if let id = el?.windowID, windows[id] != nil { onEvent?(.focused(id)); return }
        guard let next = retries.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + next) { [weak self] in
            MainActor.assumeIsolated {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }   // the user moved on meanwhile
                self?.reportFocus(of: pid, retries: Array(retries.dropFirst()))
            }
        }
    }

    /// Rescans repeatedly: Electron/Chrome windows show up late.
    func rescan(_ pid: pid_t, delays: [Double] = [0, 0.1, 0.4, 1.2]) {
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                MainActor.assumeIsolated { if self?.running == true { self?.scan(pid) } }
            }
        }
    }

    /// Registers the app's observer (no AX reads beyond the subscription); false when that failed.
    @discardableResult
    private func attach(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.handle(element, notification as String) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
        subscribeApp(obs, appEl, pid)
        return true
    }

    /// The app-wide notifications: new windows (a native tab included), focus moves, and main-window moves (all a native tab
    /// group says when it shows another tab). An app that is still launching refuses them, so they are retried for a few seconds;
    /// without them its later windows would only be found by the periodic check.
    private func subscribeApp(_ obs: AXObserver, _ appEl: AXUIElement, _ pid: pid_t, attempt: Int = 0) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let results = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
            .map { AXObserverAddNotification(obs, appEl, $0 as CFString, me) }
        guard results.contains(where: { $0 != .success && $0 != .notificationAlreadyRegistered }), attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(1 << min(attempt, 4))) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.observers[pid] === obs else { return }
                self.subscribeApp(obs, appEl, pid, attempt: attempt + 1)
            }
        }
    }

    private func dropObserver(_ pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
    }

    /// ⌘H: every managed window of the app is shelved in one go; the core closes the gaps.
    private func appHid(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard running, allowed(app), !hiddenPIDs.contains(pid) else { return }
        let mine = windows.values.filter { $0.pid == pid }
        hiddenPIDs.insert(pid)
        tabs.drop(pid: pid)   // a window that was waiting for its replacement is shelved with the rest
        guard !mine.isEmpty else { return }
        for w in mine {
            if let el = elements[w.id] { shelved[w.id] = (w, el, true) }
            windows.removeValue(forKey: w.id); elements.removeValue(forKey: w.id)
        }
        onEvent?(.appHidden(pid))
    }

    private func appUnhid(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard running, hiddenPIDs.remove(pid) != nil else { return }
        for (id, s) in shelved where s.hidden && s.window.pid == pid {
            windows[id] = s.window; elements[id] = s.element
            shelved.removeValue(forKey: id)
        }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        let front = (appEl.element(kAXFocusedWindowAttribute) ?? appEl.element(kAXMainWindowAttribute))?.windowID.flatMap { windows[$0] != nil ? $0 : nil }
        // Unhidden behind the user's back (by itself, or by another app) the windows come back quietly; clicking the app in the Dock or
        // ⌘Tab activates it, and the activation's focus report takes the ribbon there if the unhide came first.
        let takes = userIsWith(pid, window: front, "unhide \(app.localizedName ?? "\(pid)")")
        onEvent?(.appShown(pid, front: front, takesFocus: takes))
        rescan(pid)
    }

    /// Brings a shelved window back: unhide the app, or un-minimize through AX. The core re-places it when the
    /// resulting add/shown event arrives.
    func unshelve(_ id: UInt32) {
        guard let s = shelved[id] else { return }
        if s.hidden {
            NSRunningApplication(processIdentifier: s.window.pid)?.unhide()
        } else {
            AXUIElementSetAttributeValue(s.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            NSRunningApplication(processIdentifier: s.window.pid)?.activate()
        }
    }

    private func detach(_ pid: pid_t) {
        dropObserver(pid)
        health.forget(pid); AXQueues.shared.release(pid); scanning.remove(pid); rescanFrames[pid] = nil
        hiddenPIDs.remove(pid)
        tabs.drop(pid: pid)
        for (id, s) in shelved where s.window.pid == pid { shelved.removeValue(forKey: id); ids.forget(id); onEvent?(.removed(id, .terminated)) }
        for w in windows.values where w.pid == pid { remove(w.id, .terminated) }
    }

    // MARK: windows

    private static let managedNotes = [kAXUIElementDestroyedNotification, kAXResizedNotification, kAXMovedNotification,
                                       kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    /// Subscribes; any failure other than "already registered" marks the window for a retry on the next scan.
    private func subscribe(_ obs: AXObserver, _ el: AXUIElement, _ id: UInt32, _ notes: [String]) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        var ok = true
        for n in notes {
            let r = AXObserverAddNotification(obs, el, n as CFString, me)
            if r != .success && r != .notificationAlreadyRegistered { ok = false }
        }
        if ok { needsSubscribe.remove(id) } else { needsSubscribe.insert(id) }
    }

    nonisolated static func screenIsLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// What one enumeration of an app found. Built on the app's queue, applied on main.
    private final class ScanTicket: @unchecked Sendable {
        let pid: pid_t
        let lock = NSLock()
        var done = false, applied = false      // done: `result` is filled; applied: main has used it (main only)
        var result: ScanResult?
        init(pid: pid_t) { self.pid = pid }
    }

    private struct Fresh { let el: AXUIElement; let id: UInt32; let frame: CGRect; let title: String; let floating: Bool; let tabs: [String] }
    private struct ScanResult {
        var ok = false
        var seen = Set<UInt32>()
        var fresh: [Fresh] = []
        var known: [UInt32: AXUIElement] = [:]      // managed windows still listed (for subscription retries)
        var minimized = Set<UInt32>()               // managed windows that are not listed but answer as minimized
        var frames: [UInt32: CGRect] = [:]
        var tabs: [UInt32: [String]] = [:]         // the tab bars of the managed windows asked for
    }

    /// Reads everything a scan needs. Runs on the app's AX queue; touches no tracker state.
    /// `tabsOf`: managed windows whose tab bars to read again (recent newcomers that may have joined a tab group since).
    private nonisolated static func enumerate(_ pid: pid_t, managed: [UInt32: AXUIElement], retrySubscribe: Set<UInt32>,
                                              frames: Bool, tabsOf: Set<UInt32>) -> ScanResult {
        var r = ScanResult()
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref)
        AXHealth.shared.record(pid, err)
        // A failed read is NOT an empty window list: a hung app must not look like an app whose windows all closed.
        let list: [AXUIElement]
        switch err {
        case .success: list = (ref as? [AXUIElement]) ?? []
        case .noValue, .attributeUnsupported: list = []
        default: return r
        }
        r.ok = true
        for el in list {
            guard let id = el.windowID else { continue }
            r.seen.insert(id)
            if managed[id] != nil {
                r.known[id] = el
                if frames, let f = el.frame { r.frames[id] = f }
                if tabsOf.contains(id) { r.tabs[id] = el.nativeTabs }
                continue
            }
            guard el.isStandardWindow, let frame = el.frame, frame.width >= 100, frame.height >= 100 else { continue }
            AXUIElementSetMessagingTimeout(el, 0.25)
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(el, kAXSizeAttribute as CFString, &settable)
            r.fresh.append(Fresh(el: el, id: id, frame: frame, title: el.string(kAXTitleAttribute) ?? "", floating: !settable.boolValue,
                                 tabs: el.nativeTabs))
        }
        for (id, el) in managed where !r.seen.contains(id) && el.bool(kAXMinimizedAttribute) == true { r.minimized.insert(id) }
        // A failed subscription may have missed the miniaturize notification.
        for id in retrySubscribe where managed[id]?.bool(kAXMinimizedAttribute) == true { r.minimized.insert(id) }
        return r
    }

    /// Starts an enumeration on the app's queue. The result is applied on main (by `finishScan`, either through the ticket
    /// the caller waits on, or from the async hop). nil = nothing started.
    private func beginScan(_ pid: pid_t, frames: Bool, group: DispatchGroup? = nil) -> ScanTicket? {
        guard !locked, observers[pid] != nil, !hiddenPIDs.contains(pid), !health.isQuarantined(pid) else { return nil }
        if scanning.contains(pid) { rescanFrames[pid] = (rescanFrames[pid] ?? false) || frames; return nil }
        scanning.insert(pid)
        let managed = elements.filter { windows[$0.key]?.pid == pid }
        let retry = needsSubscribe.filter { windows[$0]?.pid == pid }
        let recent = tabs.recentIDs.filter { windows[$0]?.pid == pid }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App"
        let ticket = ScanTicket(pid: pid)
        group?.enter()
        AXQueues.shared.queue(pid).async { [weak self] in
            let r = Self.enumerate(pid, managed: managed, retrySubscribe: retry, frames: frames, tabsOf: recent)
            ticket.lock.lock(); ticket.result = r; ticket.done = true; ticket.lock.unlock()
            group?.leave()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishScan(ticket, appName: name) } }
        }
        return ticket
    }

    private func scan(_ pid: pid_t, frames: Bool = false) { _ = beginScan(pid, frames: frames) }

    /// Applies a finished enumeration to the tracker (main). A ticket whose result is not ready yet is left for its async hop.
    private func finishScan(_ t: ScanTicket, appName: String? = nil) {
        t.lock.lock(); let r = t.result; let ready = t.done; t.lock.unlock()
        guard ready, !t.applied, let r else { return }
        t.applied = true
        let pid = t.pid
        scanning.remove(pid)
        defer { if let again = rescanFrames.removeValue(forKey: pid), running { scan(pid, frames: again) } }
        guard running, r.ok, let obs = observers[pid], !hiddenPIDs.contains(pid) else { return }
        let name = appName ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App"
        for (id, el) in r.known where needsSubscribe.contains(id) { subscribe(obs, el, id, Self.managedNotes) }
        // Native tab groups: a window that vanished while another of its app appeared in its place is a tab switch, not a close and
        // an open. A vanished window that may be a tab waits a moment for its replacement (and keeps its place meanwhile).
        for id in r.seen { tabs.cancel(id) }
        tabs.refresh(tabs: r.tabs)
        let fresh = r.fresh.filter { windows[$0.id] == nil }
        let vanished = windows.values.filter { $0.pid == pid && !r.seen.contains($0.id) && !r.minimized.contains($0.id) }
        let shown = fresh.filter { shelved[$0.id] == nil }.map {
            NativeTabs.Shown(id: $0.id, pid: pid, frame: $0.frame, siblings: siblings(at: $0.frame, pid: pid), tabs: $0.tabs)
        }
        let held = tabs.heldIDs
        let result = tabs.step(gone: goneInfo(vanished.filter { !held.contains($0.id) }, pid: pid), shown: shown, now: Self.now())
        lookForSuccessor(of: pid, since: held)
        func manage(_ f: Fresh) -> ManagedWindow {
            // Every display is managed; the controller routes the window to a display's ribbon (windows off every display included).
            subscribe(obs, f.el, f.id, Self.managedNotes)
            let w = ManagedWindow(id: f.id, pid: pid, app: name, title: f.title, frame: f.frame, floating: f.floating)
            windows[f.id] = w; elements[f.id] = f.el; ids.remember(f.el, f.id)
            shelved.removeValue(forKey: f.id)   // deminiaturized: the core puts it back where it was
            return w
        }
        func add(_ w: ManagedWindow) { onEvent?(.added(w, takesFocus: takesFocus(w))) }
        // Tab replacements, new windows and closes (a vanished window that waits for its replacement is not among them), in that order.
        for action in result.actions(fresh: fresh.map(\.id), pairable: Set(shown.map(\.id)), managed: Set(windows.keys)) {
            switch action {
            case .replace(let old, let new, let isFresh):
                if !isFresh { replaceTab(old, with: windows[new]) } else if let f = fresh.first(where: { $0.id == new }) { replaceTab(old, with: manage(f)) }
            case .add(let id): if let f = fresh.first(where: { $0.id == id }) { add(manage(f)) }
            case .remove(let id): remove(id, .destroyed)
            }
        }
        // Gone from the list but still answering as minimized.
        for w in windows.values.filter({ $0.pid == pid && !r.seen.contains($0.id) && r.minimized.contains($0.id) }) { remove(w.id, .minimized) }
        for id in needsSubscribe where windows[id]?.pid == pid && r.minimized.contains(id) { remove(id, .minimized) }
        if !r.frames.isEmpty { onLiveFrames?(pid, r.frames.filter { windows[$0.key] != nil }) }
        armHoldTimer()
    }

    // MARK: native tab groups

    nonisolated private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// What the pairing needs to know about windows that left their app's window list: where they were last put, and what the
    /// window server says about them (one cheap query per app, only when something vanished).
    /// `destroyed`: they came through their destroyed notifications (closed, not hidden).
    private func goneInfo(_ ws: [ManagedWindow], pid: pid_t, destroyed: Bool = false) -> [NativeTabs.Gone] {
        guard !ws.isEmpty else { return [] }
        let server = WindowServer.windows(ofPID: pid)
        return ws.map { w in
            NativeTabs.gone(id: w.id, pid: pid, at: placedFrame?(w.id) ?? w.frame, title: w.title, server: server, destroyed: destroyed,
                            unmanaged: { self.windows[$0] == nil && self.shelved[$0] == nil })
        }
    }

    /// The managed windows of an app that sit at `frame`'s corner right now (where Ribbon put them, else where they first were).
    private func siblings(at frame: CGRect, pid: pid_t) -> Set<UInt32> {
        Set(windows.values.filter { $0.pid == pid && NativeTabs.sameCorner(placedFrame?($0.id) ?? $0.frame, frame) }.map(\.id))
    }

    /// A hold that has just begun waits for a tab that no notification announces: look for it until the hold runs out.
    private func lookForSuccessor(of pid: pid_t, since held: Set<UInt32>) {
        if !tabs.heldIDs.subtracting(held).isEmpty { rescan(pid, delays: [0.05, 0.15, 0.3, 0.45]) }
    }

    /// `w` (already managed) takes over `old`'s place in the app.
    private func replaceTab(_ old: UInt32, with w: ManagedWindow?) {
        guard let w, old != w.id, windows[old] != nil else { return }
        windows.removeValue(forKey: old); elements.removeValue(forKey: old)
        needsSubscribe.remove(old); ids.forget(old); resizes.discard(old)   // the old window is a hidden tab now: not ours to follow
        onEvent?(.replaced(old, w))
    }

    /// A managed window's destroyed notification: gone for good, unless a native tab group is about to show another tab in its place.
    /// A burst of closes (close all, quit) shares one window-server query.
    private func vanished(_ id: UInt32) {
        guard let w = windows[id] else { remove(id, .destroyed); return }
        if vanishing[w.pid] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in MainActor.assumeIsolated { self?.settleVanished(w.pid) } }
        }
        vanishing[w.pid, default: []].append(id)
    }

    private func settleVanished(_ pid: pid_t) {
        let gone = (vanishing.removeValue(forKey: pid) ?? []).compactMap { windows[$0] }
        guard running, !gone.isEmpty else { return }
        let held = tabs.heldIDs
        let result = tabs.step(gone: goneInfo(gone.filter { !held.contains($0.id) }, pid: pid, destroyed: true), shown: [], now: Self.now())
        for rep in result.replaced where rep.added { replaceTab(rep.old, with: windows[rep.new]) }
        for id in result.remove { remove(id, .destroyed) }
        lookForSuccessor(of: pid, since: held)   // no notification announces the tab shown in its place
        armHoldTimer()
    }

    /// Wakes up when the oldest held removal runs out, so a window nobody replaced is removed on time.
    private func armHoldTimer() {
        holdTimer?.cancel()
        guard let t = tabs.nextDeadline else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                for id in self.tabs.step(gone: [], shown: [], now: Self.now()).remove { self.remove(id, .destroyed) }
                self.armHoldTimer()
            }
        }
        holdTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, t - Self.now()) + 0.02, execute: item)
    }

    /// Stop managing a window (e.g. the user dragged it to another display) without touching it.
    func release(_ id: UInt32) { remove(id, .released) }

    private func remove(_ id: UInt32, _ reason: RemovalReason) {
        guard let w = windows.removeValue(forKey: id) else {
            // A shelved window that really closes: tell the core to drop its shelf entry.
            if reason == .destroyed, shelved.removeValue(forKey: id) != nil { ids.forget(id); resizes.discard(id); onEvent?(.removed(id, .destroyed)) }
            return
        }
        if reason == .minimized, let el = elements[id] { shelved[id] = (w, el, false) } else { ids.forget(id) }   // a shelved window keeps its element
        elements.removeValue(forKey: id)
        needsSubscribe.remove(id)
        resizes.discard(id)
        tabs.forget(id)
        onEvent?(.removed(id, reason))
    }

    /// The window number of a notification's element: from the cache, else one round trip (remembered when the tracker holds the window).
    private func windowID(of element: AXUIElement) -> UInt32? {
        if let id = ids[element] { return id }
        guard let id = element.windowID else { return nil }
        if windows[id] != nil || shelved[id] != nil { ids.remember(element, id) }
        return id
    }

    /// Reports a window's new size: the live frame is read here, once per display frame, not once per notification. Whether the
    /// window went full screen is one more round trip (milliseconds while its app is busy resizing), so only the first event of
    /// a burst (the flag is already set when the transition starts, before the frames grow) and a window that now fills a
    /// display are asked.
    private func resized(_ id: UInt32, _ element: AXUIElement, firstOfBurst: Bool = false) {
        guard running, windows[id] != nil, let f = element.frame else { return }
        if firstOfBurst || Self.mayBeFullScreen(f, displays: Screens.all().map(\.frame)), element.bool("AXFullScreen") == true { remove(id, .fullscreen); return }
        windows[id]?.frame = f
        onEvent?(.resized(id, f))
    }

    /// A full-screen window fills its display (a notch or the menu bar may leave a few points): anything clearly smaller is not.
    nonisolated static func mayBeFullScreen(_ frame: CGRect, displays: [CGRect]) -> Bool {
        displays.contains { frame.width >= $0.width * 0.9 && frame.height >= $0.height * 0.9 }
    }

    /// Runs the frame clock for a resize burst on the display the window is on.
    private func startResizeClock(near frame: CGRect?) {
        let display = frame.flatMap { f in DisplayGeometry.nearest(to: CGPoint(x: f.midX, y: f.midY), in: Screens.all())?.uuid }
        resizeClock.start(uuid: display ?? "") { display.flatMap { Screens.screen(uuid: $0) } }
    }

    private func resizeTick() {
        let (batch, stop) = resizes.tick()
        for (id, element) in batch { resized(id, element) }
        if stop { resizeClock.stop() }
    }

    private func handle(_ element: AXUIElement, _ name: String) {
        guard running else { return }
        let pid = element.pid
        switch name {
        case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification:
            rescan(pid)
        case kAXFocusedWindowChangedNotification:
            if let id = windowID(of: element), windows[id] != nil {
                // An app in the background moves its own focused window when it opens one: that is not the user going there. Once the
                // app comes to the front `appActivated` reports its focused window.
                if userIsWith(pid, window: id, "AX focus \(id) (\(windows[id]?.app ?? ""))") { onEvent?(.focused(id)) }
            } else { rescan(pid, delays: [0, 0.1, 0.4]) }
        case kAXMainWindowChangedNotification:
            // A native tab group showing another tab: the shown tab becomes the main window, while AX reports no focus move and no
            // destroyed tab. Not a focus event (the app may be in the background); only a window we do not know yet matters.
            if let id = windowID(of: element), windows[id] == nil { rescan(pid, delays: [0, 0.1, 0.4]) }
        case kAXUIElementDestroyedNotification:
            if let id = ids[element] ?? elements.first(where: { CFEqual($0.value, element) })?.key ?? shelved.first(where: { CFEqual($0.value.element, element) })?.key {
                vanished(id)
            }
        case kAXWindowMiniaturizedNotification:
            if let id = windowID(of: element) { remove(id, .minimized) }
        case kAXResizedNotification:
            guard let id = windowID(of: element) else { return }
            if windows[id] == nil { rescan(pid, delays: [0]); return }
            if resizes.note(id, element) { startResizeClock(near: windows[id]?.frame); resized(id, element, firstOfBurst: true) }
        case kAXMovedNotification:
            guard let id = windowID(of: element) else { return }
            if windows[id] != nil { onEvent?(.moved(id)); return }
            // Unmanaged window: once it stops moving, rescan so one dropped on the primary display gets picked up.
            moveSeq[id, default: 0] += 1
            let seq = moveSeq[id]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { if self?.running == true, self?.moveSeq[id] == seq { self?.scan(pid) } }
            }
        case kAXTitleChangedNotification:
            if let id = windowID(of: element), windows[id] != nil { onEvent?(.title(id, element.string(kAXTitleAttribute) ?? "")) }
        default: break
        }
    }
}
