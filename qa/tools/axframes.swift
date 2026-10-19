import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

// Usage: axframes <pid>. Prints a JSON array of the app's windows: id (CGWindowID), title, x, y, w, h (AX coords).
guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
    fputs("usage: axframes <pid>\n", stderr)
    exit(2)
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

let app = AXUIElementCreateApplication(pid)
var out: [[String: Any]] = []
for window in (attr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
    var id: CGWindowID = 0
    _ = _AXUIElementGetWindow(window, &id)
    var pos = CGPoint.zero
    var size = CGSize.zero
    if let p = attr(window, kAXPositionAttribute as String) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = attr(window, kAXSizeAttribute as String) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
    out.append([
        "id": Int(id),
        "title": (attr(window, kAXTitleAttribute as String) as? String) ?? "",
        "x": Int(pos.x), "y": Int(pos.y), "w": Int(size.width), "h": Int(size.height),
    ])
}
let data = try! JSONSerialization.data(withJSONObject: out)
print(String(decoding: data, as: UTF8.self))
