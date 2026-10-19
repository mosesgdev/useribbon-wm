import Foundation

/// Whether the user is with an app right now. A window that opens in an app they are with takes focus; one an app in the background
/// opens (Mail on new mail, a chat app) joins the ribbon quietly, and an app in the background changing its own focused window is not
/// the user going there. Pure, so the self tests can pin every case down.
///
/// How recently the app launched does not count. A first window often comes a moment before macOS makes its app the active one, but
/// an app launched in the background (`open -g`, a login item, a helper another app starts) opens its windows just as soon, and the
/// user may have moved on while a slow app was starting: no grace period can tell these apart, and focusing the window would bring the
/// app to the front. So that window joins quietly, and the app's activation (whenever it comes) reports its focused window, which
/// takes the ribbon there.
enum Foreground {
    /// Why the user is with the app (logged when it is not simply the front app).
    enum Reason: String { case front, systemFocus = "system focus" }

    /// - appIsFront: the app is the frontmost one.
    /// - systemFocused: the window is the one the system says has the keyboard (asked last: it costs an accessibility round trip, and
    ///   `frontmostApplication` can lag a moment behind a launch or ⌘Tab).
    static func reason(appIsFront: Bool, systemFocused: @autoclosure () -> Bool) -> Reason? {
        if appIsFront { return .front }
        return systemFocused() ? .systemFocus : nil
    }

    static func holds(appIsFront: Bool, systemFocused: @autoclosure () -> Bool) -> Bool {
        reason(appIsFront: appIsFront, systemFocused: systemFocused()) != nil
    }
}
