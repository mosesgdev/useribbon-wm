import Foundation
import CoreGraphics
import SwiftUI

/// Selftest for the pure ribbon-map logic and the command payloads it sends (run from `SelfTest`).
enum HUDLogicTests {
    static func run(_ check: (Bool, String) -> Void) {
        typealias L = HUDLayout
        // The numbers below are the Small (slim) strip's; "Strip size" re-checks the geometry at every size.
        let savedSize = L.size
        L.size = .small
        defer { L.size = savedSize }
        // Reconcile only adopts sizes of windows fully inside the display.
        let disp = CGRect(x: 0, y: 38, width: 1000, height: 800)
        let inside = CGRect(x: 500, y: 50, width: 400, height: 700)
        let t0 = Date()
        check(!Reconcile.throttled(Array(repeating: t0, count: 5), now: t0), "reconcile: 5 quick refusals still allowed")
        check(Reconcile.throttled(Array(repeating: t0, count: 6), now: t0), "reconcile: 6 inside 3 s is a loop, stop reporting")
        check(!Reconcile.throttled(Array(repeating: t0, count: 6), now: t0.addingTimeInterval(4)), "reconcile: old reports expire")
        check(Reconcile.eligible(planned: inside, live: inside, display: disp), "reconcile: fully visible window is eligible")
        let clipped = CGRect(x: 800, y: 50, width: 400, height: 700)
        check(!Reconcile.eligible(planned: clipped, live: clipped, display: disp), "reconcile: window clipped by the right edge is not")
        check(!Reconcile.eligible(planned: inside, live: clipped, display: disp), "reconcile: live frame drifting off the edge is not")
        check(!Reconcile.eligible(planned: CGRect(x: -100, y: 50, width: 400, height: 700), live: inside, display: disp), "reconcile: clipped by the left edge is not")
        check(Reconcile.eligible(planned: CGRect(x: 0, y: 38, width: 1000, height: 800), live: CGRect(x: -1, y: 38, width: 1001, height: 800), display: disp), "reconcile: rounding slack is allowed")
        // Loop guard: one report per (live size, planned width); a changed plan allows a retry.
        let big = CGSize(width: 890, height: 700)
        check(Reconcile.shouldRefuse(last: nil, live: big, plannedWidth: 795), "refuse guard: first mismatch is reported")
        let tried = Reconcile.Attempt(live: big, plannedWidth: 795)
        check(!Reconcile.shouldRefuse(last: tried, live: big, plannedWidth: 795), "refuse guard: same size against the same plan is not retried")
        check(Reconcile.shouldRefuse(last: tried, live: big, plannedWidth: 600), "refuse guard: a changed planned width allows another report")
        check(Reconcile.shouldRefuse(last: tried, live: CGSize(width: 880, height: 700), plannedWidth: 795), "refuse guard: a different live size is reported")
        // Drag distance -> drop slot: the slot whose final position is nearest the dragged tile's centre.
        let uni = Array(repeating: CGFloat(44), count: 7), p = CGFloat(48)
        check(L.slotIndex(from: 2, dx: 0, widths: uni) == 2, "hud: no drag keeps the slot")
        check(L.slotIndex(from: 2, dx: p * 0.49, widths: uni) == 2, "hud: under half a slot stays")
        check(L.slotIndex(from: 2, dx: p * 0.51, widths: uni) == 3, "hud: past half a slot moves right")
        check(L.slotIndex(from: 2, dx: -p * 1.6, widths: uni) == 0, "hud: left drag moves left")
        check(L.slotIndex(from: 5, dx: 9999, widths: uni) == 6 && L.slotIndex(from: 1, dx: -9999, widths: uni) == 0, "hud: slot clamps to the ends")
        let mixed: [CGFloat] = [32, 102, 51, 68]
        check([-10, 20, 50].allSatisfy { L.slotIndex(from: 0, dx: $0, widths: mixed) == 0 }, "hud: a narrow tile stays until it nears the next slot")
        check([56, 70, 100].allSatisfy { L.slotIndex(from: 0, dx: $0, widths: mixed) == 1 }
              && [200, 9999].allSatisfy { L.slotIndex(from: 0, dx: $0, widths: mixed) == 3 }, "hud: mixed widths drop by final position")
        check(L.slotIndex(from: 3, dx: -9999, widths: mixed) == 0 && L.slotIndex(from: 3, dx: -120, widths: mixed) == 1
              && L.slotIndex(from: 3, dx: -60, widths: mixed) == 2 && [-20, 0, 20].allSatisfy { L.slotIndex(from: 3, dx: $0, widths: mixed) == 3 },
              "hud: dragging left over mixed widths")
        // Tile index <-> column index while a tile is dragged: the tiles in between make room.
        check((0..<5).map { L.shift(of: $0, from: 1, to: 3) } == [0, 0, -1, -1, 0], "hud: dragging right shifts the tiles passed to the left")
        check((0..<5).map { L.shift(of: $0, from: 3, to: 1) } == [0, 1, 1, 0, 0], "hud: dragging left shifts the tiles passed to the right")
        check((0..<5).allSatisfy { L.shift(of: $0, from: 2, to: 2) == 0 }, "hud: staying put shifts nothing")
        for (from, to) in [(0, 4), (4, 0), (1, 3), (3, 1), (2, 2)] {
            let order = L.order(count: 5, from: from, to: to)
            let shown = (0..<5).sorted { (a: Int, b: Int) in
                func slot(_ i: Int) -> Int { i == from ? to : i + L.shift(of: i, from: from, to: to) }
                return slot(a) < slot(b)
            }
            check(order == shown && order[to] == from, "hud: slide offsets match the final order (\(from)->\(to))")
        }
        // Commands: single window -> move_to_index {id, 1-based index}; stack -> focus + steps; no-ops send nothing.
        let cols: [[UInt32]] = [[10], [20, 21], [30], [40]]
        check(L.moveCommands(columns: cols, from: 3, to: 0) == [HUDCommand("move_to_index", .move(id: 40, index: 1))], "hud: move_to_index uses the 1-based column")
        check(L.moveCommands(columns: cols, from: 0, to: 3) == [HUDCommand("move_to_index", .move(id: 10, index: 4))], "hud: drop at the end")
        check(L.moveCommands(columns: cols, from: 1, to: 3) == [HUDCommand("focus_window", .int(20)), HUDCommand("move_right"), HUDCommand("move_right")],
              "hud: a stack moves as one column (focus, then step right)")
        check(L.moveCommands(columns: cols, from: 1, to: 0) == [HUDCommand("focus_window", .int(20)), HUDCommand("move_left")], "hud: stack steps left")
        check(L.moveCommands(columns: cols, from: 1, to: 0, focus: 21) == [HUDCommand("focus_window", .int(21)), HUDCommand("move_left")]
              && L.moveCommands(columns: cols, from: 1, to: 0, focus: 40) == [HUDCommand("focus_window", .int(20)), HUDCommand("move_left")],
              "hud: a stack moves with its focused window, never another column's")
        let tabbedMap = RibbonMap(columns: [MapColumn(windows: [MapWindow(id: 1, app: "A", title: "")], widthFrac: 0.5, focused: false, visible: true),
                                            MapColumn(windows: (2...4).map { MapWindow(id: UInt32($0), app: "A", title: "") }, widthFrac: 0.5,
                                                      focused: true, visible: true, tabbed: true, active: 2)],
                                  viewport: Viewport(start: 0, end: 1), focusedIndex: 1)
        check(L.moveCommands(map: tabbedMap, focusID: 1, from: 1, to: 0) == [HUDCommand("focus_window", .int(4)), HUDCommand("move_left")],
              "hud: dragging a tab group keeps its active tab")
        check(L.moveCommands(columns: cols, from: 2, to: 2).isEmpty && L.moveCommands(columns: cols, from: 2, to: 9).isEmpty, "hud: no-op and out-of-range drops send nothing")
        check(L.focusCommand(7) == [HUDCommand("focus_window", .int(7))] && L.desktopCommand(3) == [HUDCommand("switch_desktop", .int(3))], "hud: click payloads")
        // Wire format.
        func wire(_ c: HUDCommand) -> [String: Any] {
            let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
            return ((try? e.encode(Event.command(c))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }
        let mv = wire(HUDCommand("move_to_index", .move(id: 40, index: 1)))
        check(mv["type"] as? String == "command" && mv["name"] as? String == "move_to_index"
              && (mv["arg"] as? [String: Int]) == ["id": 40, "index": 1], "hud: move_to_index wire format is {id, index}")
        check(wire(HUDCommand("focus_window", .int(7)))["arg"] as? Int == 7, "hud: focus_window wire arg is a number")
        check(wire(HUDCommand("move_left"))["arg"] == nil, "hud: argument-less commands send no arg")
        // The real engine accepts those payloads and lands the column where the drag said.
        let engine = Engine()
        _ = engine.handle(.display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)))
        for id in 1...4 {
            _ = engine.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: 100, app: "A\(id)", title: "t", frame: CGRect(x: 0, y: 0, width: 500, height: 500), floating: false)))
        }
        func order(_ p: Plan) -> [[UInt32]] { p.map.columns.map { $0.windows.map(\.id) } }
        var plan = engine.handle(.command(HUDCommand("move_to_index", .move(id: 4, index: 1))))
        check(plan.error == nil && order(plan) == [[4], [1], [2], [3]], "hud: engine applies move_to_index {id, index}")
        plan = engine.handle(.command(HUDCommand("focus_window", .int(3))))
        check(plan.focus == 3, "hud: engine applies focus_window")
        plan = engine.handle(.command("focus_index", arg: 2)); plan = engine.handle(.command("stack"))   // 1 joins 4's column
        let stack = order(plan)
        check(stack == [[4, 1], [2], [3]], "hud: fixture has a stack")
        let ids = stack
        for c in L.moveCommands(columns: ids, from: 0, to: 2) { plan = engine.handle(.command(c)) }
        check(order(plan) == [[2], [3], [4, 1]], "hud: dragging a stack moves the whole column")
        // Strip geometry.
        func mapOf(_ fracs: [Double], visible: ClosedRange<Int>? = nil, focus: Int = 0, desktop: Int = 1, used: [Int] = []) -> RibbonMap {
            var m = RibbonMap(columns: fracs.enumerated().map { i, f in
                MapColumn(windows: [MapWindow(id: UInt32(i + 1), app: "A", title: "")], widthFrac: f, focused: i == focus,
                          visible: visible?.contains(i) ?? true) }, viewport: Viewport(start: 0, end: 1), focusedIndex: fracs.isEmpty ? nil : focus)
            m.desktop = desktop
            m.desktops = (1...9).map { DesktopInfo(index: $0, count: used.contains($0) ? 1 : 0, active: $0 == desktop, windows: []) }
            return m
        }
        func strip(_ m: RibbonMap) -> HUDStrip { HUDStrip(map: m, focusID: m.focusedIndex.map { UInt32($0 + 1) }) }
        check(L.pillRadius == L.tileRadius + L.padX, "hud: pill and tile corners are concentric")
        check([0.1, 0.25, 1 / 3, 0.5, 2 / 3, 1, 3].map { L.tileWidth(frac: $0) } == [32, 32, 34, 51, 68, 102, 104], "hud: tiles are drawn to scale, within limits")
        let laid = L.tiles(widths: [51, 34, 68])
        check(laid.map(\.x) == [0, 55, 93] && laid.last.map { $0.x + $0.w } == 161, "hud: tiles sit one gap apart")
        check(L.pillHeight(hasTiles: true) == 78 && L.pillHeight(hasTiles: false) == 36, "hud: the strip is one slim row plus one caption line")
        let five = strip(mapOf(Array(repeating: 0.5, count: 5)))
        check(five.trackW == 271 && five.pillW == 287 && five.pillH == 78 && !five.over && five.shift == 0, "hud: pill hugs the tiles")
        check(strip(mapOf([1])).pillW == L.minPillW, "hud: a single column keeps the minimum width")
        let empty = strip(mapOf([]))
        check(empty.pillW == L.emptyPillW && empty.pillH == 36 && !empty.hasTiles, "hud: an empty desktop is one caption line")
        check(strip(mapOf([0.5, 0.5, 0.5], desktop: 9)).pillW >= 302, "hud: nine desktop dots never squeeze the title out")
        let ten = strip(mapOf(Array(repeating: 0.5, count: 10)))
        check(ten.over && ten.viewW == L.maxTrack && ten.pillW == 540, "hud: width has a max, then the strip scrolls")
        let fourteen = Array(repeating: 0.5, count: 14)
        let midStrip = strip(mapOf(fourteen, visible: 6...8, focus: 7))
        check(midStrip.trackW == 766 && midStrip.shift == 170.5 && midStrip.hiddenLeft == 3 && midStrip.hiddenRight == 2
              && midStrip.fadeL && midStrip.fadeR, "hud: an overflowing strip centres on what is on screen and counts the rest")
        let startStrip = strip(mapOf(fourteen, visible: 0...2, focus: 0))
        check(startStrip.shift == 0 && !startStrip.fadeL && startStrip.fadeR, "hud: scroll clamps at the start, no fade there")
        let endStrip = strip(mapOf(fourteen, visible: 11...13, focus: 13))
        check(endStrip.shift == 286 && !endStrip.fadeR && endStrip.fadeL, "hud: scroll clamps at the end, no fade there")
        let guarded = strip(mapOf(fourteen, focus: 10))
        check(guarded.shift == 215.5 && guarded.tiles[10].x + guarded.tiles[10].w / 2 == guarded.shift + 360, "hud: the focused tile never sits in a fade")
        let vis = [MapColumn(windows: [], widthFrac: 1, focused: false, visible: false), MapColumn(windows: [], widthFrac: 1, focused: false, visible: true),
                   MapColumn(windows: [], widthFrac: 1, focused: false, visible: true), MapColumn(windows: [], widthFrac: 1, focused: false, visible: false)]
        check(L.visibleSpan(vis) == 1...2 && L.visibleSpan([]) == nil, "hud: span of the visible columns")
        // Captions.
        func w(_ id: UInt32, _ app: String, _ title: String) -> MapWindow { MapWindow(id: id, app: app, title: title) }
        let cols2 = [MapColumn(windows: [w(1, "Safari", "Apple")], widthFrac: 0.5, focused: false, visible: true),
                     MapColumn(windows: [w(2, "Hermes", "Chat with Claude")], widthFrac: 0.5, focused: true, visible: true)]
        var map = RibbonMap(columns: cols2, viewport: Viewport(start: 0, end: 1), focusedIndex: 1)
        var cap = HUDCaption.make(map: map, focusID: 2, hoverID: nil, toast: nil)
        check(cap.primary == "Hermes — Chat with Claude" && cap.secondary == "2 of 2", "hud: caption names the focused window, no prefix")
        cap = HUDCaption.make(map: map, focusID: 2, hoverID: 1, toast: nil)
        check(cap.primary == "Safari — Apple" && cap.secondary == "1 of 2", "hud: hover names the hovered window")
        cap = HUDCaption.make(map: map, focusID: 2, hoverID: nil, toast: "Moved")
        check(cap.primary == "Moved" && cap.secondary == "2 of 2", "hud: toast replaces the name")
        map.desktop = 2; map.desktops = (1...9).map { DesktopInfo(index: $0, count: $0 == 2 ? 2 : 0, active: $0 == 2, windows: []) }
        cap = HUDCaption.make(map: map, focusID: 2, hoverID: nil, toast: nil)
        check(cap.secondary == "2 of 2 · Desktop 2" && L.shownDesktops(map) == 2, "hud: secondary line carries the desktop")
        check(HUDCaption.who(w(1, "Hermes", "Hermes")) == "Hermes" && HUDCaption.who(w(1, "Hermes", "")) == "Hermes", "hud: who() drops a repeated app name")
        check(HUDCaption.axLabel(app: "Hermes", index: 3, total: 7, focused: true, offscreen: false) == "Hermes, 4 of 7, focused", "hud: AX label")
        check(HUDCaption.axLabel(app: "Mail", index: 1, total: 7, focused: false, offscreen: false, row: 1, rows: 3) == "Mail, 2 of 7, window 2 of 3"
              && HUDCaption.axLabel(app: "Safari", index: 1, total: 7, focused: true, offscreen: false, tabs: 3) == "Safari, 2 of 7, tab group of 3, focused",
              "hud: AX label names the stack row or the tab group")
        // The strip's one caption line.
        var lineMap = RibbonMap(columns: cols2, viewport: Viewport(start: 0, end: 1), focusedIndex: 1)
        check(HUDCaption.line(map: lineMap, focusID: 2, hoverID: nil) == ("Hermes — Chat with Claude", "2/2", false), "hud: caption line names the focus")
        check(HUDCaption.line(map: lineMap, focusID: 2, hoverID: 1) == ("Safari — Apple", "1/2", true), "hud: caption line previews the hover")
        lineMap.desktops = (1...9).map { DesktopInfo(index: $0, count: $0 == 2 ? 2 : 0, active: $0 == 2, windows: []) }
        check(HUDCaption.line(map: lineMap, focusID: 2, hoverID: 1, hoverDesk: 2) == ("Desktop 2", "2 windows", true)
              && HUDCaption.line(map: lineMap, focusID: 2, hoverID: nil, hoverDesk: 3) == ("Desktop 3", "empty", true), "hud: hovering a dot names the desktop")
        let noMap = RibbonMap(columns: [], viewport: Viewport(start: 0, end: 1), focusedIndex: nil)
        let noCap = HUDCaption.make(map: noMap, focusID: nil, hoverID: nil, toast: nil)
        check(HUDCaption.line(map: noMap, focusID: nil, hoverID: nil) == (noCap.primary, noCap.secondary, false), "hud: empty caption line matches the old notice")
        // Toast pill (design B): the diagram reads the result, the text splits into headline and hint.
        check(ToastDiagram.make(toast: "Width 66\u{00A0}%", map: map, focus: 2) == .width(0.5), "toast: width diagram fills to the focused column's width")
        check(ToastDiagram.make(toast: "Height 66\u{00A0}%", map: map, focus: 2) == .height(0.66), "toast: height diagram reads the percent")
        check(ToastDiagram.make(toast: "Desktop 3 · empty", map: map, focus: 2) == .desk(3, empty: true), "toast: empty desktop draws a dashed number")
        check(ToastDiagram.make(toast: "Undid: move", map: map, focus: 2) == nil, "toast: no diagram when there is nothing to draw")
        check(HUDController.pillText("Tab group: Safari + Mail · ⌃⌥Tab to switch", map: map, focus: 2) == ("Tab group: Safari + Mail", "⌃⌥Tab to switch"), "toast: hint after the dot")
        check(HUDController.pillText("Desktop 3 · empty", map: map, focus: 2) == ("Desktop 3 is empty", "Open a window to start"), "toast: empty desktop says what to do")
        // The pill hugs its words and never outgrows its panel: a long group gives up its hint first, then the middle of its names.
        MainActor.assumeIsolated {
            func pillWidth(_ text: String, _ hint: String?, cap: CGFloat = ToastPillLayout.widest) -> CGFloat {
                let m = ToastModel(); m.text = text; m.hint = hint; m.diagram = .tabs; m.maxWidth = cap
                let panel = CGSize(width: ToastPillLayout.panelWidth(cap: cap), height: ToastPillLayout.panelHeight)
                return NSHostingController(rootView: ToastPill(model: m)).sizeThatFits(in: panel).width
            }
            func width(of toast: String, cap: CGFloat = ToastPillLayout.widest) -> CGFloat {
                let (text, hint) = HUDController.pillText(toast, map: map, focus: 2)
                return pillWidth(text, hint, cap: cap)
            }
            let hint = " · ⌃⌥Tab to switch"
            let two = "Tab group: Safari + Mail" + hint
            let three = "Tab group: Visual Studio Code + Google Chrome + Microsoft PowerPoint" + hint
            let measured = ["Tab group: Safari + Terminal + Xcode" + hint, three, "Tab group: Final Cut Pro + Adobe Photoshop 2026 + Microsoft Word + Sublime Text" + hint]
            check(abs(width(of: two) - width(of: two, cap: 1000)) < 0.5 && width(of: two) < 400, "toast pill: a short toast is as wide as its words, not as wide as its panel")
            check(measured.allSatisfy { width(of: $0) <= ToastPillLayout.widest + 0.5 }, "toast pill: three long app names stay within the cap")
            check(width(of: three) > width(of: two) && width(of: three, cap: 380) <= 380.5, "toast pill: a narrower display cap holds the long toast too")
            let (headline, tail) = HUDController.pillText(three, map: map, focus: 2)
            let alone = pillWidth(headline, nil, cap: 2000)
            check(tail != nil && abs(pillWidth(headline, tail, cap: alone + 4) - alone) < 1, "toast pill: when headline and hint do not both fit, the hint goes and the headline stays whole")
            check(alone > 400 && pillWidth(headline, tail, cap: alone - 60) <= alone - 59.5, "toast pill: a headline that does not fit gives way in its middle")
            check(ToastPillLayout.cap(usable: 3000) == ToastPillLayout.widest && ToastPillLayout.cap(usable: 600) == 552 && ToastPillLayout.cap(usable: 100) == 240,
                  "toast pill: the cap follows a small display and has a floor")
        }
        // Pointer hit-testing (pill coordinates).
        let hitCols = [[1], [2, 3], [4]].enumerated().map { i, ids in
            MapColumn(windows: ids.map { MapWindow(id: UInt32($0), app: "A", title: "") }, widthFrac: 0.5, focused: i == 0, visible: true) }
        var hitMap = RibbonMap(columns: hitCols, viewport: Viewport(start: 0, end: 1), focusedIndex: 0)
        func hit(_ x: CGFloat, _ y: CGFloat, _ m: RibbonMap? = nil) -> HUDHit? { L.hit(CGPoint(x: x, y: y), map: m ?? hitMap, focusID: 1) }
        // Tiles 51 wide at pill x 23.5 / 78.5 / 133.5, y 8...48.
        check(strip(hitMap).viewX == 23.5 && strip(hitMap).pillW == 208, "hud: hit fixture geometry")
        check(hit(49, 28) == .window(col: 0, row: 0), "hud: hit a tile")
        check(hit(104, 14) == .window(col: 1, row: 0), "hud: hit the top of a stack")
        check(hit(104, 42) == .window(col: 1, row: 1), "hud: hit the bottom of a stack")
        check(hit(104, 27.99) == .window(col: 1, row: 0) && hit(104, 28) == .window(col: 1, row: 1), "hud: the stack gap belongs to the lower window")
        check(hit(76.49, 14) == .window(col: 0, row: 0) && hit(76.5, 14) == .window(col: 1, row: 0), "hud: no dead zone between tiles")
        check(hit(23.4, 28) == nil && hit(23.5, 28) == .window(col: 0, row: 0), "hud: hits stop at the strip's edge")
        check(hit(49, 3.9) == nil && hit(49, 4) != nil && hit(49, 51.9) != nil && hit(49, 52) == nil, "hud: the rail takes hits from just above the tiles to the caption")
        let tabMap = RibbonMap(columns: [MapColumn(windows: (1...3).map { MapWindow(id: UInt32($0), app: "A", title: "") }, widthFrac: 0.5,
                                                   focused: true, visible: true, tabbed: true, active: 1)], viewport: Viewport(start: 0, end: 1), focusedIndex: 0)
        check(L.hit(CGPoint(x: 104, y: 28), map: tabMap, focusID: 2) == .window(col: 0, row: 1), "hud: a tab group's tile is its active tab")
        let threeMap = RibbonMap(columns: [MapColumn(windows: (1...3).map { MapWindow(id: UInt32($0), app: "A", title: "") }, widthFrac: 0.5,
                                                     focused: true, visible: true)], viewport: Viewport(start: 0, end: 1), focusedIndex: 0)
        check([14, 42].map { L.hit(CGPoint(x: 104, y: $0), map: threeMap, focusID: 1) } == [.window(col: 0, row: 0), .window(col: 0, row: 1)]
              && L.hit(CGPoint(x: 104, y: 42), map: threeMap, focusID: 3) == .window(col: 0, row: 2),
              "hud: a three-window stack draws two slivers, the lower one following the focus")
        let fiveMap = RibbonMap(columns: [MapColumn(windows: (1...5).map { MapWindow(id: UInt32($0), app: "A", title: "") }, widthFrac: 0.5,
                                                    focused: true, visible: true)], viewport: Viewport(start: 0, end: 1), focusedIndex: 0)
        check(HUDStrip(map: fiveMap, focusID: 5).tiles[0].rows == [0, 4] && L.hit(CGPoint(x: 104, y: 42), map: fiveMap, focusID: 5) == .window(col: 0, row: 4),
              "hud: a deep stack shows the focused window as its lower sliver")
        hitMap.desktop = 2; hitMap.desktops = (1...9).map { DesktopInfo(index: $0, count: $0 <= 2 ? 1 : 0, active: $0 == 2, windows: []) }
        check(strip(hitMap).dotsX0 == 168, "hud: dots sit right-aligned")
        check(hit(172, 65) == .dot(1) && hit(190, 65) == .dot(2) && hit(200.5, 65) == nil && hit(160, 65) == nil, "hud: hit a desktop dot")
        for (desk, used) in [(4, [1, 2, 4]), (9, [1, 9])] {
            var m = hitMap; m.desktop = desk
            m.desktops = (1...9).map { DesktopInfo(index: $0, count: used.contains($0) ? 1 : 0, active: $0 == desk, windows: []) }
            let g = strip(m)
            check(g.dotsX0 + CGFloat(g.dots) * L.dotCell == g.pillW - L.padX && hit(g.pillW - L.padX - 1, 65, m) == .dot(desk)
                  && hit(g.dotsX0 + 1, 65, m) == .dot(1), "hud: \(desk) dots end at the content edge")
        }
        let overMap = mapOf(fourteen, visible: 6...8, focus: 7)
        let og = strip(overMap)
        check(og.pillW == 540 && og.viewX == 30 && og.shift == 170.5, "hud: overflow fixture geometry")
        check(L.hit(CGPoint(x: 270, y: 28), map: overMap, focusID: 8) == .window(col: 7, row: 0) && L.hit(CGPoint(x: 29, y: 28), map: overMap, focusID: 8) == nil,
              "hud: an overflowing strip hits through its scroll, not the count slots")
        // Drawn == hit: the centre of every drawn tile and sliver, and points just inside each tile's share of the gap.
        var mixedMap = mapOf([0.5, 1 / 3, 1, 0.5, 2 / 3], focus: 2)
        mixedMap.columns[1].windows = (10...12).map { MapWindow(id: UInt32($0), app: "A", title: "") }
        mixedMap.columns[3].windows = (20...21).map { MapWindow(id: UInt32($0), app: "A", title: "") }
        for size in StripSize.allCases {
            L.size = size
            for (m, fid) in [(mixedMap, UInt32(3)), (overMap, UInt32(8))] {
                let g = HUDStrip(map: m, focusID: fid)
                var ok = true
                for (i, t) in g.tiles.enumerated() {
                    let cx = g.viewX + t.x - g.shift + t.w / 2
                    guard cx > g.viewX, cx < g.viewX + g.viewW else { continue }
                    for (r, row) in t.rows.enumerated() {
                        let h = L.sliverH(t.rows.count)
                        let y = L.padTop + CGFloat(r) * (h + L.stackGap) + h / 2
                        ok = ok && L.hit(CGPoint(x: cx, y: y), map: m, focusID: fid) == .window(col: i, row: row)
                    }
                    for x in [g.viewX + t.x - g.shift - L.gap / 2 + 0.01, g.viewX + t.x - g.shift + t.w + L.gap / 2 - 0.01]
                    where x >= g.viewX && x < g.viewX + g.viewW {
                        if case .window(let c, _)? = L.hit(CGPoint(x: x, y: L.padTop + 1), map: m, focusID: fid) { ok = ok && c == i } else { ok = false }
                    }
                }
                check(ok, "hud: every drawn tile takes its own clicks (\(size.label))")
            }
        }
        // Strip size (Settings): one scale drives every dimension; Small is the slim strip, Medium the default.
        check(StripSize.from(nil) == .medium && StripSize.from("large") == .large && StripSize.from("huge") == .medium,
              "strip size: Medium unless Settings says otherwise")
        check(StripSize.allCases.map(\.scale) == [1, 1.25, 1.5], "strip size: Small 1x, Medium 1.25x, Large 1.5x")
        for size in StripSize.allCases {
            L.size = size
            let k = size.scale
            func near(_ v: CGFloat, _ small: CGFloat) -> Bool { abs(v - small * k) <= 0.5 }
            check(near(L.pillHeight(hasTiles: true), 78) && near(L.pillHeight(hasTiles: false), 36) && near(L.tileH, 40) && near(L.gap, 4)
                  && near(L.pillRadius, 20) && near(L.iconFrame(rows: 1), 24) && near(L.badgeMin, 13) && near(L.ringW(increased: false), 2)
                  && near(L.nameFont, 12.5) && near(L.padX, 8) && near(L.dotCell, 16), "strip size: \(size.label) scales the strip by \(k)")
            check(L.pillRadius == L.tileRadius + L.padX, "strip size: \(size.label) keeps the corners concentric")
            check(L.iconFrame(rows: 1) < L.tileH && L.iconFrame(rows: 2) <= L.sliverH(2) && L.badgeMin <= L.sliverH(2)
                  && L.nameFont * 1.3 <= L.footH && L.deskDot < L.footH && L.ringW(increased: true) < L.gap,
                  "strip size: \(size.label) fits icons, badge, caption and ring without clipping")
            let g = strip(mapOf(Array(repeating: 0.5, count: 5), desktop: 4, used: [1, 2, 4]))
            check(g.pillH == L.pillHeight(hasTiles: true) && abs(g.trackW - 271 * k) <= 3 && abs(g.pillW - 287 * k) <= 3
                  && g.dotsX0 + CGFloat(g.dots) * L.dotCell == g.pillW - L.padX
                  && L.hit(CGPoint(x: g.pillW - L.padX - 1, y: g.footTop + L.footH / 2), map: mapOf(Array(repeating: 0.5, count: 5), desktop: 4, used: [1, 2, 4]),
                           focusID: 1) == .dot(4),
                  "strip size: \(size.label) pill hugs its tiles and the dots still take clicks")
        }
        L.size = .small
        pinTests(check)
        L.size = .small
        // Hold-to-show state machine (pure, timestamped).
        var m = ModifierHoldMachine()
        m.flags(held: true, any: true, at: 10)
        check(m.tick(at: 10.2) == .none && m.deadline == 10.35, "hold: nothing before 350ms")
        check(m.tick(at: 10.36) == .show && m.isShown, "hold: shows after 350ms")
        m.flags(held: false, any: false, at: 12)
        check(m.tick(at: 12.2) == .none && m.isShown, "hold: stays up 0.4s after release")
        check(m.tick(at: 12.41) == .hide && !m.isShown, "hold: hides 0.4s after release")
        m = ModifierHoldMachine()
        m.flags(held: true, any: true, at: 0); m.keyDown(at: 0.1)
        check(m.tick(at: 0.5) == .none && m.deadline == nil, "hold: a key cancels the pending show")
        m.flags(held: false, any: false, at: 1); m.flags(held: true, any: true, at: 2)
        check(m.tick(at: 2.4) == .show, "hold: works again after release")
        m = ModifierHoldMachine()
        m.flags(held: true, any: true, at: 0); m.flags(held: false, any: false, at: 0.2)
        check(m.tick(at: 1) == .none && !m.isShown, "hold: release before 350ms never shows")
        m = ModifierHoldMachine()
        m.flags(held: true, any: true, at: 0); m.flags(held: false, any: true, at: 0.1)   // shift joined: not a plain hold
        check(m.tick(at: 1) == .none, "hold: an extra modifier cancels")
        m.flags(held: true, any: true, at: 1.1)
        check(m.tick(at: 2) == .none, "hold: cancelled until everything is released")
        m = ModifierHoldMachine()
        m.flags(held: true, any: true, at: 0); _ = m.tick(at: 0.4)
        m.flags(held: false, any: false, at: 1); m.flags(held: true, any: true, at: 1.2); m.keyDown(at: 1.3)
        check(m.tick(at: 2) == .none && m.isShown, "hold: re-holding keeps it up; arrows while shown change nothing")

        // Minimize / hide: the core shelves windows and the command bar lists them with a tag.
        let eng = Engine()
        _ = eng.handle(.display(id: 1, frame: CGRect(x: 0, y: 38, width: 1440, height: 862)))
        func win(_ id: UInt32, _ pid: Int32) -> ManagedWindow {
            ManagedWindow(id: id, pid: pid, app: "P\(pid)", title: "W\(id)", frame: CGRect(x: 0, y: 0, width: 600, height: 500), floating: false)
        }
        for (id, pid) in [(1, 10), (2, 20), (3, 10)] as [(UInt32, Int32)] { _ = eng.handle(.windowAdded(win(id, pid))) }
        var sp = eng.handle(.windowMinimized(2))
        check(sp.frames.count == 2 && sp.shelf == [ShelfItem(id: 2, app: "P20", title: "W2", desk: 1, hidden: false)], "shelf: minimize shelves, plan lists it")
        sp = eng.handle(.windowAdded(win(2, 20)))
        check(sp.shelf.isEmpty && sp.frames.count == 3 && sp.focus == 2, "shelf: re-add restores and focuses")
        sp = eng.handle(.appHidden(10))
        check(sp.frames.count == 1 && sp.shelf.count == 2 && sp.shelf.allSatisfy(\.hidden), "shelf: ⌘H shelves the app's windows")
        sp = eng.handle(.appShown(10, front: 3))
        check(sp.frames.count == 3 && sp.focus == 3 && sp.shelf.isEmpty, "shelf: unhide restores them and focuses the front window")
        let items = MainActor.assumeIsolated {
            BarModel.shelfItems([ShelfItem(id: 5, app: "Notes", title: "", desk: 2, hidden: false),
                                 ShelfItem(id: 6, app: "Mail", title: "Inbox", desk: 1, hidden: true)]) { _ in nil }
        }
        check(items.map(\.badge) == ["Minimized", "Hidden"] && items.map(\.title) == ["Notes", "Inbox"], "bar: shelf rows are tagged")
        check(items.allSatisfy(\.isWindow) && items.map(\.id) == ["win:5", "win:6"], "bar: shelf rows are windows")
        if case .restoreWindow(5) = items[0].action {} else { check(false, "bar: choosing a shelf row restores it") }
    }

    // Fixtures for the pinned column's tests, here and in the Plus edition's own.
    static func win(_ id: UInt32, _ app: String = "A", _ title: String = "") -> MapWindow { MapWindow(id: id, app: app, title: title) }
    static let buzz = win(100, "Buzz", "Inbox"), chat = win(101, "WhatsApp", "Family")
    /// A ribbon of one-window columns (ids 1...) with the pin (`pinWins`, default Buzz) against `side`.
    static func pinned(_ fracs: [Double], side: PinSide = .left, pinFrac: Double = 0.25, pinWins: [MapWindow]? = nil, tabbed: Bool = false,
                       active: Int? = nil, pinFocus: Bool = false, focus: Int = 0, visible: ClosedRange<Int>? = nil) -> RibbonMap {
        var m = RibbonMap(columns: fracs.enumerated().map { i, f in
            MapColumn(windows: [win(UInt32(i + 1))], widthFrac: f, focused: !pinFocus && i == focus, visible: visible?.contains(i) ?? true) },
                          viewport: Viewport(start: 0, end: 1), focusedIndex: fracs.isEmpty || pinFocus ? nil : focus)
        m.pin = MapPin(side: side, column: MapColumn(windows: pinWins ?? [buzz], widthFrac: pinFrac, focused: pinFocus, visible: true,
                                                     tabbed: tabbed, active: active), everyDesktop: true)
        return m
    }
    static func bare(_ m: RibbonMap) -> RibbonMap { var b = m; b.pin = nil; return b }
    static func strip(_ m: RibbonMap, focus: UInt32? = nil) -> HUDStrip {
        HUDStrip(map: m, focusID: focus ?? m.focusedIndex.map { UInt32($0 + 1) })
    }
    static func hit(_ x: CGFloat, _ y: CGFloat, _ m: RibbonMap, focus: UInt32? = nil) -> HUDHit? {
        HUDLayout.hit(CGPoint(x: x, y: y), map: m, focusID: focus ?? m.focusedIndex.map { UInt32($0 + 1) })
    }
    static func wire(_ c: HUDCommand) -> [String: Any] {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
        return ((try? e.encode(Event.command(c))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    /// The pinned column's tile on the strip: sizes, clicks, focus and the drags, from maps built here. (Its caption, its labels, the drags
    /// through the real core and its toasts are the Plus edition's own checks.) Numbers in comments are the Small strip's.
    private static func pinTests(_ check: (Bool, String) -> Void) {
        typealias L = HUDLayout
        let five = Array(repeating: 0.5, count: 5)
        let fourteen = Array(repeating: 0.5, count: 14)

        // Geometry at Small: the pin on the ribbon's scale, at the strip's edge, one glyph gap from the track.
        L.size = .small
        check([0.2, 0.25, 1 / 3, 0.5].map { L.pinTileWidth(frac: $0) } == [34, 34, 51, 102], "pin tile: drawn on the ribbon's scale (f / (1 - f)), never under 34")
        let left = strip(pinned(five, side: .left))
        check(left.pin?.w == 34 && left.pinSide == .left && left.pinX == 8 && left.pinGapX == 42 && left.viewX == 62 && left.pillW == 341 && left.pillH == 78,
              "pin tile: a left pin leads the row, the glyph's gap between it and the track")
        let right = strip(pinned(five, side: .right))
        check(right.pin?.w == 34 && right.pinX == 299 && right.pinGapX == 279 && right.viewX == 8 && right.pillW == 341 && right.pinX + 34 == right.pillW - L.padX,
              "pin tile: a right pin ends the row")
        check(strip(pinned(five, side: .left, pinFrac: 1 / 3)).pin?.w == 51 && strip(pinned(five, side: .left, pinFrac: 0.2)).pin?.w == 34,
              "pin tile: a third is wider than a quarter; a fifth keeps the minimum")
        for size in StripSize.allCases {
            L.size = size
            for side in [PinSide.left, .right] {
                let m = pinned(five, side: side), b = strip(bare(m)), g = strip(m)
                let name = "\(side.label), \(size.label)"
                check(g.pin?.w == max(L.u(34), L.tileWidth(frac: 0.25 / 0.75)), "pin tile: width follows the strip size (\(name))")
                check(g.tiles == b.tiles && g.trackW == b.trackW && g.viewW == b.viewW && g.shift == b.shift && g.over == b.over,
                      "pin tile: the track is the ribbon's alone (\(name))")
                check(g.pillW == g.rowW + 2 * L.padX && g.rowW == b.rowW + L.pinGap + g.pin!.w, "pin tile: the pill holds the pin and its gap (\(name))")
                let gap = side == .left ? g.viewX - (g.pinX + g.pin!.w) : g.pinX - (g.viewX + g.viewW)
                check(gap == L.pinGap && g.pinX >= L.padX && g.pinX + g.pin!.w <= g.pillW - L.padX, "pin tile: one glyph gap from the track, inside the pill (\(name))")
                let y = L.padTop + L.tileH / 2
                check(hit(g.pinX + g.pin!.w / 2, y, m) == .pin(row: 0) && hit(g.viewX + 1, y, m) == .window(col: 0, row: 0)
                      && hit(g.pinGapX + L.pinGap / 2, y, m) == nil, "pin tile: it takes its own clicks, the glyph's gap none (\(name))")
            }
        }
        L.size = .small
        // The track ignores the pin: overflow, fades, counters and the scroll are the ribbon's own.
        let overBare = bare(pinned(fourteen, focus: 7, visible: 6...8)), b0 = strip(overBare)
        for side in [PinSide.left, .right] {
            let g = strip(pinned(fourteen, side: side, focus: 7, visible: 6...8))
            let sameTrack = g.tiles == b0.tiles && g.shift == b0.shift && g.viewW == L.maxTrack && g.over
            let sameFades = g.fadeL && g.fadeR && g.hiddenLeft == 3 && g.hiddenRight == 2
            check(sameTrack && sameFades && g.shift == 170.5, "pin tile: overflow, fades and counters ignore the pin (\(side.label))")
            check(g.pillW == b0.pillW + 54, "pin tile: only the pill's width grows (\(side.label))")
        }
        let startOver = strip(pinned(fourteen, side: .left, focus: 0, visible: 0...2))
        check(startOver.shift == 0 && !startOver.fadeL && startOver.fadeR && startOver.viewX == L.padX + 54 + L.moreW, "pin tile: the count slot sits between the pin's gap and the track")
        let pinOnly = strip(pinned([], side: .right), focus: 100)
        check(pinOnly.hasTiles && !pinOnly.hasTrack && pinOnly.pillH == 78 && pinOnly.pillW == L.minPillW && pinOnly.pinX == (L.minPillW - 34) / 2
              && hit(pinOnly.pinX + 5, 28, pinned([], side: .right), focus: 100) == .pin(row: 0), "pin tile: a pin alone is a one-tile strip")
        // Focus: the ring is the pin's when its window (or, with none, the map) says so; the ribbon then has none.
        let pf = pinned(five, pinFocus: true)
        check(strip(pf, focus: 100).pinFocused && strip(pf, focus: 100).focus == nil && strip(pf).pinFocused && strip(pf).focus == nil,
              "pin focus: the pin's window, or the map's flag, gives the pin the ring")
        check(!strip(pinned(five)).pinFocused && strip(pinned(five)).focus == 0 && !strip(pf, focus: 3).pinFocused && strip(pf, focus: 3).focus == 2,
              "pin focus: a focused ribbon window keeps the ring in the ribbon")
        check(!strip(bare(pf)).pinFocused && strip(bare(pf)).pin == nil, "pin focus: no pin, no pinned tile")

        // Hit testing: a stack in the pin has a row per sliver, a tab group the active tab.
        let pinStack = pinned(five, pinWins: [buzz, chat]), pinTabs = pinned(five, pinWins: [buzz, chat], tabbed: true, active: 1)
        check(hit(20, 14, pinStack) == .pin(row: 0) && hit(20, 42, pinStack) == .pin(row: 1) && hit(20, 28, pinTabs) == .pin(row: 1)
              && hit(7.9, 28, pinStack) == nil && hit(8, 14, pinStack) == .pin(row: 0) && hit(41.9, 28, pinStack) != nil && hit(42, 28, pinStack) == nil,
              "pin hit: slivers and the active tab, stopping at the tile's edge")
        check(strip(pinTabs).pin?.rows == [1] && strip(pinStack).pin?.rows == [0, 1], "pin tile: a tab group draws its active tab, a stack its slivers")

        // Dragging. Left pin: pin 8...42, track tiles centred at 87.5, 142.5, 197.5, 252.5, 307.5; the pin's side of the gap ends at 52.
        let lm = pinned(five, side: .left, focus: 2), lg = strip(lm)
        check((0..<5).map { lg.centre(of: $0) } == [87.5, 142.5, 197.5, 252.5, 307.5] && lg.overPin(51.9) && !lg.overPin(52), "pin drag: fixture geometry")
        check(L.drop(HUDDrag(from: 2, dx: -200), lg) == .pin && L.drop(HUDDrag(from: 0, dx: -40), lg) == .pin && L.drop(HUDDrag(from: 0, dx: -30), lg) == .slot(0)
              && L.drop(HUDDrag(from: 2, dx: 60), lg) == .slot(3) && L.drop(HUDDrag(from: 2, dx: 0), lg) == .slot(2),
              "pin drag: a tile centred over the pin joins it, otherwise it takes its slot")
        let rm = pinned(five, side: .right, focus: 2), rg = strip(rm)
        check(rg.overPin(288.9) == false && rg.overPin(289) && L.drop(HUDDrag(from: 4, dx: 40), rg) == .pin && L.drop(HUDDrag(from: 4, dx: 30), rg) == .slot(4)
              && L.drop(HUDDrag(from: 1, dx: -9999), rg) == .slot(0), "pin drag: a right pin mirrors it")
        check(L.drop(HUDDrag(from: 2, dx: -200), strip(bare(lm))) == .slot(0), "pin drag: with no pin, dragging past the end is still the first slot")
        check(L.dropCommands(map: lm, focusID: 3, drag: HUDDrag(from: 2, dx: -200)) == [HUDCommand("move_window_to", .pinInto(id: 3, position: "tabs"))],
              "pin drag: dropping a tile on the pin sends move_window_to {id, pin, tabs}")
        check(L.dropCommands(map: lm, focusID: 3, drag: HUDDrag(from: 2, dx: 60)) == L.moveCommands(map: lm, focusID: 3, from: 2, to: 3)
              && L.dropCommands(map: lm, focusID: 3, drag: HUDDrag(from: 2, dx: 0)).isEmpty, "pin drag: a reorder is the old reorder")
        var stackMap = lm
        stackMap.columns[1].windows = [win(2), win(12), win(13)]
        check(L.pinCommands(map: stackMap, focusID: 12, from: 1) == [2, 13, 12].map { HUDCommand("move_window_to", .pinInto(id: $0, position: "tabs")) },
              "pin drag: a stack joins the pin whole, its focused window last (the tab the pin ends on)")
        stackMap.columns[1].tabbed = true; stackMap.columns[1].active = 0
        check(L.pinCommands(map: stackMap, focusID: 3, from: 1) == [12, 13, 2].map { HUDCommand("move_window_to", .pinInto(id: $0, position: "tabs")) },
              "pin drag: a tab group joins the pin whole, its active tab last")
        check(L.pinCommands(map: bare(lm), focusID: 3, from: 2).isEmpty && L.pinCommands(map: lm, focusID: 3, from: 9).isEmpty, "pin drag: nothing to join, nothing sent")
        // The pinned tile pulled out: before the ribbon tiles whose centres it passed, or after the last one.
        check(L.drop(.pinned(row: 0, dx: 150), lg) == .ribbon(2) && L.drop(.pinned(row: 0, dx: 40), lg) == .ribbon(0) && L.drop(.pinned(row: 0, dx: 10), lg) == .stay
              && L.drop(.pinned(row: 0, dx: 9999), lg) == .ribbon(5), "pin drag: the pinned tile lands before the tiles it has passed")
        check(L.drop(.pinned(row: 0, dx: -150), rg) == .ribbon(3) && L.drop(.pinned(row: 0, dx: -10), rg) == .stay && L.drop(.pinned(row: 0, dx: -9999), rg) == .ribbon(0),
              "pin drag: the pinned tile, mirrored for a right pin")
        check(L.dropCommands(map: lm, focusID: 3, drag: .pinned(row: 0, dx: 150)) == [HUDCommand("move_window_to", .moveTo(id: 100, column: 3, position: "before"))]
              && L.dropCommands(map: lm, focusID: 3, drag: .pinned(row: 0, dx: 9999)) == [HUDCommand("move_window_to", .moveTo(id: 100, column: 5, position: "after"))]
              && L.dropCommands(map: lm, focusID: 3, drag: .pinned(row: 0, dx: 10)).isEmpty,
              "pin drag: the pinned tile dropped on the track sends move_window_to {id, column, position}")
        let stackedPin = pinned(five, pinWins: [buzz, chat])
        check(L.dropCommands(map: stackedPin, focusID: 3, drag: .pinned(row: 1, dx: 150)) == [HUDCommand("move_window_to", .moveTo(id: 101, column: 3, position: "before"))],
              "pin drag: the grabbed window of the pin is the one that leaves")
        check(L.leavePinCommands(map: lm, row: 7, at: 0).isEmpty && L.leavePinCommands(map: bare(lm), row: 0, at: 0).isEmpty, "pin drag: no such window, nothing sent")
        check((0..<5).map { L.slide(of: $0, drag: .pinned(row: 0, dx: 150), drop: .ribbon(2)) } == [0, 0, 1, 1, 1]
              && (0..<5).map({ L.slide(of: $0, drag: HUDDrag(from: 2, dx: -200), drop: .pin) }) == [0, 0, 0, -1, -1]
              && (0..<5).allSatisfy { L.slide(of: $0, drag: .pinned(row: 0, dx: 10), drop: .stay) == 0 }
              && (0..<5).map({ L.slide(of: $0, drag: HUDDrag(from: 1, dx: 110), drop: .slot(3)) }) == [0, 0, -1, -1, 0], "pin drag: the tiles make room only where something will land")
        // Wire format: what the core's move_window_to reads.
        let into = wire(HUDCommand("move_window_to", .pinInto(id: 4, position: "tabs")))
        check(into["name"] as? String == "move_window_to" && (into["arg"] as? NSDictionary) == ["id": 4, "pin": true, "position": "tabs"] as NSDictionary,
              "pin drag: pin wire format is {id, pin: true, position}")
        let to = wire(HUDCommand("move_window_to", .moveTo(id: 9, column: 2, position: "after")))
        check((to["arg"] as? NSDictionary) == ["id": 9, "column": 2, "position": "after"] as NSDictionary, "pin drag: move wire format is {id, column, position}")
        L.size = .small
    }
}
