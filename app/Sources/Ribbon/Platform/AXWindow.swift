import AppKit
import ApplicationServices

// The only private symbol we use; every window manager relies on it.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

/// A window we know about. `id` is the CGWindowID.
struct ManagedWindow {
    var id: UInt32
    var pid: Int32
    var app: String
    var title: String
    var frame: CGRect
    var floating: Bool
}

extension AXUIElement {
    func value<T>(_ attr: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    func string(_ attr: String) -> String? { value(attr) }
    func bool(_ attr: String) -> Bool? { (value(attr) as NSNumber?)?.boolValue }
    func element(_ attr: String) -> AXUIElement? {
        guard let v: CFTypeRef = value(attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    func windows() -> [AXUIElement] { value(kAXWindowsAttribute) ?? [] }

    @discardableResult func set(_ attr: String, _ v: CFTypeRef) -> Bool { setStatus(attr, v) == .success }
    @discardableResult func setStatus(_ attr: String, _ v: CFTypeRef) -> AXError { AXUIElementSetAttributeValue(self, attr as CFString, v) }

    var pid: pid_t { var p: pid_t = 0; AXUIElementGetPid(self, &p); return p }

    var windowID: UInt32? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var position: CGPoint? {
        guard let v: AXValue = value(kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v: AXValue = value(kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult func setPosition(_ p: CGPoint) -> AXError { var p = p; return AXValueCreate(.cgPoint, &p).map { setStatus(kAXPositionAttribute, $0) } ?? .failure }
    @discardableResult func setSize(_ s: CGSize) -> AXError { var s = s; return AXValueCreate(.cgSize, &s).map { setStatus(kAXSizeAttribute, $0) } ?? .failure }

    /// Write order matters: shrink first then move, grow after moving (AeroSpace does size,pos,size).
    /// Returns the first error; stops at "cannot complete" (a hung app would otherwise cost a timeout per write).
    @discardableResult func setFrame(_ r: CGRect) -> AXError {
        let a = setSize(r.size)
        if a == .cannotComplete { return a }
        let b = setPosition(r.origin)
        if b == .cannotComplete { return b }
        let c = setSize(r.size)
        return [a, b, c].first { $0 != .success } ?? .success
    }

    /// Disable AXEnhancedUserInterface (animated, janky moves) while `body` runs.
    /// Returns `.cannotComplete` without running `body` when the app does not answer even the flag read (hung app).
    @discardableResult static func withoutEnhancedUI(pid: pid_t, _ body: () -> Void) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &ref)
        if read == .cannotComplete { return read }
        let was = (ref as? NSNumber)?.boolValue ?? false
        if was { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        body()
        if was { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
        return .success
    }

    /// Bring this window to the front without private APIs.
    func focusWindow() { focusWindowStatus() }

    /// Same, and reports whether the app answered at all (`.cannotComplete` = hung).
    @discardableResult func focusWindowStatus() -> AXError {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let a = app.setStatus(kAXFrontmostAttribute, kCFBooleanTrue)
        if a == .cannotComplete { return a }
        setStatus(kAXMainAttribute, kCFBooleanTrue)
        return AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }

    /// Puts this window above other windows without activating its app or making it the app's main window.
    @discardableResult func raiseOnly() -> AXError {
        AXUIElementSetMessagingTimeout(self, 0.25)
        return AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }

    var isStandardWindow: Bool {
        string(kAXRoleAttribute) == kAXWindowRole && string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && bool(kAXMinimizedAttribute) != true && bool("AXFullScreen") != true && bool(kAXModalAttribute) != true
    }

    /// The titles of the tabs in the window's native tab bar (an AXTabGroup of radio buttons among its children); empty when it
    /// shows none. Only the shown tab of a group has one: a hidden tab's window lists no children of that kind.
    var nativeTabs: [String] {
        let kids: [AXUIElement] = value(kAXChildrenAttribute) ?? []
        guard let bar = kids.first(where: { $0.string(kAXRoleAttribute) == kAXTabGroupRole }) else { return [] }
        let tabs: [AXUIElement] = bar.value(kAXTabsAttribute) ?? bar.value(kAXChildrenAttribute) ?? []
        return tabs.filter { $0.string(kAXRoleAttribute) == kAXRadioButtonRole }.map { $0.string(kAXTitleAttribute) ?? "" }
    }
}
