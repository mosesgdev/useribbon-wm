import SwiftUI
import AppKit

/// Design tokens from docs/design.md.
enum Theme {
    /// AppKit twin of `accent` (the focus ring draws with it); resolves per appearance.
    static let accentNS = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x8E/255, green: 0x9B/255, blue: 1, alpha: 1)
                                                            : NSColor(srgbRed: 0x6B/255, green: 0x7C/255, blue: 1, alpha: 1) }
    static let accent = Color(nsColor: accentNS)
    /// Solid accent for filled buttons: dark enough for white text in both appearances (the plain accent lightens in dark mode).
    static let accentFill = Color(red: 0x55/255, green: 0x66/255, blue: 0xEE/255)
    static let amber = Color(red: 0xE0/255, green: 0xA5/255, blue: 0x26/255)
    static let success = Color(red: 0x3F/255, green: 0xA2/255, blue: 0x73/255)
    /// Muted text: primary ink, dimmed.
    static let muted = MutedStyle()

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)

    static let panelSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let hudSpring = Animation.spring(response: 0.28, dampingFraction: 0.9)
    static let micro = Animation.easeOut(duration: 0.15)
    static let reduced = Animation.easeOut(duration: 0.12)
    /// The house ease, cubic-bezier(.2, .9, .2, 1): quick to start, soft to land.
    static func ease(_ duration: Double) -> Animation { .timingCurve(0.2, 0.9, 0.2, 1, duration: duration) }

    /// The whole corner scale. Everything Ribbon draws uses one of these four, and nested shapes are concentric
    /// (inner = outer - padding): sheet 28, floating panel 20, row 12, keycap 6.
    enum Radius {
        static let sheet: CGFloat = 28
        static let panel: CGFloat = 20
        static let row: CGFloat = 12
        static let key: CGFloat = 6
    }
    /// Gap between a floating panel and the edge it docks to.
    static let dockInset: CGFloat = 12
}

struct MutedStyle: ShapeStyle {
    /// Primary ink at 70% (85% with Increase Contrast): readable on any glass tint, still quieter than titles.
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        AnyShapeStyle(.primary.opacity(environment.colorSchemeContrast == .increased ? 0.85 : 0.7))
    }
}

private struct FlatGlassKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Snapshots only: real glass draws nothing offscreen, so render the opaque fallback instead.
    var flatGlass: Bool { get { self[FlatGlassKey.self] } set { self[FlatGlassKey.self] = newValue } }
}

/// Liquid Glass with an opaque fallback for Reduce Transparency.
struct AdaptiveGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.flatGlass) private var flatGlass
    @Environment(\.colorSchemeContrast) private var contrast
    var shape: S
    var tint: Color?

    private var increased: Bool { contrast == .increased }

    func body(content: Content) -> some View {
        if reduceTransparency || flatGlass {
            // Tint is applied once, as given by the caller, over an opaque base.
            content.background(shape.fill(tint ?? Color.clear).background(shape.fill(Color(nsColor: .windowBackgroundColor))))
                .overlay(shape.stroke(Color.primary.opacity(increased ? 0.45 : 0.15), lineWidth: increased ? 1 : 0.5))
        } else {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
                .overlay { if increased { shape.stroke(Color.primary.opacity(0.45), lineWidth: 1).allowsHitTesting(false) } }
        }
    }
}

/// Backing for content-heavy panels (lists, sheets). Liquid Glass belongs to the control layer, so reading surfaces get a thick
/// material over a window-coloured wash: bright windows behind never tint the text. Opaque under Reduce Transparency.
struct ReadingSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.flatGlass) private var flatGlass
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    var shape: S

    private var wash: Color { Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.62 : 0.68) }
    private var edge: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.28 : 0.8), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private var backing: some View {
        if reduceTransparency || flatGlass { shape.fill(Color(nsColor: .windowBackgroundColor)) }
        else { ZStack { shape.fill(.thickMaterial); shape.fill(wash) } }
    }

    func body(content: Content) -> some View {
        content
            .background(backing)
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.5 : 0.10), lineWidth: 0.5))
            .clipShape(shape)
    }
}

/// Buttons for cards and sheets. Primary is the one we recommend: a solid accent pill that never looks disabled, whatever the
/// window's key state. Secondary is quiet.
struct RibbonButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule(style: .continuous).fill(kind == .primary ? Theme.accentFill : Color.primary.opacity(0.08)))
            .overlay(Capsule(style: .continuous).stroke(kind == .primary ? Color.white.opacity(0.25) : Color.primary.opacity(0.14), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule(style: .continuous))
    }
}

/// The strip and its toasts: the system's Liquid Glass and nothing of ours under it, so the Liquid Glass setting in System
/// Settings (clear to tinted) decides how clear it is, as it does for the system's own controls. Opaque under Reduce
/// Transparency, outlined under Increase Contrast (`AdaptiveGlass`).
struct FloatingSurface<S: InsettableShape>: ViewModifier {
    var shape: S

    func body(content: Content) -> some View {
        content.adaptiveGlass(in: shape)
    }
}

extension View {
    func floatingSurface<S: InsettableShape>(in shape: S) -> some View { modifier(FloatingSurface(shape: shape)) }

    func readingSurface<S: InsettableShape>(in shape: S) -> some View { modifier(ReadingSurface(shape: shape)) }

    func adaptiveGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View { modifier(AdaptiveGlass(shape: shape, tint: tint)) }

    /// Picks the spring, or a plain fade when Reduce Motion is on.
    func calmAnimation<V: Equatable>(_ a: Animation, value: V, reduce: Bool) -> some View {
        animation(reduce ? Theme.reduced : a, value: value)
    }
}

/// Panel that may become key (text input) without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Esc (the standard cancel action) reaches the panel itself, so it works whichever view has focus.
    var onCancel: (() -> Void)?
    /// A click on a panel that is not key yet makes it key first, so SwiftUI buttons answer that very click.
    /// (A non-activating panel in an inactive app does not take clicks reliably otherwise.)
    var keyOnClick = false
    override func sendEvent(_ event: NSEvent) {
        if keyOnClick, event.type == .leftMouseDown || event.type == .rightMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { if let onCancel { onCancel() } else { super.cancelOperation(sender) } }

    static func make(size: CGSize, floating: Bool = true) -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isFloatingPanel = floating; p.level = .floating
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }
}

/// One physical key, drawn as a keycap.
struct KeyCap: View {
    enum Metrics { case small, regular
        var height: CGFloat { self == .small ? 20 : 22 }
        var minWidth: CGFloat { self == .small ? 20 : 24 }
        var font: CGFloat { self == .small ? 11 : 12 }
    }
    let label: String
    var metrics: Metrics = .regular
    var body: some View {
        Text(label)
            .font(.system(size: metrics.font, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 6)
            .frame(minWidth: metrics.minWidth, minHeight: metrics.height, maxHeight: metrics.height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
            .fixedSize()
    }
}

/// A row of keycaps, e.g. [⌃][⌥][←].
struct KeyCaps: View {
    let keys: [String]
    var metrics: KeyCap.Metrics = .regular
    var gap: CGFloat = 4
    var body: some View {
        HStack(spacing: gap) { ForEach(Array(keys.enumerated()), id: \.offset) { _, k in KeyCap(label: k, metrics: metrics) } }
    }
}

extension ModifierChoice {
    /// Each modifier glyph as its own key, then optional extras: `ctrlOpt.keys("→")` = ["⌃", "⌥", "→"].
    func keys(shift: Bool = false, _ rest: String...) -> [String] {
        glyphs.map(String.init) + (shift ? ["⇧"] : []) + rest
    }
}

/// Backdrop for offscreen snapshots (glass renders flat without something behind it).
struct SnapshotBackdrop<Content: View>: View {
    let size: CGSize
    var dark = false
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.13, blue: 0.22), Color(red: 0.22, green: 0.15, blue: 0.16)] : [Color(red: 0.84, green: 0.86, blue: 1), Color(red: 1, green: 0.88, blue: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
            content
        }.frame(width: size.width, height: size.height)
    }
}
