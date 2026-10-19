import ApplicationServices
import Foundation

// Usage: axclose <pid> <title>. Presses the close button of the first window with that exact title.
guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]) else {
    fputs("usage: axclose <pid> <title>\n", stderr)
    exit(2)
}
let title = CommandLine.arguments[2]

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

let app = AXUIElementCreateApplication(pid)
let windows = (attr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { (attr($0, kAXTitleAttribute as String) as? String) == title }),
      let button = attr(window, kAXCloseButtonAttribute as String) else {
    fputs("no closable window titled '\(title)'\n", stderr)
    exit(1)
}
let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
exit(result == .success ? 0 : 1)
