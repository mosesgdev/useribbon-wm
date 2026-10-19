import Foundation
import CoreGraphics

/// Selftest for how a swipe ends, through the real core: the rest it settles on, and the core being lined up with tiles that
/// are still gliding when the next swipe catches them (run from `SelfTest`).
enum ScrollRestTests {
    static func run(_ check: (Bool, String) -> Void) {
        func win(_ id: UInt32) -> ManagedWindow {
            ManagedWindow(id: id, pid: Int32(id), app: "App\(id)", title: "w\(id)", frame: CGRect(x: 0, y: 0, width: 400, height: 300), floating: false)
        }
        /// `n` half-width columns on a 1000 pt display: columns every 494 pt, the viewport 976 wide, so rests at 0, 494, 988 ... and the end.
        func ribbon(_ n: UInt32) -> Engine {
            let e = Engine()
            _ = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1000, height: 800)))
            for id in 1...n { _ = e.handle(.windowAdded(win(id))) }
            _ = e.handle(.command("focus_index", arg: 1))
            return e
        }
        func lx(_ p: Plan, _ id: UInt32) -> Double { p.frames.first { $0.id == id }?.lx ?? .nan }

        // No pin: a release rests a column against the display's left edge, whatever the fingers did.
        var e = ribbon(5)
        _ = e.handle(.scrollBy(700))
        var plan = e.handle(.scrollEnd(velocity: 0))
        check(lx(plan, 2) == 12 && plan.focus == 3, "swipe release: a slow release settles on the nearest column start and focuses the side it went towards")
        e = ribbon(5)
        _ = e.handle(.scrollBy(150))
        plan = e.handle(.scrollEnd(velocity: 900))
        check(lx(plan, 2) == 12, "swipe release: a flick pages on to the next column, 150 pt of travel or not")
        e = ribbon(5)
        _ = e.handle(.scrollBy(150))
        plan = e.handle(.scrollEnd(velocity: 0))
        check(lx(plan, 1) == 12, "swipe release: a short, slow swipe comes back")
        e = ribbon(5)
        _ = e.handle(.scrollBy(5000))
        plan = e.handle(.scrollEnd(velocity: 0))
        check(lx(plan, 5) + (plan.frames.first { $0.id == 5 }?.w ?? 0) == 1000 - 12 && plan.focus == 5, "swipe release: the end of the ribbon sits flush with the display and focuses the last column")

        // The wire form of the alignment event.
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        let json = (try? enc.encode(Event.scrollTo(3, x: 52))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(json.contains("\"type\":\"scroll_to\"") && json.contains("\"id\":3") && json.contains("\"x\":52"), "scroll_to: the event carries the window and its x")

        // A swipe that catches a release inside the rubber band: the tiles are 40 pt past the start, the core already at the rest.
        e = ribbon(5)
        _ = e.handle(.scrollBy(-100))
        plan = e.handle(.query)
        let past = lx(plan, 1)
        plan = e.handle(.scrollEnd(velocity: 0))
        check(past == 52 && lx(plan, 1) == 12, "catch: the release pulled the ribbon from 40 pt past the start back to it")
        plan = e.handle(.scrollTo(1, x: past))
        check(lx(plan, 1) == past && plan.error == nil, "catch: the core joins the tiles where they are, not part of the way")
        plan = e.handle(.scrollBy(-10))
        check(abs(lx(plan, 1) - past) <= 10, "catch: the first feed moves the tiles by no more than the finger moved")
        // And at the other end.
        e = ribbon(5)
        _ = e.handle(.scrollBy(5000))
        let beyond = lx(e.handle(.query), 5)
        plan = e.handle(.scrollEnd(velocity: 0))
        check(lx(plan, 5) > beyond, "catch: at the end the release pulled the ribbon back too")
        plan = e.handle(.scrollTo(5, x: beyond))
        check(lx(plan, 5) == beyond, "catch: the core joins the tiles 60 pt past the end exactly")
        plan = e.handle(.scrollBy(5))
        check(abs(lx(plan, 5) - beyond) <= 5, "catch: and goes on from there")
    }
}
