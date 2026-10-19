import AppKit
import QuartzCore

/// "Other windows: Dim / Blur" (and Focus mode, which is Blur on a hotkey): one click-through, non-activating panel per display, ordered directly below the focused window
/// (or below its focus ring, which sits just under the window), so everything beneath it darkens and nothing above it does.
///
/// - The panel covers the display's *usable* area only, so the menu bar and the Dock are never dimmed (both are also above
///   normal windows in z-order, and Ribbon's own panels are on higher levels still).
/// - A dark layer with an even-odd cutout the size of the focused window, so a translucent window (Terminal, vibrancy) still
///   shows the real desktop behind it. The cutout glides to the new window over 150 ms on a focus change.
/// - A floating window that has focus is just another focused window: it gets the cutout and is never dimmed. Floating
///   windows that are not focused dim like the rest.
/// - Blur: the same panel holds an `NSVisualEffectView` (`.behindWindow`, so it blurs whatever is behind the panel; no
///   permission) under a light tint, masked with the same cutouts. Reduce Transparency never gets here: the style resolves
///   to a stronger dim instead (`OverlayStyle.resolve`). Reduce Motion: no cutout glide, no fade.
/// - The focused column's tab bar is cut out too, so its glass never sits on blur.
/// - Click-through on purpose: clicking a blurred window reaches it and focuses it, and the blur moves there.
/// - No permission: only public window ordering, like the focus ring.
@MainActor
final class DimOverlay {
    @MainActor private final class Slot {
        let panel: NSPanel
        let view = DimView()
        var layer = 0
        var fade = PanelFade()      // the panel's own fade: a refresh while it fades in must not cut it, and a fade-out can turn back
        init() {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.isFloatingPanel = false; p.animationBehavior = .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            view.autoresizingMask = [.width, .height]
            p.contentView = view
            panel = p
        }

        /// Fades the panel from `from` to `to`; `completion` runs when the animation ends (it checks that this is still the fade in force).
        func fadeTo(_ to: Double, duration: Double, from: Double, at now: Double, completion: (() -> Void)? = nil) {
            fade.begin(from: from, to: to, duration: duration, at: now)
            panel.alphaValue = from
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = duration
                panel.animator().alphaValue = to
            }, completionHandler: completion)
        }
    }

    private var slots: [String: Slot] = [:]
    private static let fadeDuration = 0.15

    /// - Parameters:
    ///   - focus: the focused window (id, AX frame), or nil to remove the dim (no managed window has focus).
    ///   - orderBelow: the window number to sit directly below (the focus ring's panel when it is up), else `focus.id`.
    ///   - tabBar: the focused column's tab bar (AX frame), cut out as well.
    ///   - fade: false where the swipe overlay covers the panel while it is placed: it is there at full opacity when the overlay goes.
    func update(style: OverlayStyle, displays: [DisplayInfo], focus: (id: UInt32, frame: CGRect)?, tabBar: CGRect? = nil, orderBelow: Int?, animated: Bool, fade: Bool = true) {
        if style == .off { hide(); return }
        guard let focus else { hide(); return }
        let live = Set(displays.map(\.uuid))
        for gone in slots.keys where !live.contains(gone) { slots[gone]?.panel.orderOut(nil); slots[gone] = nil }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let layer = Self.layer(of: focus.id)
        let now = CACurrentMediaTime()
        for d in displays {
            let slot = slots[d.uuid] ?? Slot()
            slots[d.uuid] = slot
            let frame = Screens.appKitRect(d.visible).integral
            if slot.layer != layer || !slot.panel.isVisible { slot.panel.level = NSWindow.Level(rawValue: layer); slot.layer = layer }
            if slot.panel.frame != frame { slot.panel.setFrame(frame, display: false) }
            let holes = DimGeometry.holes(area: d.visible, focused: focus.frame, tabBar: tabBar).map {
                OverlayHole(rect: DimGeometry.flipped($0.rect, height: d.visible.height), radius: $0.radius)
            }
            let fresh = !slot.panel.isVisible
            slot.view.set(style: style, holes: holes, animated: animated && !fresh && !reduce)
            let duration = reduce || !fade ? 0 : Self.fadeDuration
            if fresh {
                slot.panel.alphaValue = 0
                slot.panel.order(.below, relativeTo: orderBelow ?? Int(focus.id))
                slot.fadeTo(1, duration: duration, from: 0, at: now)
            } else {
                if slot.fade.isFadingIn(at: now) {
                    // On its way in: a refresh leaves the fade alone.
                } else if slot.fade.isRunning(at: now) {
                    slot.fadeTo(1, duration: duration, from: slot.fade.alpha(at: now), at: now)    // a fade-out turns back from where it has got to
                } else {
                    slot.panel.alphaValue = 1
                    slot.fade.stop()             // a fade-out whose completion has not run yet must not order the panel out
                }
                slot.panel.order(.below, relativeTo: orderBelow ?? Int(focus.id))
            }
        }
    }

    func hide() {
        let now = CACurrentMediaTime()
        for slot in slots.values where slot.panel.isVisible && slot.fade.to != 0 {
            slot.fadeTo(0, duration: Self.fadeDuration, from: slot.fade.alpha(at: now), at: now) { [weak slot] in
                MainActor.assumeIsolated { if let slot, slot.fade.to == 0 { slot.panel.orderOut(nil) } }
            }
        }
    }

    /// Dimming is up (a panel is visible and not fading out).
    var isShowing: Bool { slots.values.contains { $0.panel.isVisible && $0.panel.alphaValue > 0 } }

    /// The dim layers' geometry for QA: (display area, cutout in top-left coordinates).
    var debugState: [(frame: CGRect, hole: CGRect?)] { slots.values.map { ($0.panel.frame, $0.view.holes.first?.rect) } }
    /// "off", "dim" or "blur" for QA, from the newest update.
    var debugKind: String { guard isShowing, let v = slots.values.first?.view else { return "off" }; return v.kind }

    /// The dim panel's window number on this display while it is up (the edge curtain sits directly below it), else nil.
    func windowNumber(forDisplay uuid: String) -> Int? {
        guard let p = slots[uuid]?.panel, p.isVisible, p.windowNumber > 0 else { return nil }
        return p.windowNumber
    }

    private static func layer(of id: UInt32) -> Int { FocusRing.layer(of: id) }
}

/// The overlay's content: [blur view] + a dark layer, both with the same even-odd cutouts, animated by path.
private final class DimView: NSView {
    private let shape = CAShapeLayer()           // the dark layer (the dim, or the tint over the blur)
    private let maskShape = CAShapeLayer()       // the blur view's mask
    private let blur = NSVisualEffectView()
    private(set) var holes: [OverlayHole] = []   // bottom-left coordinates of this view
    private(set) var kind = "off"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active                      // the panel is never key; vibrancy must not go flat for that
        blur.wantsLayer = true
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        blur.isHidden = true
        maskShape.fillRule = .evenOdd
        maskShape.fillColor = NSColor.black.cgColor
        blur.layer?.mask = maskShape
        addSubview(blur)
        shape.fillRule = .evenOdd
        shape.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        blur.frame = bounds
        maskShape.frame = blur.bounds
        shape.frame = bounds
        maskShape.path = path(holes: holes)
        shape.path = path(holes: holes)
    }

    private func path(holes: [OverlayHole]) -> CGPath {
        let p = CGMutablePath()
        p.addRect(CGRect(origin: .zero, size: bounds.size))
        for h in holes { p.addRoundedRect(in: h.rect, cornerWidth: h.radius, cornerHeight: h.radius) }
        return p
    }

    /// `holes` in bottom-left coordinates of this view.
    func set(style: OverlayStyle, holes new: [OverlayHole], animated: Bool) {
        switch style {
        case .off: kind = "off"; blur.isHidden = true; shape.opacity = 0
        case .dim(let a): kind = "dim"; blur.isHidden = true; shape.opacity = Float(a)
        case .blur(let tint): kind = "blur"; blur.isHidden = false; shape.opacity = Float(tint)
        }
        let old = shape.path ?? path(holes: holes)
        holes = new
        let target = path(holes: new)
        shape.frame = bounds; maskShape.frame = blur.bounds
        shape.path = target; maskShape.path = target
        guard animated else { shape.removeAnimation(forKey: "hole"); maskShape.removeAnimation(forKey: "hole"); return }
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = old; a.toValue = target
        a.duration = 0.15
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
        shape.add(a, forKey: "hole")
        maskShape.add(a, forKey: "hole")
    }
}
