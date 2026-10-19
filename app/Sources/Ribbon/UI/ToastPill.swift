import SwiftUI
import AppKit

/// What the toast's 30×20 sketch shows: the result as a shape you take in at a glance, so the words only confirm it.
enum ToastDiagram: Equatable {
    case width(Double), height(Double), tabs, move, jump, focus, float, desk(Int, empty: Bool)
    /// A sketch a Plus feature draws (the free edition has none).
    case plus(PlusDiagram)

    /// Read from the engine's toast and the map: "Width 66 %" fills to the focused column's width, "Desktop 3 · empty" draws a dashed 3.
    static func make(toast t: String, map: RibbonMap, focus: UInt32?) -> ToastDiagram? {
        let focusCol = focus.flatMap { HUDCaption.find(map, $0)?.0 } ?? map.focusedIndex
        // Before "Moved": a Plus feature's toast may start with it too ("Moved to the right edge" is a column held at an edge).
        if let d = PlusToast.diagram(t, map: map) { return .plus(d) }
        if t.hasPrefix("Back in the ribbon") { return .move }
        if t.hasPrefix("Width") { return .width(focusCol.map { map.columns[$0].widthFrac } ?? 0.5) }
        if t.hasPrefix("Height") { return .height(fraction(in: t) ?? 0.5) }
        if t.hasPrefix("Tab") || t.hasPrefix("Tabbed") { return .tabs }
        if t.hasPrefix("Focus mode") { return .focus }
        if t.hasPrefix("Moved") || t.hasPrefix("Stacked") { return .move }
        if t.hasPrefix("First window") || t.hasPrefix("Last window") { return .jump }
        if t.localizedCaseInsensitiveContains("float") || t.localizedCaseInsensitiveContains("out of the ribbon") { return .float }
        if t.hasPrefix("Desktop "), let n = Int(t.dropFirst(8).prefix { $0.isNumber }) { return .desk(n, empty: t.hasSuffix("empty")) }
        return nil
    }

    private static func fraction(in t: String) -> Double? {
        // "Height 55 %": every height toast says the share in percent.
        if let r = t.range(of: #"\d+(?=\s*%)"#, options: .regularExpression), let n = Double(t[r]) { return min(n, 100) / 100 }
        return nil
    }
}

/// How wide the pill may get. It hugs its words; a long toast ("Tab group: Pages + Numbers + Keynote") never reaches past the panel
/// that holds it, and gives way in a fixed order instead: the hint goes first, then the middle of the headline.
enum ToastPillLayout {
    /// The widest pill, however much the toast says.
    static let widest: CGFloat = 620
    /// What stays clear of a small display's edges on either side.
    static let sideMargin: CGFloat = 24
    /// Room the glass's shadow needs beside the pill inside its panel.
    static let shadowRoom: CGFloat = 16
    static let panelHeight: CGFloat = 58

    /// The pill's width cap on a display whose usable area is `usable` points wide.
    static func cap(usable: CGFloat) -> CGFloat { max(240, min(widest, usable - 2 * sideMargin)) }
    /// The panel that holds a pill capped at `cap`.
    static func panelWidth(cap: CGFloat) -> CGFloat { cap + 2 * shadowRoom }
}

final class ToastModel: ObservableObject {
    @Published var text = ""
    @Published var hint: String?
    @Published var diagram: ToastDiagram?
    @Published var visible = false
    /// Bumps on a repeat of the same toast, for the small "again" pulse.
    @Published var pulse = 0
    /// The widest the pill may be (see `ToastPillLayout`); the controller sets it for the display the toast lands on.
    @Published var maxWidth = ToastPillLayout.widest
}

/// Recommendation B: a glass pill with a live diagram. A new toast updates it in place (text crossfades,
/// the diagram morphs), so pressing ⌃⌥R three times reads as one thing changing, not three messages.
struct ToastPillView: View {
    @ObservedObject var model: ToastModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ToastPill(model: model)
            .scaleEffect(model.visible || reduceMotion ? (model.pulse % 2 == 1 && !reduceMotion ? 1.03 : 1) : 0.96)
            .offset(y: model.visible || reduceMotion ? 0 : 8)
            .opacity(model.visible ? 1 : 0)
            .animation(reduceMotion ? Theme.reduced : .timingCurve(0.2, 0.9, 0.2, 1, duration: 0.22), value: model.visible)
            .animation(reduceMotion ? Theme.reduced : .timingCurve(0.2, 0.9, 0.2, 1, duration: 0.26), value: model.diagram)
            .animation(reduceMotion ? nil : .timingCurve(0.2, 0.9, 0.2, 1, duration: 0.16), value: model.pulse)
            .animation(Theme.micro, value: model.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([model.text, model.hint].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Offers its one child at most `limit` of width and is exactly as big as the child chooses to be. (`frame(maxWidth:)` would
/// stretch the child up to the limit; this only caps what it is offered.)
private struct WidthCap: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(offer(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    private func offer(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(p.width ?? limit, limit), height: p.height)
    }
}

/// The pill itself: as wide as its words, never wider than `model.maxWidth`. When the whole line does not fit, the hint is left
/// out; when the headline alone does not fit, its middle gives way ("Tab group: Pages … Keynote").
struct ToastPill: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        WidthCap(limit: model.maxWidth) {
            ViewThatFits(in: .horizontal) {
                capsule(hint: model.hint)
                capsule(hint: nil)
            }
        }
    }

    private func capsule(hint: String?) -> some View {
        HStack(spacing: 10) {
            if let d = model.diagram { DiagramView(diagram: d).frame(width: 30, height: 20).transition(.opacity) }
            HStack(spacing: 8) {
                Text(model.text).font(.system(size: 13.5, weight: .semibold, design: .rounded)).truncationMode(.middle)
                if let h = hint { Text(h).font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
            }
            .lineLimit(1)
            .id(model.text + (model.hint ?? ""))
            .transition(.opacity)
        }
        .padding(.leading, model.diagram == nil ? 17 : 12).padding(.trailing, 17)
        .frame(height: 42)
        .floatingSurface(in: Capsule(style: .continuous))
    }
}

/// The 30×20 sketches from the design mock, drawn in the text colour.
private struct DiagramView: View {
    let diagram: ToastDiagram

    var body: some View {
        let ink = Color.primary
        ZStack(alignment: .topLeading) {
            switch diagram {
            case .width(let f):
                rect(0.75, 0.75, 28.5, 18.5, 4.5).stroke(ink.opacity(0.35), lineWidth: 1.5)
                rect(3, 3, 24, 14, 2.2).fill(ink.opacity(0.14))
                rect(3, 3, 24 * min(max(f, 0.04), 1), 14, 2.2).fill(ink)
            case .height(let f):
                rect(8.75, 0.75, 12.5, 18.5, 3.5).stroke(ink.opacity(0.35), lineWidth: 1.5)
                rect(11, 3, 8, 14, 1.6).fill(ink.opacity(0.14))
                rect(11, 3, 8, 14 * min(max(f, 0.06), 1), 1.6).fill(ink)
            case .tabs:
                rect(9, 1.5, 17, 13, 2.5).fill(ink.opacity(0.3))
                rect(5, 5, 17, 13.5, 2.5).fill(ink)
            case .move, .jump:
                rect(1, 3, 8, 14, 2).fill(ink.opacity(0.18))
                rect(21, 3, 8, 14, 2).fill(ink.opacity(0.18))
                rect(11, 3, 8, 14, 2).fill(ink)
                if diagram == .jump { rect(9.25, 1.25, 11.5, 17.5, 3.2).stroke(ink.opacity(0.5), lineWidth: 1.2) }
            case .focus:
                rect(0, 4, 6, 12, 1.6).fill(ink.opacity(0.16))
                rect(24, 4, 6, 12, 1.6).fill(ink.opacity(0.16))
                rect(9.5, 3, 11, 14, 2).fill(ink)
                rect(7.75, 1.25, 14.5, 17.5, 3.6).stroke(ink.opacity(0.5), lineWidth: 1.2)
            case .float:
                ForEach([1.0, 11, 21], id: \.self) { x in rect(x, 7, 8, 12, 2).fill(ink.opacity(0.18)) }
                rect(8, 1, 14, 11, 2.4).fill(ink)
            case .plus(let d):
                PlusDiagramView(diagram: d, ink: ink)
            case .desk(let n, let empty):
                rect(1.75, 1.75, 26.5, 16.5, 4)
                    .stroke(ink.opacity(empty ? 0.45 : 0.8), style: StrokeStyle(lineWidth: 1.5, dash: empty ? [2.6, 2.2] : []))
                Text("\(n)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(ink.opacity(empty ? 0.55 : 1))
                    .frame(width: 30, height: 20)
            }
        }
        .frame(width: 30, height: 20, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// A continuous-corner rectangle placed in the 30×20 sketch.
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> some Shape {
        Positioned(frame: CGRect(x: x, y: y, width: w, height: h), radius: r)
    }
}

/// Animatable so the width and height fills glide to their new size instead of jumping.
struct Positioned: Shape {
    var frame: CGRect
    var radius: Double
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(frame.minX, frame.minY), .init(frame.width, frame.height)) }
        set { frame = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in _: CGRect) -> Path { RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: frame) }
}

/// Owns the click-through toast panel: bottom centre, just above the strip when the strip is up.
@MainActor
final class ToastPillController {
    let model = ToastModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// `above`: the strip's frame when it is on screen, so the pill stacks on top of it instead of covering it.
    func show(text: String, hint: String?, diagram: ToastDiagram?, above: NSRect?, lingerMs: Int) {
        let p = panel ?? makePanel()
        let again = model.visible && model.text == text && model.hint == hint
        model.text = text; model.hint = hint; model.diagram = diagram
        if again { model.pulse += 1; Task { [weak self] in try? await Task.sleep(for: .milliseconds(160)); self?.model.pulse += 1 } }
        place(p, above: above)
        if !p.isVisible { p.orderFrontRegardless() }
        model.visible = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(lingerMs))   // restarts on every toast
            guard !Task.isCancelled, let self else { return }
            self.model.visible = false
            try? await Task.sleep(for: .milliseconds(260))
            if !Task.isCancelled { self.panel?.orderOut(nil) }
        }
    }

    func hideNow() { hideTask?.cancel(); model.visible = false; panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ToastPillLayout.panelWidth(cap: model.maxWidth), height: ToastPillLayout.panelHeight),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.isFloatingPanel = true; p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false; p.ignoresMouseEvents = true; p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ToastPillView(model: model))
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    /// Bottom centre of the focused display, in a panel as wide as the widest pill that display allows.
    private func place(_ p: NSPanel, above strip: NSRect?) {
        guard let f = Screens.focused?.visibleFrame else { return }
        let cap = ToastPillLayout.cap(usable: f.width)
        if model.maxWidth != cap { model.maxWidth = cap }
        let size = CGSize(width: ToastPillLayout.panelWidth(cap: cap), height: ToastPillLayout.panelHeight)
        let y = strip.map { $0.maxY + 2 } ?? f.minY + Theme.dockInset
        p.setFrame(NSRect(x: (f.midX - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height), display: false)
    }
}
