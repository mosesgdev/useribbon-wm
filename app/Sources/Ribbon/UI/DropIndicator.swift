import SwiftUI
import AppKit

/// What the indicator draws for a mark, laid out in the panel's own coordinates (bottom-left origin, like AppKit's): flat shapes
/// for the bar and the columns, and the small glass label that says what dropping will do. Pure, so the self tests pin it down.
struct DropIndicatorShapes: Equatable {
    /// How a shape is painted: the bar between columns, the column that takes the window, and the two capsules of a tab-group preview.
    enum Fill: Equatable { case bar, column, tab, newTab }
    struct Shape: Equatable { var rect: CGRect; var radius: CGFloat; var fill: Fill }
    /// The words, centred in `room` (the label never outgrows it).
    struct Label: Equatable { var text: String; var room: CGRect }
    var shapes: [Shape]
    var label: Label?

    /// An AX rect inside `area` (the AX rect the panel covers), in the panel's coordinates.
    static func local(_ r: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: r.minX - area.minX, y: area.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The part of `rect` the panel shows: a column that runs past the display's edge keeps its words on screen.
    static func visible(_ rect: CGRect, in area: CGRect) -> CGRect {
        let room = rect.intersection(CGRect(origin: .zero, size: area.size))
        return room.isNull ? rect : room
    }

    static func make(for mark: DropRule.Mark, in area: CGRect) -> DropIndicatorShapes {
        func capsule(_ r: CGRect, _ fill: Fill) -> Shape { Shape(rect: r, radius: min(r.width, r.height) / 2, fill: fill) }
        switch mark {
        case .bar(let r):
            return DropIndicatorShapes(shapes: [capsule(local(r, in: area).insetBy(dx: 1, dy: 0), .bar)], label: nil)
        case .stack(let r, let tab):
            let rect = local(r, in: area)
            let radius = min(Theme.Radius.row, min(rect.width, rect.height) / 2)
            return DropIndicatorShapes(shapes: [Shape(rect: rect, radius: radius, fill: .column)],
                                       label: Label(text: tab ? "Add as a tab" : "Stack here", room: visible(rect, in: area)))
        case .tabGroup(let strip):
            // What will appear: a tab bar with two capsules (the column's window and the dropped one).
            let bar = local(strip, in: area)
            let slots = TabLayout.tabs(count: 2, width: bar.width)
            let shapes = zip(slots, [Fill.tab, .newTab]).map { slot, fill in
                capsule(CGRect(x: bar.minX + slot.x, y: bar.minY + 2, width: slot.w, height: bar.height - 4), fill)
            }
            return DropIndicatorShapes(shapes: shapes, label: Label(text: "Make a tab group", room: visible(shapes[1].rect, in: area)))
        }
    }
}

/// The soft marker shown while a window is dragged: a slim bar in the gap where it will become its own column, or a calm
/// highlight over the column that will take it as a stack (or a tab). Click-through and non-activating.
///
/// One fixed panel covers the display's usable area for the whole drag and never changes size. The marks are plain layers
/// (flat accent fill and stroke) that Core Animation glides from one target to the next with a critically damped spring, off the
/// main thread; only the small label is Liquid Glass. A new target lays out and re-renders no mark (the label only when its
/// words change).
@MainActor
final class DropIndicator {
    private let panel: NSPanel
    private let marks: [CALayer]
    private let label = NSHostingView(rootView: DropLabelView(text: ""))
    private var current: DropRule.Mark?
    private var area: CGRect?          // the AX rect the panel covers
    private var shown = false          // the marks sit at a target (else the next one appears in place)
    private var labelText = ""
    private var labelShown = false     // the label sits at a target (a label that was hidden appears in place instead of flying in)
    private var leaving = 0            // bumped whenever the panel is wanted again, so a pending "take it off screen" is called off

    init() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.isFloatingPanel = true; p.level = .floating; p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let content = NSView(frame: p.contentRect(forFrameRect: p.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = .clear
        marks = (0..<2).map { _ in
            let l = CALayer()
            l.anchorPoint = .zero; l.cornerCurve = .continuous; l.opacity = 0
            content.layer?.addSublayer(l)
            return l
        }
        label.wantsLayer = true; label.layer?.backgroundColor = .clear
        label.alphaValue = 0
        content.addSubview(label)
        p.contentView = content
        panel = p
        label.rootView = DropLabelView(text: "Make a tab group"); labelText = "Make a tab group"   // the longest words: laid out once, now
        _ = label.fittingSize
    }

    /// A drag began over the display area `usable` (AX coordinates): the panel goes on screen, still invisible, so the first target
    /// does not wait for the window server to put a display-sized window up.
    func begin(over usable: CGRect) {
        leaving += 1
        area = usable
        panel.setFrame(Screens.appKitRect(usable), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
    }

    /// Shows the marker for `mark` over the display area `usable` (AX coordinates); nil hides it (the window will snap back).
    func show(_ mark: DropRule.Mark?, over usable: CGRect) {
        guard mark != current || (mark != nil && usable != area) else { return }
        current = mark
        guard let mark else {
            guard shown else { return }
            shown = false; labelShown = false
            fade(to: 0)
            return
        }
        leaving += 1
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var glide = shown && !reduce && usable == area
        if usable != area || !panel.isVisible {
            area = usable
            panel.setFrame(Screens.appKitRect(usable), display: false)
            glide = false
        }
        if !panel.isVisible { panel.alphaValue = 0; panel.orderFrontRegardless() }
        let target = DropIndicatorShapes.make(for: mark, in: usable)
        place(target, glide: glide)
        if !shown { fade(to: 1) }
        shown = true
    }

    /// The drag is over: fade out and leave.
    func end() {
        current = nil; shown = false; labelShown = false
        guard panel.isVisible else { return }
        leaving += 1
        fade(to: 0, leave: true)
    }

    var isVisible: Bool { panel.isVisible && current != nil }

    /// Fades the panel; `leave` takes it off screen afterwards unless a new drag wanted it again meanwhile.
    private func fade(to alpha: CGFloat, leave: Bool = false) {
        let token = leaving
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.12; panel.animator().alphaValue = alpha },
                                             completionHandler: { [weak self] in MainActor.assumeIsolated { if leave, self?.leaving == token { self?.panel.orderOut(nil) } } })
    }

    // MARK: layers

    private struct Paint { var fill: CGColor; var stroke: CGColor; var width: CGFloat }

    /// Flat accent paint per role, resolved for the panel's appearance. Accent stays a tint: faint fills, and a stroke only
    /// where a column or tab is named.
    private func paint(_ f: DropIndicatorShapes.Fill) -> Paint {
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        var out = Paint(fill: .clear, stroke: .clear, width: 0)
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            func accent(_ a: CGFloat) -> CGColor { Theme.accentNS.withAlphaComponent(a).cgColor }
            let edge: CGFloat = contrast ? 0.95 : 0.6
            switch f {
            case .bar: out = Paint(fill: accent(dark ? 0.55 : 0.5), stroke: .clear, width: 0)
            case .column: out = Paint(fill: accent(dark ? 0.16 : 0.12), stroke: accent(edge), width: contrast ? 3 : 2)
            case .tab: out = Paint(fill: accent(0.12), stroke: accent(contrast ? 0.8 : 0.35), width: contrast ? 2 : 1)
            case .newTab: out = Paint(fill: accent(0.30), stroke: accent(edge), width: contrast ? 2 : 1)
            }
        }
        return out
    }

    private func place(_ t: DropIndicatorShapes, glide: Bool) {
        for (i, layer) in marks.enumerated() {
            let shape = i < t.shapes.count ? t.shapes[i] : nil
            // A mark that was not on screen appears where it belongs and fades in; one that was glides there.
            put(layer, shape, glide: glide && layer.opacity > 0.01, fade: shown)
        }
        placeLabel(t.label, glide: glide)
    }

    /// Moves a layer to its new look. The model changes at once; an explicit animation carries the presentation there from where
    /// it is now, so a retarget in mid-glide continues from the picture on screen.
    private func put(_ layer: CALayer, _ shape: DropIndicatorShapes.Shape?, glide: Bool, fade: Bool) {
        let now = layer.presentation() ?? layer
        let was = (bounds: now.bounds, position: now.position, radius: now.cornerRadius, fill: now.backgroundColor, stroke: now.borderColor,
                   width: now.borderWidth, opacity: now.opacity)
        let p = shape.map { paint($0.fill) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let shape, let p {
            layer.bounds = CGRect(origin: .zero, size: shape.rect.size); layer.position = shape.rect.origin
            layer.cornerRadius = shape.radius
            layer.backgroundColor = p.fill; layer.borderColor = p.stroke; layer.borderWidth = p.width
        }
        layer.opacity = shape == nil ? 0 : 1
        CATransaction.commit()
        // A glide replaces the running animations key by key; anything else must not leave a stale one heading for the old target.
        if !glide || shape == nil { layer.removeAllAnimations() }
        if fade, abs(was.opacity - layer.opacity) > 0.01 { layer.add(Self.ease("opacity", was.opacity, layer.opacity), forKey: "opacity") }
        guard glide, shape != nil else { return }
        layer.add(Self.spring("bounds", NSValue(rect: was.bounds), NSValue(rect: layer.bounds)), forKey: "bounds")
        layer.add(Self.spring("position", NSValue(point: was.position), NSValue(point: layer.position)), forKey: "position")
        layer.add(Self.spring("cornerRadius", was.radius, layer.cornerRadius), forKey: "cornerRadius")
        if let f = was.fill { layer.add(Self.ease("backgroundColor", f, layer.backgroundColor as Any), forKey: "backgroundColor") }
        if let s = was.stroke { layer.add(Self.ease("borderColor", s, layer.borderColor as Any), forKey: "borderColor") }
        layer.add(Self.ease("borderWidth", was.width, layer.borderWidth), forKey: "borderWidth")
    }

    private func placeLabel(_ l: DropIndicatorShapes.Label?, glide: Bool) {
        guard let l else {
            if labelShown { fadeLabel(to: 0) } else { label.alphaValue = 0 }
            labelShown = false
            return
        }
        let glide = glide && labelShown
        if !labelShown { label.alphaValue = 0; labelShown = true }   // it fades in where it belongs
        if labelText != l.text { labelText = l.text; label.rootView = DropLabelView(text: l.text) }
        let fit = label.fittingSize
        let size = CGSize(width: min(fit.width, max(0, l.room.width - 8)), height: fit.height)
        let was = label.layer?.presentation()?.position
        label.frame = CGRect(x: (l.room.midX - size.width / 2).rounded(), y: (l.room.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        if glide, let was, let now = label.layer?.position {
            label.layer?.add(Self.spring("position", NSValue(point: was), NSValue(point: now)), forKey: "position")
        }
        fadeLabel(to: 1)
    }

    private func fadeLabel(to alpha: CGFloat) {
        guard label.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.12; label.animator().alphaValue = alpha }
    }

    /// Critically damped (no overshoot into the neighbour's column), settling in a fifth of a second or so.
    private static func spring(_ keyPath: String, _ from: Any, _ to: Any) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1; a.stiffness = 600; a.damping = 2 * (600.0).squareRoot()
        a.fromValue = from; a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    private static func ease(_ keyPath: String, _ from: Any, _ to: Any) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from; a.toValue = to
        a.duration = 0.14
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
        return a
    }
}

/// The label's words on a small Liquid Glass capsule: the only glass the indicator draws.
struct DropLabelView: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .adaptiveGlass(in: Capsule(style: .continuous), tint: Theme.accent.opacity(0.25))
    }
}
