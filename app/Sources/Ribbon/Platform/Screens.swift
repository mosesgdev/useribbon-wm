import AppKit

enum Screens {
    /// The display with the menu bar (first in NSScreen.screens).
    static var primary: NSScreen? { NSScreen.screens.first }

    /// Set by the controller: the display of the focused window. HUD, command bar and sheets appear there.
    nonisolated(unsafe) static var focusedProvider: () -> NSScreen? = { nil }
    static var focused: NSScreen? { focusedProvider() ?? primary }

    /// Every display, primary first, in AX space, keyed by UUID (duplicates, e.g. mirrored sets, are dropped).
    static func all() -> [DisplayInfo] {
        var seen = Set<String>()
        return NSScreen.screens.compactMap { s in
            let u = uuid(of: s)
            guard seen.insert(u).inserted else { return nil }
            return DisplayInfo(uuid: u, id: displayID(s), name: s.localizedName, frame: axRect(s.frame), visible: axRect(s.visibleFrame))
        }
    }

    static func screen(uuid u: String) -> NSScreen? { NSScreen.screens.first { uuid(of: $0) == u } }

    static func uuid(of s: NSScreen) -> String {
        let id = displayID(s)
        if let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), let str = CFUUIDCreateString(nil, cf) as String? { return str }
        return "display-\(id)"
    }

    static func displayID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 1
    }

    /// "Displays have separate Spaces" (System Settings > Desktop & Dock). Ribbon needs it on with more than one display.
    static var separateSpaces: Bool { NSScreen.screensHaveSeparateSpaces }
    /// System Settings → Desktop & Dock, where "Displays have separate Spaces" lives.
    static func openSpacesSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// The pointer in AX space.
    static func mouseAX() -> CGPoint {
        let p = NSEvent.mouseLocation
        let maxY = NSScreen.screens.first?.frame.maxY ?? p.y
        return CGPoint(x: p.x, y: maxY - p.y)
    }

    /// AppKit (bottom-left origin) -> AX (top-left origin of the primary screen).
    static func axRect(_ r: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? r.maxY
        return CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    /// AX -> AppKit.
    static func appKitRect(_ r: CGRect) -> CGRect { axRect(r) }  // the flip is its own inverse

    static func observe(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in handler() }
    }
}
