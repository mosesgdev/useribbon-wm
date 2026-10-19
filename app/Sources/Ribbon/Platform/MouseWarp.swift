import AppKit

/// Lets the pointer cross between displays that macOS will not connect (they touch only at a corner, or not at all).
/// Listens with an NSEvent global monitor for mouse movement, which needs no extra permission (only key events do).
@MainActor
final class MouseWarp {
    static let cooldown = 0.05
    private var monitor: Any?
    private var displays: [DisplayInfo] = []
    private var lastWarp = Date.distantPast
    private(set) var warps = 0   // for QA

    var isRunning: Bool { monitor != nil }

    /// Starts or stops listening; with fewer than two displays there is nothing to do.
    func configure(enabled: Bool, displays: [DisplayInfo]) {
        self.displays = displays
        lastWarp = .distantPast
        guard enabled, displays.count > 1 else { stop(); return }
        guard monitor == nil else { return }
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.moved() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// The pointer moved (also callable from QA with an explicit location).
    func moved(at p: CGPoint = Screens.mouseAX()) {
        guard Date().timeIntervalSince(lastWarp) > Self.cooldown,
              let dest = DisplayGeometry.warpDestination(from: p, in: displays),
              CGDisplayIsActive(dest.display.id) != 0, CGDisplayBounds(dest.display.id).contains(dest.point) else { return }
        lastWarp = Date()
        warps += 1
        CGWarpMouseCursorPosition(dest.point)
        // Hover states and anything following the pointer update only after a real move event.
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: dest.point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
