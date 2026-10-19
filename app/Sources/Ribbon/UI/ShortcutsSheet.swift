import SwiftUI
import Combine

/// Where the shortcut list is scrolled to: drives the fades, the "More" cue and the keys.
struct ScrollEdges: Equatable {
    var top = false, bottom = false
    var maxY: CGFloat = 0, page: CGFloat = 300, y: CGFloat = 0
}

/// Scroll keys for the sheet: the panel's key monitor (works whatever has focus) sends them here.
final class SheetKeys {
    enum Key { case line(CGFloat), page(CGFloat), top, bottom }
    let events = PassthroughSubject<Key, Never>()

    /// Arrow, Page and Home/End keys with no modifier. nil = not a scroll key.
    static func key(code: Int, modifiers: NSEvent.ModifierFlags) -> Key? {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch code {
        case 125: return .line(1)
        case 126: return .line(-1)
        case 121: return .page(1)
        case 116: return .page(-1)
        case 115: return .top
        case 119: return .bottom
        default: return nil
        }
    }
}

struct ShortcutsView: View {
    @ObservedObject var store: ShortcutStore
    var onClose: () -> Void = {}
    @State private var scroll = ScrollPosition()
    @State private var edges = ScrollEdges()
    var keys = SheetKeys()
    /// The list's natural height: the sheet hugs it (up to what the display allows) instead of reserving a fixed block.
    @State private var listH: CGFloat = 0
    var onFit: () -> Void = {}

    private var listCap: CGFloat { max(160, (Screens.focused?.visibleFrame.height ?? 700) - 80 - 150) }

    private func scrollBy(_ dy: CGFloat) { scroll.scrollTo(y: min(max(edges.y + dy, 0), edges.maxY)) }

    private struct Row: Identifiable {
        let id: String
        let title: String
        var hotkey: Hotkey?       // nil = a fixed group row (desktops)
        var groupKeys: [String] = []
    }

    private func group(of hk: Hotkey) -> String { hk.action == .pause ? "Ribbon" : hk.group }

    private func rows(_ g: String) -> [Row] {
        let m = store.modifier
        var out: [Row] = []
        for hk in Hotkeys.table where group(of: hk) == g {
            if hk.group == "Displays", NSScreen.screens.count < 2, store.overrides[hk.id] == nil { continue }
            switch hk.action {
            case .command("switch_desktop", let n?):
                if n == 1 { out.append(Row(id: "desktops", title: "Go to desktop", groupKeys: m.keys("1…9"))) }
                continue
            case .command("move_to_desktop", let n?):
                if n == 1 { out.append(Row(id: "desktops-send", title: "Send window to desktop", groupKeys: m.keys(shift: true, "1…9"))) }
                continue
            case .command("width_step", let n?):
                // Named after the step the active width list has; a step the list lacks (Simple has four) hides unless it was customised.
                let steps = WidthPresets.current()
                if n <= steps.count { out.append(Row(id: hk.id, title: WidthPresets.title(steps[n - 1]), hotkey: hk)) }
                else if store.overrides[hk.id] != nil { out.append(Row(id: hk.id, title: hk.title, hotkey: hk)) }
            default: out.append(Row(id: hk.id, title: hk.title, hotkey: hk))
            }
        }
        return out
    }

    private func column(_ gs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(gs.filter { !rows($0).isEmpty }, id: \.self) { g in
                VStack(alignment: .leading, spacing: 8) {
                    Text(g.uppercased()).font(Theme.caption.weight(.semibold)).tracking(0.6).foregroundStyle(Theme.muted)
                    ForEach(rows(g)) { ShortcutRow(store: store, title: $0.title, hotkey: $0.hotkey, groupKeys: $0.groupKeys) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts").font(Theme.display(20))
                Text(store.overrides.isEmpty
                     ? "Hold \(store.modifier.glyphs) and press → to try it. Click any shortcut to change it."
                     : "Most start with \(store.modifier.glyphs). Click a shortcut to change it.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            // Two columns keep the sheet short. On a small display the list scrolls (wheel, trackpad, ↑↓, Page Up/Down, Home/End, or the
            // "More" button), the header and footer stay put, and fades plus a "More" cue say there is more above or below.
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 32) {
                    column(["Move around", "Rearrange"] + FeatureRegistry.shared.shortcutGroups(inColumn: 0))
                    column(["Resize", "Desktops", "Displays", "Find", "Oops", "Ribbon"] + FeatureRegistry.shared.shortcutGroups(inColumn: 1))
                }
                .padding(.trailing, 10)   // room for the scroll bar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in listH = h; DispatchQueue.main.async { onFit() } }
            }
            .frame(height: listH > 0 ? min(listH, listCap) : nil)
            .scrollIndicators(.visible)
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: ScrollEdges.self) { g in
                ScrollEdges(top: g.contentOffset.y + g.contentInsets.top > 1,
                            bottom: g.contentOffset.y + g.containerSize.height < g.contentSize.height - 1,
                            maxY: max(0, g.contentSize.height - g.containerSize.height), page: g.containerSize.height * 0.85, y: g.contentOffset.y)
            } action: { _, e in edges = e }
            .onReceive(keys.events) { k in
                switch k {
                case .line(let d): scrollBy(d * 40)
                case .page(let d): scrollBy(d * edges.page)
                case .top: scroll.scrollTo(y: 0)
                case .bottom: scroll.scrollTo(y: edges.maxY)
                }
            }
            .mask {   // soft fades where the list runs under the header / footer
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: edges.top ? 22 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: edges.bottom ? 30 : 0)
                }
            }
            .animation(Theme.micro, value: edges.bottom).animation(Theme.micro, value: edges.top)
            HStack {
                Button { store.endRecording(); store.resetAll() } label: {
                    Label("Reset to defaults", systemImage: "arrow.counterclockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)   // quiet, but at least 4.5:1 (primary at 70%)
                .opacity(store.overrides.isEmpty ? 0.8 : 1).disabled(store.overrides.isEmpty)
                .help("Restore defaults")
                Spacer()
                Button("Got it", action: onClose).buttonStyle(.glassProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
            // The "More" cue lives in the footer, centred: over the list it would sit on the left column's keys.
            .overlay {
                if edges.bottom {
                    Button { scroll.scrollTo(y: edges.maxY) } label: {
                        Label("More", systemImage: "chevron.down").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(Capsule(style: .continuous).fill(Theme.accent.opacity(0.16)))
                            .overlay(Capsule(style: .continuous).stroke(Theme.accent.opacity(0.4), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .accessibilityLabel("Show more shortcuts")
                    .transition(.opacity)
                }
            }
            .animation(Theme.micro, value: edges.bottom)
        }
        .background {   // Esc closes too (while recording, Esc cancels the recording first)
            Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .focusEffectDisabled()
        .padding(24).frame(width: 800)
        .frame(maxHeight: max(300, (Screens.focused?.visibleFrame.height ?? 700) - 80))   // never taller than the display; the list scrolls
        .readingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
    }
}

/// One action: title, reset arrow (only when customised), clickable key chip, and an inline note while recording.
private struct ShortcutRow: View {
    @ObservedObject var store: ShortcutStore
    let title: String
    let hotkey: Hotkey?
    let groupKeys: [String]
    @State private var hovering = false

    private var recording: Bool { hotkey != nil && store.recording == hotkey?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(Theme.body)
                Spacer(minLength: 12)
                if let hk = hotkey {
                    Button { store.endRecording(); store.reset(hk.id) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium))
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    .opacity(store.isCustom(hk) ? 1 : 0).disabled(!store.isCustom(hk))   // space stays reserved: nothing shifts
                    .help("Back to the default").accessibilityLabel("Reset \(title) to default")
                    .accessibilityHidden(!store.isCustom(hk))
                    chip(hk)
                } else {
                    KeyCaps(keys: groupKeys).padding(.horizontal, 4)
                }
            }
            if recording, let notice = store.notice { note(notice) }
        }
    }

    @ViewBuilder private func chip(_ hk: Hotkey) -> some View {
        Button { store.beginRecording(hk.id) } label: {
            if recording { RecordingChip(held: store.held) }
            else if store.keys(for: hk).isEmpty {
                Text("Not set").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).frame(height: 22)
            } else { KeyCaps(keys: store.keys(for: hk)) }
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .padding(.horizontal, 3).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.key + 2, style: .continuous).fill(Color.primary.opacity(hovering && !recording ? 0.08 : 0)))
        .onHover { hovering = $0 }
        .animation(Theme.micro, value: hovering)
        .help(recording ? "Press new keys · Esc cancels · Delete clears" : "Click to change this shortcut")
        .accessibilityLabel("\(title) shortcut: \(store.keys(for: hk).isEmpty ? "not set" : store.keys(for: hk).joined(separator: " "))")
        .accessibilityHint("Click, then press the new shortcut")
    }

    @ViewBuilder private func note(_ n: ShortcutStore.Notice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.amber).font(.system(size: 11))
            switch n {
            case .warning(let msg):
                Text(msg).font(Theme.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            case .replace(_, _, let otherTitle):
                Text("Used by \(otherTitle) — replace?").font(Theme.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button("Cancel") { store.endRecording() }.buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.muted)
                Button("Replace") { store.confirmReplace() }.buttonStyle(.plain)
                    .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

/// "Type shortcut…" with a soft accent pulse (static under Reduce Motion). Held modifiers show as you press them.
private struct RecordingChip: View {
    let held: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Text(held.isEmpty ? "Type shortcut…" : held.joined() + "…")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).frame(minWidth: 96, minHeight: 22, maxHeight: 22)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous).fill(Theme.accent.opacity(reduceMotion ? 0.14 : (on ? 0.20 : 0.08))))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous).stroke(Theme.accent.opacity(reduceMotion ? 0.7 : (on ? 0.85 : 0.4)), lineWidth: 1))
            .fixedSize()
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } } }
    }
}

/// Hosting view for the sheet: the first click on a chip or button works even when the sheet is not key.
final class SheetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ShortcutsPanel {
    private var panel: KeyPanel?
    private var sizeObserver: AnyCancellable?
    private var keeper: KeyKeeper?
    private var keyMonitor: Any?
    private let sheetKeys = SheetKeys()
    private var store: ShortcutStore?
    var isOpen: Bool { panel != nil }

    func show(store: ShortcutStore) {
        close()
        self.store = store
        var fit: () -> Void = {}
        var placed = false
        let host = SheetHostingView(rootView: ShortcutsView(store: store, onClose: { [weak self] in self?.close() }, keys: sheetKeys, onFit: { fit() }))
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        host.layoutSubtreeIfNeeded()
        let p = KeyPanel.make(size: host.fittingSize)
        p.contentView = host
        p.onCancel = { [weak self] in self?.close() }
        if let s = Screens.focused { p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - p.frame.width / 2, y: s.visibleFrame.midY - p.frame.height / 2)) }
        // A note under a row makes the sheet taller: grow it downward, keeping the top edge where it is.
        fit = { [weak p, weak host] in
            guard let p, let host else { return }
            let h = host.fittingSize.height
            guard abs(h - p.frame.height) > 0.5 else { return }
            var y = p.frame.maxY - h
            if !placed, let s = Screens.focused { placed = true; y = (s.visibleFrame.midY - h / 2).rounded() }   // first fit: centre the real size
            if let floor = (p.screen ?? Screens.focused)?.visibleFrame.minY { y = max(y, floor) }   // never grow off the bottom
            p.setFrame(NSRect(x: p.frame.minX, y: y, width: p.frame.width, height: h), display: true)
        }
        sizeObserver = store.objectWillChange.sink { _ in DispatchQueue.main.async { fit() } }
        // The sheet stays key (scroll keys, Esc, recording): a notification or a screen-sharing banner can borrow the keyboard for a moment.
        // Only a click somewhere else, a real app switch (⌘Tab, Dock) or Esc means the user left on purpose; then it lets go and any
        // recording ends so the hotkeys never stay suspended. Shared with the command bar.
        let k = KeyKeeper(panel: { [weak self] in self?.panel }, holding: { [weak self] in self?.panel != nil },
                          onLeft: { [weak self] in self?.store?.endRecording() })
        k.start(window: p)
        keeper = k
        store.ensureKey = { [weak self] in self?.keeper?.reclaim(attempts: 3) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak p] e in
            let code = Int(e.keyCode), mods = e.modifierFlags
            return MainActor.assumeIsolated {
                guard let self, let p, p.isKeyWindow, self.store?.recording == nil, let k = SheetKeys.key(code: code, modifiers: mods) else { return e }
                self.sheetKeys.events.send(k)
                return nil
            }
        }
        panel = p
        keeper?.reclaim(attempts: 3)
    }

    func close() {
        store?.ensureKey = {}
        store?.endRecording()
        sizeObserver = nil
        keeper?.stop(); keeper = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.close(); panel = nil
    }
}
