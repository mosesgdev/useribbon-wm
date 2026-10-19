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
        tabLayoutFits(check)
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

    /// Nothing is drawn past a bar's edge: from `minWidth` up every tab fits inside the width, below it fewer tabs are laid out
    /// (the active one among them), and a bar that keeps room at its trailing end lays its tabs out before it.
    private static func tabLayoutFits(_ check: (Bool, String) -> Void) {
        let eps: CGFloat = 0.001, gap = TabLayout.gap, inset = TabLayout.inset, icon = TabLayout.iconOnlyMin
        // The one rule for icon-only: a title shows from the width that leaves room for about six characters beside the icon
        // and the padding (12 + 16 + 7 + 12 before the text).
        let textRoom: CGFloat = 96 - 12 - 16 - 7 - 12
        check(TabLayout.showsTitle(tabWidth: 96) && !TabLayout.showsTitle(tabWidth: 95.9) && textRoom >= 49, "tab fit: a title shows from 96 pt, with room for about six characters")
        var bad: [String] = []
        for trailing in [CGFloat(0), 34] { for count in 2...6 { for w in 250...945 {
            let width = CGFloat(w), t = TabLayout.tabs(count: count, width: width, trailing: trailing), end = t[count - 1].x + t[count - 1].w
            var ok = t.count == count && t[0].x == inset && end + trailing + inset <= width + eps && t.allSatisfy { $0.w >= icon - eps }
            ok = ok && (1..<count).allSatisfy { abs(t[$0].x - (t[$0 - 1].x + t[$0 - 1].w + gap)) < eps }
            ok = ok && t.indices.allSatisfy { TabLayout.index(at: t[$0].x + t[$0].w / 2, count: count, width: width, trailing: trailing) == $0 }
            if trailing > 0 { ok = ok && TabLayout.inTrailing(x: width - inset - 1, width: width, trailing: trailing) && TabLayout.index(at: width - 6, count: count, width: width, trailing: trailing) == nil }
            if !ok { bad.append("\(count) tabs, trailing \(trailing), \(w) pt") }
        } } }
        check(bad.isEmpty, "tab layout fits: every width 250...945, 2...6 tabs, with and without trailing room: tabs and gaps inside the bar" + (bad.first.map { " (first miss: \($0))" } ?? ""))
        let m = TabLayout.minWidth(count: 5), at = TabLayout.tabs(count: 5, width: m), under = TabLayout.tabs(count: 5, width: m - 0.5)
        check(m == 2 * inset + 5 * icon + 4 * gap && at.allSatisfy { abs($0.w - icon) < eps } && under.filter { $0.w > 0 }.count == 4,
              "tab layout fits: tabs fill exactly their minWidth; half a point less drops one tab")
        var narrowOK = true
        for active in 0..<12 {
            let t = TabLayout.tabs(count: 12, width: 294, active: active), laid = t.indices.filter { t[$0].w > 0 }
            narrowOK = narrowOK && laid.count == 8 && laid.contains(active) && laid.indices.dropFirst().allSatisfy { laid[$0] == laid[$0 - 1] + 1 }
                && stride(from: CGFloat(0), through: 294, by: 1).allSatisfy { x in TabLayout.index(at: x, count: 12, width: 294, active: active).map { t[$0].w > 0 } ?? true }
        }
        check(narrowOK, "tab layout fits: twelve tabs in a 294 pt bar: eight are laid out, the active one among them, none hit unseen")
        let same: Bool = MainActor.assumeIsolated {
            let model = TabBarModel()
            model.bar = TabBar(column: 0, x: 0, y: 0, w: 300, h: 32, onScreen: true, active: 8, focused: true,
                               tabs: (1...12).map { TabItem(id: UInt32($0), app: "App\($0)", title: "Title \($0)") })
            model.width = 300
            let t = TabLayout.tabs(count: 12, width: 300, trailing: model.trailing, active: 7)
            return model.activeIndex == 7 && model.layout.count == 12 && zip(model.layout, t).allSatisfy { $0.0.x == $0.1.x && $0.0.w == $0.1.w }
        }
        check(same, "tab layout fits: the bar model hands the view and the hit view the very layout TabLayout computes")
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
