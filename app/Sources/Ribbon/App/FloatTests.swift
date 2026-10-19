import Foundation
import CoreGraphics

/// Floating windows on the Swift side: which windows the core floats, which planned frames go stale when one floats (the drift
/// check pulled a floated Finder window back into its old column), and where a window lands when it leaves the ribbon.
enum FloatTests {
    static func run(_ check: (Bool, String) -> Void) {
        let e = Engine()
        var plan = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 38, width: 1440, height: 862)), log: false)
        for id in 1...3 {
            plan = e.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: 100, app: "App\(id)", title: "W\(id)",
                                                       frame: CGRect(x: 50, y: 50, width: 600, height: 500), floating: false)), log: false)
        }
        var known: [UInt32: Bool] = [:]
        var c = Floating.changes(&known, plan: plan)
        check(c.floated.isEmpty && c.tiled.isEmpty && known == [1: false, 2: false, 3: false], "float: windows seen for the first time are no change")
        let planned = plan.frames.map(\.id)
        _ = e.handle(.command("focus_window", arg: 2), log: false)
        plan = e.handle(.command("toggle_float"), log: false)
        c = Floating.changes(&known, plan: plan)
        check(c.floated == [2] && c.tiled.isEmpty && known[2] == true, "float: toggle_float takes window 2 out of the ribbon")
        check(Floating.stale(planned, plan: plan, keep: { _ in false }) == [2], "float: its column frame goes stale, so nothing pulls it back there")
        check(Floating.stale(planned, plan: plan, keep: { $0 == 2 }).isEmpty, "float: a window that is not this plan's to judge keeps its frame")
        let failed = Plan(frames: [], focus: nil, changed: [], map: RibbonMap(columns: [], viewport: Viewport(start: 0, end: 1), focusedIndex: nil),
                          showMap: false, error: "engine returned null", toast: nil, jump: false, floatingParked: [])
        check(Floating.stale(planned, plan: failed, keep: { _ in false }).isEmpty, "float: a failed call forgets nothing")
        check(Floating.changes(&known, plan: failed) == ([], []) && known[2] == true, "float: a failed call changes no state")
        plan = e.handle(.command("toggle_float"), log: false)
        c = Floating.changes(&known, plan: plan)
        check(c.tiled == [2] && c.floated.isEmpty, "float: toggling it back tiles it")
        plan = e.handle(rawJSON: "{\"type\":\"command\",\"name\":\"set_floating\",\"arg\":{\"ids\":[1,3],\"floating\":true}}", log: false)
        c = Floating.changes(&known, plan: plan)
        check(plan.error == nil && c.floated == [1, 3] && plan.map.columns.map { $0.windows.map(\.id) } == [[2]],
              "float: an app put out of the ribbon floats all its windows at once")

        // Where a window goes when it leaves the ribbon: never the full-height column it had.
        let vis = CGRect(x: 0, y: 38, width: 1440, height: 862)
        let tile = CGRect(x: 12, y: 50, width: 702, height: 838)
        let own = CGRect(x: 100, y: 100, width: 900, height: 450)
        check(Floating.frame(remembered: nil, original: own, visible: vis) == own, "float frame: back where it was before Ribbon took it in")
        check(Floating.frame(remembered: CGRect(x: 300, y: 200, width: 700, height: 800), original: own, visible: vis) == CGRect(x: 300, y: 100, width: 700, height: 800),
              "float frame: where it last floated comes first, pulled onto the display")
        check(Floating.frame(remembered: nil, original: CGRect(x: 2000, y: 100, width: 900, height: 450), visible: vis) == CGRect(x: 540, y: 100, width: 900, height: 450),
              "float frame: a frame from another display is pulled onto this one")
        let middle = CGRect(x: 360, y: 167, width: 720, height: 603)
        check(Floating.frame(remembered: nil, original: tile, visible: vis) == middle, "float frame: a full-height original gives a window-sized one in the middle")
        check(Floating.frame(remembered: nil, original: nil, visible: vis) == middle, "float frame: nothing known gives a window-sized one in the middle")
        check(Floating.frame(remembered: CGRect(x: 0, y: 0, width: 40, height: 40), original: nil, visible: vis) == middle, "float frame: a sliver is no frame")
    }
}
