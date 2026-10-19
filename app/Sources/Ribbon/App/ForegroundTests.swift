import Foundation
import CoreGraphics

/// Self tests for "a window an app in the background opens does not steal focus": the foreground decision, and the real core behind it.
enum ForegroundTests {
    static func run(_ check: (Bool, String) -> Void) {
        decision(check)
        engine(check)
    }

    private static func decision(_ check: (Bool, String) -> Void) {
        func holds(front: Bool = false, system: Bool = false) -> Bool { Foreground.holds(appIsFront: front, systemFocused: system) }
        check(holds(front: true), "foreground: a window of the frontmost app takes focus")
        check(!holds(), "foreground: a window of an app in the background does not, however recently it launched (open -g opens windows just as soon)")
        check(holds(system: true), "foreground: the window the system has focused counts, even while the front app lookup lags")
        check(holds(front: true, system: false), "foreground: any one reason is enough")
        check(Foreground.reason(appIsFront: true, systemFocused: true) == .front && Foreground.reason(appIsFront: false, systemFocused: true) == .systemFocus
              && Foreground.reason(appIsFront: false, systemFocused: false) == nil, "foreground: the reason logged is the first one that holds")
        // The accessibility round trip is the last resort: asked only when nothing cheaper decides.
        var asked = 0
        func system(_ answer: Bool) -> Bool { asked += 1; return answer }
        _ = Foreground.holds(appIsFront: true, systemFocused: system(true))
        check(asked == 0, "foreground: the system focus is not asked for when the app is in front")
        check(!Foreground.holds(appIsFront: false, systemFocused: system(false)) && asked == 1, "foreground: ... but it is asked for otherwise")
    }

    private static func engine(_ check: (Bool, String) -> Void) {
        func win(_ id: UInt32) -> ManagedWindow {
            ManagedWindow(id: id, pid: Int32(id), app: "App\(id)", title: "w\(id)", frame: CGRect(x: 0, y: 0, width: 400, height: 300), floating: false)
        }
        func shown(_ p: Plan) -> [UInt32: Int] { Dictionary(p.frames.filter(\.onScreen).map { ($0.id, Int($0.x)) }, uniquingKeysWith: { $1 }) }
        func ready() -> Engine {
            let e = Engine()
            _ = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1440, height: 875)))
            for id in UInt32(1)...4 { _ = e.handle(.windowAdded(win(id))) }
            _ = e.handle(.command("focus_window", arg: 1))
            _ = e.handle(.scrollBy(900))   // the viewport moved on; focus is still on the first column, now out of view
            return e
        }

        // Default: today's behaviour (focus and reveal), and the field is only on the wire when it says no.
        var e = ready()
        var plan = e.handle(.windowAdded(win(9)))
        check(plan.focus == 9 && plan.map.focusedIndex == 1, "foreground add: the window takes focus and the ribbon goes to it")
        let enc = JSONEncoder(); enc.keyEncodingStrategy = .convertToSnakeCase
        func json(_ ev: Event) -> String { (try? enc.encode(ev)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        check(!json(.windowAdded(win(9))).contains("take_focus") && json(.windowAdded(win(9), takeFocus: false)).contains("\"take_focus\":false"),
              "foreground add: the protocol field is optional and only sent for a background window")

        // A window an app in the background opened: in its place, but nobody's focus or view moves.
        e = ready()
        let before = e.handle(.query)
        plan = e.handle(.windowAdded(win(9), takeFocus: false))
        check(plan.error == nil && plan.focus == nil && plan.map.focusedIndex == 0, "background add: focus stays, and none is asked of the OS")
        check(plan.map.columns.map(\.windows.first?.id) == [1, 9, 2, 3, 4], "background add: it joins right of the focused column like any other")
        let now = shown(plan), was = shown(before)
        check(!was.isEmpty && was.allSatisfy { now[$0.key] == $0.value }, "background add: left of the viewport, the windows in view stay where they are on screen")
        check(plan.frames.first { $0.id == 9 }?.onScreen == false, "background add: the new window waits out of view")

        // A launched app's first window is often seen a moment before the app is active: it joins quietly, and the app's activation
        // reports it as focused (the tracker asks again while a launching app does not answer yet), which focuses and reveals it.
        plan = e.handle(.windowFocused(9))
        check(plan.map.focusedIndex == 1 && plan.frames.first { $0.id == 9 }?.onScreen == true, "background add: once its app is active the window is focused and revealed")

        // An app that brings a window back by itself (un-minimized, un-hidden) while the user is in another app: back in its place, quietly.
        func order(_ p: Plan) -> [UInt32?] { p.map.columns.map(\.windows.first?.id) }
        e = ready()
        _ = e.handle(.windowMinimized(3))
        _ = e.handle(.command("focus_window", arg: 1))
        var was2 = shown(e.handle(.query))
        plan = e.handle(.windowAdded(win(3), takeFocus: false))
        check(plan.error == nil && plan.focus == nil && plan.map.focusedIndex == 0 && !plan.showMap, "background unminimize: focus stays, no map, nothing asked of the OS")
        check(order(plan) == [1, 3, 2, 4] && plan.shelf.isEmpty, "background unminimize: right of the focused column, as a foreground return would be")
        check(shown(plan).filter { was2[$0.key] != nil }.allSatisfy { was2[$0.key] == $0.value }, "background unminimize: what is in view stays where it is")
        plan = e.handle(.windowAdded(win(9)))   // the shelf is empty again: a fresh foreground window still takes focus
        check(plan.focus == 9 && plan.showMap, "background unminimize: the next foreground add still focuses and shows the map")

        e = ready()
        _ = e.handle(.appHidden(3))
        _ = e.handle(.command("focus_window", arg: 1))
        was2 = shown(e.handle(.query))
        plan = e.handle(.appShown(3, front: 3, takeFocus: false))
        check(plan.error == nil && plan.focus == nil && plan.map.focusedIndex == 0 && !plan.showMap && order(plan) == [1, 3, 2, 4],
              "background unhide: the app's windows come back in place; focus, map and view stay put")
        check(shown(plan).filter { was2[$0.key] != nil }.allSatisfy { was2[$0.key] == $0.value }, "background unhide: what is in view stays where it is")
        check(!json(.appShown(3, front: 3)).contains("take_focus") && json(.appShown(3, front: 3, takeFocus: false)).contains("\"take_focus\":false"),
              "background unhide: the protocol field is optional and only sent when it says no")
        plan = e.handle(.windowFocused(3))   // the user ⌘Tabs there afterwards
        check(plan.map.focusedIndex == 1 && plan.frames.first { $0.id == 3 }?.onScreen == true, "background unhide: going to the app afterwards focuses and reveals it")
        e = ready()
        _ = e.handle(.appHidden(3))
        plan = e.handle(.appShown(3, front: 3))
        check(plan.focus == 3 && plan.showMap, "foreground unhide: the front window takes focus, as before")
    }
}
