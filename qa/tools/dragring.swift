import CoreGraphics
import Foundation

// Usage: dragring <CGWindowID> <ribbon-pid> [seconds] [dx] [dy]. Drags the window by its title bar with synthetic mouse events
// (the posting process needs Accessibility) along a straight line over [seconds] (default 1.5), then lets go, and samples the
// window server at 240 Hz throughout: where the window is, and where Ribbon's focus ring is (the Ribbon window whose size is the
// window's plus the same margin on every side). Prints how far, and how long, the ring trails the window while it moves, and
// how long it takes to catch up once the button is up. No AX and no Screen Recording: only window-server bounds are read.
guard CommandLine.arguments.count >= 3, let wid = UInt32(CommandLine.arguments[1]), let rpid = Int(CommandLine.arguments[2]) else {
    fputs("usage: dragring <window-id> <ribbon-pid> [seconds] [dx] [dy]\n", stderr)
    exit(2)
}
let args = CommandLine.arguments
let secs = args.count > 3 ? Double(args[3]) ?? 1.5 : 1.5
let dx = args.count > 4 ? Double(args[4]) ?? 600 : 600
let dy = args.count > 5 ? Double(args[5]) ?? 200 : 200
setvbuf(stdout, nil, _IOLBF, 0)

struct Sample { var t: Double; var win: CGRect?; var ring: CGRect? }

func bounds(_ w: [String: Any]) -> CGRect? {
    guard let b = w[kCGWindowBounds as String] else { return nil }
    return CGRect(dictionaryRepresentation: b as! CFDictionary)
}

func snapshot() -> (win: CGRect?, ring: CGRect?) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    guard let win = list.first(where: { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) == wid }).flatMap(bounds) else { return (nil, nil) }
    // The ring: same margin on all four sides around the window's size (a few px of stroke plus its glow).
    let rings = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == rpid }.compactMap(bounds).filter { r in
        let mw = (r.width - win.width) / 2, mh = (r.height - win.height) / 2
        return mw >= 2 && mw <= 40 && abs(mw - mh) <= 1.5
    }
    return (win, rings.min { hypot($0.midX - win.midX, $0.midY - win.midY) < hypot($1.midX - win.midX, $1.midY - win.midY) })
}

let lock = NSLock()
var samples: [Sample] = []
var sampling = true
let t0 = Date()
let sampler = Thread {
    while true {
        lock.lock(); let go = sampling; lock.unlock()
        if !go { break }
        let s0 = Date()
        let (w, r) = snapshot()
        lock.lock(); samples.append(Sample(t: s0.timeIntervalSince(t0), win: w, ring: r)); lock.unlock()
        let spent = Date().timeIntervalSince(s0)
        if spent < 1 / 240.0 { usleep(useconds_t((1 / 240.0 - spent) * 1_000_000)) }
    }
}

guard let start = snapshot().win else { fputs("window \(wid) is not on screen\n", stderr); exit(1) }
let grab = CGPoint(x: start.midX, y: start.minY + 12)       // the title bar
func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: 1)
    e?.post(tap: .cghidEventTap)
}

sampler.start()
post(.mouseMoved, grab); usleep(300_000)
post(.leftMouseDown, grab); usleep(150_000)
let pressAt = Date().timeIntervalSince(t0)
let steps = Int(secs * 120)
for i in 1...steps {
    let f = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: grab.x + dx * f, y: grab.y + dy * f))
    usleep(useconds_t(1_000_000 / 120))
}
usleep(200_000)
let end = CGPoint(x: grab.x + dx, y: grab.y + dy)
post(.leftMouseUp, end)
let upAt = Date().timeIntervalSince(t0)
usleep(1_500_000)
lock.lock(); sampling = false; lock.unlock()
usleep(50_000)

// The ring stands for the window at its centre; how far that is from the window, and how long ago the window was there.
func origin(_ r: CGRect, around w: CGRect) -> CGPoint { CGPoint(x: r.midX - w.width / 2, y: r.midY - w.height / 2) }
let moving = samples.filter { $0.t >= pressAt && $0.t <= upAt }
let path = samples.compactMap { s in s.win.map { (t: s.t, p: $0.origin) } }
var gaps: [Double] = [], lags: [Double] = [], ringMoves = 0, missing = 0
var lastRing: CGPoint?
for s in moving {
    guard let w = s.win else { continue }
    guard let r = s.ring else { missing += 1; continue }
    let o = origin(r, around: w)
    if lastRing != o { ringMoves += 1; lastRing = o }
    gaps.append(hypot(o.x - w.minX, o.y - w.minY))
    // The latest moment, up to now, that the window was nearest the place the ring shows (of equally near ones, the latest: a
    // window that stood still before the drag was there all along).
    if let best = path.filter({ $0.t <= s.t }).reversed().min(by: { hypot($0.p.x - o.x, $0.p.y - o.y) < hypot($1.p.x - o.x, $1.p.y - o.y) }) {
        lags.append((s.t - best.t) * 1000)
    }
}
let caught = samples.first { s in
    guard s.t >= upAt, let w = s.win, let r = s.ring else { return false }
    let o = origin(r, around: w)
    return hypot(o.x - w.minX, o.y - w.minY) <= 2 && samples.filter { $0.t >= s.t }.allSatisfy { x in
        guard let ww = x.win, let rr = x.ring else { return true }
        let oo = origin(rr, around: ww); return hypot(oo.x - ww.minX, oo.y - ww.minY) <= 2
    }
}
func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? .nan : a.sorted()[min(a.count - 1, Int(Double(a.count - 1) * p))] }
func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
let windowMoved = (path.last.map { hypot($0.p.x - start.minX, $0.p.y - start.minY) } ?? 0)
let out: [String: Any] = [
    "window_moved_px": r1(windowMoved),
    "samples_while_dragging": moving.count,
    "ring_missing_samples": missing,
    "ring_moves_while_dragging": ringMoves,
    "ring_hz": r1(Double(ringMoves) / max(upAt - pressAt, 0.001)),
    "gap_px": ["mean": r1(gaps.reduce(0, +) / Double(max(gaps.count, 1))), "p95": r1(pct(gaps, 0.95)), "max": r1(gaps.max() ?? .nan)],
    "lag_ms": ["mean": r1(lags.reduce(0, +) / Double(max(lags.count, 1))), "p95": r1(pct(lags, 0.95)), "max": r1(lags.max() ?? .nan)],
    "catch_up_after_release_ms": caught.map { r1(($0.t - upAt) * 1000) } ?? -1,
]
print(String(decoding: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
