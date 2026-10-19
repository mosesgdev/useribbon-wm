import CoreGraphics
import Foundation

// Pure logic for the tabs, dim and drag-to-reorder features. No AppKit state, so the self tests can pin every rule down.
// All rects are in AX space (global, top-left origin) unless a name says otherwise.

// MARK: - Dim other windows

/// How strong the dim is. Two steps only: "Subtle" stays out of the way, "Medium" is for bright rooms and busy desktops.
enum DimLevel: String, CaseIterable, Identifiable {
    case subtle, medium
    var id: String { rawValue }
    var label: String { self == .subtle ? "Subtle" : "Medium" }
    /// Black layer opacity.
    var alpha: CGFloat { self == .subtle ? 0.20 : 0.38 }
    static func from(_ raw: String?) -> DimLevel { raw.flatMap(DimLevel.init(rawValue:)) ?? .subtle }
}

/// UserDefaults keys for the dim (read directly: the overlay is not part of the layout config).
enum DimPrefs {
    static let enabledKey = "dimOthers", levelKey = "dimLevel"
}

enum DimGeometry {
    /// The hole in a display's dim layer: the focused window's frame clipped to the dimmed area, in the layer's own
    /// coordinates (top-left origin). nil = nothing to cut out (the focused window is on another display, or too small to matter).
    static func cutout(area: CGRect, focused: CGRect?) -> CGRect? {
        guard let focused else { return nil }
        let hole = focused.intersection(area)
        guard !hole.isNull, hole.width >= 1, hole.height >= 1 else { return nil }
        return hole.offsetBy(dx: -area.minX, dy: -area.minY)
    }

    /// The same hole in bottom-left (Core Animation / AppKit) coordinates of a layer `height` tall.
    static func flipped(_ r: CGRect, height: CGFloat) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }

    /// Corner radius of the hole: the window's, but never more than half the hole's shorter side.
    static func radius(of hole: CGRect, windowRadius: CGFloat = 12) -> CGFloat { min(windowRadius, min(hole.width, hole.height) / 2) }

    /// Even-odd path pieces: the dimmed area and (if any) the rounded hole.
    static func isFullyCut(area: CGRect, hole: CGRect?) -> Bool {
        guard let hole else { return false }
        return hole.width >= area.width - 0.5 && hole.height >= area.height - 0.5
    }
}

// MARK: - Tab bar layout

enum TabLayout {
    /// Tabs share the bar's width equally (2 tabs split it in two, 3 in three), separated by `gap`, inset from the bar's edges.
    /// Nothing is reserved for tabs that do not exist. A tab never gets narrower than `iconOnlyMin`, the room for its icon alone;
    /// a bar too narrow for all its tabs at that width (`minWidth`) lays out only the ones that fit, so nothing overflows.
    static let inset: CGFloat = 4, gap: CGFloat = 6, iconOnlyMin: CGFloat = 28
    static let barHeight: CGFloat = 32
    /// Pop-out ✕ hit width at a tab's trailing edge (shown on hover).
    static let closeZone: CGFloat = 26
    /// A pinned group's bar ends in one round button (unpin), as tall as a tab. It takes its own width and one `gap` from the tabs.
    static let pinButton: CGFloat = barHeight - 4

    /// What the bar gives up to the pin button on its trailing side.
    static func reserved(pin: Bool) -> CGFloat { pin ? pinButton + gap : 0 }

    /// The narrowest bar that lays out all `count` tabs (as icons) and, for a pinned group, its pin button.
    static func minWidth(count: Int, pin: Bool = false) -> CGFloat {
        let n = CGFloat(max(count, 1))
        return 2 * inset + n * iconOnlyMin + (n - 1) * gap + reserved(pin: pin)
    }

    /// Does a pinned group's bar of this `width` have room for its pin button beside one icon-only tab? Narrower, the button goes
    /// first (a clipped half-scrolled bar is never the pin's, so this only guards the arithmetic).
    static func showsPinButton(pin: Bool, width: CGFloat) -> Bool { pin && width >= minWidth(count: 1, pin: true) }

    /// (x, width) of each tab relative to the bar, one entry per tab; width 0 marks a tab that is not laid out. `pin`: the bar is
    /// a pinned group's and ends in the pin button. Whatever fits is laid out edge to edge (all of it from `minWidth` up); when
    /// not every tab fits, the ones laid out are a run that includes the tab at `active`.
    static func tabs(count: Int, width: CGFloat, pin: Bool = false, active: Int = 0) -> [(x: CGFloat, w: CGFloat)] {
        guard count > 0 else { return [] }
        let room = width - reserved(pin: showsPinButton(pin: pin, width: width)) - 2 * inset
        let fit = min(count, max(1, Int(((room + gap) / (iconOnlyMin + gap)).rounded(.down))))
        let w = max(0, (room - CGFloat(fit - 1) * gap) / CGFloat(fit))
        let a = min(max(active, 0), count - 1), first = a < fit ? 0 : a - fit + 1
        return (0..<count).map { i in
            let k = i - first
            return k >= 0 && k < fit ? (x: inset + CGFloat(k) * (w + gap), w: w) : (x: inset, w: 0)
        }
    }

    /// (x, width) of the pin button relative to the bar: against the trailing inset.
    static func pinButtonFrame(width: CGFloat) -> (x: CGFloat, w: CGFloat) { (x: width - inset - pinButton, w: pinButton) }

    /// Is `x` over the pin button? Half the gap before it counts too, so the last tab and the button leave no dead strip.
    static func inPinButton(x: CGFloat, width: CGFloat) -> Bool {
        showsPinButton(pin: true, width: width) && x >= pinButtonFrame(width: width).x - gap / 2 && x <= width
    }

    /// Which tab a point `x` (bar coordinates) is over (the gap belongs to the nearer tab; on a pinned bar the one before the
    /// button splits its gap with the button). Tabs that are not laid out are never hit.
    static func index(at x: CGFloat, count: Int, width: CGFloat, pin: Bool = false, active: Int = 0) -> Int? {
        let pin = showsPinButton(pin: pin, width: width)
        let t = tabs(count: count, width: width, pin: pin, active: active)
        let laid = t.indices.filter { t[$0].w > 0 }
        guard let first = laid.first, let last = laid.last, x >= t[first].x - inset, x < t[last].x + t[last].w + (pin ? gap / 2 : inset) else { return nil }
        if pin && inPinButton(x: x, width: width) { return nil }
        return laid.min { abs(x - (t[$0].x + t[$0].w / 2)) < abs(x - (t[$1].x + t[$1].w / 2)) }
    }

    /// A tab shows its title from this width on (room for about six characters beside the icon); narrower ones show the app icon
    /// alone. The one rule, for drawing and for hit-testing alike.
    static func showsTitle(tabWidth: CGFloat) -> Bool { tabWidth >= 96 }

    /// Is `x` inside the pop-out ✕ of the tab at `tab` (x, w)?
    static func inCloseZone(x: CGFloat, tab: (x: CGFloat, w: CGFloat)) -> Bool { x >= tab.x + tab.w - closeZone && x < tab.x + tab.w }
}

// MARK: - Drag to reorder

/// One column on screen, as the drop rule sees it.
struct DropColumn: Equatable {
    var index: Int                 // 0-based column index in the ribbon (the pin: one past the last, as the core numbers its tab bar)
    var frame: CGRect              // the whole column (tab bar included for tabbed columns)
    var rows: [CGRect]             // windows of a stacked column other than the dragged one, top to bottom (empty when tabbed)
    var tabbed: Bool
    var windows: [UInt32]
    /// The pinned column: a drop target of its own, held against an edge beside the ribbon rather than in its order.
    var pinned = false
}

/// Where a dragged window will land.
enum DropTarget: Equatable {
    case before(column: Int)
    case after(column: Int)
    /// Join the column: a row of its stack (counted among the column's other windows) or its newest tab.
    case into(column: Int, row: Int)
    /// Dropped on the title-bar area of a non-tabbed column: the two become a tab group.
    case tabs(column: Int)
    /// Dropped on the title-bar zone of the pinned column: the window becomes a tab of the pin.
    case pinTabs
    /// Dropped on the body of the pinned column: a row of its stack or its newest tab (`row` counts its other windows).
    /// Nothing goes before or after the pin: it has no neighbour to be ordered against.
    case pinInto(row: Int)

    /// The ribbon column it names; nil for the pin, which is not one.
    var column: Int? {
        switch self {
        case .before(let c), .after(let c), .tabs(let c), .into(let c, _): c
        case .pinTabs, .pinInto: nil
        }
    }
    var position: String {
        switch self { case .before: "before"; case .after: "after"; case .into, .pinInto: "into"; case .tabs, .pinTabs: "tabs" }
    }

    /// The `move_window_to` argument that performs this drop: a ribbon column is 1-based, the pin is `pin: true`.
    func moveArg(id: UInt32) -> [String: Any] {
        var arg: [String: Any] = ["id": Int(id), "position": position]
        if let c = column { arg["column"] = c + 1 } else { arg["pin"] = true }
        switch self { case .into(_, let row), .pinInto(let row): arg["row"] = row; default: break }
        return arg
    }

    /// A `move_window_to` command as raw event JSON.
    static func moveEvent(_ arg: [String: Any]) -> String? {
        let ev: [String: Any] = ["type": "command", "name": "move_window_to", "arg": arg]
        return (try? JSONSerialization.data(withJSONObject: ev)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// The drop rule, in one sentence: the column under the pointer wins; in its middle third (vertically) the window joins it
/// as a stack (or a tab); in the top or bottom third it becomes its own column on the side of the column centre the pointer
/// is on. Releasing over nothing, or where the window already is, puts it back. The pinned column is the exception: its top
/// band makes the window a tab of it, the rest of it takes the window in, and nothing is dropped beside it.
enum DropRule {
    /// The top of a non-tabbed column that counts as its title bar (a window's title bar is 28-38pt; a little slack on top).
    static let titleBand: CGFloat = 40

    /// - Parameters:
    ///   - pointer: where the mouse is.
    ///   - columns: the visible columns, left to right, and the pinned column if there is one (in any position).
    ///   - usable: the display's usable area; the pointer must be inside it. The first and last ribbon column also own the margin to the display edge, except on the pin's side: there the pin owns it.
    ///   - gap: gap between columns (the gap belongs half to each neighbour).
    ///   - source: the dragged window's own column, whether it is alone in it, and its row (windows above it) in that column.
    ///   - pinSource: the same for a window of the pin, which has no ribbon column (every ribbon target then moves it out of the pin).
    static func target(pointer: CGPoint, columns: [DropColumn], usable: CGRect, gap: CGFloat,
                       source: (column: Int, alone: Bool, row: Int)?, pinSource: (alone: Bool, row: Int)? = nil) -> DropTarget? {
        guard usable.contains(pointer) else { return nil }
        let half = gap / 2
        let pin = columns.first { $0.pinned }
        let ribbon = columns.filter { !$0.pinned }
        // The pin owns its own width, half the gap beside it and the margin out to the display edge; the ribbon owns the rest.
        var lo = usable.minX, hi = usable.maxX
        if let pin {
            if pin.frame.midX < usable.midX { lo = pin.frame.maxX + half } else { hi = pin.frame.minX - half }
            if pointer.x < lo || pointer.x >= hi {
                let t = pinTarget(pointer, pin)
                return isNoOp(t, source: source, columns: columns, pinSource: pinSource) ? nil : t
            }
        }
        guard let first = ribbon.first, let last = ribbon.last else { return nil }
        guard let col = ribbon.first(where: { c in
            let l = c.index == first.index ? lo : c.frame.minX - half
            let h = c.index == last.index ? hi : c.frame.maxX + half
            return pointer.x >= l && pointer.x < h
        }) else { return nil }
        let f = col.frame
        let third = f.height / 3
        let t: DropTarget
        if col.tabbed && pointer.y < f.minY + TabLayout.barHeight {
            t = .into(column: col.index, row: col.windows.count)   // dropped on a tab bar: join as a tab
        } else if !col.tabbed && pointer.y < f.minY + titleBand {
            t = .tabs(column: col.index)                           // dropped on a window's title bar: make a tab group
        } else if pointer.y >= f.minY + third && pointer.y < f.minY + 2 * third {
            let row = col.tabbed ? col.windows.count : col.rows.filter { $0.midY < pointer.y }.count
            t = .into(column: col.index, row: row)
        } else {
            t = pointer.x < f.midX ? .before(column: col.index) : .after(column: col.index)
        }
        return isNoOp(t, source: source, columns: columns, pinSource: pinSource) ? nil : t
    }

    /// On the pin: the top band (a tab bar's height on a tabbed pin, else a title bar's) makes the window a tab of it, the rest
    /// of it puts the window into it, at the row under the pointer.
    private static func pinTarget(_ p: CGPoint, _ pin: DropColumn) -> DropTarget {
        if p.y < pin.frame.minY + (pin.tabbed ? TabLayout.barHeight : titleBand) { return .pinTabs }
        return .pinInto(row: pin.tabbed ? pin.windows.count : pin.rows.filter { $0.midY < p.y }.count)
    }

    /// A drop that would leave everything as it is: a lone window next to (or in) its own column, or a stack window
    /// dropped back at its own row.
    static func isNoOp(_ t: DropTarget, source: (column: Int, alone: Bool, row: Int)?, columns: [DropColumn],
                       pinSource: (alone: Bool, row: Int)? = nil) -> Bool {
        // A window of the pin has no ribbon column, so every ribbon target moves it out (the core makes it a column of its own).
        // Inside the pin only a lone window, its own title bar, or its own row of a stack changes nothing.
        if let p = pinSource {
            switch t {
            case .pinTabs: return true
            case .pinInto(let row): return p.alone || (row == p.row && columns.first { $0.pinned }?.tabbed == false)
            default: return false
            }
        }
        guard let s = source else { return false }
        if s.alone {
            switch t {
            case .into(let c, _), .tabs(let c): return c == s.column
            case .before(let c): return c == s.column || c == s.column + 1
            case .after(let c): return c == s.column || c == s.column - 1
            case .pinTabs, .pinInto: return false   // into the pin always changes something
            }
        }
        // Dropped back at its own row of its own stack (rows exclude the dragged window, so its slot is `row`).
        if case .into(let c, let row) = t, c == s.column, row == s.row, columns.first(where: { $0.index == c && !$0.pinned })?.tabbed == false { return true }
        if case .tabs(let c) = t, c == s.column { return true }   // onto its own title bar: nothing to join
        return false
    }

    /// What the indicator should draw for a target: a bar between columns, or a highlight over the receiving column.
    enum Mark: Equatable { case bar(CGRect), stack(CGRect, tab: Bool), tabGroup(CGRect) }

    static func mark(for t: DropTarget, columns: [DropColumn], usable: CGRect, gap: CGFloat) -> Mark? {
        let col = t.column == nil ? columns.first { $0.pinned } : columns.first { !$0.pinned && $0.index == t.column }
        guard let col else { return nil }
        let f = col.frame
        let barW: CGFloat = 8
        // A tab bar where it will appear: the strip at the top of the column, as wide as the column.
        let strip = CGRect(x: f.minX, y: f.minY, width: f.width, height: TabLayout.barHeight).insetBy(dx: 0, dy: 1)
        switch t {
        case .before:
            let x = max(f.minX - gap / 2, usable.minX + barW / 2)
            return .bar(CGRect(x: x - barW / 2, y: f.minY, width: barW, height: f.height))
        case .after:
            let x = min(f.maxX + gap / 2, usable.maxX - barW / 2)
            return .bar(CGRect(x: x - barW / 2, y: f.minY, width: barW, height: f.height))
        case .into, .pinInto:
            return .stack(f.insetBy(dx: 2, dy: 2), tab: col.tabbed)
        case .tabs, .pinTabs:
            // The pin's bar zone on a tabbed pin already has its bar: highlight the column as a tab drop, like any tabbed column.
            return col.tabbed ? .stack(f.insetBy(dx: 2, dy: 2), tab: true) : .tabGroup(strip)
        }
    }

    /// Windows that barely moved are a click or a nudge, not a drag: leave them alone.
    static func isTinyMove(from: CGPoint, to: CGPoint, threshold: CGFloat = 12) -> Bool {
        hypot(to.x - from.x, to.y - from.y) < threshold
    }
}

/// The drop rule's input, read off a plan: the visible ribbon columns, the pinned column, and where the dragged window sits.
struct DropLayout {
    var columns: [DropColumn] = []
    var source: (column: Int, alone: Bool, row: Int)?
    /// Set instead of `source` when the dragged window is one of the pin's.
    var pinSource: (alone: Bool, row: Int)?

    static func build(from plan: Plan, dragging id: UInt32) -> DropLayout {
        var l = DropLayout()
        for (i, col) in plan.map.columns.enumerated() {
            let frames = col.windows.compactMap { w in plan.frames.first { $0.id == w.id }?.cg }
            guard frames.count == col.windows.count else { continue }
            if let r = col.windows.firstIndex(where: { $0.id == id }) { l.source = (i, col.windows.count == 1, r) }
            guard col.visible else { continue }
            l.columns.append(dropColumn(i, col, frames: frames, bar: plan.tabBars.first { $0.column == i && !$0.isPinned }?.cg, dragging: id, pinned: false))
        }
        // The pin is not in `map.columns`. Its frames and its tab bar are the plan's pinned ones.
        if let pin = plan.map.pin?.column {
            if let r = pin.windows.firstIndex(where: { $0.id == id }) { l.pinSource = (pin.windows.count == 1, r) }
            let frames = pin.windows.compactMap { w in plan.frames.first { $0.id == w.id && $0.isPinned }?.cg }
            if !frames.isEmpty, frames.count == pin.windows.count {
                l.columns.append(dropColumn(plan.map.columns.count, pin, frames: frames, bar: plan.tabBars.first { $0.isPinned }?.cg, dragging: id, pinned: true))
            }
        }
        return l
    }

    private static func dropColumn(_ index: Int, _ col: MapColumn, frames: [CGRect], bar: CGRect?, dragging id: UInt32, pinned: Bool) -> DropColumn {
        if col.tabbed {
            var f = frames[min(col.active ?? 0, frames.count - 1)]
            if let bar { f = f.union(bar) }
            return DropColumn(index: index, frame: f, rows: [], tabbed: true, windows: col.windows.map(\.id), pinned: pinned)
        }
        let rows = zip(col.windows, frames).filter { $0.0.id != id }.map(\.1).sorted { $0.minY < $1.minY }
        return DropColumn(index: index, frame: frames.dropFirst().reduce(frames[0]) { $0.union($1) }, rows: rows, tabbed: false, windows: col.windows.map(\.id), pinned: pinned)
    }
}
