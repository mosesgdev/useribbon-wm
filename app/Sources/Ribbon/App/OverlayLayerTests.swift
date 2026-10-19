import Foundation
import AppKit
import QuartzCore

/// Selftest for what the swipe overlay draws besides the sliding tiles: their shadows, which tile is on top, and the windows the
/// ribbon leaves where they are (run from `SelfTest`).
enum OverlayLayerTests {
    static func run(_ check: (Bool, String) -> Void) {
        MainActor.assumeIsolated {
            shadows(check)
            stacking(check)
        }
        floaters(check)
    }

    /// Real windows have shadows and the snapshots are taken without: every tile carries the same soft one, on a path precomputed
    /// from the window's own corner (no offscreen pass per frame).
    @MainActor private static func shadows(_ check: (Bool, String) -> Void) {
        func rounded(_ r: CGFloat) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 400, height: 300), cornerWidth: r * 2, cornerHeight: r * 2, transform: nil))
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath()
            return ctx.makeImage()
        }
        let tile = CALayer()
        tile.bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        SwipeOverlay.shade(tile, image: rounded(10))
        check(tile.shadowOpacity == 0.32 && tile.shadowRadius == 16 && tile.shadowOffset == .zero && tile.shadowPath?.boundingBoxOfPath == tile.bounds,
              "overlay: a ribbon tile has the soft shadow of the pin, on a path of its own size")
        let bare = CALayer()
        bare.bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        SwipeOverlay.shade(bare, image: nil)
        check(bare.shadowPath?.boundingBoxOfPath == bare.bounds && bare.shadowOpacity == 0.32, "overlay: so does a tile that waits for its picture")
        // A floating window's tile that has no picture yet is empty: a shadow on its path alone would be a dark box over the window.
        let floater = CALayer()
        floater.bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        SwipeOverlay.shadeFloater(floater, image: nil)
        check(floater.shadowOpacity == 0 && floater.shadowPath == nil, "overlay: a floating window without its picture casts no shadow")
        SwipeOverlay.shadeFloater(floater, image: rounded(10))
        check(floater.shadowOpacity == 0.32 && floater.shadowPath?.boundingBoxOfPath == floater.bounds, "overlay: and the soft shadow once its picture has arrived")
    }

    /// The focused window is the frontmost of the ribbon's windows: where two pass each other (a column swap) its tile is on top.
    @MainActor private static func stacking(_ check: (Bool, String) -> Void) {
        let layers: [UInt32: CALayer] = [1: CALayer(), 2: CALayer(), 3: CALayer()]
        SwipeOverlay.raise(2, from: nil, in: layers)
        check(layers[2]!.zPosition > layers[1]!.zPosition && layers[2]!.zPosition > layers[3]!.zPosition, "overlay: the focused tile is above the others in a swap")
        SwipeOverlay.raise(3, from: 2, in: layers)
        check(layers[3]!.zPosition > layers[2]!.zPosition && layers[2]!.zPosition == layers[1]!.zPosition, "overlay: focus moving on puts the new tile on top and the old one back with the rest")
        SwipeOverlay.raise(nil, from: 3, in: layers)
        check(layers.values.allSatisfy { $0.zPosition == 0 }, "overlay: no focus, no raised tile")
    }

    private static func floaters(_ check: (Bool, String) -> Void) {
        typealias E = WindowStack.Entry
        let disp = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let own: pid_t = 77
        func win(_ id: Int, _ pid: pid_t, _ x: Double, _ w: Double = 600, layer: Int = 0, y: Double = 40, h: Double = 500) -> E {
            E(id: id, layer: layer, pid: pid, bounds: CGRect(x: x, y: y, width: w, height: h))
        }
        let tiled: Set<UInt32> = [1, 2]
        // Front to back: a float rule's window over both tiles, the tiles, the Dock, Ribbon's own windows, a sheet of a tile's app,
        // a parked sliver, a helper window, something far off the display, a window behind everything.
        let stack = [win(50, 9, 300), win(1, 3, 12), win(2, 4, 700), win(30, 5, 0, 1512, layer: 20), win(31, own, 0, 1512, layer: 3), win(60, 3, 100, 300, y: 100, h: 200),
                     win(80, 6, -599, 600), win(70, 8, 400, 10, h: 10), win(90, 9, 5000), win(95, 10, 200, 1000, y: 500, h: 400)]
        let picked = OverlayFloaters.pick(stack: stack, tiled: tiled, ownPID: own, display: disp)
        check(picked.map(\.id) == [50, 95], "floaters: the windows the ribbon does not move are picked (not the tiles, the Dock, Ribbon's own, a sheet, a sliver, a helper, one off the display)")
        check(picked.first?.above == true && picked.last?.above == false, "floaters: one in front of every tile is drawn over the ribbon, one behind them under it")
        check(picked.first?.rect == CGRect(x: 300, y: 40, width: 600, height: 500), "floaters: a window is drawn where the window server has it")
        let between = [win(1, 3, 12), win(50, 9, 300), win(2, 4, 700)]
        check(OverlayFloaters.pick(stack: between, tiled: tiled, ownPID: own, display: disp).first?.above == false,
              "floaters: one that a tile covers is under the ribbon (the tile in front of it hides it where they overlap)")
        check(OverlayFloaters.pick(stack: [win(50, 9, 300)], tiled: tiled, ownPID: own, display: disp).first?.above == true,
              "floaters: with no tile on the display the window is simply over the ribbon")
        let many = (0..<9).map { win(100 + $0, pid_t(20 + $0), Double($0) * 40) }
        check(OverlayFloaters.pick(stack: many, tiled: [], ownPID: own, display: disp).map(\.id) == [100, 101, 102, 103], "floaters: no more than four, the frontmost")

        // The backdrop leaves the floating windows out too; the Dock and menus above the overlay and Ribbon's own go as before.
        let ws: [(id: UInt32, layer: Int, pid: pid_t?)] = [(1, -2147483624, 90), (2, 0, 91), (3, 0, 92), (4, 0, 93), (5, 20, 90), (8, 2, 77)]
        check(SnapshotStore.backdropHides(ws, managed: [3], floaters: [2], ownPID: 77) == [2, 3, 5, 8] && SnapshotStore.backdropHides(ws, managed: [3], ownPID: 77) == [3, 5, 8],
              "overlay backdrop: a floating window is left out of it (drawn as a tile of its own), the wallpaper and unmanaged others stay")

        // The backdrop is captured again when the windows a ribbon lays out change: one opened, closed, floated or tiled.
        var set = TiledSet()
        check(set.changed([1, 2, 3], on: "A"), "backdrop: the first look at a display counts as a change")
        check(!set.changed([3, 2, 1], on: "A"), "backdrop: the same windows are no change")
        check(set.changed([1, 2, 3, 4], on: "A") && set.changed([1, 2, 4], on: "A"), "backdrop: a window that opened, or one that closed or floated, is a change")
        check(set.changed([1, 2, 3, 4], on: "A") && !set.changed([1, 2, 3, 4], on: "A"), "backdrop: one that tiled again is a change, once")
        check(set.changed([1, 2], on: "B") && !set.changed([1, 2, 3, 4], on: "A"), "backdrop: each display has its own windows")
    }
}
