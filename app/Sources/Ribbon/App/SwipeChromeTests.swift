import Foundation
import CoreGraphics
import AppKit

/// Selftest for what the swipe overlay draws besides the windows: the focus ring that travels with its tile through a swipe and
/// glides to the new focus at release (run from `SelfTest`). The overlay is built and moved but its panel never goes on screen.
enum SwipeChromeTests {
    static func run(_ check: (Bool, String) -> Void) {
        MainActor.assumeIsolated { ring(check); dim(check) }
    }

    @MainActor private static func image(_ side: Int = 8) -> CGImage? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    /// Other windows: Dim / Blur while the overlay covers the display: every tile but the focus one carries a tint, the backdrop's
    /// cutout follows the focus tile, and at release the cutout glides to the new focus while the tints swap.
    @MainActor private static func dim(_ check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { return }
        let o = overlay(screen, [12, 724, 1436], pinnedAt: 9)
        defer { o.teardown() }
        let area = CGRect(x: 0, y: 25, width: screen.frame.width, height: screen.frame.height - 25)
        check(!o.hasDim, "swipe dim: nothing is dimmed until the overlay is told")
        o.setDim(.dim(0.3), area: area, focus: 1, bar: nil, softened: { _ in nil }, softBackdrop: nil)
        check(o.hasDim && o.debugDimOpacity(1) == 0 && o.debugDimOpacity(2) == 0.3 && o.debugDimOpacity(3) == 0.3, "swipe dim: the other windows carry the tint, the focus window is clear")
        check(o.debugDimOpacity(9) == 0.3, "swipe dim: the pinned tile is darkened like the rest while the focus is in the ribbon, as the real dim sits above the pin")
        check(o.debugDimHole == CGRect(x: 12, y: 13, width: 700, height: 800), "swipe dim: the backdrop is cut out where the focus window is")
        var follows = true
        for dx in stride(from: 25.0, through: 300, by: 25) {
            o.move([1: 12 - dx, 2: 724 - dx, 3: 1436 - dx])
            let hole = o.debugDimHole
            follows = follows && hole?.maxX == o.currentX(1)! + 700 && hole?.minX == max(0, o.currentX(1)!)
        }
        check(follows, "swipe dim: the cutout moves with the focus window frame by frame (cut at the display's edge)")
        // Release: the focus passes to tile 2; the cutout glides there, the tints trade places.
        o.setDimFocus(2, bar: nil, now: 1)
        check(o.debugDimOpacity(1) == 0.3 && o.debugDimOpacity(2) == 0, "swipe dim: the old focus darkens, the new one clears")
        check(o.debugDimHole?.maxX == o.currentX(1)! + 700, "swipe dim: at release the cutout is still where the old focus is")
        o.settle(to: [1: -700, 2: 12, 3: 724], velocity: 0, now: 1)
        var t = 1.0
        while t < 1.6 { t += 1.0 / 120; _ = o.step(at: t) }
        let landed = o.debugDimHole ?? .zero
        check(abs(landed.minX - 12) < 0.01 && abs(landed.minY - 13) < 0.01 && abs(landed.width - 700) < 0.01 && o.currentX(2) == 12, "swipe dim: the cutout lands on the new focus window")
        // The focus in the pin: the pinned tile is clear, the ribbon's tiles carry the tint, and the cutout is where the pin is.
        o.setDim(.dim(0.3), area: area, focus: 9, bar: nil, softened: { _ in nil }, softBackdrop: nil)
        check(o.debugDimOpacity(9) == 0 && o.debugDimOpacity(1) == 0.3 && o.debugDimHole == CGRect(x: 12, y: 13, width: 500, height: 800), "swipe dim: with the focus in the pin the pinned tile is clear and the ribbon is darkened")
        o.setDimFocus(1, bar: nil, now: 3)
        check(o.debugDimOpacity(9) == 0.3 && o.debugDimOpacity(1) == 0, "swipe dim: the focus leaving the pin darkens the pinned tile")
        // The focus column's tab bar is cut out too, and rides with the window.
        o.setDim(.dim(0.3), area: area, focus: 2, bar: CGRect(x: 0, y: -34, width: 700, height: 28), softened: { _ in nil }, softBackdrop: nil)
        o.move([1: -700, 2: 100, 3: 812])
        check(o.debugDimHole?.minX == 100, "swipe dim: with a tab bar the window's cutout still follows its tile")
        // A placeholder that gets its picture while the swipe runs keeps its tint.
        let o2 = overlay(screen, [12, 724])
        defer { o2.teardown() }
        o2.setDim(.dim(0.3), area: area, focus: 1, bar: nil, softened: { _ in nil }, softBackdrop: nil)
        o2.setImage(2, image()!, softened: nil, real: nil)
        check(o2.debugDimOpacity(2) == 0.3, "swipe dim: a tile whose picture arrives mid-swipe is still dimmed")
        // Blur: the same layout, a light tint over frosted twins.
        o2.setDim(.blur(tint: 0.12), area: area, focus: 1, bar: nil, softened: { _ in image() }, softBackdrop: image())
        check(o2.debugDimOpacity(2) == Float(0.12) && o2.debugDimOpacity(1) == 0, "swipe dim: Blur tints the other windows lightly")
        o2.removeDim()
        check(!o2.hasDim && o2.debugDimHole == nil && o2.debugDimOpacity(2) == nil, "swipe dim: removed")
        o2.setDim(.off, area: area, focus: 1, bar: nil, softened: { _ in nil }, softBackdrop: nil)
        check(!o2.hasDim, "swipe dim: no style, no dim")
    }

    @MainActor private static func overlay(_ screen: NSScreen, _ xs: [Double], pinnedAt: UInt32? = nil) -> SwipeOverlay {
        let o = SwipeOverlay()
        o.presents = false
        let disp = CGRect(origin: .zero, size: screen.frame.size)
        var specs = xs.enumerated().map { SwipeOverlay.TileSpec(id: UInt32($0.offset + 1), rect: CGRect(x: $0.element, y: 38, width: 700, height: 800), pid: 1) }
        if let pin = pinnedAt { specs.append(SwipeOverlay.TileSpec(id: pin, rect: CGRect(x: 12, y: 38, width: 500, height: 800), pid: 1, held: true)) }
        o.stage(on: screen, displayAX: disp, backdrop: nil, softBackdrop: nil, tiles: specs, edge: nil, signature: "chrome",
                image: { _, _ in nil }, realFrame: { _ in nil }, softened: { _ in nil }, icon: { _ in nil })
        o.reveal()
        return o
    }

    @MainActor private static func ring(_ check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { return }
        let o = overlay(screen, [12, 724, 1436])
        defer { o.teardown() }
        func ringX(_ o: SwipeOverlay) -> Double? { o.debugRingFrame.map { $0.minX + o.debugRingMargin } }     // where the ring's window edge is
        check(!o.hasRing, "swipe ring: no ring until one is asked for")
        // At the first movement the ring is drawn on the focus tile, and every move of the tiles carries it along.
        o.ring(from: nil, to: 1, now: 0)
        check(o.hasRing && ringX(o) == 12, "swipe ring: drawn on the focus tile when the swipe starts")
        var follows = true
        for dx in stride(from: 25.0, through: 600, by: 25) {
            o.move([1: 12 - dx, 2: 724 - dx, 3: 1436 - dx])
            follows = follows && ringX(o) == o.currentX(1)
        }
        check(follows && ringX(o) == -588, "swipe ring: it follows its tile through 600 px of swipe, frame by frame")
        // Release: the focus passes to the next tile and the ring glides there under the tiles' spring.
        o.ring(from: 1, to: 2, now: 1)
        check(ringX(o) == -588, "swipe ring: at release it is still where the old focus is")
        o.settle(to: [1: -700, 2: 12, 3: 724], velocity: 0, now: 1)
        var last = ringX(o)!, monotone = true, t = 1.0
        while t < 1.6 {
            t += 1.0 / 120
            _ = o.step(at: t)
            let x = ringX(o)!
            monotone = monotone && x >= last - 1e-9
            last = x
        }
        check(monotone && abs(ringX(o)! - 12) < 0.01 && o.currentX(2) == 12, "swipe ring: it glides to the new focus without overshoot and lands on it")
        // Reduce Motion: no glide.
        o.ring(from: 2, to: 3, now: 5, animated: false)
        check(ringX(o) == o.currentX(3), "swipe ring: without a glide it is on the new focus at once")
        // A release that moves no tile but changes the focus: the overlay waits for the ring.
        o.ring(from: 3, to: 1, now: 10)
        o.settle(to: [1: -700, 2: 12, 3: 724], velocity: 0, now: 10)
        check(!o.step(at: 10.1) && o.step(at: 10.6), "swipe ring: with no tile gliding the overlay stays up until the ring has arrived")
        o.removeRing()
        check(!o.hasRing && o.debugRingFrame == nil, "swipe ring: removed")
    }
}
