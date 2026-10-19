import CoreGraphics
import Foundation

/// One display as Ribbon sees it. All rects are in AX space (global, top-left origin of the primary display), so a
/// display above the primary one has negative y.
struct DisplayInfo: Equatable {
    /// Stable across reconnects (CGDisplayCreateUUIDFromDisplayID). Everything per-display is keyed by this.
    var uuid: String
    /// CGDirectDisplayID (can change between reconnects; only used for the core's `display` event and CG calls).
    var id: UInt32
    var name: String
    /// The whole display.
    var frame: CGRect
    /// The part windows may use (below the menu bar, beside the Dock).
    var visible: CGRect
}

/// Directions in AX space: up means smaller y.
enum DisplayDirection: Equatable {
    case left, right, up, down
    var opposite: DisplayDirection {
        switch self { case .left: .right; case .right: .left; case .up: .down; case .down: .up }
    }
    var isHorizontal: Bool { self == .left || self == .right }
    /// Unit step in AX space.
    var step: CGPoint {
        switch self { case .left: CGPoint(x: -1, y: 0); case .right: CGPoint(x: 1, y: 0); case .up: CGPoint(x: 0, y: -1); case .down: CGPoint(x: 0, y: 1) }
    }
}

/// A window that changes display, e.g. after a hot-plug.
struct DisplayMove: Equatable {
    var id: UInt32
    var to: String
}

/// Everything that decides where things go between displays. Pure, so it is unit-tested without a second monitor.
enum DisplayGeometry {
    // MARK: adjacency

    /// The display next to `from` in a direction, from the geometry alone (OmniWM's `macOSAdjacentMonitor`): a candidate
    /// counts when its centre lies in that direction and that axis dominates. The nearest one on the axis wins, then the
    /// one best lined up with `from`. A corner-touching staircase (the built-in above and to the right of the main
    /// display) reads as "right", because the horizontal offset dominates.
    static func adjacent(from uuid: String, _ dir: DisplayDirection, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard let src = displays.first(where: { $0.uuid == uuid }) else { return nil }
        let c = CGPoint(x: src.frame.midX, y: src.frame.midY)
        let candidates = displays.filter { $0.uuid != uuid }.compactMap { d -> (d: DisplayInfo, axis: CGFloat, cross: CGFloat)? in
            let dx = d.frame.midX - c.x, dy = d.frame.midY - c.y
            switch dir {
            case .left: return dx < 0 && abs(dx) >= abs(dy) ? (d, -dx, abs(dy)) : nil
            case .right: return dx > 0 && abs(dx) >= abs(dy) ? (d, dx, abs(dy)) : nil
            case .up: return dy < 0 && abs(dy) >= abs(dx) ? (d, -dy, abs(dx)) : nil
            case .down: return dy > 0 && abs(dy) >= abs(dx) ? (d, dy, abs(dx)) : nil
            }
        }
        return candidates.min { ($0.axis, $0.cross, $0.d.uuid) < ($1.axis, $1.cross, $1.d.uuid) }?.d
    }

    /// Length of the edge two displays share when `b` is on the `dir` side of `a` (0 = they only touch at a corner, or
    /// not at all).
    static func sharedEdge(_ a: DisplayInfo, _ b: DisplayInfo, _ dir: DisplayDirection, tolerance: CGFloat = 1) -> CGFloat {
        let touching: Bool, overlap: CGFloat
        switch dir {
        case .right: touching = abs(a.frame.maxX - b.frame.minX) <= tolerance; overlap = min(a.frame.maxY, b.frame.maxY) - max(a.frame.minY, b.frame.minY)
        case .left: touching = abs(b.frame.maxX - a.frame.minX) <= tolerance; overlap = min(a.frame.maxY, b.frame.maxY) - max(a.frame.minY, b.frame.minY)
        case .down: touching = abs(a.frame.maxY - b.frame.minY) <= tolerance; overlap = min(a.frame.maxX, b.frame.maxX) - max(a.frame.minX, b.frame.minX)
        case .up: touching = abs(b.frame.maxY - a.frame.minY) <= tolerance; overlap = min(a.frame.maxX, b.frame.maxX) - max(a.frame.minX, b.frame.minX)
        }
        return touching ? max(0, overlap) : 0
    }

    /// Whether any neighbouring pair needs the pointer teleport: they touch at a corner only, or not at all. Side-by-side
    /// and stacked displays share an edge macOS already lets the pointer cross.
    static func warpDefault(_ displays: [DisplayInfo]) -> Bool {
        guard displays.count > 1 else { return false }
        for a in displays {
            for dir in [DisplayDirection.left, .right, .up, .down] {
                if let b = adjacent(from: a.uuid, dir, in: displays), sharedEdge(a, b, dir) <= 0 { return true }
            }
        }
        return false
    }

    // MARK: routing

    /// The display holding the centre of a frame.
    static func display(containing p: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(p) }
    }

    /// The display whose centre holds `frame`, else `fallback` (windows off every display go to the display under the mouse).
    static func route(_ frame: CGRect, in displays: [DisplayInfo], fallback: DisplayInfo) -> DisplayInfo {
        display(containing: CGPoint(x: frame.midX, y: frame.midY), in: displays) ?? fallback
    }

    /// The display under a point; a point in a gap (the pointer sits on the corner between two displays) takes the nearest one.
    static func nearest(to p: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let d = display(containing: p, in: displays) { return d }
        return displays.min { distance(p, $0.frame) < distance(p, $1.frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Moves a frame from one display's visible area to another's, keeping its relative position and clamping it inside.
    static func translated(_ f: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let w = min(f.width, to.width), h = min(f.height, to.height)
        let rx = from.width > 0 ? (f.minX - from.minX) / from.width : 0
        let ry = from.height > 0 ? (f.minY - from.minY) / from.height : 0
        let x = min(max(to.minX + rx * to.width, to.minX), to.maxX - w)
        let y = min(max(to.minY + ry * to.height, to.minY), to.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    // MARK: parking

    /// Where to park an off-viewport window so it never lands on another display (OmniWM's side hiding). `r` is the
    /// core's placement: a 1pt sliver past the home display's left or right edge. If that bleeds onto another display, try
    /// the opposite side; if both do, hang the window off the bottom-left corner of the home display so only one pixel
    /// shows. The candidate with the least overlap wins, ties keep the earlier one.
    static func parked(_ r: CGRect, home: CGRect, homeFrame: CGRect, others: [CGRect]) -> CGRect {
        func overlap(_ x: CGRect) -> CGFloat {
            others.reduce(0) { sum, o in let i = x.intersection(o); return i.isNull ? sum : sum + i.width * i.height }
        }
        let requested = r
        if overlap(requested) == 0 { return requested }
        var other = r
        other.origin.x = r.midX >= home.midX ? home.minX - r.width + 1 : home.maxX - 1
        let alt = overlap(other)
        if alt == 0 { return other }
        var corner = r
        corner.origin = CGPoint(x: homeFrame.minX - r.width + 1, y: homeFrame.maxY - 1)
        var best = (rect: requested, area: overlap(requested))
        if alt < best.area { best = (other, alt) }
        let c = overlap(corner)
        if c < best.area { best = (corner, c) }
        return best.rect
    }

    // MARK: mouse warp

    /// Where the pointer should jump to, if it is pressed against a display edge that macOS will not let it cross.
    /// Trigger: within `margin` of the edge, with a neighbour in that direction and no display just beyond the edge.
    /// Landing: `margin + 1` inside the neighbour's facing edge, the tangent coordinate ratio-mapped and kept
    /// `corner` away from the corners.
    static func warpDestination(from p: CGPoint, in displays: [DisplayInfo], margin: CGFloat = 1, corner: CGFloat = 16)
        -> (display: DisplayInfo, point: CGPoint)? {
        guard displays.count > 1, let src = displays.first(where: { $0.frame.insetBy(dx: -margin, dy: -margin).contains(p) }) else { return nil }
        let f = src.frame
        var dirs: [DisplayDirection] = []
        if p.x >= f.maxX - margin { dirs.append(.right) }
        if p.x <= f.minX + margin { dirs.append(.left) }
        if p.y <= f.minY + margin { dirs.append(.up) }
        if p.y >= f.maxY - margin { dirs.append(.down) }
        for dir in dirs {
            // A display right beyond the edge: macOS carries the pointer across itself.
            let probe = CGPoint(x: p.x + dir.step.x * (margin + 1), y: p.y + dir.step.y * (margin + 1))
            if displays.contains(where: { $0.uuid != src.uuid && $0.frame.contains(probe) }) { continue }
            guard let dst = adjacent(from: src.uuid, dir, in: displays) else { continue }
            let t = dst.frame, inset = margin + 1
            func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? (lo + hi) / 2 : min(max(v, lo), hi) }
            let out: CGPoint
            if dir.isHorizontal {
                let ratio = f.height > 0 ? (p.y - f.minY) / f.height : 0.5
                let y = clamp(t.minY + ratio * t.height, t.minY + corner, t.maxY - corner)
                out = CGPoint(x: dir == .right ? t.minX + inset : t.maxX - inset, y: y)
            } else {
                let ratio = f.width > 0 ? (p.x - f.minX) / f.width : 0.5
                let x = clamp(t.minX + ratio * t.width, t.minX + corner, t.maxX - corner)
                out = CGPoint(x: x, y: dir == .down ? t.minY + inset : t.maxY - inset)
            }
            return (dst, out)
        }
        return nil
    }

    // MARK: hot-plug

    /// Which windows change display after a topology change. Windows whose display vanished go to the primary one and
    /// remember where they came from (`origins`); windows whose original display is back return to it. `homes` holds only
    /// live windows. Deterministic: ids in ascending order.
    static func hotplug(homes: [UInt32: String], connected: Set<String>, primary: String, origins: [UInt32: String])
        -> (moves: [DisplayMove], origins: [UInt32: String]) {
        var moves: [DisplayMove] = []
        var origins = origins.filter { homes[$0.key] != nil }
        for id in homes.keys.sorted() {
            guard let home = homes[id] else { continue }
            if !connected.contains(home) {
                if origins[id] == nil { origins[id] = home }
                moves.append(DisplayMove(id: id, to: primary))
            } else if let o = origins[id], o != home, connected.contains(o) {
                moves.append(DisplayMove(id: id, to: o))
                origins[id] = nil
            } else if let o = origins[id], o == home {
                origins[id] = nil
            }
        }
        return (moves, origins)
    }
}
