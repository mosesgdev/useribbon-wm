import AppKit
import ApplicationServices

/// `Ribbon --bench-ax <pid>`: AX write latency of one app's first window, to decide which AX tricks pay off.
/// Measures setPosition, setFrame, the AXEnhancedUserInterface read that precedes every write batch, and the same
/// writes after setting AXManualAccessibility (the Electron switch). Prints milliseconds (median / p95 of 200).
enum AXBench {
    static func run(pid: pid_t) -> Int32 {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let win = app.windows().first(where: { $0.isStandardWindow }), let f0 = win.frame else { print("no standard window for pid \(pid)"); return 1 }
        AXUIElementSetMessagingTimeout(win, 1)
        func stats(_ xs: [Double]) -> String {
            let s = xs.sorted()
            return String(format: "median %.3f  p95 %.3f ms", s[s.count / 2], s[Int(Double(s.count) * 0.95)])
        }
        func time(_ n: Int = 200, _ body: (Int) -> Void) -> String {
            var out: [Double] = []
            for i in 0..<n { let t = CACurrentMediaTime(); body(i); out.append((CACurrentMediaTime() - t) * 1000) }
            return stats(out)
        }
        func battery(_ label: String) {
            print("\(label)")
            print("  setPosition              \(time { i in win.setPosition(CGPoint(x: f0.minX + Double(i % 2) * 40, y: f0.minY)) })")
            print("  setFrame (3 writes)      \(time { i in win.setFrame(CGRect(x: f0.minX + Double(i % 2) * 40, y: f0.minY, width: f0.width, height: f0.height)) })")
            print("  read EnhancedUI flag     \(time { _ in _ = app.bool("AXEnhancedUserInterface") })")
            print("  withoutEnhancedUI+write  \(time { i in AXUIElement.withoutEnhancedUI(pid: pid) { win.setPosition(CGPoint(x: f0.minX + Double(i % 2) * 40, y: f0.minY)) } })")
            print("  read frame               \(time { _ in _ = win.frame })")
        }
        var ref: CFTypeRef?
        let eui = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &ref)
        print("pid \(pid) EnhancedUI read: \(eui.rawValue) value \(String(describing: ref))")
        battery("baseline")
        let manual = app.setStatus("AXManualAccessibility", kCFBooleanTrue)
        print("set AXManualAccessibility=true -> AXError \(manual.rawValue) (0 = accepted)")
        if manual == .success { battery("with AXManualAccessibility") }
        win.setFrame(f0)
        return 0
    }
}
