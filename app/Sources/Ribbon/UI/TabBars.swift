import SwiftUI
import AppKit

/// The tab bars of tabbed columns.
///
/// Placement (decided in the core): the bar sits in a strip *above* the window, as wide as the column, and the window is
/// laid out below it. Overlapping the window's own title bar would cover the traffic lights and whatever each app puts in
/// its toolbar; a reserved strip never covers anything, works for every app, and reads as one object with the column.
/// The bar is a Liquid Glass capsule (the only glass layer; tabs are plain fills inside it) in a click-through-free,
/// non-activating panel, so clicking a tab never steals the keyboard from the window you are working in.
/// Everything a tab can do besides being clicked.
enum TabAction: Equatable {
    case popOut(UInt32), moveLeft(UInt32), moveRight(UInt32), showAsStack(UInt32), closeGroup(UInt32), keepOut(UInt32)
    /// Dragged sideways within the bar to this position.
    case reorder(UInt32, to: Int)
    /// A core command about this tab's window or column (a Plus feature's), run once its window has focus.
    case command(UInt32, String, Int?)
    /// A menu is about to open on this tab: the controller answers by setting `TabBarController.menuContext`, because what a
    /// feature's entries need (its state in the plan, the live shortcuts) is in the plan and the store, not in a bar.
    case menuOpening(UInt32)
}

/// One entry a feature adds to a tab's menu: it runs the core command `name` (with `arg`) on the tab's window.
struct TabMenuEntry: Equatable {
    var title: String
    var symbol: String
    var name: String
    var arg: Int?
    var keys: [String] = []
    var checked = false
}

enum TabMenuKeys {
    /// A menu item's key equivalent from keycaps like ["⌃", "⌥", "K"]: the last cap is the key (a letter or digit), the others are
    /// modifiers. nil for anything a menu cannot show as a key equivalent (arrows, function keys, nothing bound).
    static func equivalent(_ caps: [String]) -> (key: String, mask: NSEvent.ModifierFlags)? {
        guard caps.count >= 2, let key = caps.last, key.count == 1, key.first!.isLetter || key.first!.isNumber else { return nil }
        var mask: NSEvent.ModifierFlags = []
        for cap in caps.dropLast() {
            switch cap {
            case "⌃": mask.insert(.control)
            case "⌥": mask.insert(.option)
            case "⇧": mask.insert(.shift)
            case "⌘": mask.insert(.command)
            default: return nil
            }
        }
        return (key.lowercased(), mask)
    }
}

extension TabBar {
    /// The bar without its place: what the tab view draws from it. A bar that only moves (riding with its tile) keeps the same.
    var drawn: TabBar { var b = self; b.x = 0; b.y = 0; b.w = 0; b.h = 0; b.onScreen = true; return b }

    /// This bar riding with its column's tile at `x` (AX space): there and on screen, to be clipped by the display; without a tile
    /// (out of the overlay's reach, or a window not moved yet) it is out of sight. A held column's bar (`isPinned`) never moves.
    func riding(at x: Double?) -> TabBar {
        guard !isPinned else { return self }
        var b = self
        if let x { b.x = x; b.onScreen = true } else { b.onScreen = false }
        return b
    }
}

enum TabBarPlacement {
    /// Narrower than this, a clipped bar is not worth a panel.
    static let minWidth = 24.0

    /// The bars that show and the rect (AX space) each panel takes: on screen, clipped to `visible` (a held column's bar) or to
    /// `area` (a ribbon bar: the display beside a held column, so it passes beneath that column with its own instead of across it).
    static func shown(_ bars: [TabBar], visible: CGRect, area: CGRect) -> [(bar: TabBar, rect: CGRect)] {
        bars.compactMap { b in
            let r = b.cg.intersection(b.isPinned ? visible : area)
            return b.onScreen && !r.isNull && r.width >= minWidth ? (b, r) : nil
        }
    }
}

/// What one bar panel's SwiftUI model holds, so a bar that only moves writes nothing to it: each write publishes and redraws the
/// glass, which a bar riding with its tile must not pay for on every display frame.
struct TabBarFeed: Equatable {
    struct Writes: OptionSet { let rawValue: Int; static let content = Writes(rawValue: 1), width = Writes(rawValue: 2), receded = Writes(rawValue: 4) }
    private(set) var content: TabBar?
    private var width: Double?, receded: Bool?

    /// The window ids of the tabs the model shows: how a bar finds its panel again.
    var held: Set<UInt32> { Set(content?.tabs.map(\.id) ?? []) }

    /// Records what the model is about to show and says which of its fields differ from what it showed.
    mutating func take(_ bar: TabBar, width w: Double, receded r: Bool) -> Writes {
        var out: Writes = []
        let drawn = bar.drawn
        if content != drawn { content = drawn; out.insert(.content) }
        if width != w { width = w; out.insert(.width) }
        if receded != r { receded = r; out.insert(.receded) }
        return out
    }
}

/// Which panel shows which bar. A bar keeps the panel that showed its tabs (a column that re-indexes, or leaves the display and
/// comes back, keeps its glass); the others take a free panel, else one more.
enum TabSlots {
    /// The panel index for each bar, given the tab ids of each bar (`bars`) and of what each panel last showed (`held`).
    static func assign(bars: [[UInt32]], held: [Set<UInt32>]) -> [Int] {
        var out = [Int](repeating: -1, count: bars.count)
        var used = Set<Int>()
        for (n, ids) in bars.enumerated() {
            if let i = held.indices.first(where: { !used.contains($0) && !held[$0].isDisjoint(with: ids) }) { out[n] = i; used.insert(i) }
        }
        var free = held.indices.filter { !used.contains($0) }[...]
        var next = held.count
        for n in out.indices where out[n] < 0 {
            if let i = free.popFirst() { out[n] = i } else { out[n] = next; next += 1 }
        }
        return out
    }
}

/// App icons by process, so a tab bar never asks `NSRunningApplication` for one on the frame path. An icon goes when its app
/// launches or quits (a process id can come back as another app); one that was not available is asked for again.
@MainActor
final class AppIconCache {
    private var icons: [pid_t: NSImage] = [:]
    private let lookup: (pid_t) -> NSImage?
    /// How many times the system was asked (QA, tests).
    private(set) var lookups = 0

    init(lookup: @escaping (pid_t) -> NSImage? = { NSRunningApplication(processIdentifier: $0)?.icon }) { self.lookup = lookup }

    func icon(pid: pid_t) -> NSImage? {
        if let i = icons[pid] { return i }
        lookups += 1
        guard let i = lookup(pid) else { return nil }
        icons[pid] = i
        return i
    }

    func forget(pid: pid_t) { icons[pid] = nil }
    func removeAll() { icons = [:] }
}

@MainActor
final class TabBarController {
    @MainActor private final class Slot {
        let panel: NSPanel
        let model = TabBarModel()
        let view: TabBarHitView
        var feed = TabBarFeed()
        var held = Set<UInt32>()          // the tab ids it showed last, kept while the bar is out of sight
        init() {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 28), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = false; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.isFloatingPanel = true; p.level = .floating; p.animationBehavior = .none
            // No canJoinAllSpaces: a bar belongs to the Space its windows live in and must not float over a full-screen app.
            p.collectionBehavior = [.transient, .ignoresCycle]
            // The bar's size is the core's rect, never SwiftUI's: the host reports no sizes and clips what it draws.
            let host = NSHostingView(rootView: TabBarView(model: model))
            host.sizingOptions = []
            host.wantsLayer = true; host.layer?.backgroundColor = .clear; host.layer?.masksToBounds = true
            view = TabBarHitView(model: model, host: host)
            p.contentView = view
            p.contentMinSize = .zero
            panel = p
        }
    }

    private var slots: [String: [Slot]] = [:]       // by display uuid, one per tabbed ribbon column
    /// A held column's bar has a slot of its own, so it never takes over (and glides in from) the panel of a ribbon bar.
    private var heldSlots: [String: Slot] = [:]
    private var shown: [String: [CGRect]] = [:]
    /// A tab was clicked: the window to show.
    var onSelect: (UInt32) -> Void = { _ in }
    /// Wheel over a bar: +1 next tab, -1 previous. Middle-click or ⌥-click on a tab: pop that window out into its own column.
    var onCycle: (UInt32, Int) -> Void = { _, _ in }
    var onAction: (TabAction) -> Void = { _ in }
    var icon: (UInt32) -> NSImage? = { _ in nil }
    /// Set by the controller in answer to `TabAction.menuOpening`, read by the menu that asked.
    var menuContext: TabMenuContext?

    /// Show `bars` for one display (everything the core reported for its active desktop), clipped to `visible` so a bar of a
    /// half-scrolled column never reaches onto the neighbouring display, and a ribbon bar to `ribbonArea` (the display beside
    /// a held column), so it passes beneath that column with its own instead of across it. `dimmed`: the dim feature is on,
    /// so bars of columns you are not in step back a little with the windows. `moving`: the bars ride with their tiles (a swipe or
    /// a keyboard glide calls this every display frame): a bar that only moved changes nothing but its panel's place.
    func update(_ bars: [TabBar], display uuid: String, visible: CGRect, ribbonArea: CGRect? = nil, dimmed: Bool, animated: Bool, moving: Bool = false) {
        let t0 = CACurrentMediaTime()
        defer { updateCalls += 1; updateMs += (CACurrentMediaTime() - t0) * 1000 }
        let area = ribbonArea.map { $0.intersection(visible) } ?? visible
        let live = TabBarPlacement.shown(bars, visible: visible, area: area)
        let ribbon = live.filter { !$0.bar.isPinned }
        var list = slots[uuid] ?? []
        let places = TabSlots.assign(bars: ribbon.map { $0.bar.tabs.map(\.id) }, held: list.map(\.held))
        while list.count <= (places.max() ?? -1) { list.append(Slot()) }
        for (b, i) in zip(ribbon, places) { show(b.bar, at: b.rect, in: list[i], dimmed: dimmed, animated: animated, moving: moving) }
        let used = Set(places)
        for (i, slot) in list.enumerated() where !used.contains(i) && slot.panel.isVisible { slot.panel.orderOut(nil) }
        slots[uuid] = list
        if let b = live.first(where: \.bar.isPinned) {
            let slot = heldSlots[uuid] ?? Slot()
            heldSlots[uuid] = slot
            show(b.bar, at: b.rect, in: slot, dimmed: dimmed, animated: animated, moving: moving)
        } else if let slot = heldSlots[uuid], slot.panel.isVisible { slot.panel.orderOut(nil) }
        shown[uuid] = live.map(\.bar.cg)
    }

    /// How many times a model was written and how many panel frames were set (QA: a bar riding with its tile writes no model),
    /// and the milliseconds spent in `update` and in setting panel frames in all.
    private(set) var modelWrites = 0, frameMoves = 0, updateCalls = 0
    private(set) var updateMs = 0.0, frameMs = 0.0

    /// Put `bar` in `slot`: its model and handlers when they differ from what it shows, and its panel (a fade-in the first time, a
    /// quick glide to a new frame after, or at once while `moving`).
    private func show(_ bar: TabBar, at ax: CGRect, in slot: Slot, dimmed: Bool, animated: Bool, moving: Bool) {
        let frame = Screens.appKitRect(ax).integral
        let writes = slot.feed.take(bar, width: frame.width, receded: dimmed && !bar.focused)
        if !writes.isEmpty { modelWrites += 1 }
        if writes.contains(.width) { slot.model.width = frame.width }
        if writes.contains(.receded) { slot.model.receded = dimmed && !bar.focused }
        if writes.contains(.content) {
            slot.held = slot.feed.held
            slot.model.bar = bar
            slot.model.icons = icons(of: bar)
            slot.view.onSelect = { [weak self] id in self?.onSelect(id) }
            slot.view.onCycle = { [weak self] dir in self?.onCycle(bar.active, dir) }
            slot.view.onAction = { [weak self] a in self?.onAction(a) }
            slot.view.context = { [weak self] in self?.menuContext }
        } else if !moving, slot.model.icons.values.contains(where: { $0 == nil }) {
            slot.model.icons = icons(of: bar)       // an app's icon that was not there yet
        }
        if !slot.panel.isVisible {
            slot.panel.setFrame(frame, display: true)
            slot.panel.alphaValue = 0
            slot.panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; slot.panel.animator().alphaValue = 1 }
            frameMoves += 1
        } else if slot.panel.frame != frame {
            frameMoves += 1
            if moving || !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // Straight to the place (no animation group per display frame); only a width change redraws.
                let f0 = CACurrentMediaTime()
                if frame.size == slot.panel.frame.size { slot.panel.setFrameOrigin(frame.origin) } else { slot.panel.setFrame(frame, display: true) }
                frameMs += (CACurrentMediaTime() - f0) * 1000
                if !moving { slot.panel.orderFrontRegardless() }
            } else {
                NSAnimationContext.runAnimationGroup { c in
                    c.duration = 0.14
                    c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
                    c.allowsImplicitAnimation = true
                    slot.panel.animator().setFrame(frame, display: true)
                }
                slot.panel.orderFrontRegardless()
            }
        }
    }

    private func icons(of bar: TabBar) -> [UInt32: NSImage?] {
        Dictionary(bar.tabs.map { ($0.id, icon($0.id)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Bars hidden (pause, or the ribbon of a display that went away).
    func hideAll() {
        for s in allSlots { s.panel.orderOut(nil) }
        shown = [:]
    }

    func forget(display uuid: String) {
        (slots[uuid] ?? []).forEach { $0.panel.orderOut(nil) }
        heldSlots[uuid]?.panel.orderOut(nil)
        slots[uuid] = nil; heldSlots[uuid] = nil; shown[uuid] = nil
    }

    /// Windows of the bars currently shown (QA).
    var visibleCount: Int { allSlots.filter { $0.panel.isVisible }.count }
    private var allSlots: [Slot] { slots.values.flatMap { $0 } + heldSlots.values }
}

@MainActor
final class TabBarModel: ObservableObject {
    @Published var bar: TabBar?
    /// The panel's width: what the tabs are laid out in (`TabLayout`) and what the hit view tests against.
    @Published var width: CGFloat = 0
    /// The active tab's slot (what a bar's own trailing button acts on).
    var activeIndex: Int? { bar.flatMap { b in b.tabs.firstIndex { $0.id == b.active } } }
    /// Where the tabs are: the one layout the view draws from and the hit view tests against.
    var layout: [(x: CGFloat, w: CGFloat)] {
        TabLayout.tabs(count: bar?.tabs.count ?? 0, width: width, trailing: trailing, active: activeIndex ?? 0)
    }
    /// What the bar keeps free at its trailing end for a feature's button (`HeldBarButton`; 0 when there is none).
    var trailing: CGFloat { HeldBarButton.trailing(for: bar, width: width) }
    var showsHeldButton: Bool { trailing > 0 }
    @Published var icons: [UInt32: NSImage?] = [:]
    @Published var hovered: Int?
    @Published var pressed: Int?
    /// The bar's trailing button, when a feature gives it one.
    @Published var heldHovered = false
    @Published var heldPressed = false
    @Published var receded = false
    /// The tab that just became active (keyboard or click): pulses once so you see where you landed.
    @Published var pulse: UInt32?
}

struct TabBarView: View {
    @ObservedObject var model: TabBarModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glass

    /// Liquid Glass the canonical way: a container so neighbouring glass shapes blend and morph, and every tab its own glass
    /// capsule (own hover, own press, own hit target). No bar behind them: the glass floats on the content layer.
    /// A feature may end the bar in one more glass shape of its own (`HeldBarButton`).
    /// Everything is drawn where `TabLayout` puts it, which is also where the hit view looks, inside exactly the panel's width:
    /// a tab that does not fit is not drawn, and whatever a tab's own content would like, the bar clips at its edge.
    var body: some View {
        let tabs = model.bar?.tabs ?? []
        let t = model.layout
        GlassEffectContainer(spacing: TabLayout.gap) {
            ZStack(alignment: .leading) {
                ForEach(tabs.enumerated().filter { t[$0.offset].w > 0 }, id: \.element.id) { i, tab in
                    tabView(tab, active: tab.id == model.bar?.active, hovered: model.hovered == i, pressed: model.pressed == i, width: t[i].w)
                        .padding(.leading, t[i].x)
                }
                HeldBarButton(model: model, glass: glass)
            }
            .padding(.vertical, 2)
        }
        .frame(width: model.width, alignment: .leading).clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(model.receded ? 0.72 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.12), value: model.pressed)
        .animation(reduceMotion ? nil : .smooth(duration: 0.12), value: model.heldPressed)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.bar?.isPinned)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: tabs.map(\.id))
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: model.bar?.active)
        .animation(reduceMotion ? nil : Theme.micro, value: model.hovered)
        .animation(reduceMotion ? nil : Theme.micro, value: model.heldHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    /// Safari-style hierarchy: every tab is its own glass button, but only the active one is raised (regular glass, soft
    /// shadow); the others recede (clear glass, secondary text) and brighten on hover. The glass is the system's own, with no
    /// fill of ours under it, so the Liquid Glass setting in System Settings (clear to tinted) decides how clear it is. Neutral, not accent: the focus ring
    /// already says "you are here", and accent on accent over a coloured wallpaper turned the whole bar into one blue slab.
    /// Content is centred so a wide tab reads as a tab, not a text field; the pop-out button overlays the trailing edge.
    /// `width` is the tab's own, from `TabLayout`: too narrow for a title (`showsTitle`), it is the app icon alone, centred and
    /// without the pop-out button; otherwise the title takes what the icon and padding leave and truncates in the middle.
    private func tabView(_ tab: TabItem, active: Bool, hovered: Bool, pressed: Bool, width: CGFloat) -> some View {
        let dark = scheme == .dark
        let name = tab.title.isEmpty ? tab.app : tab.title
        let iconOnly = !TabLayout.showsTitle(tabWidth: width)
        let capsule = Capsule(style: .continuous)
        let h = TabLayout.barHeight - 4
        let label = HStack(spacing: 7) {
            Group {
                if let img = model.icons[tab.id] ?? nil { Image(nsImage: img).resizable().interpolation(.high) }
                else { Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .frame(width: 16, height: 16)
            .saturation(active ? 1 : 0.85).opacity(active ? 1 : 0.8)
            if !iconOnly {
                Text(name).font(.system(size: 12.5, weight: active ? .semibold : .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(minWidth: 0).layoutPriority(-1)
            }
        }
        .padding(.horizontal, iconOnly ? 0 : hovered ? TabLayout.closeZone : 12)
        .frame(width: width, height: h)
        .overlay(alignment: .trailing) {
            if hovered && !iconOnly {
                Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    .accessibilityHidden(true)
            }
        }
        // A whisper of fill on hover for the receding tabs; the active one is the glass alone.
        let fill: Color = Color.white.opacity(!active && hovered ? (dark ? 0.08 : 0.22) : 0)
        return Group {
            if reduceTransparency {
                label.background(capsule.fill(active ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor).opacity(0.85)))
                    .overlay(capsule.strokeBorder(Color.primary.opacity(active ? 0.18 : 0.1), lineWidth: 0.5))
            } else {
                label.background(capsule.fill(fill))
                    .glassEffect(active ? Glass.regular.interactive() : Glass.clear.interactive(), in: capsule)
                    .glassEffectID(tab.id, in: glass)
            }
        }
        // Depth from layered shadows, only where something is raised.
        .shadow(color: .black.opacity(active ? (dark ? 0.32 : 0.10) : 0), radius: 0.5, y: 0.5)
        .shadow(color: .black.opacity(active ? (dark ? 0.28 : 0.10) : 0), radius: 6, y: 2)
        .scaleEffect(pressed ? 0.96 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(tab.app)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Catches the mouse for the bar. The SwiftUI view underneath only draws, so a click works on the first try even though
/// the panel never becomes key.
final class TabBarHitView: NSView {
    let model: TabBarModel
    var onSelect: (UInt32) -> Void = { _ in }
    /// What the controller says a menu needs (answers `TabAction.menuOpening`).
    var context: () -> TabMenuContext? = { nil }
    private var area: NSTrackingArea?

    init(model: TabBarModel, host: NSView) {
        self.model = model
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }

    /// Hit-testing goes by the model's width and layout, which are what the view draws from (not the panel's own width, which
    /// glides while the bar moves to a new frame).
    private func index(_ e: NSEvent) -> Int? {
        TabLayout.index(at: convert(e.locationInWindow, from: nil).x, count: model.bar?.tabs.count ?? 0, width: model.width, trailing: model.trailing, active: model.activeIndex ?? 0)
    }
    /// The trailing button a feature may end the bar with.
    private func overHeldButton(_ e: NSEvent) -> Bool { TabLayout.inTrailing(x: convert(e.locationInWindow, from: nil).x, width: model.width, trailing: model.trailing) }
    /// The ✕ of the hovered tab (pop out into its own column); only a tab with a title has one.
    private func onClose(_ e: NSEvent, _ i: Int) -> Bool {
        let t = model.layout[i]
        return TabLayout.showsTitle(tabWidth: t.w) && TabLayout.inCloseZone(x: convert(e.locationInWindow, from: nil).x, tab: t)
    }
    var onCycle: (Int) -> Void = { _ in }
    var onAction: (TabAction) -> Void = { _ in }
    private var downIndex: Int?, downPoint = NSPoint.zero, dragged = false, heldDown = false
    private var wheel = 0.0, lastWheel = Date.distantPast

    override func mouseMoved(with event: NSEvent) {
        let onButton = overHeldButton(event)
        model.heldHovered = onButton
        let i = onButton ? nil : index(event)
        model.hovered = i
        if onButton { toolTip = HeldBarButton.tooltip(for: model.bar) }
        else if let i, let t = model.bar?.tabs[i] {
            toolTip = onClose(event, i) ? "Move to its own column" : (t.title.isEmpty ? t.app : "\(t.title) (\(t.app))")
        } else { toolTip = nil }
    }
    override func mouseExited(with event: NSEvent) { model.hovered = nil; model.heldHovered = false; toolTip = nil }
    override func mouseDown(with event: NSEvent) {
        if overHeldButton(event) {
            // Like any button: it acts on release, and only if the pointer is still on it.
            if event.modifierFlags.contains(.control), let a = model.activeIndex { showMenu(event, tab: a); return }
            model.heldPressed = true; heldDown = true
            return
        }
        guard let i = index(event), let tab = model.bar?.tabs[i] else { return }
        model.pressed = i
        downIndex = i; downPoint = event.locationInWindow; dragged = false
        if event.modifierFlags.contains(.control) { showMenu(event, tab: i); return }
        if event.modifierFlags.contains(.option) || onClose(event, i) { onAction(.popOut(tab.id)); downIndex = nil; return }
        onSelect(tab.id)
    }
    /// Drag a tab sideways to reorder it; drag it out of the bar (about 40pt down) to move it to its own column.
    override func mouseDragged(with event: NSEvent) {
        guard let i = downIndex, let tab = model.bar?.tabs[i] else { return }
        let dx = abs(event.locationInWindow.x - downPoint.x), dy = abs(event.locationInWindow.y - downPoint.y)
        if dx > 6 || dy > 6 { dragged = true }
        if dy > 40 { onAction(.popOut(tab.id)); downIndex = nil; model.pressed = nil; return }
        guard dragged, let to = index(event), to != i else { return }
        onAction(.reorder(tab.id, to: to))
        downIndex = to
    }
    override func mouseUp(with event: NSEvent) {
        if heldDown {
            heldDown = false; model.heldPressed = false
            if overHeldButton(event), let id = model.bar?.active, let a = HeldBarButton.action(for: id) { onAction(a) }
            return
        }
        model.pressed = nil; downIndex = nil
    }
    override func otherMouseDown(with event: NSEvent) {
        if let i = index(event), let tab = model.bar?.tabs[i] { onAction(.popOut(tab.id)) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if overHeldButton(event), let a = model.activeIndex { showMenu(event, tab: a) } else if let i = index(event) { showMenu(event, tab: i) }
    }

    private func showMenu(_ event: NSEvent, tab i: Int) {
        guard let bar = model.bar, bar.tabs.indices.contains(i) else { return }
        let id = bar.tabs[i].id
        onAction(.menuOpening(id))   // the controller fills in what a feature's entries need from the plan
        let ctx = context()
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ a: TabAction, enabled: Bool = true, keys: [String] = [], checked: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(menuPick(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = Box(a); item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.state = checked ? .on : .off
            if let k = TabMenuKeys.equivalent(keys) { item.keyEquivalent = k.key; item.keyEquivalentModifierMask = k.mask }
            menu.addItem(item)
        }
        add("Move to its own column", "rectangle.portrait.and.arrow.right", .popOut(id))
        menu.addItem(.separator())
        // What the running edition's features add for this tab.
        let extra = TabMenuFeature.entries(for: bar, context: ctx)
        for it in extra { add(it.title, it.symbol, .command(id, it.name, it.arg), keys: it.keys, checked: it.checked) }
        if !extra.isEmpty { menu.addItem(.separator()) }
        add("Move left", "arrow.left", .moveLeft(id), enabled: i > 0)
        add("Move right", "arrow.right", .moveRight(id), enabled: i < bar.tabs.count - 1)
        menu.addItem(.separator())
        add("Show as stack", "rectangle.split.1x2", .showAsStack(id))
        if TabMenuFeature.closesGroup(bar) { add("Close tab group", "rectangle.split.3x1", .closeGroup(id)) }
        add(TabMenuFeature.keepOutTitle(bar) ?? "Keep out of the ribbon", "rectangle.on.rectangle", .keepOut(id))
        model.pressed = nil
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    private final class Box { let a: TabAction; init(_ a: TabAction) { self.a = a } }
    @objc private func menuPick(_ s: NSMenuItem) { if let b = s.representedObject as? Box { onAction(b.a) } }

    /// Wheel or two-finger scroll over the bar steps through the tabs, one per gesture notch (rate-limited so momentum does not skip).
    override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if event.phase == .began || event.phase == [] { wheel = 0 }
        wheel += d
        guard abs(wheel) > (event.hasPreciseScrollingDeltas ? 14 : 1), Date().timeIntervalSince(lastWheel) > 0.18 else { return }
        lastWheel = Date()
        onCycle(wheel < 0 ? 1 : -1)
        wheel = 0
    }
}
