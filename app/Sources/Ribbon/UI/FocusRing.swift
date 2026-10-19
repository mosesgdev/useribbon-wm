import SwiftUI
import AppKit

/// A calm accent ring around the focused window: a borderless, click-through panel ordered directly
/// *below* the window (public `order(_:relativeTo:)`), so it frames the window but never covers it or
/// anything above it. On a focus change it fades in around the new window (a glide between two windows would run behind
/// both of them, since the panel sits below the new one, and show only as a line wiping across their shared edge);
/// it glides only when its own window moves or resizes.
@MainActor
final class FocusRing {
    /// Window corner radius on macOS 26 (no public API for the real one). Measured on a 2x VM capture of a plain titled window:
    /// the corner arc fits r = 28-30 px, so 15 pt. The ring's outer edge is windowRadius + ringWidth, concentric with the window.
    static let windowRadius: CGFloat = 15
    private static let glow: CGFloat = 10

    private var panel: NSPanel?
    private let view = RingView()
    private var target: UInt32?
    private var layer: Int = 0
    private var shown = false
    private var fade = RingFade()                    // the fade-in in flight: a refresh meanwhile must not cut it to full opacity
    private var windowSize = CGSize.zero, margin = 0.0   // the framed window's size and the ring's reach beyond it, for `follow`
    private static let glide: TimeInterval = 0.2
    private var glideEnds: CFTimeInterval = 0            // when the glide to the ring's last frame ends

    /// Show (or move) the ring around `axFrame` (global top-left coordinates) for window `id`. `fadeIn`: false where something
    /// covers the ring while it is placed (the swipe overlay), so that it is there at full opacity when the cover goes.
    func show(windowID id: UInt32, axFrame: CGRect, animated: Bool, fadeIn: Bool = true) {
        let p = panel ?? makePanel()
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        view.configure(width: contrast ? 8 : 5, strong: contrast)
        let margin = view.ringWidth + (contrast ? 0 : Self.glow)
        windowSize = axFrame.size; self.margin = margin
        let frame = Screens.appKitRect(axFrame).insetBy(dx: -margin, dy: -margin).integral
        let switched = shown && id != target
        let redraw = !shown || switched || p.frame.size != frame.size       // a ring that only moves keeps its picture
        if id != target || !shown {
            target = id
            layer = Self.layer(of: id)
            p.level = NSWindow.Level(rawValue: layer)
        }
        let move = animated && shown && p.frame != frame && !reduceMotion
        if switched, animated, p.frame != frame {
            // The old ring went with its window: the new one fades in around the new window. In a burst of switches it carries
            // on from the opacity it has instead of dipping to nothing each time, and with Reduce Motion it does not dip at all.
            let from = reduceMotion ? 1 : fade.switched(at: now)
            p.alphaValue = from
            p.setFrame(frame, display: true)
            p.order(.below, relativeTo: Int(id))
            if from < 1 { fadeUp(p) } else { fade.stop() }
        } else if !shown {
            p.setFrame(frame, display: true)
            p.alphaValue = fadeIn ? 0 : 1
            p.order(.below, relativeTo: Int(id))
            if fadeIn { fade.appear(at: now); fadeUp(p) } else { fade.stop(); snapOpaque(p) }
            shown = true
        } else {
            if p.frame != frame {
                if move {
                    NSAnimationContext.runAnimationGroup { c in
                        c.duration = Self.glide
                        c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
                        c.allowsImplicitAnimation = true
                        p.animator().setFrame(frame, display: true)
                    }
                    glideEnds = now + Self.glide
                } else if now < glideEnds {
                    // A glide is still running: a zero-length animation takes it over (its next step would undo a plain setFrame).
                    NSAnimationContext.runAnimationGroup { c in
                        c.duration = 0
                        p.animator().setFrame(frame, display: true)
                    }
                    glideEnds = 0
                } else {
                    // At once. A zero-length animation lands a moment later, and one per display frame (a floating window
                    // followed while it is dragged or resized) replaced the last before it landed: the ring stood still.
                    p.setFrame(frame, display: true)
                }
            }
            if switched { fade.noteSwitch(at: now) }           // the ring only moved to the next window: still part of a burst
            if !fade.isFadingIn(at: now) { p.alphaValue = 1 }
            p.order(.below, relativeTo: Int(id))
        }
        if redraw { view.needsDisplay = true }
    }

    private func fadeUp(_ p: NSPanel) {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = RingFade.duration
            p.animator().alphaValue = 1
        }
    }

    /// Full opacity at once, ending any fade the panel was still running (a hide that has not finished).
    private func snapOpaque(_ p: NSPanel) {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0
            p.animator().alphaValue = 1
        }
    }

    /// The ring is up around window `id`.
    func isUp(for id: UInt32) -> Bool { shown && target == id }

    /// Direct mode, every display frame while the window moves under the fingers: only the panel's place changes (its size and
    /// picture stay), so the ring keeps to the window between the full refreshes.
    func follow(axOrigin: CGPoint) {
        guard shown, let p = panel else { return }
        let r = Screens.appKitRect(CGRect(origin: axOrigin, size: windowSize)).insetBy(dx: -margin, dy: -margin).integral
        if r.origin != p.frame.origin { p.setFrameOrigin(r.origin) }
    }

    /// Window number of the ring's panel while it is up (the dim layer sits directly below it), else nil.
    var windowNumber: Int? { shown ? panel.map(\.windowNumber).flatMap { $0 > 0 ? $0 : nil } : nil }

    func hide(duration: TimeInterval = 0.12) {
        guard shown, let p = panel else { return }
        shown = false; target = nil; fade.stop()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = duration
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak p] in
            MainActor.assumeIsolated { if self?.shown == false { p?.orderOut(nil) } }
        })
    }

    /// kCGWindowLayer of the window (normally 0); the ring must sit on the same level to order next to it.
    static func layer(of id: UInt32) -> Int {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]]
        return (info?.first?[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.isFloatingPanel = false; p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        view.autoresizingMask = [.width, .height]
        p.contentView = view
        panel = p
        return p
    }
}

/// Draws the ring inset from the (glow-padded) panel edge. The ring tucks 2pt under the window so the
/// corner stays closed even if the window's real radius is a little larger than ours.
private final class RingView: NSView {
    private(set) var ringWidth: CGFloat = 4
    private var strong = false
    private static let tuck: CGFloat = 2

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(width: CGFloat, strong: Bool) {
        if width != ringWidth || strong != self.strong { ringWidth = width; self.strong = strong; needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let glow: CGFloat = strong ? 0 : 10
        let w = ringWidth, tuck = Self.tuck
        // Stroke centre line sits (w - tuck)/2 outside the window edge; stroke width w + tuck.
        let window = bounds.insetBy(dx: glow + w, dy: glow + w)
        let centre = window.insetBy(dx: -(w - tuck) / 2, dy: -(w - tuck) / 2)
        let r = FocusRing.windowRadius + (w - tuck) / 2
        // Continuous (squircle) corners, like the window it hugs.
        let path = NSBezierPath(cgPath: RoundedRectangle(cornerRadius: r, style: .continuous).path(in: centre).cgPath)
        path.lineWidth = w + tuck
        NSGraphicsContext.saveGraphicsState()
        if !strong {
            let s = NSShadow()
            s.shadowColor = Theme.accentNS.withAlphaComponent(0.5)
            s.shadowBlurRadius = 8; s.shadowOffset = .zero
            s.set()
        }
        (strong ? Theme.accentNS : Theme.accentNS.withAlphaComponent(1)).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
