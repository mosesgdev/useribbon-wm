import ApplicationServices
import Foundation

// Usage: axresize <pid> <title> <w>. Sets the width of the first window with that exact title (height kept).
// Like a mouse drag, it grows the right edge; when that would run past the display edge (macOS clamps such a size to the
// screen, so a drag cannot do it either) it drags the left edge instead: the right edge stays, the window moves left first.
guard CommandLine.arguments.count == 4, let pid = pid_t(CommandLine.arguments[1]),
      let width = Double(CommandLine.arguments[3]) else {
    fputs("usage: axresize <pid> <title> <w>\n", stderr)
    exit(2)
}
let title = CommandLine.arguments[2]

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

let app = AXUIElementCreateApplication(pid)
let windows = (attr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { (attr($0, kAXTitleAttribute as String) as? String) == title }) else {
    fputs("no window titled '\(title)'\n", stderr)
    exit(1)
}
var size = CGSize.zero
if let s = attr(window, kAXSizeAttribute as String) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
var origin = CGPoint.zero
if let p = attr(window, kAXPositionAttribute as String) { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
let screenRight = CGDisplayBounds(CGMainDisplayID()).maxX
if origin.x + width > screenRight {
    var moved = CGPoint(x: max(0, origin.x + size.width - width), y: origin.y)
    guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &moved)!) == .success else { exit(1) }
}
var target = CGSize(width: width, height: size.height)
let value = AXValueCreate(.cgSize, &target)!
let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
exit(result == .success ? 0 : 1)
