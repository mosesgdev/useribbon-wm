import CoreGraphics
import Foundation

// Usage: wsample <pid> <seconds> [hz]. Samples the window server's bounds of every on-screen window of <pid> (no AX, no
// Screen Recording needed) at [hz] (default 240) and prints one JSON line per sample whose positions changed:
// {"t": seconds since start, "x": {"<CGWindowID>": x, ...}}. What the screen shows, so a glide's real steps, their timing
// and how far apart windows drift can be measured (qa/tools/glide_report.py reads this).
guard CommandLine.arguments.count >= 3, let pid = Int(CommandLine.arguments[1]), let secs = Double(CommandLine.arguments[2]) else {
    fputs("usage: wsample <pid> <seconds> [hz]\n", stderr)
    exit(2)
}
let hz = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 240 : 240
setvbuf(stdout, nil, _IOLBF, 0)

let start = Date()
var last: [String: Int] = [:]
while Date().timeIntervalSince(start) < secs {
    let t0 = Date()
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var xs: [String: Int] = [:]
    for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double else { continue }
        xs[String(id)] = Int(x.rounded())
    }
    if xs != last {
        let line: [String: Any] = ["t": (t0.timeIntervalSince(start) * 1000).rounded() / 1000, "x": xs]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self))
        last = xs
    }
    let spent = Date().timeIntervalSince(t0)
    if spent < 1 / hz { usleep(useconds_t((1 / hz - spent) * 1_000_000)) }
}
