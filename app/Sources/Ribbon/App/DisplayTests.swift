import CoreGraphics
import Foundation

/// Pure multi-display logic, checked without a second monitor. Layouts are in AX space (y grows downward).
enum DisplayTests {
    private static func d(_ u: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, menu: Double = 25) -> DisplayInfo {
        DisplayInfo(uuid: u, id: 1, name: u, frame: CGRect(x: x, y: y, width: w, height: h),
                    visible: CGRect(x: x, y: y + menu, width: w, height: h - menu))
    }

    static func run(_ check: (Bool, String) -> Void) {
        // The user's setup: PHL 3840x1200 main, built-in 1512x982 above and to the right, touching only at a corner.
        let main = d("main", 0, 0, 3840, 1200), built = d("built", 3840, -982, 1512, 982)
        let stair = [main, built]
        check(DisplayGeometry.adjacent(from: "main", .right, in: stair)?.uuid == "built", "displays: staircase, built-in is right of main")
        check(DisplayGeometry.adjacent(from: "built", .left, in: stair)?.uuid == "main", "displays: staircase, main is left of built-in")
        check(DisplayGeometry.adjacent(from: "main", .up, in: stair) == nil && DisplayGeometry.adjacent(from: "main", .left, in: stair) == nil,
              "displays: nothing above or left of main")
        check(DisplayGeometry.sharedEdge(main, built, .right) == 0 && DisplayGeometry.warpDefault(stair), "displays: corner contact shares no edge, warp on by default")
        // Side by side, and stacked: edges are shared, macOS crosses by itself.
        let ext = d("ext", 1920, 0, 1920, 1080), left = d("left", 0, 0, 1920, 1080)
        check(DisplayGeometry.adjacent(from: "left", .right, in: [left, ext])?.uuid == "ext" && DisplayGeometry.sharedEdge(left, ext, .right) == 1080,
              "displays: side by side share the whole edge")
        check(!DisplayGeometry.warpDefault([left, ext]), "displays: side by side, warp off by default")
        let top = d("top", 0, -1080, 1920, 1080), bottom = d("bottom", 0, 0, 1920, 1080)
        check(DisplayGeometry.adjacent(from: "bottom", .up, in: [top, bottom])?.uuid == "top"
              && DisplayGeometry.adjacent(from: "top", .down, in: [top, bottom])?.uuid == "bottom", "displays: stacked up/down")
        check(!DisplayGeometry.warpDefault([top, bottom]) && !DisplayGeometry.warpDefault([main]), "displays: stacked or single, warp off by default")
        let apart = d("apart", 5000, 0, 1000, 800)
        check(DisplayGeometry.warpDefault([main, apart]) && DisplayGeometry.adjacent(from: "main", .right, in: [main, apart])?.uuid == "apart",
              "displays: apart (not touching) still neighbours, warp on")
        let row = [left, d("mid", 1920, 0, 1920, 1080), d("far", 3840, 0, 1920, 1080)]
        check(DisplayGeometry.adjacent(from: "left", .right, in: row)?.uuid == "mid" && DisplayGeometry.adjacent(from: "far", .left, in: row)?.uuid == "mid",
              "displays: three in a row pick the nearest")

        // Routing a frame to a display.
        let onBuilt = CGRect(x: 4000, y: -900, width: 800, height: 600)
        check(DisplayGeometry.route(onBuilt, in: stair, fallback: main).uuid == "built", "route: centre decides the display")
        let straddle = CGRect(x: 3500, y: 100, width: 800, height: 600)   // centre x 3900: past main's edge, but y is below the built-in
        check(DisplayGeometry.route(straddle, in: stair, fallback: built).uuid == "built", "route: off every display goes to the fallback (mouse display)")
        check(DisplayGeometry.route(CGRect(x: 100, y: 100, width: 800, height: 600), in: stair, fallback: built).uuid == "main", "route: window on main stays on main")
        check(DisplayGeometry.nearest(to: CGPoint(x: 3830, y: -3), in: stair)?.uuid == "main", "route: a point in the gap takes the nearest display")
        let moved = DisplayGeometry.translated(CGRect(x: 1920, y: 600, width: 800, height: 500), from: main.visible, to: built.visible)
        check(built.visible.contains(moved) && moved.size == CGSize(width: 800, height: 500), "route: translated frame lands inside the target display")

        // Parking never bleeds onto another display.
        let rightPark = CGRect(x: main.visible.maxX - 1, y: 40, width: 1800, height: 1100)
        check(DisplayGeometry.parked(rightPark, home: main.visible, homeFrame: main.frame, others: [built.frame]) == rightPark,
              "parking: staircase main keeps the right sliver (built-in is above, not beside)")
        let leftPark = CGRect(x: built.visible.minX - 800 + 1, y: -950, width: 800, height: 900)
        check(DisplayGeometry.parked(leftPark, home: built.visible, homeFrame: built.frame, others: [main.frame]) == leftPark,
              "parking: staircase built-in keeps the left sliver")
        let sbs = CGRect(x: left.visible.maxX - 1, y: 40, width: 900, height: 900)
        let flipped = DisplayGeometry.parked(sbs, home: left.visible, homeFrame: left.frame, others: [ext.frame])
        check(flipped.minX == left.visible.minX - 900 + 1 && flipped.intersection(ext.frame).isNull, "parking: side by side, the bleeding right side flips to the left")
        let mid = d("mid", 1920, 0, 1920, 1080)
        let midPark = CGRect(x: mid.visible.maxX - 1, y: 40, width: 900, height: 900)
        let cornered = DisplayGeometry.parked(midPark, home: mid.visible, homeFrame: mid.frame, others: [left.frame, d("far", 3840, 0, 1920, 1080).frame])
        check(cornered.minX == mid.frame.minX - 900 + 1 && cornered.minY == mid.frame.maxY - 1, "parking: both sides bleed, hang off the bottom-left corner")
        check(DisplayGeometry.parked(rightPark, home: main.visible, homeFrame: main.frame, others: []) == rightPark, "parking: single display unchanged")

        // Mouse warp.
        let mid1200 = DisplayGeometry.warpDestination(from: CGPoint(x: 3839, y: 600), in: stair)
        check(mid1200?.display.uuid == "built" && mid1200?.point.x == 3842, "warp: main right edge -> built-in left edge, 2pt inside")
        check(abs((mid1200?.point.y ?? 0) - (-982 + 0.5 * 982)) < 0.01, "warp: ratio mapping keeps the height fraction")
        let low = DisplayGeometry.warpDestination(from: CGPoint(x: 3839, y: 1199), in: stair)
        check((low?.point.y ?? 0) == -16, "warp: landing is clamped 16pt from the corner (bottom)")
        let high = DisplayGeometry.warpDestination(from: CGPoint(x: 3839.5, y: 2), in: stair)
        check((high?.point.y ?? 0) == -982 + 16, "warp: landing is clamped 16pt from the corner (top)")
        let back = DisplayGeometry.warpDestination(from: CGPoint(x: 3841, y: -491), in: stair)
        check(back?.display.uuid == "main" && back?.point.x == 3838 && abs((back?.point.y ?? 0) - 600) < 0.01, "warp: built-in left edge -> main right edge, ratio mapped")
        check(DisplayGeometry.warpDestination(from: CGPoint(x: 3836, y: 600), in: stair) == nil, "warp: 4pt from the edge does nothing (1pt trigger)")
        check(DisplayGeometry.warpDestination(from: CGPoint(x: 1000, y: 0), in: stair) == nil, "warp: main's top edge has no neighbour above")
        check(DisplayGeometry.warpDestination(from: CGPoint(x: 1919, y: 500), in: [left, ext]) == nil, "warp: side by side, macOS crosses by itself")
        check(DisplayGeometry.warpDestination(from: CGPoint(x: 3839, y: 600), in: [main]) == nil, "warp: one display never warps")
        let gap = [main, apart]
        check(DisplayGeometry.warpDestination(from: CGPoint(x: 3839, y: 300), in: gap)?.display.uuid == "apart", "warp: displays apart connect across the gap")

        // Hot-plug.
        let homes: [UInt32: String] = [1: "main", 2: "built", 3: "built", 4: "main"]
        let out = DisplayGeometry.hotplug(homes: homes, connected: ["main"], primary: "main", origins: [:])
        check(out.moves == [DisplayMove(id: 2, to: "main"), DisplayMove(id: 3, to: "main")] && out.origins == [2: "built", 3: "built"],
              "hotplug: windows of a removed display go to the primary and remember their origin")
        let back2 = DisplayGeometry.hotplug(homes: [1: "main", 2: "main", 3: "main", 4: "main"], connected: ["main", "built"], primary: "main", origins: out.origins)
        check(back2.moves == [DisplayMove(id: 2, to: "built"), DisplayMove(id: 3, to: "built")] && back2.origins.isEmpty,
              "hotplug: reconnecting moves them back (best effort)")
        let stay = DisplayGeometry.hotplug(homes: homes, connected: ["main", "built"], primary: "main", origins: [:])
        check(stay.moves.isEmpty, "hotplug: nothing moves when every display is still there")
        let twice = DisplayGeometry.hotplug(homes: [2: "main"], connected: ["main"], primary: "main", origins: [2: "built"])
        check(twice.moves.isEmpty && twice.origins == [2: "built"], "hotplug: still waiting for the original display")
        let primaryGone = DisplayGeometry.hotplug(homes: [1: "main"], connected: ["built"], primary: "built", origins: [:])
        check(primaryGone.moves == [DisplayMove(id: 1, to: "built")], "hotplug: if the main display vanishes the new primary takes over")

        // Session restore is per display, keyed by UUID.
        let desk = { (i: Int) in SavedDesk(index: 1, columns: [SavedColumn(windows: [SessionWindow(id: UInt32(i), pid: 1, key: "k", title: "t")], width: CoreWidth(kind: "frac", value: 0.5), heights: nil)], floating: [], focus: UInt32(i), scroll: 0) }
        let fa = SessionFile(savedAt: Date(), active: 1, desks: [desk(1)]), fb = SessionFile(savedAt: Date(), active: 2, desks: [desk(2)])
        let both = SessionFile.combine([("main", fa), ("built", fb)], primary: "main", now: Date())
        check(both?.slice(for: "built", primary: "main")?.desks == fb.desks && both?.slice(for: "main", primary: "main")?.desks == fa.desks
              && both?.slice(for: "gone", primary: "main") == nil && both?.desks == fa.desks, "session: one entry per display, keyed by UUID; top level is the primary's")
        check(fa.slice(for: "main", primary: "main") != nil && fa.slice(for: "built", primary: "main") == nil, "session: an older single-display file restores onto the primary only")

        // Restore: originals may be on any display.
        let all = [main.frame, built.frame]
        let orig = CGRect(x: 4000, y: -800, width: 900, height: 600)
        check(Restore.restoredFrame(orig, displays: all, fallback: main.visible) == orig, "restore: a frame on the second display is kept")
        let stranded = CGRect(x: 9000, y: 9000, width: 800, height: 600)
        check(main.visible.contains(Restore.restoredFrame(stranded, displays: all, fallback: main.visible)), "restore: a frame off every display is centred on the fallback")
    }
}
