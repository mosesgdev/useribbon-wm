import Foundation
import CoreGraphics

// Pure logic behind the interactive ribbon map: geometry, drag slots, captions and the commands a gesture sends.
// No UI types here, so the selftest can cover all of it.

/// A command argument: a plain number, or one of the objects a drag sends.
enum CmdArg: Equatable, Encodable {
    case int(Int)
    case double(Double)
    /// `move_to_index`'s {"id", "index"}.
    case move(id: UInt32, index: Int)
    /// `move_window_to` into a column held outside the ribbon (Plus): its own argument.
    case held(HeldArg)
    /// `move_window_to` at a ribbon column (1-based, as the map shows it): {"id", "column", "position": "before" | "after" | ...}.
    case moveTo(id: UInt32, column: Int, position: String)

    private struct MoveTo: Encodable { var id: Int; var column: Int; var position: String }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let n): try c.encode(n)
        case .double(let d): try c.encode(d)
        case .move(let id, let index): try c.encode(["id": Int(id), "index": index])
        case .held(let a): try c.encode(a)
        case .moveTo(let id, let column, let position): try c.encode(MoveTo(id: Int(id), column: column, position: position))
        }
    }
}

/// One engine command produced by a HUD gesture.
struct HUDCommand: Equatable {
    var name: String
    var arg: CmdArg?
    init(_ name: String, _ arg: CmdArg? = nil) { self.name = name; self.arg = arg }
}

/// An in-flight tile drag: which column, and how far the pointer has moved horizontally.
/// A held column's tile (Plus) has no ribbon column: `from` is -1 and `held` names the window of it that was grabbed.
struct HUDDrag: Equatable {
    var from: Int
    var dx: CGFloat
    var held: HeldHit? = nil
}

/// Where a drag would land if it were let go now.
enum HUDDrop: Equatable {
    /// A ribbon tile takes this slot of the ribbon.
    case slot(Int)
    /// Somewhere a held column (Plus) decides: into it, or out of it into the ribbon.
    case held(HeldLanding)
    /// Nothing to do.
    case stay
}

enum HUDPointerEvent { case move, down, drag, up, exit }
/// What the pointer is on: a ribbon window, a window of a held column's tile (Plus), or a desktop dot.
enum HUDHit: Equatable { case window(col: Int, row: Int), held(HeldHit), dot(Int) }

/// How big the strip draws (Settings → General). Small is the slim 78pt strip; Medium, the default, is 1.25× and Large 1.5×.
enum StripSize: String, CaseIterable, Identifiable {
    case small, medium, large
    static let key = "stripSize"
    var id: String { rawValue }
    var label: String { switch self { case .small: "Small"; case .medium: "Medium"; case .large: "Large" } }
    var scale: CGFloat { switch self { case .small: 1; case .medium: 1.25; case .large: 1.5 } }
    static func from(_ raw: String?) -> StripSize { raw.flatMap(StripSize.init(rawValue:)) ?? .medium }
}

enum HUDLayout {
    /// The one size knob. Every dimension below is written once, at Small, and drawn at `size`; `HUDController.setSize`
    /// changes it (main thread) and redraws, so drawing, hit testing and the panel size always agree.
    static var size = StripSize.medium
    /// A Small measurement at the current size, snapped to the half point (a Retina pixel) so edges stay crisp.
    static func u(_ small: CGFloat) -> CGFloat { (small * size.scale * 2).rounded() / 2 }

    // The slim strip: 40pt tiles drawn to scale (width follows the column's width), one caption line with desktop dots.
    static var tileH: CGFloat { u(40) }; static var gap: CGFloat { u(4) }; static var stackGap: CGFloat { u(2) }
    /// Tile width per unit of column width: a ratio, so it scales unsnapped (`tileWidth` rounds the result).
    static var minTileW: CGFloat { u(32) }; static var maxTileW: CGFloat { u(104) }; static var ptPerFrac: CGFloat { 102.4 * size.scale }
    /// Pill radius (a floating panel, 20 at Small) = tile radius (a row) + the padding around the tiles, so the corners stay concentric.
    static var tileRadius: CGFloat { u(Theme.Radius.row) }
    static var pillRadius: CGFloat { tileRadius + padX }
    static var padX: CGFloat { u(8) }; static var padTop: CGFloat { u(8) }; static var padBottom: CGFloat { u(4) }; static var emptyPadV: CGFloat { u(7) }
    static var railGap: CGFloat { u(4) }; static var footH: CGFloat { u(22) }; static var footInset: CGFloat { u(6) }
    static var minPillW: CGFloat { u(208) }; static var emptyPillW: CGFloat { u(360) }
    /// Room the caption needs before the dots: about 16 characters of title, the gap and "10/10".
    static var titleBlockMin: CGFloat { u(142) }; static var footGap: CGFloat { u(12) }
    static var maxTrack: CGFloat { u(480) }; static var moreW: CGFloat { u(22) }; static var fadeW: CGFloat { u(32) }
    static var dotCell: CGFloat { u(16) }
    /// Tiles take hits a little above their top edge, so the pill's padding is not a dead zone.
    static var hitTop: CGFloat { u(4) }

    // Drawing only: type, rings, badge, dots and shadows follow the same size.
    /// Caption: the window's name, then "6/10" (or the empty desktop's hint), `captionGap` apart.
    static var nameFont: CGFloat { u(12.5) }; static var detailFont: CGFloat { u(12) }; static var hintFont: CGFloat { u(11.5) }
    static var captionGap: CGFloat { u(8) }
    /// "‹ 3" beside an overflowing strip.
    static var moreFont: CGFloat { u(10.5) }; static var chevronFont: CGFloat { u(8) }; static var moreSpacing: CGFloat { u(1) }
    /// Corners where two slivers of a stack meet (the tile's own clip rounds the outside).
    static var sliverRadius: CGFloat { u(4) }
    /// Focus ring on the tile's edge (Increase Contrast: thicker), and the plain edge Increase Contrast gives other tiles.
    static func ringW(increased: Bool) -> CGFloat { u(increased ? 3 : 2) }
    static var edgeW: CGFloat { u(1) }
    /// Count badge on a tile's corner: type, a capsule at least `badgeMin` across, and its ring of window colour.
    static var badgeFont: CGFloat { u(9) }; static var badgeMin: CGFloat { u(13) }; static var badgePadX: CGFloat { u(3) }
    static var badgeRing: CGFloat { u(1.5) }; static var badgeOutset: CGFloat { u(1) }
    /// Desktop dots: a capsule for here, dots for the rest, ringed when empty.
    static var deskDot: CGFloat { u(5) }; static var deskHereW: CGFloat { u(12) }
    static func deskStroke(increased: Bool) -> CGFloat { u(increased ? 1.5 : 1) }
    /// Shadows of the focused plate and of a lifted tile, and the room the clip leaves them.
    static var raisedShadow: (radius: CGFloat, y: CGFloat) { (u(6), u(2)) }
    static var dragShadow: (radius: CGFloat, y: CGFloat) { (u(16), u(8)) }
    static var clipRoom: CGFloat { u(60) }; static var clipRoomOver: CGFloat { u(8) }; static var clipRoomV: CGFloat { u(30) }

    static func tileWidth(frac: Double) -> CGFloat { min(max((CGFloat(frac) * ptPerFrac).rounded(), minTileW), maxTileW) }
    static func pillHeight(hasTiles: Bool) -> CGFloat { hasTiles ? padTop + tileH + railGap + footH + padBottom : 2 * emptyPadV + footH }
    /// Height of one window's sliver when a column stacks `rows` of them (40 / 19 at Small).
    static func sliverH(_ rows: Int) -> CGFloat { rows <= 1 ? tileH : (tileH - stackGap * CGFloat(rows - 1)) / CGFloat(rows) }
    /// App icon frame by sliver: icons carry about 10% transparent margin, so 24 draws about 19pt of artwork (at Small).
    static func iconFrame(rows: Int) -> CGFloat { u(rows <= 1 ? 24 : 17) }

    /// Window indices a stack draws, top to bottom: at most two (a third sliver would be too thin to round or to read),
    /// and the second is the focused window when it sits lower. The tile's count badge says how many there are.
    static func stackRows(count: Int, focusRow: Int?) -> [Int] {
        if count <= 2 { return Array(0..<count) }
        if let f = focusRow, f >= 2, f < count { return [0, f] }
        return [0, 1]
    }

    /// The window indices a column's tile draws: a tab group shows its active tab, a stack its slivers.
    static func rows(of c: MapColumn, focusID: UInt32?) -> [Int] {
        guard !c.windows.isEmpty else { return [] }
        if c.tabbed { return [min(max(c.active ?? 0, 0), c.windows.count - 1)] }
        return stackRows(count: c.windows.count, focusRow: focusID.flatMap { id in c.windows.firstIndex { $0.id == id } })
    }

    /// Tiles laid out left to right with `gap` between them (track coordinates).
    static func tiles(widths: [CGFloat], rows: [[Int]]? = nil) -> [HUDStrip.Tile] {
        var x: CGFloat = 0
        return widths.enumerated().map { i, w in
            defer { x += w + gap }
            return HUDStrip.Tile(x: x, w: w, rows: rows.map { $0[i] } ?? [0])
        }
    }

    /// How far an overflowing track scrolls: centred on what is on screen, but never with the focused tile in a fade.
    static func stripShift(tiles: [HUDStrip.Tile], viewW: CGFloat, trackW: CGFloat, span: ClosedRange<Int>?, focus: Int?) -> CGFloat {
        guard trackW > viewW, !tiles.isEmpty else { return 0 }
        let maxShift = trackW - viewW
        let f = focus.map { min(max($0, 0), tiles.count - 1) }
        func mid(_ i: Int) -> CGFloat { tiles[i].x + tiles[i].w / 2 }
        let centre: CGFloat
        if let s = span, tiles.indices.contains(s.lowerBound), tiles.indices.contains(s.upperBound) {
            centre = (tiles[s.lowerBound].x + tiles[s.upperBound].x + tiles[s.upperBound].w) / 2
        } else {
            centre = mid(f ?? 0)
        }
        var s = min(max(centre - viewW / 2, 0), maxShift)
        if let f { s = min(max(s, mid(f) - 0.75 * viewW), mid(f) - 0.25 * viewW) }
        return min(max(s, 0), maxShift)
    }

    /// Where a column lands when dragged `dx` points: the slot whose final position is nearest the dragged tile's centre.
    /// Ties stay put. With equal widths this is whole slots, as before.
    static func slotIndex(from: Int, dx: CGFloat, widths: [CGFloat]) -> Int {
        guard widths.indices.contains(from) else { return 0 }
        let w = widths[from]
        let centre = widths[..<from].reduce(0, +) + CGFloat(from) * gap + w / 2 + dx
        let others = widths.enumerated().filter { $0.offset != from }.map(\.element)
        var best = from, bestD = CGFloat.infinity, x: CGFloat = 0
        for t in widths.indices {
            let d = abs(x + w / 2 - centre)
            if d < bestD - 0.001 || (abs(d - bestD) <= 0.001 && abs(t - from) < abs(best - from)) { best = t; bestD = d }
            if t < others.count { x += others[t] + gap }
        }
        return best
    }

    /// Slots a non-dragged tile slides while `from` is dragged over `to`: the tiles in between make room.
    static func shift(of i: Int, from: Int, to: Int) -> Int {
        if i == from { return 0 }
        if from < to, i > from, i <= to { return -1 }
        if from > to, i < from, i >= to { return 1 }
        return 0
    }

    /// Final left-to-right order (original indices) if `from` is dropped at `to`.
    static func order(count: Int, from: Int, to: Int) -> [Int] {
        var o = Array(0..<count)
        guard o.indices.contains(from), o.indices.contains(to) else { return o }
        o.insert(o.remove(at: from), at: to)
        return o
    }

    /// Index range of the columns on screen (the lens), or nil when none are.
    static func visibleSpan(_ cols: [MapColumn]) -> ClosedRange<Int>? {
        let v = cols.indices.filter { cols[$0].visible }
        return v.first.flatMap { f in v.last.map { f...$0 } }
    }

    /// Commands for dropping column `from` at slot `to` (both 0-based). A single window uses `move_to_index` with the
    /// 1-based target. A stack must move as one: focus it (`focus` when it is in the column, else its first window), then step
    /// it with `move_left`/`move_right` (they swap columns).
    static func moveCommands(columns: [[UInt32]], from: Int, to: Int, focus: UInt32? = nil) -> [HUDCommand] {
        guard columns.indices.contains(from), columns.indices.contains(to), from != to, let first = columns[from].first else { return [] }
        if columns[from].count == 1 { return [HUDCommand("move_to_index", .move(id: first, index: to + 1))] }
        let lead = focus.flatMap { columns[from].contains($0) ? $0 : nil } ?? first
        return [HUDCommand("focus_window", .int(Int(lead)))]
            + Array(repeating: HUDCommand(to > from ? "move_right" : "move_left"), count: abs(to - from))
    }

    /// The same for a map: a tab group keeps its active tab (focusing another tab would switch to it), a stack its focused window.
    static func moveCommands(map: RibbonMap, focusID: UInt32?, from: Int, to: Int) -> [HUDCommand] {
        let ids = map.columns.map { $0.windows.map(\.id) }
        guard map.columns.indices.contains(from) else { return [] }
        let c = map.columns[from]
        let lead = c.tabbed ? c.active.flatMap { c.windows.indices.contains($0) ? c.windows[$0].id : nil } : focusID
        return moveCommands(columns: ids, from: from, to: to, focus: lead)
    }

    /// Where a drag lands if let go now: the slot whose final position is nearest the dragged tile, unless a held column (Plus)
    /// claims the drop. Both read the raw pointer, as drops always have.
    static func drop(_ d: HUDDrag, _ g: HUDStrip) -> HUDDrop {
        if let h = d.held { return h.drop(dx: d.dx, g) }
        guard g.tiles.indices.contains(d.from) else { return .stay }
        if let l = g.held?.landing(from: d.from, dx: d.dx, g) { return .held(l) }
        return .slot(slotIndex(from: d.from, dx: d.dx, widths: g.tiles.map(\.w)))
    }

    /// Slots a ribbon tile slides while something is dragged: the tiles passed make room for a reorder (a held column's landing
    /// says its own).
    static func slide(of i: Int, drag d: HUDDrag, drop: HUDDrop) -> Int {
        switch drop {
        case .slot(let to): return shift(of: i, from: d.from, to: to)
        case .held(let l): return l.slide(of: i, from: d.from)
        case .stay: return 0
        }
    }

    /// Commands for letting go of `d`: a reorder, or what a held column's landing sends.
    static func dropCommands(map: RibbonMap, focusID: UInt32?, drag d: HUDDrag) -> [HUDCommand] {
        switch drop(d, HUDStrip(map: map, focusID: focusID)) {
        case .stay: return []
        case .slot(let to): return moveCommands(map: map, focusID: focusID, from: d.from, to: to)
        case .held(let l): return l.commands(map: map, focusID: focusID, drag: d)
        }
    }

    /// What is under `p` (pill coordinates, top-left origin). Reads the same `HUDStrip` the view draws from.
    /// Each tile owns half the gap on either side, so there is no dead zone between tiles.
    static func hit(_ p: CGPoint, map: RibbonMap, focusID: UInt32?) -> HUDHit? {
        let g = HUDStrip(map: map, focusID: focusID)
        if g.hasTiles, p.y >= padTop - hitTop, p.y < g.footTop {
            if let h = g.held, h.covers(p.x, g) { return h.hit(p) }
            if g.hasTrack, p.x >= g.viewX, p.x < g.viewX + g.viewW {
                let tx = p.x - g.viewX + g.shift
                guard let c = g.tiles.firstIndex(where: { tx >= $0.x - gap / 2 && tx < $0.x + $0.w + gap / 2 }) else { return nil }
                let rows = g.tiles[c].rows
                guard let first = rows.first else { return nil }
                guard rows.count > 1 else { return .window(col: c, row: first) }
                return .window(col: c, row: rows[stackRow(p.y, rows: rows.count)])
            }
        }
        if g.dots > 0, p.y >= g.footTop, p.y < g.pillH, p.x >= g.dotsX0, p.x < g.dotsX0 + CGFloat(g.dots) * dotCell {
            return .dot(Int((p.x - g.dotsX0) / dotCell) + 1)
        }
        return nil
    }

    /// Which of a stack's `rows` slivers pill height `y` is on (the gap between two belongs to the lower one).
    static func stackRow(_ y: CGFloat, rows: Int) -> Int {
        let pitch = sliverH(rows) + stackGap
        return min(max(Int(((y - padTop + stackGap / 2) / pitch).rounded(.down)), 0), rows - 1)
    }

    static func focusCommand(_ id: UInt32) -> [HUDCommand] { [HUDCommand("focus_window", .int(Int(id)))] }
    static func desktopCommand(_ n: Int) -> [HUDCommand] { [HUDCommand("switch_desktop", .int(n))] }

    /// Desktops to draw as dots: up to the last one in use or active; nothing while everything lives on desktop 1.
    static func shownDesktops(_ map: RibbonMap) -> Int {
        let n = max(map.desktop, map.desktops.last(where: { $0.count > 0 })?.index ?? 1)
        return n > 1 ? n : 0
    }
}

/// Every coordinate of the strip for one map: the view draws from it, `HUDLayout.hit` resolves against it and the
/// controller sizes the panel from it, so drawing and hit testing cannot drift apart.
struct HUDStrip: Equatable {
    /// A column's tile in track coordinates; `rows` are the window indices it draws, top to bottom.
    struct Tile: Equatable { var x: CGFloat; var w: CGFloat; var rows: [Int] }
    let tiles: [Tile]
    let trackW: CGFloat, viewW: CGFloat, shift: CGFloat
    let focus: Int?
    /// A column held outside the ribbon (Plus): its tile sits outside the track, at the strip's edge. It never counts toward the
    /// track's width, overflow, fades, counters or scroll.
    let held: HeldTile?
    let dots: Int
    let pillW: CGFloat, pillH: CGFloat

    private typealias L = HUDLayout
    /// The ribbon's tiles (the part that scrolls); a strip can hold only a held column's tile.
    var hasTrack: Bool { !tiles.isEmpty }
    var hasTiles: Bool { hasTrack || held != nil }
    var over: Bool { trackW > viewW }
    /// What a held column takes of the tile row (its tile and whatever parts it from the track).
    var heldBlockW: CGFloat { held?.blockW(hasTrack: hasTrack) ?? 0 }
    /// Is the held column's tile before the track (at the left)?
    var heldLeads: Bool { held?.leads == true }
    /// The tile row (a held tile, the track with its "more" slots), centred in the pill.
    var rowW: CGFloat { viewW + (over ? 2 * L.moreW : 0) + heldBlockW }
    var railX: CGFloat { (pillW - rowW) / 2 }
    /// Left edge of the clip box the tiles show through (pill coordinates).
    var viewX: CGFloat { railX + (heldLeads ? heldBlockW : 0) + (over ? L.moreW : 0) }
    var padTop: CGFloat { hasTiles ? L.padTop : L.emptyPadV }
    var padBottom: CGFloat { hasTiles ? L.padBottom : L.emptyPadV }
    /// Top of the caption line, where the dots take hits.
    var footTop: CGFloat { hasTiles ? L.padTop + L.tileH + L.railGap : 0 }
    var dotsX0: CGFloat { pillW - L.padX - CGFloat(dots) * L.dotCell }
    var fadeL: Bool { over && shift > 1 }
    var fadeR: Bool { over && shift < trackW - viewW - 1 }
    var hiddenLeft: Int { over ? tiles.filter { $0.x + $0.w <= shift + 2 }.count : 0 }
    var hiddenRight: Int { over ? tiles.filter { $0.x >= shift + viewW - 2 }.count : 0 }

    /// Centre of ribbon tile `i` as drawn (pill coordinates).
    func centre(of i: Int) -> CGFloat { viewX + tiles[i].x - shift + tiles[i].w / 2 }

    init(map: RibbonMap, focusID: UInt32?) {
        let held = HeldTile(map: map, focusID: focusID)
        // A held column with the focus takes it from the ribbon.
        let focus = held?.focused == true ? nil : (focusID.flatMap { HUDCaption.find(map, $0)?.0 } ?? map.focusedIndex)
        let rows: [[Int]] = map.columns.map { L.rows(of: $0, focusID: focusID) }
        let tiles = L.tiles(widths: map.columns.map { L.tileWidth(frac: $0.widthFrac) }, rows: rows)
        let trackW = tiles.last.map { $0.x + $0.w } ?? 0
        let viewW = min(trackW, L.maxTrack)
        let dots = L.shownDesktops(map)
        self.tiles = tiles; self.trackW = trackW; self.viewW = viewW; self.focus = focus; self.dots = dots
        self.held = held
        shift = L.stripShift(tiles: tiles, viewW: viewW, trackW: trackW, span: L.visibleSpan(map.columns), focus: focus)
        let heldBlock = held?.blockW(hasTrack: !tiles.isEmpty) ?? 0
        let rowW = viewW + (trackW > viewW ? 2 * L.moreW : 0) + heldBlock
        let footNeeds = 2 * L.padX + L.footInset + L.titleBlockMin + (dots > 0 ? L.footGap + L.dotCell * CGFloat(dots) : L.footInset)
        let hasTiles = !tiles.isEmpty || held != nil
        pillW = hasTiles ? max(L.minPillW, rowW + 2 * L.padX, footNeeds) : max(L.emptyPillW, footNeeds)
        pillH = L.pillHeight(hasTiles: hasTiles)
    }
}

enum HUDCaption {
    /// "App — title" (title cut short), or just the title when it already names the app.
    static func who(_ w: MapWindow) -> String {
        let t = w.title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return w.app }
        let short = t.count > 34 ? String(t.prefix(33)) + "…" : t
        return t.localizedCaseInsensitiveContains(w.app) ? short : "\(w.app) — \(short)"
    }

    /// Two levels: the name (or engine feedback) first, then "4 of 7 · Desktop 2".
    static func make(map: RibbonMap, focusID: UInt32?, hoverID: UInt32?, toast: String?) -> (primary: String, secondary: String) {
        let desk = HUDLayout.shownDesktops(map) > 0 ? "Desktop \(map.desktop)" : nil
        func join(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        let total = map.columns.count
        // Hover wins over focus: it names whatever the pointer is on.
        if let h = hoverID, let (i, w) = find(map, h) {
            return (who(w), join("\(i + 1) of \(total)", desk))
        }
        let focus = focusID.flatMap { find(map, $0) } ?? map.focusedIndex.flatMap { i in
            map.columns.indices.contains(i) ? map.columns[i].windows.first.map { (i, $0) } : nil }
        if let toast { return Self.toast(toast, focus: focus, total: total, desk: desk) }
        guard let (i, w) = focus else {
            if let desk { return ("\(desk) is empty", "Open a window to start") }
            return ("Nothing to arrange", "Open something and it'll find its place")
        }
        return (who(w), join("\(i + 1) of \(total)", desk))
    }

    /// A toast names *which* window it is about, not just where: "Doc 1 · first of 4".
    private static func toast(_ t: String, focus: (Int, MapWindow)?, total: Int, desk: String?) -> (primary: String, secondary: String) {
        func join(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        // A two-sentence notice ("X isn't responding. Ribbon will leave it alone...") reads as headline + detail.
        if let r = t.range(of: ". ") { return (String(t[..<r.lowerBound]), String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        if let (i, w) = focus {
            let name = short(w)
            switch t {
            case "First window": return ("\(name) · first of \(total)", join(desk))
            case "Last window": return ("\(name) · last of \(total)", join(desk))
            default: return (t, join("\(i + 1) of \(total)", desk))
            }
        }
        // "Desktop 3 · empty" from the engine: say what it means and what to do.
        if t.hasSuffix(" · empty") { return ("\(t.dropLast(" · empty".count)) is empty", "Open a window to start") }
        return (t, join(desk))
    }

    /// The window's own name, short: its title, or the app when it has none.
    static func short(_ w: MapWindow) -> String {
        let t = w.title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return w.app }
        return t.count > 24 ? String(t.prefix(23)) + "…" : t
    }

    static func find(_ map: RibbonMap, _ id: UInt32) -> (Int, MapWindow)? {
        for (i, c) in map.columns.enumerated() { if let w = c.windows.first(where: { $0.id == id }) { return (i, w) } }
        return nil
    }

    /// The strip's one caption line: the name, then "6/10" (or a hovered desktop's window count). A column held outside the
    /// ribbon (Plus) has no place in its order and says so instead (`heldCaption`). Toasts never show here: they have their own pill.
    static func line(map: RibbonMap, focusID: UInt32?, hoverID: UInt32?, hoverDesk: Int? = nil) -> (name: String, detail: String, preview: Bool) {
        let total = map.columns.count
        if let n = hoverDesk, let d = map.desktops.first(where: { $0.index == n }) {
            return ("Desktop \(n)", d.count == 0 ? "empty" : "\(d.count) \(d.count == 1 ? "window" : "windows")", true)
        }
        if let h = hoverID, let (i, w) = find(map, h) { return (who(w), "\(i + 1)/\(total)", true) }
        if let held = heldCaption(map, focusID: focusID, hoverID: hoverID) { return held }
        let focus = focusID.flatMap { find(map, $0) } ?? map.focusedIndex.flatMap { i in
            map.columns.indices.contains(i) && !map.columns[i].windows.isEmpty ? (i, map.columns[i].windows[0]) : nil }
        if let (i, w) = focus { return (who(w), "\(i + 1)/\(total)", false) }
        let cap = make(map: map, focusID: focusID, hoverID: nil, toast: nil)
        return (cap.primary, cap.secondary, false)
    }

    /// "Hermes, 4 of 7, focused" for VoiceOver; a tab group adds "tab group of 3", a stack "window 2 of 3" (`row` is 0-based).
    static func axLabel(app: String, index: Int, total: Int, focused: Bool, offscreen: Bool,
                        tabs: Int? = nil, row: Int? = nil, rows: Int? = nil) -> String {
        var s = "\(app), \(index + 1) of \(total)"
        if let tabs, tabs > 1 { s += ", tab group of \(tabs)" }
        if let row, let rows, rows > 1 { s += ", window \(row + 1) of \(rows)" }
        return s + (focused ? ", focused" : "") + (offscreen && !focused ? ", off screen" : "")
    }
}
