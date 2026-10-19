import SwiftUI
import AppKit

final class HUDModel: ObservableObject {
    @Published var map = RibbonMap(columns: [], viewport: Viewport(start: 0, end: 1), focusedIndex: nil)
    @Published var focusID: UInt32?
    /// Short feedback from the engine ("Undid: move"); replaces the window name in the caption while set.
    @Published var toast: String?
    @Published var visible = false
    /// Window or desktop dot under the pointer (they name themselves in the caption), what is pressed, and the tile being dragged.
    @Published var hoverID: UInt32?
    @Published var hoverDesk: Int?
    @Published var pressed: HUDHit?
    @Published var drag: HUDDrag?
    var icon: (UInt32) -> NSImage? = { _ in nil }
    /// Gestures end up here: the controller forwards each command to the engine.
    var onCommands: ([HUDCommand]) -> Void = { _ in }
}

/// The strip's plain fills (the pill is the only glass layer, and glass can't sample glass).
struct StripInk {
    let dark: Bool, increased: Bool
    var idle: Color { dark ? .white.opacity(0.11) : .black.opacity(0.07) }
    var hover: Color { dark ? .white.opacity(0.17) : .black.opacity(0.10) }
    /// The focused (or lifted) plate: opaque, so nothing shows through a dragged tile, and washed with the accent so it is the
    /// strongest plate in both schemes (a white plate vanishes on the light pill).
    var raised: Color { dark ? Color(red: 0.25, green: 0.26, blue: 0.33) : Color(red: 0.84, green: 0.85, blue: 0.94) }
    var raisedShadow: Color { .black.opacity(dark ? 0.35 : 0.12) }
    var dragShadow: Color { .black.opacity(dark ? 0.5 : 0.26) }
    /// The strip's only accent: "you are here". The deeper fill keeps 4.5:1 on a light pill with Increase Contrast.
    var ring: Color { increased && !dark ? Theme.accentFill : Theme.accent }
    var ink2: Color { .primary.opacity(increased ? 0.85 : 0.55) }
    var badge: Double { increased ? 0.9 : 0.72 }
    var offscreen: Double { increased ? (dark ? 0.6 : 0.75) : (dark ? 0.4 : 0.55) }
    /// Hairline around icon artwork: dark icons keep their outline on a dark plate, white ones on a light plate.
    var rim: Color { dark ? .white.opacity(0.18) : .black.opacity(0.08) }
    var dotCurrent: Double { increased ? 1 : 0.85 }
    var dotOccupied: Double { increased ? 0.8 : 0.55 }
    var dotEmpty: Double { increased ? 0.7 : 0.45 }
}

/// The ribbon map: one tile per column, drawn to scale (stacked windows as slivers), off-screen columns faded,
/// and one caption line with the desktop dots. Click a tile to jump, drag it sideways to reorder, click a dot to switch desktop.
struct RibbonMapView: View {
    @ObservedObject var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    typealias L = HUDLayout
    private var cols: [MapColumn] { model.map.columns }
    var increased: Bool { contrast == .increased }
    var ink: StripInk { StripInk(dark: scheme == .dark, increased: increased) }
    /// Movement is instant under Reduce Motion; fades and fills still ease, just quicker.
    func slide(_ d: Double) -> Animation? { reduceMotion ? nil : Theme.ease(d) }
    func fade(_ d: Double) -> Animation { reduceMotion ? Theme.reduced : Theme.ease(d) }

    var body: some View {
        let g = HUDStrip(map: model.map, focusID: model.focusID)
        let line = HUDCaption.line(map: model.map, focusID: model.focusID, hoverID: model.hoverID, hoverDesk: model.hoverDesk)
        VStack(spacing: L.railGap) {
            if g.hasTiles { rail(g) }
            foot(g, line)
        }
        .padding(.top, g.padTop).padding(.bottom, g.padBottom)
        .padding(.horizontal, L.padX)
        .frame(width: g.pillW, height: g.pillH)
        // The pill is the only glass layer, applied directly to the content (never a background inside a container).
        .floatingSurface(in: RoundedRectangle(cornerRadius: L.pillRadius, style: .continuous))   // base fill + stroke: legible over any backdrop
        // The panel resizes instantly, so the pill does too: an animated frame would lag behind its window.
        .transaction(value: [g.pillW, g.pillH]) { $0.animation = nil }
        .scaleEffect(model.visible || reduceMotion ? 1 : 0.97, anchor: .bottom)
        .opacity(model.visible ? 1 : 0)
        .animation(fade(0.2), value: model.visible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your windows")
    }

    // MARK: rail

    /// A column held outside the ribbon (Plus) sits outside the scrolling track at the strip's edge, parted from it by a glyph.
    private func rail(_ g: HUDStrip) -> some View {
        HStack(spacing: 0) {
            heldBlock(g, leading: true)
            if g.hasTrack {
                if g.over { more(g.hiddenLeft, left: true) }
                track(g)
                if g.over { more(g.hiddenRight, left: false) }
            }
            heldBlock(g, leading: false)
        }
        .frame(height: L.tileH)
    }

    private func track(_ g: HUDStrip) -> some View {
        let drop = model.drag.map { L.drop($0, g) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(cols.enumerated()), id: \.element.windows.first?.id) { i, col in
                if g.tiles.indices.contains(i) { column(col, i, g, drop: drop) }
            }
        }
        .frame(width: g.trackW, height: L.tileH, alignment: .topLeading)
        .animation(slide(0.25), value: g.tiles)
        .animation(slide(0.25), value: cols.map { $0.windows.map(\.id) })
        .animation(fade(0.2), value: model.focusID)
        .animation(fade(0.15), value: model.hoverID)
        .animation(fade(0.15), value: model.pressed)
        .offset(x: -g.shift)
        .animation(slide(0.25), value: g.shift)
        .frame(width: g.viewW, height: L.tileH, alignment: .leading)
        .mask { mask(g) }
    }

    /// Fades only the sides that hide tiles; elsewhere nothing is clipped, so the focused tile's shadow keeps its room.
    /// The fades grow and shrink with the scroll, so tiles slide in and out through them instead of popping at the edge.
    private func mask(_ g: HUDStrip) -> some View {
        let room = -(g.over ? L.clipRoomOver : L.clipRoom)
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: g.fadeL ? L.fadeW : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: g.fadeR ? L.fadeW : 0)
        }
        .padding(.leading, g.fadeL ? 0 : room).padding(.trailing, g.fadeR ? 0 : room).padding(.vertical, -L.clipRoomV)
        .animation(slide(0.25), value: [g.fadeL, g.fadeR])
    }

    /// "‹ 3": how many columns sit beyond the edge of an overflowing strip.
    private func more(_ n: Int, left: Bool) -> some View {
        HStack(spacing: L.moreSpacing) {
            if n > 0 {
                if left { Image(systemName: "chevron.left").font(.system(size: L.chevronFont, weight: .semibold)) }
                Text("\(n)").font(.system(size: L.moreFont, weight: .semibold)).monospacedDigit()
                if !left { Image(systemName: "chevron.right").font(.system(size: L.chevronFont, weight: .semibold)) }
            }
        }
        .foregroundStyle(ink.ink2)
        .frame(width: L.moreW, height: L.tileH)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n) \(n == 1 ? "column" : "columns") to the \(left ? "left" : "right")")
        .accessibilityHidden(n == 0)
    }

    // MARK: tiles

    private func column(_ col: MapColumn, _ i: Int, _ g: HUDStrip, drop: HUDDrop?) -> some View {
        let t = g.tiles[i]
        let d = model.drag
        let dragging = d?.from == i
        let slots = d.flatMap { d in drop.map { L.slide(of: i, drag: d, drop: $0) } } ?? 0
        // Tiles that make room move by exactly the dragged tile's width plus the gap: where they will sit after the drop.
        let room = d.map { $0.held != nil ? (g.held?.w ?? 0) + L.gap : (g.tiles.indices.contains($0.from) ? g.tiles[$0.from].w + L.gap : 0) } ?? 0
        let focusedHere = col.windows.contains { $0.id == model.focusID }
        let hoveredHere = col.windows.contains { $0.id == model.hoverID }
        let offscreen = !col.visible && !focusedHere && !dragging
        // The dragged tile stays on the rail (the drop still reads the raw pointer, so dragging past the end means "to the end").
        let lo = (g.over ? g.shift : 0) - t.x, hi = (g.over ? g.shift + g.viewW : g.trackW) - t.x - t.w
        let dragX = dragging ? min(max(d?.dx ?? 0, lo), hi) : 0
        return face(col, t, at: i, focused: focusedHere, dragging: dragging)
            .opacity(offscreen ? (hoveredHere ? 0.85 : ink.offscreen) : 1)
            // Lifting eases (scale, plate, shadow) ...
            .animation(fade(0.15), value: dragging)
            .offset(x: t.x + CGFloat(slots) * room + dragX)
            // ... but the dragged tile follows the pointer without easing; everything else (and the drop) eases.
            .transaction { tr in if dragging { tr.animation = nil } }
            .animation(slide(0.22), value: slots)
            .zIndex(dragging ? 10 : (focusedHere ? 2 : 1))
    }

    /// A column's tile, the ribbon's or a held column's (`i` nil): its slivers, focus ring, count badge and plate shadow. Where it sits is up to
    /// the caller. `target` lights it as the place a dragged tile would land.
    func face(_ col: MapColumn, _ t: HUDStrip.Tile, at i: Int?, focused: Bool, dragging: Bool, target: Bool = false) -> some View {
        let pressedWhole: Bool = {
            guard t.rows.count == 1 else { return false }
            switch model.pressed {
            case .window(let c, _)?: return c == i
            case .held?: return i == nil
            default: return false
            }
        }()
        let shape = RoundedRectangle(cornerRadius: L.tileRadius, style: .continuous)
        return VStack(spacing: L.stackGap) {
            ForEach(Array(t.rows.enumerated()), id: \.element) { k, r in
                sliver(col, i, row: r, k: k, of: t.rows.count, width: t.w, raised: dragging || (t.rows.count == 1 && focused))
            }
        }
        .frame(width: t.w, height: L.tileH)
        .clipShape(shape)
        .overlay {
            // Centred on the tile's edge: clear of the icons inside, still 3pt clear of a neighbour.
            if focused || target { shape.stroke(ink.ring, lineWidth: L.ringW(increased: increased)) }
            else if increased { shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: L.edgeW) }
        }
        // A tab group, or a stack with more windows than slivers, counts its windows.
        .overlay(alignment: .bottomTrailing) { if col.windows.count > t.rows.count { countBadge(col.windows.count) } }
        // Only opaque plates cast a shadow (it would show through the translucent slivers of a stack).
        .shadow(color: dragging ? ink.dragShadow : (focused && t.rows.count == 1 ? ink.raisedShadow : .clear),
                radius: dragging ? L.dragShadow.radius : L.raisedShadow.radius, y: dragging ? L.dragShadow.y : L.raisedShadow.y)
        .scaleEffect(dragging || (target && !reduceMotion) ? 1.05 : (pressedWhole && !reduceMotion ? 0.96 : 1))
    }

    /// One window's share of a tile. Corners facing a neighbouring sliver are small; the tile's clip rounds the outside.
    private func sliver(_ col: MapColumn, _ i: Int?, row r: Int, k: Int, of n: Int, width: CGFloat, raised: Bool) -> some View {
        let w = col.windows[r]
        let focused = w.id == model.focusID
        let hovered = w.id == model.hoverID
        let pressed = n > 1 && model.pressed == (i.map { .window(col: $0, row: r) } ?? HeldHit.hit(row: r))
        let inner = L.sliverRadius
        let shape = UnevenRoundedRectangle(topLeadingRadius: k > 0 ? inner : 0, bottomLeadingRadius: k < n - 1 ? inner : 0,
                                           bottomTrailingRadius: k < n - 1 ? inner : 0, topTrailingRadius: k > 0 ? inner : 0, style: .continuous)
        return ZStack {
            shape.fill(raised || focused ? ink.raised : (hovered ? ink.hover : ink.idle))
            windowIcon(w, size: L.iconFrame(rows: n))
        }
        .frame(width: width, height: L.sliverH(n))
        .contentShape(Rectangle())
        .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axLabel(w, col, at: i, row: r, focused: focused))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onCommands(L.focusCommand(w.id)) }
        .accessibilityActions {
            // The drags' keyboard-free twins: reorder, join the held column (Plus), or leave it.
            if let i {
                Button("Move left") { move(i, i - 1) }
                Button("Move right") { move(i, i + 1) }
                heldJoinAction(from: i)
            } else {
                heldLeaveAction()
            }
        }
    }

    private func axLabel(_ w: MapWindow, _ col: MapColumn, at i: Int?, row r: Int, focused: Bool) -> String {
        let tabs = col.tabbed ? col.windows.count : nil, row = col.tabbed ? nil : r, rows = col.tabbed ? nil : col.windows.count
        guard let i else { return HUDCaption.heldAxLabel(app: HUDCaption.who(w), focused: focused, tabs: tabs, row: row, rows: rows) }
        return HUDCaption.axLabel(app: HUDCaption.who(w), index: i, total: cols.count, focused: focused, offscreen: !col.visible,
                                  tabs: tabs, row: row, rows: rows)
    }

    /// App icons already carry their own shadow and margin: drawn as they are, no extra shadow or crop. A hairline traces
    /// the artwork (the squircle fills 824 of the icon grid's 1024), so a black or white icon keeps its outline on any plate.
    @ViewBuilder private func windowIcon(_ w: MapWindow, size: CGFloat) -> some View {
        if let img = model.icon(w.id) {
            let art = size * 824 / 1024
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: art * 0.2237, style: .continuous).strokeBorder(ink.rim, lineWidth: 0.5)
                    .frame(width: art, height: art))
        } else {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous).fill(Color.primary.opacity(0.12))
                .overlay(Image(systemName: "macwindow").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(Theme.muted))
                .frame(width: size, height: size)
        }
    }

    /// Window count in inverted ink, sitting on the tile's corner like a Dock badge (the label carries it for VoiceOver).
    private func countBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: L.badgeFont, weight: .bold)).monospacedDigit()
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, L.badgePadX)
            .frame(minWidth: L.badgeMin, minHeight: L.badgeMin)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(ink.badge)))
            // A ring of window colour parts it from the icon and the edge it sits on.
            .background(Capsule(style: .continuous).fill(Color(nsColor: .windowBackgroundColor)).padding(-L.badgeRing))
            .padding(-L.badgeOutset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func move(_ from: Int, _ to: Int) {
        model.onCommands(L.moveCommands(map: model.map, focusID: model.focusID, from: from, to: to))
    }

    // MARK: caption and desktops

    /// One line: the window's name and "6/10" on the left, the desktop dots on the right.
    private func foot(_ g: HUDStrip, _ line: (name: String, detail: String, preview: Bool)) -> some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: L.captionGap) {
                Text(line.name)
                    .font(.system(size: L.nameFont, weight: line.preview ? .medium : .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                if !line.detail.isEmpty {
                    if g.hasTiles {
                        Text(line.detail).font(.system(size: L.detailFont)).monospacedDigit().foregroundStyle(Theme.muted)
                            .fixedSize().contentTransition(.numericText())
                    } else {
                        // "Open a window to start": a hint, so it gives way first.
                        Text(line.detail).font(.system(size: L.hintFont)).foregroundStyle(Theme.muted).layoutPriority(-1)
                    }
                }
            }
            .lineLimit(1)
            .padding(.leading, L.footInset)
            // The tiles name themselves; with none, this line is all there is to read.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.detail.isEmpty ? line.name : "\(line.name). \(line.detail)")
            .accessibilityHidden(g.hasTiles)
            Spacer(minLength: g.dots > 0 ? L.footGap : L.footInset)
            if g.dots > 0 { dots(g.dots) }
        }
        .frame(height: L.footH)
        .animation(fade(0.18), value: line.name)
        .animation(fade(0.18), value: line.detail)
    }

    /// One cell per desktop up to the last one in use (or active): a capsule for here, a dot for in use, a ring for empty.
    /// Hidden while everything lives on desktop 1, so single-desktop use stays calm.
    private func dots(_ shown: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(model.map.desktops.prefix(shown), id: \.index) { d in
                let pressed = model.pressed == .dot(d.index)
                dotGlyph(d, lift: model.hoverDesk == d.index || pressed ? 0.3 : 0)
                    .frame(width: L.dotCell, height: L.footH)
                    .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Desktop \(d.index), \(d.count) \(d.count == 1 ? "window" : "windows")" + (d.active ? ", current" : ""))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.onCommands(L.desktopCommand(d.index)) }
            }
        }
        .animation(fade(0.2), value: model.map.desktops)
        .animation(fade(0.15), value: model.hoverDesk)
        .animation(fade(0.15), value: model.pressed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Desktops")
    }

    @ViewBuilder private func dotGlyph(_ d: DesktopInfo, lift: Double) -> some View {
        if d.active {
            Capsule(style: .continuous).fill(Color.primary.opacity(min(1, ink.dotCurrent + lift))).frame(width: L.deskHereW, height: L.deskDot)
        } else if d.count > 0 {
            Circle().fill(Color.primary.opacity(min(1, ink.dotOccupied + lift))).frame(width: L.deskDot, height: L.deskDot)
        } else {
            Circle().strokeBorder(Color.primary.opacity(min(1, ink.dotEmpty + lift)), lineWidth: L.deskStroke(increased: increased)).frame(width: L.deskDot, height: L.deskDot)
        }
    }
}

/// Hosting view for the panel. Mouse events are handled here, not by SwiftUI gestures: a non-key, non-activating panel
/// gets no SwiftUI hover or tap. Points are reported in pill coordinates (top-left origin).
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    var onPointer: (HUDPointerEvent, CGPoint) -> Void = { _, _ in }
    var pillInset: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x - pillInset, y: (isFlipped ? p.y : bounds.height - p.y) - pillInset)
    }
    override func mouseDown(with event: NSEvent) { onPointer(.down, point(event)) }
    override func mouseDragged(with event: NSEvent) { onPointer(.drag, point(event)) }
    override func mouseUp(with event: NSEvent) { onPointer(.up, point(event)) }
    // ⌃-click arrives as a right click (and holding the Ribbon modifier means ⌃ is down): a click is a click, whatever the modifiers.
    override func rightMouseDown(with event: NSEvent) { onPointer(.down, point(event)) }
    override func rightMouseDragged(with event: NSEvent) { onPointer(.drag, point(event)) }
    override func rightMouseUp(with event: NSEvent) { onPointer(.up, point(event)) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// Owns the non-activating panel and the show/linger/fade timing. The pointer over the panel holds it open.
@MainActor
final class HUDController {
    let model = HUDModel()
    /// Runs the commands a gesture produced (set by the Controller).
    var onCommands: ([HUDCommand]) -> Void = { _ in }
    private var panel: NSPanel?
    /// True while the shortcuts sheet or the command bar is up: the strip stays away so it never covers them.
    var isSuppressed: () -> Bool = { false }
    private var hideTask: Task<Void, Never>?
    private var hovering = false
    /// Held open by a held modifier (the ⌘Tab-style peek); `release()` lets go.
    private var heldOpen = false
    private static let margin: CGFloat = 6
    private static let linger = 1200
    private static let summonedLinger = 6000
    /// A toast ("First window", "Heights evened out") stays readable this long, whatever else happens to the strip meanwhile:
    /// a key release, or a focus echo that shows the strip again without a toast.
    static let toastLinger = 1800
    private var toastClock = ToastClock()
    /// Toasts live in their own pill above the strip (design B), so the strip's caption keeps naming your window.
    let pill = ToastPillController()
    /// A command's shortcut as the pill's hints name it ("⌃⌥T to switch"). Follows the modifier preset by default; the controller
    /// can swap in the shortcut store's live keys (per-action overrides included).
    var keyText: (String) -> String? = { HUDController.presetKey($0) }

    init() {
        model.onCommands = { [weak self] cmds in
            guard let self else { return }
            self.onCommands(cmds)
            // A click or a reorder is done: let the panel go shortly after, even with the pointer still on it.
            self.scheduleHide(after: 700, force: true)
        }
    }

    /// Shown by navigation: lingers briefly, stays while the pointer is on it.
    func show(map: RibbonMap, focus: UInt32?, toast: String? = nil, linger: Int? = nil) {
        guard !isSuppressed() else { return }
        let p = panel ?? makePanel()
        let now = Date()
        _ = toastClock.resolve(new: toast, current: nil, now: now, lingerMs: Self.toastLinger)
        model.map = map
        model.toast = nil
        // A held column has no ribbon index: with no focus given, its own window is the focus.
        model.focusID = focus ?? map.columns.first(where: \.focused)?.windows.first?.id ?? HUDCaption.heldFocus(map, nil)?.id
        place(p)
        // An empty desktop already says so in the strip's own caption line (unless a held column has focus and the caption names
        // it); the pill would repeat it word for word.
        if let toast, !(map.columns.isEmpty && HUDCaption.heldFocus(map, model.focusID) == nil && toast.hasSuffix(" · empty")) {
            let (text, hint) = Self.pillText(toast, map: map, focus: model.focusID, key: keyText)
            pill.show(text: text, hint: hint, diagram: ToastDiagram.make(toast: toast, map: map, focus: model.focusID),
                      above: p.frame.insetBy(dx: Self.margin, dy: Self.margin), lingerMs: Self.toastLinger)
        }
        if !p.isVisible { p.orderFrontRegardless() }
        startPolling()
        model.visible = true
        scheduleHide(after: max(linger ?? Self.linger, toastClock.remainingMs(now: now)))
    }

    /// Settings → strip size, applied live: every strip dimension follows `HUDLayout.size`, so redraw and re-fit the panel.
    func setSize(_ size: StripSize) {
        guard HUDLayout.size != size else { return }
        HUDLayout.size = size
        model.objectWillChange.send()
        if let p = panel, p.isVisible { place(p) }
    }

    /// Builds the panel and renders the (empty) strip once, invisibly, so the first swipe's first strip update is not a
    /// 30 ms SwiftUI cold start in the middle of a frame.
    func prewarm(map: RibbonMap? = nil, focus: UInt32? = nil) {
        guard panel == nil, !model.visible else { return }
        let p = makePanel()
        if let map { model.map = map; model.focusID = focus ?? map.columns.first(where: \.focused)?.windows.first?.id }
        p.alphaValue = 0
        place(p)
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                if !self.model.visible { p.orderOut(nil) }
                p.alphaValue = 1
            }
        }
    }

    /// Summoned on purpose (command bar, menu bar): stays long enough to reach it with the pointer.
    func summon(map: RibbonMap, focus: UInt32?) { show(map: map, focus: focus, linger: Self.summonedLinger) }

    /// Shown while a modifier is held: stays up (and updates live) until `release()`.
    func hold(map: RibbonMap, focus: UInt32?) { heldOpen = true; show(map: map, focus: focus) }
    /// Letting go hides the strip, but never cuts a toast short (a tap on a hotkey is also a modifier hold and release).
    func release() { heldOpen = false; scheduleHide(after: toastClock.remainingMs(now: Date())) }

    /// A command's default shortcut as keycap text ("⌃⌥K"), from the modifier preset; nil when it has none in the table.
    nonisolated static func presetKey(_ command: String) -> String? {
        guard let hk = Hotkeys.table.first(where: { $0.action == .command(command) }), !hk.allMods, !hk.widthKey else { return nil }
        let preset = ModifierChoice(rawValue: UserDefaults.standard.string(forKey: "modifier") ?? "") ?? .ctrlOpt
        return preset.keys(shift: hk.shift, hk.keyLabel).joined()
    }

    /// Headline and quieter hint for the pill: "Tab group: A + B · ⌃⌥Tab to switch" splits at the dot;
    /// notices and "Desktop 3 · empty" read as the caption would put them. A Plus feature's toasts have their own wording
    /// (`PlusToast`), and `key` names the shortcuts in their hints.
    nonisolated static func pillText(_ t: String, map: RibbonMap, focus: UInt32?, key: (String) -> String? = { _ in nil }) -> (String, String?) {
        if let own = PlusToast.text(t, key: key) { return own }
        let cap = HUDCaption.make(map: map, focusID: focus, hoverID: nil, toast: t)
        if t.hasSuffix(" · empty") { return ("\(t.dropLast(" · empty".count)) is empty", "Open a window to start") }
        if t.contains(". ") { return (cap.primary, cap.secondary.isEmpty ? nil : cap.secondary) }
        if let r = t.range(of: " · ") { return (String(t[..<r.lowerBound]), String(t[r.upperBound...])) }
        return (cap.primary, nil)
    }

    func hideNow() {
        pill.hideNow()
        hideTask?.cancel(); hovering = false; heldOpen = false
        toastClock = ToastClock()
        stopPolling()
        model.visible = false; clearPointer(); model.drag = nil
        panel?.orderOut(nil)
    }

    private var press: (point: CGPoint, hit: HUDHit?)?

    /// Hover, click and drag, resolved against the pure layout.
    private func pointerEvent(_ e: HUDPointerEvent, _ p: CGPoint) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let anim: Animation? = reduce ? nil : Theme.ease(0.25)
        let hit = HUDLayout.hit(p, map: model.map, focusID: model.focusID)
        switch e {
        case .exit: clearPointer()
        case .move:
            // Polled every 30 ms: only publish a change, so an idle pointer doesn't redraw the strip.
            var window: UInt32?, desk: Int?
            switch hit {
            case .window(let c, let r)?: window = model.map.columns[c].windows[r].id
            case .held(let h)?: window = h.window(in: model.map)?.id
            case .dot(let d)?: desk = d
            case nil: break
            }
            if model.hoverID != window { model.hoverID = window }
            if model.hoverDesk != desk { model.hoverDesk = desk }
        case .down:
            // The press lands on a panel that may be fading out (the keys were just released): keep it.
            press = (p, hit); hovering = true; hideTask?.cancel(); model.visible = true
            model.pressed = hit
        case .drag:
            guard let press else { return }
            let dx = p.x - press.point.x
            // A tile of the ribbon or a held column's: both lift once the pointer has moved a few points.
            let grabbed: HUDDrag? = {
                switch press.hit {
                case .window(let c, _)?: return HUDDrag(from: c, dx: dx)
                case .held(let h)?: return h.grab(dx: dx)
                default: return nil
                }
            }()
            if let grabbed, model.drag != nil || abs(dx) >= 6 {
                model.drag = grabbed
                if model.pressed != nil { model.pressed = nil }
            } else {
                // Not a drag (yet): the press shows only while the pointer stays on what it pressed, as the click would.
                let still = hit == press.hit ? hit : nil
                if model.pressed != still { model.pressed = still }
            }
        case .up:
            defer { press = nil }
            model.pressed = nil
            guard let press else { return }
            if let d = model.drag {
                withAnimation(anim) {
                    model.drag = nil
                    model.onCommands(HUDLayout.dropCommands(map: model.map, focusID: model.focusID, drag: d))
                }
            } else if case .window(let c, let r)? = press.hit, case .window(let c2, let r2)? = hit, c == c2, r == r2 {
                model.onCommands(HUDLayout.focusCommand(model.map.columns[c].windows[r].id))
            } else if case .held(let h)? = press.hit, hit == press.hit, let w = h.window(in: model.map) {
                model.onCommands(HUDLayout.focusCommand(w.id))
            } else if case .dot(let d)? = press.hit, case .dot(let d2)? = hit, d == d2 {
                model.onCommands(HUDLayout.desktopCommand(d))
            }
        }
    }

    /// Hover is polled while the panel is up: tracking-area events proved unreliable for a non-key, non-activating panel.
    private var hoverPoll: Timer?
    private func startPolling() {
        guard hoverPoll == nil else { return }
        hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHover() }
        }
    }
    private func stopPolling() { hoverPoll?.invalidate(); hoverPoll = nil }

    private func pollHover() {
        guard let p = panel, p.isVisible else { return }
        let l = NSEvent.mouseLocation
        let pt = CGPoint(x: l.x - p.frame.minX - Self.margin, y: p.frame.maxY - l.y - Self.margin)
        let inside = pt.x >= 0 && pt.y >= 0 && pt.x <= p.frame.width - 2 * Self.margin && pt.y <= p.frame.height - 2 * Self.margin
        if press == nil, inside != hovering { pointer(inside: inside) }
        if inside, press == nil { pointerEvent(.move, pt) }
    }

    private func pointer(inside: Bool) {
        hovering = inside
        if inside { hideTask?.cancel() }
        else { clearPointer(); scheduleHide(after: Self.linger) }
    }

    private func clearPointer() {
        if model.hoverID != nil { model.hoverID = nil }
        if model.hoverDesk != nil { model.hoverDesk = nil }
        if model.pressed != nil { model.pressed = nil }
    }

    /// `force` ignores the pointer (after a click); otherwise hovering cancels the timer and exit restarts it.
    private func scheduleHide(after ms: Int, force: Bool = false) {
        hideTask?.cancel()
        if (hovering || heldOpen) && !force { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))   // restarts on every change
            guard !Task.isCancelled, let self else { return }
            self.model.visible = false
            try? await Task.sleep(for: .milliseconds(320))
            if !Task.isCancelled { self.panel?.orderOut(nil); self.hovering = false; self.stopPolling(); self.clearPointer() }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isFloatingPanel = true; p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Takes clicks and drags but never key status: the user's app keeps the keyboard.
        p.hidesOnDeactivate = false; p.ignoresMouseEvents = false; p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true; 
        let host = HUDHostingView(rootView: RibbonMapView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        host.pillInset = Self.margin
        host.onPointer = { [weak self] e, p in self?.pointerEvent(e, p) }
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    /// The panel hugs the pill, so clicks beside it still reach the windows underneath.
    private func place(_ p: NSPanel) {
        guard let f = Screens.focused?.visibleFrame else { return }
        let g = HUDStrip(map: model.map, focusID: model.focusID)
        let w = g.pillW + 2 * Self.margin
        let h = g.pillH + 2 * Self.margin
        p.setFrame(NSRect(x: (f.midX - w / 2).rounded(), y: f.minY + Theme.dockInset - Self.margin, width: w, height: h), display: false)
    }
}


/// How long the current toast must stay on screen. Pure, so the timing is testable.
struct ToastClock {
    private(set) var until = Date.distantPast

    /// The toast to display: a new one starts the clock; none keeps the current one while it is still within its time.
    mutating func resolve(new: String?, current: String?, now: Date, lingerMs: Int) -> String? {
        if let new { until = now.addingTimeInterval(Double(lingerMs) / 1000); return new }
        return now < until ? current : nil
    }

    func remainingMs(now: Date) -> Int { max(0, Int((until.timeIntervalSince(now) * 1000).rounded(.up))) }
}
