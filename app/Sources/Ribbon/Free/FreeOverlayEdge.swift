import AppKit
import QuartzCore

// The free edition's swipe overlay has no column held outside the ribbon to dress itself for: nothing is blurred, dissolved or clipped.

/// Where the ribbon meets a held column: there is none, so no window is ever hidden beneath one.
struct PinEdge: Equatable {
    func hides(_ r: CGRect) -> Bool { false }
}

/// What the swipe overlay adds for a held column (the Plus edition's `OverlayEdge`): nothing, and the ribbon's tiles go straight into the clip.
@MainActor
final class OverlayEdge {
    var edge: PinEdge? { nil }
    var layers: [CALayer] { [] }
    func install(bounds: CGRect) {}
    func setBackground(_ color: CGColor?) {}
    func setDissolve(_ image: CGImage?) {}
    func reset() {}
    func place(_ layer: CALayer, held: Bool, in ribbonClip: CALayer) { ribbonClip.addSublayer(layer) }
    func clearTiles() {}
    func hide() {}
    func layOut(_ e: PinEdge?, ribbonClip: CALayer, bounds: CGRect) {
        ribbonClip.frame = bounds
        ribbonClip.bounds = bounds                                // children keep display coordinates
    }
    func update(now: Double, tiles: @autoclosure () -> [(x: CGFloat, w: CGFloat)]) {}
    func setTwin(_ id: UInt32, _ img: CGImage, look: CGSize, at position: CGPoint) {}
    func removeTwin(_ id: UInt32) {}
    func moveTwin(_ id: UInt32, to position: CGPoint) {}
    func fitTwin(_ id: UInt32, bounds: CGRect, at position: CGPoint) {}
}
