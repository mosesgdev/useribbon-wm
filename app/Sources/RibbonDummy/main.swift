import AppKit

// QA helper: `RibbonDummy --count 3 --title-prefix Dummy [--close-after-seconds 5] [--add-after-seconds 4] [--refocus-after-seconds 4]
// [--deminiaturize-after-seconds 4] [--unhide-after-seconds 4] [--away-after-seconds 4 [--away-to same|other]]
// [--tab-in-after-seconds 4 [--tab-in-delay 0.25]]`
let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let count = Int(value("--count") ?? "") ?? 3
let prefix = value("--title-prefix") ?? "Dummy"
let closeAfter = Double(value("--close-after-seconds") ?? "")
let addAfter = Double(value("--add-after-seconds") ?? "")   // opens one more window later, on the primary display (like an app that ignores the mouse)
// Orders window 1 out (alive, off screen, out of the window list: what a Spaces switch does to the windows of the Space left) and
// shows a plain window "<prefix> away" where window 1 was (`--away-to same`, default) or elsewhere (`--away-to other`).
let awayAfter = Double(value("--away-after-seconds") ?? "")
let awayTo = value("--away-to") ?? "same"
// Shows a window "<prefix> tab" where window 1 is, and `--tab-in-delay` seconds later (default 0.25) makes it a native tab of
// window 1 and selects it: the new tab is listed before window 1 becomes a hidden tab (the add-first order).
let tabInAfter = Double(value("--tab-in-after-seconds") ?? "")
let tabInDelay = Double(value("--tab-in-delay") ?? "") ?? 0.25

let minWidth = Double(value("--min-width") ?? "").map { CGFloat($0) }   // the LAST window cannot be narrower than this (like Slack-style apps)
let minHeight = Double(value("--min-height") ?? "").map { CGFloat($0) } // EVERY window refuses to be shorter than this (like WhatsApp / Buzz)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let colors: [NSColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink, .systemGreen, .systemPurple, .systemYellow, .systemRed]
var windows: [NSWindow] = []
// Always open on the primary display (the one Ribbon manages), whatever screen has focus.
let primary = NSScreen.screens.first?.visibleFrame ?? .zero
for i in 0..<count {
    let w = NSWindow(contentRect: NSRect(x: primary.minX + 100 + CGFloat(40 * i), y: primary.minY + 200 - CGFloat(20 * i),
                                         width: 600, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = "\(prefix) \(i + 1)"
    w.isReleasedWhenClosed = false
    let label = NSTextField(labelWithString: "\(i + 1)")
    label.font = .systemFont(ofSize: 160, weight: .bold)
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = colors[i % colors.count].cgColor
    view.addSubview(label)
    NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                 label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    w.contentView = view
    if let m = minWidth, i == count - 1 { w.contentMinSize = NSSize(width: m, height: 200); w.setContentSize(NSSize(width: max(m, 600), height: 500)) }
    if let h = minHeight { w.contentMinSize = NSSize(width: w.contentMinSize.width, height: h); w.setContentSize(NSSize(width: w.frame.width, height: max(h, 500))) }
    w.makeKeyAndOrderFront(nil)
    windows.append(w)
}
if let s = addAfter {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) {
        let w = NSWindow(contentRect: NSRect(x: primary.minX + 300, y: primary.minY + 300, width: 600, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "\(prefix) late"; w.isReleasedWhenClosed = false
        w.contentView = { let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.systemRed.cgColor; return v }()
        w.makeKeyAndOrderFront(nil); windows.append(w)
    }
}
// What an app in the background does on its own (a chat app on a new message): it never activates itself for these.
if let s = Double(value("--refocus-after-seconds") ?? "") {   // makes its first window key again
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { windows.first?.makeKeyAndOrderFront(nil) }
}
if let s = Double(value("--deminiaturize-after-seconds") ?? "") {   // brings its minimized windows back
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { for w in windows where w.isMiniaturized { w.deminiaturize(nil) } }
}
if let s = Double(value("--unhide-after-seconds") ?? "") {   // un-hides itself after a ⌘H
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { app.unhideWithoutActivation() }
}
func plain(_ title: String, _ frame: NSRect, _ color: NSColor) -> NSWindow {
    let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = title; w.isReleasedWhenClosed = false
    w.contentView = { let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = color.cgColor; return v }()
    w.setFrame(frame, display: false)
    return w
}
if let s = awayAfter, let first = windows.first {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) {
        let at = awayTo == "other" ? first.frame.offsetBy(dx: 260, dy: -140) : first.frame
        first.orderOut(nil)
        let w = plain("\(prefix) away", at, .systemBrown)
        w.makeKeyAndOrderFront(nil); windows.append(w)
        print("away \(first.windowNumber) -> \(w.windowNumber)"); fflush(stdout)
    }
}
if let s = tabInAfter, let first = windows.first {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) {
        let w = plain("\(prefix) tab", first.frame, .systemMint)
        w.orderFront(nil); windows.append(w)
        print("tab shown \(w.windowNumber)"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + tabInDelay) {
            first.addTabbedWindow(w, ordered: .above)
            w.makeKeyAndOrderFront(nil)
            print("tab joined \(first.windowNumber) -> \(w.windowNumber) visible=\(first.isVisible)"); fflush(stdout)
        }
    }
}
if let s = closeAfter {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) {
        for w in windows { w.close() }
        windows.removeAll()
    }
}
print("pid \(ProcessInfo.processInfo.processIdentifier)")
fflush(stdout)
app.activate()
app.run()
