import AppKit

/// Keeps a Ribbon panel (command bar, shortcuts sheet while recording) key through brief borrowings by transient system UI:
/// a notification banner, an alert, a screen-sharing banner, another app's helper panel. The panel only lets go when the user
/// really left: a mouse click elsewhere (within `leaveWindow` seconds), the frontmost app changing through ⌘Tab or the Dock to a
/// regular app, or Esc (the owner handles Esc itself). Otherwise it activates and takes key back. A deliberate ⌘Tab is never fought.
@MainActor
final class KeyKeeper {
    nonisolated static let leaveWindow: TimeInterval = 1.0
    /// Helper processes that show banners and panels without being the app the user switched to.
    nonisolated static let transientBundles: Set<String> = [
        "com.apple.notificationcenterui", "com.apple.UserNotificationCenter", "com.apple.screensharing.agent", "com.apple.ScreenSharing",
        "com.apple.controlcenter", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent",
        "com.apple.systemuiserver", "com.apple.dock", "com.apple.universalcontrol", "com.apple.AirPlayUIAgent",
    ]

    /// Pure: did the user leave? A click elsewhere or an app switch, recent enough to be the cause of the lost key.
    nonisolated static func userLeft(now: Date, lastOutsideClick: Date, lastAppSwitch: Date) -> Bool {
        now.timeIntervalSince(lastOutsideClick) < leaveWindow || now.timeIntervalSince(lastAppSwitch) < leaveWindow
    }

    /// Pure: an activation that is not a switch by the user (menu-less helpers, system UI, Ribbon itself).
    nonisolated static func isTransient(bundleID: String?, regular: Bool, isSelf: Bool) -> Bool {
        isSelf || !regular || (bundleID.map(transientBundles.contains) ?? false)
    }

    private let panel: () -> NSWindow?
    /// Only holds on to the keyboard while true (the bar: always; the sheet: while recording).
    private let holding: () -> Bool
    /// The user left on purpose (or key could not be taken back): the owner closes / ends recording.
    private let onLeft: () -> Void
    private var clickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private(set) var lastOutsideClick = Date.distantPast
    private(set) var lastAppSwitch = Date.distantPast
    /// True once the keeper activated Ribbon to take key back (the owner then hands the keyboard back on Esc).
    private(set) var activatedRibbon = false

    init(panel: @escaping () -> NSWindow?, holding: @escaping () -> Bool, onLeft: @escaping () -> Void) {
        self.panel = panel; self.holding = holding; self.onLeft = onLeft
    }

    func start(window: NSWindow) {
        stop()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastOutsideClick = Date() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostKey() }
        }
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
    }

    func stop() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        if let o = activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); activateObserver = nil }
        activatedRibbon = false
    }

    private func activated(_ app: NSRunningApplication?) {
        guard let app, holding() else { return }
        let transient = Self.isTransient(bundleID: app.bundleIdentifier, regular: app.activationPolicy == .regular,
                                         isSelf: app.processIdentifier == getpid())
        guard !transient else { return }
        lastAppSwitch = Date()
        // The panel keeps the keyboard without being active, so a real switch shows up here, often before or without a resign.
        if let p = panel(), !p.isKeyWindow { onLeft() }
    }

    private func lostKey() {
        guard holding() else { return }
        if Self.userLeft(now: Date(), lastOutsideClick: lastOutsideClick, lastAppSwitch: lastAppSwitch) { onLeft(); return }
        // The activation notice of a ⌘Tab can land a beat after the resign: look again before taking key back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.holding() else { return }
            if Self.userLeft(now: Date(), lastOutsideClick: self.lastOutsideClick, lastAppSwitch: self.lastAppSwitch) { self.onLeft(); return }
            self.reclaim(attempts: 3)
        }
    }

    /// Make the panel key again (activating Ribbon: it is a window the user is working in). Gives up, telling the owner, after a few tries.
    func reclaim(attempts: Int = 1) {
        guard let p = panel(), !p.isKeyWindow else { return }
        if let k = NSApp.keyWindow, k !== p, k.isVisible { return }   // another Ribbon window (Settings) took it on purpose
        NSApp.activate(ignoringOtherApps: true)
        activatedRibbon = true
        p.makeKeyAndOrderFront(nil)
        guard !p.isKeyWindow, attempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.holding(), let p = self.panel(), !p.isKeyWindow else { return }
            if Self.userLeft(now: Date(), lastOutsideClick: self.lastOutsideClick, lastAppSwitch: self.lastAppSwitch) { self.onLeft(); return }
            if attempts > 2 { self.reclaim(attempts: attempts - 1) } else { self.onLeft() }
        }
    }
}
