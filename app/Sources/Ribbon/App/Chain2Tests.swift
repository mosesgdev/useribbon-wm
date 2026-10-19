import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox

/// Pure-logic self tests for tabs, dim and drag to reorder: the drop rule, the dim cutout, tab layout, wire types.
enum Chain2Tests {
    static func run(_ check: (Bool, String) -> Void) {
        dropRule(check)
        dimGeometry(check)
        tabLayout(check)
        wire(check)
        hotkeys(check)
        pinTabLayout(check)
        tabLayoutFits(check)
        pinDrop(check)
        tabMenuKeys(check)
    }

    // Three 400pt-wide columns, 12pt gap, on a 1300 x 800 display; column 1 is a two-window stack.
    private static let usable = CGRect(x: 0, y: 25, width: 1300, height: 800)
    private static func col(_ i: Int, x: CGFloat, rows: [CGRect] = [], tabbed: Bool = false, windows: [UInt32] = []) -> DropColumn {
        DropColumn(index: i, frame: CGRect(x: x, y: 37, width: 400, height: 776), rows: rows, tabbed: tabbed, windows: windows.isEmpty ? [UInt32(i + 1)] : windows)
    }
    private static let cols = [col(0, x: 12), col(1, x: 424, rows: [CGRect(x: 424, y: 37, width: 400, height: 382)], windows: [2, 5]), col(2, x: 836)]

    private static func dropRule(_ check: (Bool, String) -> Void) {
        func t(_ x: CGFloat, _ y: CGFloat, source: (column: Int, alone: Bool, row: Int)? = nil, columns: [DropColumn] = cols) -> DropTarget? {
            DropRule.target(pointer: CGPoint(x: x, y: y), columns: columns, usable: usable, gap: 12, source: source)
        }
        // Column 1 spans 424...824 (centre 624); thirds of 37...813 are 37-295 / 295-554 / 554-813.
        check(t(500, 100) == .before(column: 1), "drop: top third, left of the centre -> before the column")
        check(t(700, 100) == .after(column: 1), "drop: top third, right of the centre -> after the column")
        check(t(500, 700) == .before(column: 1) && t(700, 700) == .after(column: 1), "drop: bottom third works like the top")
        check(t(624, 100) == .after(column: 1) && t(623.9, 100) == .before(column: 1), "drop: the centre line itself belongs to 'after'")
        check(t(624, 400) == .into(column: 1, row: 1), "drop: middle third, below the first row's middle -> row 1 of the stack")
        check(t(700, 300) == .into(column: 1, row: 1), "drop: just inside the middle third joins the stack")
        check(t(700, 294) == .after(column: 1), "drop: just above the middle third is a side drop")
        check(t(700, 556) == .after(column: 1), "drop: the middle third ends at two thirds")
        // The gap belongs half to each neighbour.
        check(t(827, 100) == .before(column: 2) || t(827, 100) == .after(column: 1), "drop: in the gap resolves to a neighbour")
        check(t(831, 100) == .before(column: 2), "drop: past the gap midpoint is the right neighbour")
        // Edges: the first and last column own the margin up to the display edge; outside the display is nothing.
        check(t(3, 100, source: (2, true, 0)) == .before(column: 0), "drop: left margin -> before the first column")
        check(t(1295, 100, source: (0, true, 0)) == .after(column: 2), "drop: right margin -> after the last column")
        check(t(500, 10) == nil && t(500, 900) == nil && t(1400, 100) == nil, "drop: outside the usable area snaps back")
        check(DropRule.target(pointer: CGPoint(x: 500, y: 100), columns: [], usable: usable, gap: 12, source: nil) == nil, "drop: no columns -> nothing")
        // A lone window dropped where it already is does nothing.
        check(t(500, 100, source: (1, true, 0)) == nil && t(700, 100, source: (1, true, 0)) == nil, "drop: lone window on its own column snaps back")
        check(t(500, 100, source: (2, true, 0)) == .before(column: 1) && t(500, 100, source: (0, true, 0)) == nil,
              "drop: lone window next to its own slot is a no-op, elsewhere it moves")
        // A stack window dropped at the side of its own column pops out; dropped on its own row it stays.
        check(t(500, 100, source: (1, false, 0)) == .before(column: 1), "drop: stack window dropped beside its column pops out")
        check(t(700, 400, source: (1, false, 1)) == nil, "drop: back on its own row of its own stack does nothing")
        check(t(700, 400, source: (1, false, 0)) == .into(column: 1, row: 1), "drop: another row of the same stack reorders")
        // Tabbed columns take the window as the newest tab.
        let tabbed = [col(0, x: 12), col(1, x: 424, tabbed: true, windows: [2, 5, 6])]
        check(t(600, 400, columns: tabbed) == .into(column: 1, row: 3), "drop: middle third of a tabbed column -> a new tab at the end")
        // Marks.
        if case .bar(let r)? = DropRule.mark(for: .before(column: 1), columns: cols, usable: usable, gap: 12) {
            check(abs(r.midX - 418) < 0.01 && r.height == 776, "mark: 'before' draws a bar in the gap left of the column")
        } else { check(false, "mark: before is a bar") }
        if case .stack(let r, let tab)? = DropRule.mark(for: .into(column: 2, row: 0), columns: cols, usable: usable, gap: 12) {
            check(!tab && r == cols[2].frame.insetBy(dx: 2, dy: 2), "mark: 'into' highlights the column")
        } else { check(false, "mark: into is a highlight") }
        if case .stack(_, let tab)? = DropRule.mark(for: .into(column: 1, row: 0), columns: tabbed, usable: usable, gap: 12) { check(tab, "mark: tabbed column says 'tab'") }
        check(DropRule.isTinyMove(from: .zero, to: CGPoint(x: 5, y: 5)) && !DropRule.isTinyMove(from: .zero, to: CGPoint(x: 20, y: 0)), "drag: small moves are clicks")
        let tgt = DropTarget.into(column: 3, row: 2)
        check(tgt.column == 3 && tgt.position == "into" && DropTarget.before(column: 0).position == "before", "drop: target wire names")
    }

    private static func dimGeometry(_ check: (Bool, String) -> Void) {
        let area = CGRect(x: 0, y: 25, width: 1440, height: 875)
        check(DimGeometry.cutout(area: area, focused: CGRect(x: 100, y: 125, width: 600, height: 500)) == CGRect(x: 100, y: 100, width: 600, height: 500),
              "dim: the cutout is the focused frame in the layer's own coordinates")
        check(DimGeometry.cutout(area: area, focused: CGRect(x: -200, y: 25, width: 400, height: 300)) == CGRect(x: 0, y: 0, width: 200, height: 300),
              "dim: a window hanging off the display is clipped")
        check(DimGeometry.cutout(area: area, focused: CGRect(x: 2000, y: 100, width: 500, height: 500)) == nil, "dim: focus on another display -> no hole")
        check(DimGeometry.cutout(area: area, focused: nil) == nil, "dim: no focus -> no hole")
        check(DimGeometry.cutout(area: area, focused: CGRect(x: 0, y: 20, width: 400, height: 5)) == nil, "dim: a window only in the menu bar strip leaves no hole")
        // Second display to the right: its area starts at x 1440.
        let two = CGRect(x: 1440, y: 25, width: 1440, height: 875)
        check(DimGeometry.cutout(area: two, focused: CGRect(x: 1500, y: 125, width: 300, height: 300)) == CGRect(x: 60, y: 100, width: 300, height: 300), "dim: per-display coordinates")
        check(DimGeometry.flipped(CGRect(x: 10, y: 100, width: 50, height: 40), height: 875) == CGRect(x: 10, y: 735, width: 50, height: 40), "dim: flip to bottom-left")
        check(DimGeometry.radius(of: CGRect(x: 0, y: 0, width: 600, height: 400)) == 12 && DimGeometry.radius(of: CGRect(x: 0, y: 0, width: 10, height: 400)) == 5, "dim: radius never exceeds half the hole")
        check(DimGeometry.isFullyCut(area: CGRect(x: 0, y: 0, width: 100, height: 100), hole: CGRect(x: 0, y: 0, width: 100, height: 100)), "dim: a window covering the display needs no dim")
        check(DimLevel.subtle.alpha < DimLevel.medium.alpha && DimLevel.from(nil) == .subtle && DimLevel.from("medium") == .medium && DimLevel.from("x") == .subtle, "dim: two levels, subtle by default")
        check(UserDefaults.standard.object(forKey: "dimOthers__never_set") == nil && DimPrefs.enabledKey == "dimOthers", "dim: off unless the key says so")
    }

    private static func tabLayout(_ check: (Bool, String) -> Void) {
        let two = TabLayout.tabs(count: 2, width: 800), three = TabLayout.tabs(count: 3, width: 800)
        check(abs(two[0].w - (800 - 8 - 6) / 2) < 0.01 && two[0].w == two[1].w, "tabs: two tabs split the width in two")
        check(abs(three[0].w - (800 - 8 - 12) / 3) < 0.01 && three[1].x == three[0].x + three[0].w + TabLayout.gap, "tabs: three tabs split it three ways with a 6pt gap")
        check(abs(three[2].x + three[2].w - (800 - TabLayout.inset)) < 0.01, "tabs: they fill the bar edge to edge")
        check(TabLayout.tabs(count: 1, width: 500)[0].w == 492, "tabs: a lone tab takes the bar")
        let crowded = TabLayout.tabs(count: 40, width: 400)
        check(crowded.filter { $0.w > 0 }.allSatisfy { $0.w >= TabLayout.iconOnlyMin } && crowded.filter { $0.w > 0 }.count == 11,
              "tabs: when very crowded the ones that fit keep their icon-only floor, the rest are not laid out")
        check(!TabLayout.showsTitle(tabWidth: 50) && TabLayout.showsTitle(tabWidth: 120), "tabs: narrow tabs show the icon alone")
        check(TabLayout.index(at: three[1].x + 3, count: 3, width: 800) == 1 && TabLayout.index(at: three[0].x + three[0].w + 2, count: 3, width: 800) == 0
              && TabLayout.index(at: three[0].x + three[0].w + 4, count: 3, width: 800) == 1 && TabLayout.index(at: 900, count: 3, width: 800) == nil, "tabs: hit testing, the gap goes to the nearer tab")
        check(TabLayout.inCloseZone(x: three[0].x + three[0].w - 5, tab: three[0]) && !TabLayout.inCloseZone(x: three[0].x + 10, tab: three[0]), "tabs: the pop-out button sits at the trailing edge")
        check(TabLayout.tabs(count: 0, width: 300).isEmpty, "tabs: none, no layout")
    }

    private static func wire(_ check: (Bool, String) -> Void) {
        let json = """
        {"frames":[],"focus":null,"changed":[],"map":{"columns":[{"windows":[{"id":1,"app":"A","title":"t"},{"id":2,"app":"B","title":"u"}],"width_frac":0.5,"focused":true,"visible":true,"tabbed":true,"active":1}],
        "viewport":{"start":0,"end":1},"focused_index":0,"desktop":1,"desktops":[]},"show_map":false,"error":null,"toast":null,"jump":true,"floating_parked":[],"shelf":[],
        "tab_bars":[{"column":0,"x":12,"y":37,"w":482,"h":28,"on_screen":true,"active":2,"focused":true,"tabs":[{"id":1,"app":"A","title":"t"},{"id":2,"app":"B","title":"u"}]}]}
        """
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let p = try? d.decode(Plan.self, from: Data(json.utf8))
        check(p?.tabBars.count == 1 && p?.tabBars[0].active == 2 && p?.tabBars[0].tabs.count == 2 && p?.map.columns[0].tabbed == true && p?.map.columns[0].active == 1, "wire: plan decodes tab bars and tabbed columns")
        let old = json.replacingOccurrences(of: ",\"tabbed\":true,\"active\":1", with: "").replacingOccurrences(of: ",\n        \"tab_bars\"", with: "")
        let q = try? d.decode(Plan.self, from: Data(old.utf8))
        check(q != nil, "wire: plans from before tabs still decode")
        // Engine round trip: tabs, cycling and move_window_to through the real core.
        let e = Engine()
        _ = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1000, height: 800)))
        for i in 1...3 { _ = e.handle(.windowAdded(ManagedWindow(id: UInt32(i), pid: 1, app: "App\(i)", title: "W\(i)", frame: CGRect(x: 0, y: 0, width: 400, height: 300), floating: false))) }
        _ = e.handle(.windowFocused(2)); _ = e.handle(.command("stack"))
        _ = e.handle(.windowFocused(3)); _ = e.handle(.command("stack"))
        var plan = e.handle(.command("toggle_tabs"))
        check(plan.tabBars.count == 1 && plan.tabBars[0].tabs.map(\.id) == [1, 2, 3] && plan.map.columns[0].tabbed, "engine: toggle_tabs makes a tab bar")
        let parked = plan.frames.filter { !$0.onScreen }.count
        check(parked == 2, "engine: the two inactive tabs are parked")
        plan = e.handle(.command("next_tab"))
        check(plan.tabBars[0].active == 1 && plan.toast == "Tab 1 of 3 · App1", "engine: next_tab wraps")
        plan = e.handle(rawJSON: "{\"type\":\"command\",\"name\":\"move_window_to\",\"arg\":{\"id\":2,\"column\":1,\"position\":\"after\"}}")
        check(plan.error == nil && plan.map.columns.count == 2 && plan.map.columns[1].windows.map(\.id) == [2], "engine: move_window_to pops a tab out to its own column")
        let ids = Engine(config: EngineConfig())
        check(EngineConfig().widthPresets == [0.25, 0.333, 0.5, 0.667, 0.75, 1.0] && WidthPresets.list(for: "simple") == [0.333, 0.5, 0.667, 1.0], "presets: rich by default, simple available")
        _ = ids
    }

    private static func hotkeys(_ check: (Bool, String) -> Void) {
        let byId = Dictionary(Hotkeys.table.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        check(byId["toggle_tabs"]?.key == kVK_ANSI_T && byId["toggle_tabs"]?.shift == false, "hotkeys: tabs on T")
        check(byId["toggle_float"]?.key == kVK_ANSI_T && byId["toggle_float"]?.shift == true, "hotkeys: float / tile moved to shift T")
        check(byId["next_tab"]?.key == kVK_PageDown && byId["prev_tab"]?.key == kVK_PageUp, "hotkeys: tabs cycle on Page Down / Up (Tab is 'back to last window')")
        check(byId["focus_previous"]?.key == kVK_Tab, "hotkeys: Tab keeps going back to the last window")
        check(["toggle_tabs", "next_tab", "prev_tab"].allSatisfy { byId[$0]?.isRecordable == true }, "hotkeys: the tab actions are recordable")
        let titles = MainActor.assumeIsolated { BarModel.specTitles }
        check(titles.contains("Make tabs / toggle tabs") && titles.contains("Dim other windows"), "command bar: tabs and dim actions exist")
    }

    // MARK: pinned column

    /// A pinned group's bar: the pin button takes its own width and one gap off the tabs, at the trailing end.
    private static func pinTabLayout(_ check: (Bool, String) -> Void) {
        let plain = TabLayout.tabs(count: 2, width: 800), pinned = TabLayout.tabs(count: 2, width: 800, pin: true)
        let btn = TabLayout.pinButtonFrame(width: 800)
        check(TabLayout.pinButton == TabLayout.barHeight - 4 && TabLayout.reserved(pin: true) == TabLayout.pinButton + TabLayout.gap && TabLayout.reserved(pin: false) == 0,
              "pin button: as tall as a tab, plus one gap, and only on a pinned bar")
        check(abs(pinned[0].w - (800 - 34 - 8 - 6) / 2) < 0.01 && pinned[0].w < plain[0].w && pinned[0].x == plain[0].x, "pin button: tabs share what is left of the bar")
        check(abs((pinned[1].x + pinned[1].w + TabLayout.gap) - btn.x) < 0.01 && abs(btn.x + btn.w - (800 - TabLayout.inset)) < 0.01,
              "pin button: one gap after the last tab, against the trailing inset")
        check(TabLayout.tabs(count: 3, width: 800, pin: false).map(\.w) == TabLayout.tabs(count: 3, width: 800).map(\.w), "pin button: an ordinary bar is laid out as before")
        let last = pinned[1].x + pinned[1].w / 2
        check(TabLayout.index(at: last, count: 2, width: 800, pin: true) == 1 && !TabLayout.inPinButton(x: last, width: 800), "pin button: the middle of the last tab is the tab")
        check(TabLayout.inPinButton(x: btn.x + btn.w / 2, width: 800) && TabLayout.index(at: btn.x + btn.w / 2, count: 2, width: 800, pin: true) == nil,
              "pin button: the middle of the button is the button, not a tab")
        let seam = btn.x - TabLayout.gap / 2
        check(TabLayout.inPinButton(x: seam, width: 800) && !TabLayout.inPinButton(x: seam - 0.1, width: 800)
              && TabLayout.index(at: seam - 0.1, count: 2, width: 800, pin: true) == 1 && TabLayout.index(at: seam, count: 2, width: 800, pin: true) == nil,
              "pin button: the gap between the last tab and the button splits evenly, no dead strip")
        check(TabLayout.inPinButton(x: 799, width: 800) && !TabLayout.inPinButton(x: 801, width: 800) && !TabLayout.inPinButton(x: 5, width: 800), "pin button: nothing else is the button")
        check(TabLayout.index(at: btn.x + 5, count: 2, width: 800) == 1, "pin button: on an unpinned bar the same spot is still a tab")
        check(TabLayout.index(at: 2, count: 2, width: 800, pin: true) == 0, "pin button: the first tab is unchanged")
    }

    /// Nothing is drawn past a bar's edge: from `minWidth` up every tab and the pin button fit inside the width, below it fewer
    /// tabs are laid out (the active one among them), and the view and the hit view read the same layout.
    private static func tabLayoutFits(_ check: (Bool, String) -> Void) {
        let eps: CGFloat = 0.001, btn = TabLayout.pinButton, gap = TabLayout.gap, inset = TabLayout.inset, icon = TabLayout.iconOnlyMin
        var bad: [String] = []
        for pin in [false, true] { for count in 2...6 { for w in 250...945 {
            let width = CGFloat(w), t = TabLayout.tabs(count: count, width: width, pin: pin)
            let tail: CGFloat = pin ? gap + btn : 0, end = t[count - 1].x + t[count - 1].w
            var ok = t.count == count && t[0].x == inset && end + tail + inset <= width + eps
            ok = ok && t.allSatisfy { $0.w >= icon - eps }
            ok = ok && (1..<count).allSatisfy { abs(t[$0].x - (t[$0 - 1].x + t[$0 - 1].w + gap)) < eps }
            ok = ok && t.indices.allSatisfy { TabLayout.index(at: t[$0].x + t[$0].w / 2, count: count, width: width, pin: pin) == $0 }
            if pin {
                ok = ok && TabLayout.pinButtonFrame(width: width).x >= end + gap - eps
                ok = ok && TabLayout.inPinButton(x: width - inset - btn / 2, width: width) && TabLayout.index(at: width - 6, count: count, width: width, pin: pin) == nil
            }
            if !ok { bad.append("\(count) tabs, pin \(pin), \(w) pt") }
        } } }
        check(bad.isEmpty, "tab fit: every width 250...945, 2...6 tabs, with and without the pin: tabs, gaps and pin button inside the bar" + (bad.first.map { " (first miss: \($0))" } ?? ""))
        let min3pin: CGFloat = 2 * inset + 3 * icon + 2 * gap + gap + btn, min3: CGFloat = 2 * inset + 3 * icon + 2 * gap
        check(TabLayout.minWidth(count: 3, pin: true) == min3pin && TabLayout.minWidth(count: 3) == min3 && min3pin == 138, "tab fit: minWidth is the insets, icon-only tabs, gaps and the pin button")
        for (count, pin) in [(2, false), (5, false), (3, true), (6, true)] {
            let m = TabLayout.minWidth(count: count, pin: pin)
            let at = TabLayout.tabs(count: count, width: m, pin: pin), under = TabLayout.tabs(count: count, width: m - 0.5, pin: pin)
            check(at.allSatisfy { abs($0.w - icon) < eps } && under.filter { $0.w > 0 }.count == count - 1,
                  "tab fit: \(count) tabs\(pin ? " and the pin" : "") fill exactly their minWidth; half a point less drops one tab")
        }
        // A bar too narrow for its tabs lays out a run of them that includes the active one, and nothing hit is hidden.
        var narrowOK = true
        for pin in [false, true] { for active in 0..<12 {
            let width: CGFloat = 294, t = TabLayout.tabs(count: 12, width: width, pin: pin, active: active)
            let laid = t.indices.filter { t[$0].w > 0 }, tail: CGFloat = pin ? gap + btn : 0
            let end = laid.last.map { t[$0].x + t[$0].w } ?? 0
            var ok = laid.count == (pin ? 7 : 8) && laid.contains(active) && end + tail + inset <= width + eps
            ok = ok && laid.indices.dropFirst().allSatisfy { laid[$0] == laid[$0 - 1] + 1 }
            ok = ok && laid.allSatisfy { t[$0].w >= icon - eps }
            ok = ok && stride(from: CGFloat(0), through: width, by: 1).allSatisfy { x in
                TabLayout.index(at: x, count: 12, width: width, pin: pin, active: active).map { t[$0].w > 0 } ?? true
            }
            narrowOK = narrowOK && ok
        } }
        check(narrowOK, "tab fit: twelve tabs in a 294 pt bar: seven (eight without the pin) are laid out, the active one among them, none hit unseen")
        let sliver = TabLayout.tabs(count: 3, width: 30, pin: true)
        check(!TabLayout.showsPinButton(pin: true, width: 30) && !TabLayout.inPinButton(x: 29, width: 30) && sliver.filter { $0.w > 0 }.count == 1
              && sliver[0].x + sliver[0].w + inset <= 30 + eps, "tab fit: a sliver of a bar drops the pin button and keeps one tab inside it")
        // The one rule for icon-only: a title shows from the width that leaves room for about six characters beside the icon
        // and the padding (12 + 16 + 7 + 12 before the text); the narrowest pin (294 pt) holds three tabs as icons, two with titles.
        let textRoom: CGFloat = 96 - 12 - 16 - 7 - 12
        check(TabLayout.showsTitle(tabWidth: 96) && !TabLayout.showsTitle(tabWidth: 95.9) && textRoom >= 49, "tab fit: a title shows from 96 pt, with room for about six characters")
        let three = TabLayout.tabs(count: 3, width: 294, pin: true), two = TabLayout.tabs(count: 2, width: 294, pin: true)
        check(three.allSatisfy { !TabLayout.showsTitle(tabWidth: $0.w) } && two.allSatisfy { TabLayout.showsTitle(tabWidth: $0.w) }, "tab fit: three tabs in the narrowest pin are icons, two have titles")
        // What the view draws and the hit view tests is one layout: the model's.
        let same: Bool = MainActor.assumeIsolated {
            let tabs = (1...8).map { TabItem(id: UInt32($0), app: "App\($0)", title: "A rather long window title \($0)") }
            let model = TabBarModel()
            model.bar = TabBar(column: 3, x: 0, y: 0, w: 300, h: 32, onScreen: true, active: 8, focused: true, tabs: tabs, pinned: true)
            model.width = 300
            let t = TabLayout.tabs(count: 8, width: 300, pin: true, active: 7)
            var ok = model.activeIndex == 7 && model.showsPinButton && model.layout.count == 8 && t[0].w == 0
            ok = ok && zip(model.layout, t).allSatisfy { $0.0.x == $0.1.x && $0.0.w == $0.1.w }
            return ok
        }
        check(same, "tab fit: the bar model hands the view and the hit view the very layout TabLayout computes, active tab and pin included")
    }

    // A 2560 x 800 display with a ¼-width pin (640) against one edge and ribbon columns of 400, one gap (12) apart.
    private static let pinUsable = CGRect(x: 0, y: 25, width: 2560, height: 800)
    private static func pinCol(left: Bool = true, rows: [CGRect] = [], tabbed: Bool = false, windows: [UInt32] = [90]) -> DropColumn {
        DropColumn(index: 3, frame: CGRect(x: left ? 0 : 1920, y: 37, width: 640, height: 776), rows: rows, tabbed: tabbed, windows: windows, pinned: true)
    }
    private static func ribbonCols(from x: CGFloat) -> [DropColumn] {
        (0..<3).map { DropColumn(index: $0, frame: CGRect(x: x + CGFloat($0) * 412, y: 37, width: 400, height: 776), rows: [], tabbed: false, windows: [UInt32($0 + 1)]) }
    }

    private static func pinDrop(_ check: (Bool, String) -> Void) {
        let left = ribbonCols(from: 652) + [pinCol()]
        func t(_ x: CGFloat, _ y: CGFloat, columns: [DropColumn]? = nil, source: (column: Int, alone: Bool, row: Int)? = nil, pinSource: (alone: Bool, row: Int)? = nil) -> DropTarget? {
            DropRule.target(pointer: CGPoint(x: x, y: y), columns: columns ?? left, usable: pinUsable, gap: 12, source: source, pinSource: pinSource)
        }
        // The title-bar zone (top band) makes a tab of the pin, the rest of it takes the window in. No before / after anywhere on it.
        check(t(300, 50) == .pinTabs && t(300, 76) == .pinTabs, "pin drop: its title-bar zone makes the window a tab of the pin")
        check(t(300, 78) == .pinInto(row: 0) && t(300, 400) == .pinInto(row: 0) && t(300, 800) == .pinInto(row: 0), "pin drop: the whole body takes the window in, thirds do not matter")
        var onlyPin = true
        for x in [CGFloat(2), 100, 320, 500, 645] { for y in [CGFloat(40), 200, 420, 700] {
            switch t(x, y) { case .pinTabs?, .pinInto?: break; default: onlyPin = false }
        } }
        check(onlyPin, "pin drop: nothing beside the pin, every point of it is a pin target (no before / after)")
        check(t(2, 300) == .pinInto(row: 0) && t(645.9, 100) == .pinInto(row: 0), "pin drop: the pin owns the margin to the display edge and half the gap beside it")
        check(t(646, 100) == .before(column: 0) && t(646, 50) == .tabs(column: 0), "pin drop: its zone ends exactly where the first ribbon column's starts")
        check(t(700, 100) == .before(column: 0) && t(1000, 100) == .after(column: 0) && t(1200, 400) == .into(column: 1, row: 0), "pin drop: ribbon columns beside it work as before")
        // A stacked pin: the row is the slot among the pin's other windows.
        let stack = ribbonCols(from: 652) + [pinCol(rows: [CGRect(x: 0, y: 37, width: 640, height: 380), CGRect(x: 0, y: 420, width: 640, height: 393)], windows: [90, 91, 92])]
        check(t(300, 50, columns: stack) == .pinTabs && t(300, 100, columns: stack) == .pinInto(row: 0) && t(300, 300, columns: stack) == .pinInto(row: 1) && t(300, 700, columns: stack) == .pinInto(row: 2),
              "pin drop: a stacked pin counts the row under the pointer")
        // A tabbed pin: the bar (a tab's height) is the tabs zone, everything below adds a newest tab.
        let tabbed = ribbonCols(from: 652) + [pinCol(tabbed: true, windows: [90, 91])]
        check(t(300, 60, columns: tabbed) == .pinTabs && t(300, 68, columns: tabbed) == .pinTabs && t(300, 69, columns: tabbed) == .pinInto(row: 2) && t(300, 500, columns: tabbed) == .pinInto(row: 2),
              "pin drop: a tabbed pin's bar is the tabs zone, the body adds a tab at the end")
        // A pin on the right edge, the ribbon beside it on the left: the margin goes to the pin on that side only.
        let right = ribbonCols(from: 684) + [pinCol(left: false)]
        check(t(2000, 300, columns: right) == .pinInto(row: 0) && t(2559, 50, columns: right) == .pinTabs && t(1914, 300, columns: right) == .pinInto(row: 0),
              "pin drop: a right pin owns its width, the margin to the right edge and half the gap")
        check(t(1913.9, 300, columns: right) == .into(column: 2, row: 0) && t(1900, 100, columns: right) == .after(column: 2), "pin drop: just left of a right pin it is the ribbon's last column")
        check(t(3, 100, columns: right) == .before(column: 0), "pin drop: the ribbon's own margin, on the side without the pin, still belongs to its first column")
        // The ribbon rule is unchanged without a pin.
        check(t(3, 100, columns: ribbonCols(from: 12)) == .before(column: 0) && t(2500, 100, columns: ribbonCols(from: 12)) == .after(column: 2), "pin drop: without a pin the first and last column own the margins as before")
        check(t(700, 900) == nil && t(2600, 100) == nil, "pin drop: outside the display is still nothing")
        // A ribbon window dropped on the pin always changes something, even a lone one.
        check(t(300, 50, source: (0, true, 0)) == .pinTabs && t(300, 400, source: (0, true, 0)) == .pinInto(row: 0) && t(300, 400, source: (1, false, 1)) == .pinInto(row: 0),
              "pin drop: a ribbon window (lone or stacked) dropped on the pin joins it")
        // A window of the pin has no ribbon column: every ribbon target moves it out, whatever the column numbers say.
        let lone: (alone: Bool, row: Int) = (true, 0)
        check(t(700, 100, pinSource: lone) == .before(column: 0) && t(1000, 100, pinSource: lone) == .after(column: 0) && t(900, 400, pinSource: lone) == .into(column: 0, row: 0),
              "pin drop: a pinned window dropped on a ribbon column leaves the pin there")
        check(t(1850, 100, pinSource: lone) == .after(column: 2) && t(660, 100, pinSource: lone) == .before(column: 0),
              "pin drop: the slots next to the last and the first ribbon column are real moves for it, not no-ops")
        check(t(1900, 100, columns: right, pinSource: lone) == .after(column: 2) && t(20, 100, columns: right, pinSource: lone) == .before(column: 0),
              "pin drop: a right pin's window dropped after the last ribbon column leaves the pin")
        check(t(900, 50, pinSource: lone) == .tabs(column: 0), "pin drop: onto a ribbon window's title bar it joins that window as a tab")
        check(t(300, 50, pinSource: lone) == nil && t(300, 400, pinSource: lone) == nil, "pin drop: a lone pinned window dropped back on the pin does nothing")
        // A window of a pinned stack: its own row stays put, another row reorders, the title bar has nothing to join.
        let mid: (alone: Bool, row: Int) = (false, 1)
        check(t(300, 50, columns: stack, pinSource: mid) == nil && t(300, 300, columns: stack, pinSource: mid) == nil && t(300, 500, columns: stack, pinSource: mid) == nil,
              "pin drop: a pinned stack window on its own title bar or row does nothing")
        check(t(300, 100, columns: stack, pinSource: mid) == .pinInto(row: 0) && t(300, 700, columns: stack, pinSource: mid) == .pinInto(row: 2), "pin drop: on another row of the pin it reorders")
        check(t(300, 200, columns: tabbed, pinSource: (false, 0)) == .pinInto(row: 2), "pin drop: a tabbed pin's own window can still be moved to the end")
        // Marks.
        if case .stack(let r, let tab)? = DropRule.mark(for: .pinInto(row: 0), columns: left, usable: pinUsable, gap: 12) {
            check(!tab && r == CGRect(x: 2, y: 39, width: 636, height: 772), "pin mark: the body drop highlights the pin")
        } else { check(false, "pin mark: into is a highlight") }
        if case .tabGroup(let r)? = DropRule.mark(for: .pinTabs, columns: left, usable: pinUsable, gap: 12) {
            check(r == CGRect(x: 0, y: 38, width: 640, height: TabLayout.barHeight - 2), "pin mark: the title-bar zone previews a tab bar at the top of the pin")
        } else { check(false, "pin mark: tabs is a tab bar preview") }
        if case .stack(_, let tab)? = DropRule.mark(for: .pinTabs, columns: tabbed, usable: pinUsable, gap: 12) { check(tab, "pin mark: an existing tab bar highlights the column as a tab drop") }
        else { check(false, "pin mark: tabbed pin is a highlight") }
        check(DropRule.mark(for: .pinInto(row: 0), columns: ribbonCols(from: 12), usable: pinUsable, gap: 12) == nil, "pin mark: no pin, no mark")
        if case .stack(let r, _)? = DropRule.mark(for: .into(column: 0, row: 0), columns: left, usable: pinUsable, gap: 12) { check(r.minX == 654, "pin mark: ribbon targets still find their own column, not the pin's") }
        else { check(false, "pin mark: a ribbon target next to a pin is a highlight") }
        // Wire.
        let tab = DropTarget.pinTabs, into = DropTarget.pinInto(row: 2)
        check(tab.column == nil && into.column == nil && tab.position == "tabs" && into.position == "into" && DropTarget.tabs(column: 4).column == 4, "pin drop: targets name no ribbon column, positions as the core wants them")
        let a = tab.moveArg(id: 7), b = into.moveArg(id: 7), c = DropTarget.after(column: 2).moveArg(id: 7), d = DropTarget.into(column: 0, row: 1).moveArg(id: 7)
        check(a["pin"] as? Bool == true && a["column"] == nil && a["position"] as? String == "tabs" && a["row"] == nil && a["id"] as? Int == 7, "pin wire: tabs is {id, pin: true, position: tabs}")
        check(b["pin"] as? Bool == true && b["position"] as? String == "into" && b["row"] as? Int == 2 && b["column"] == nil, "pin wire: into carries its row")
        check(c["column"] as? Int == 3 && c["pin"] == nil && c["position"] as? String == "after" && d["column"] as? Int == 1 && d["row"] as? Int == 1, "pin wire: ribbon targets keep their 1-based column")
    }

    /// The tab menu's key equivalents and actions: what any edition shows.
    private static func tabMenuKeys(_ check: (Bool, String) -> Void) {
        let k = TabMenuKeys.equivalent(["⌃", "⌥", "K"])
        check(k?.key == "k" && k?.mask == NSEvent.ModifierFlags([.control, .option])
              && TabMenuKeys.equivalent(["⌃", "⌥", "⇧", "K"])?.mask == NSEvent.ModifierFlags([.control, .option, .shift])
              && TabMenuKeys.equivalent(["⌃", "⌥", "⌘", "K"])?.mask == NSEvent.ModifierFlags([.control, .option, .command]),
              "tab menu: keycaps become the menu item's key equivalent")
        check(TabMenuKeys.equivalent([]) == nil && TabMenuKeys.equivalent(["K"]) == nil && TabMenuKeys.equivalent(["⌃", "⌥", "→"]) == nil && TabMenuKeys.equivalent(["fn", "K"]) == nil,
              "tab menu: unbound, bare or unshowable keys show nothing")
        check(ModifierChoice.ctrlOpt.keys(shift: false, "K").joined() == "⌃⌥K" && ModifierChoice.ctrlOpt.keys(shift: true, "K").joined() == "⌃⌥⇧K"
              && ModifierChoice.hyper.keys(shift: false, "K").joined() == "⌃⌥⌘K", "tab menu: the default keycaps follow the modifier preset")
        check(TabAction.command(3, "go", -1) == .command(3, "go", -1) && TabAction.command(3, "go", -1) != .command(3, "go", 1) && TabAction.menuOpening(2) == .menuOpening(2),
              "tab menu: the actions compare, so a repeated pick is the same action")
    }

}
