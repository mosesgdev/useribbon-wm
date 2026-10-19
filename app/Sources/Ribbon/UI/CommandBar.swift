import SwiftUI
import AppKit
import Combine

enum BarAction { case focusWindow(UInt32), restoreWindow(UInt32), command(String), commandArg(String, Int), pause, shortcuts, showMap
    /// "Always float <App>" (on) / "Stop floating <App>" (off) for the focused window's app.
    case floatApp(id: String, name: String, on: Bool)
    /// "wid 75": the focused column to an exact fraction.
    case setWidth(Double)
}

/// The window the bar's actions apply to: the focused window when the bar opened.
struct BarTarget {
    let id: UInt32
    let title: String
    let app: String
    let icon: NSImage?
    /// Its column's width as a fraction of the display, for "Now 50 % wide".
    var width: Double? = nil
    /// The window is in a column held outside the ribbon (a Plus feature's): `width` is then that column's share of the
    /// whole display, and the ribbon-only actions (stack, full width, centre, direct widths) are left out.
    var held = false
    /// The word the bar adds after the app's name for such a window ("Buzz · <tag>"); nil for a ribbon window.
    var tag: String? = nil
}

struct BarItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let symbol: String
    let action: BarAction
    var keys: [String] = []
    /// "Minimized" / "Hidden": a window that is out of the ribbon. Shown as a tag with a dimmed icon.
    var badge: String? = nil
    /// Window rows: the app name, searchable even when the subtitle shows "Desktop 2" instead.
    var app = ""
    /// Other names for an action. A query that starts one of them ranks like one that starts the title.
    var keywords = ""
    /// A state the row shows with a check: the width in force, "On every desktop" while it is on.
    var checked = false
    /// The window an action is named after ("Make a tab group with Notes"): typing that name lists the window first, the action after it.
    var about: UInt32? = nil
    /// Frecency key: actions by title, windows by app name.
    var frecencyKey: String { isWindow ? "app:\(app.isEmpty ? subtitle : app)" : id }
    var searchText: String { (keywords.isEmpty ? "" : keywords + " ") + title + " " + (app.isEmpty || app == subtitle ? subtitle : app + " " + subtitle) }
    func hasKeyword(prefix q: String) -> Bool { keywords.lowercased().split(separator: " ").contains { $0.hasPrefix(q) } }
    var isWindow: Bool {
        switch action { case .focusWindow, .restoreWindow: true; default: false }
    }
    /// Actions that change the focused window (or its column); the footer names that window while one is selected.
    var actsOnWindow: Bool {
        switch action {
        case .command(let c), .commandArg(let c, _): Self.windowCommands.contains(c) || FeatureRegistry.shared.windowCommands.contains(c)
        case .floatApp, .setWidth: true
        default: false
        }
    }
    static let windowCommands: Set<String> = [
        "cycle_width", "cycle_width_back", "width_step", "cycle_height", "equalize_heights", "toggle_full", "center",
        "stack", "unstack", "toggle_tabs", "add_tab_left", "add_tab_right", "tab_with", "next_tab", "prev_tab",
        "toggle_dim", "toggle_focus", "toggle_float", "move_to_other_display", "move_left", "move_right", "move_to_desktop",
        "grow_width", "shrink_width", "grow_height", "shrink_height", "stack_right", "move_first", "move_last", "move_up", "move_down",
    ]
}

extension BarAction {
    /// What the core refuses (or does nothing with) while a column held outside the ribbon has focus: the bar leaves these out for such a window.
    static let ribbonOnlyCommands: Set<String> = [
        "toggle_full", "center", "stack", "stack_right", "unstack", "add_tab_left", "add_tab_right", "tab_with", "move_left", "move_right",
        "move_first", "move_last", "width_step",
    ]
    var isRibbonOnly: Bool {
        switch self {
        case .command(let c), .commandArg(let c, _): Self.ribbonOnlyCommands.contains(c)
        default: false
        }
    }
}

/// Subsequence match with bonuses for word starts and runs. nil = no match.
/// The first letter must start a word (any word: the earliest one the rest of the query fits after), and short queries
/// (3 letters or less) may not skip letters after it.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let q = Array(query.lowercased()), t = Array(text.lowercased())
    if q.isEmpty { return 0 }
    func score(from start: Int) -> Int? {
        var score = 0, ti = 0, run = 0, skipped = 0
        for (n, c) in q.enumerated() {
            guard ti < t.count, let idx = n == 0 ? start : t[ti...].firstIndex(of: c) else { return nil }
            if n > 0 { skipped += idx - ti }
            run = idx == ti ? run + 1 : 0
            score += 1 + run * 2 + (idx == 0 || !t[idx - 1].isLetter ? 4 : 0) - (idx - ti)
            ti = idx + 1
        }
        return skipped <= max(q.count - 3, 0) ? score : nil
    }
    // "edge" starts a word of "Move to the right edge", though the first e is inside "Move"; a keyword can be the second word of a phrase.
    for start in t.indices where t[start] == q[0] && (start == 0 || !t[start - 1].isLetter) {
        if let s = score(from: start) { return s }
    }
    return nil
}

/// Positions in `text` that `query` matched, for highlighting. Words of the query match word starts or any run;
/// falls back to the fuzzy subsequence. Empty when nothing matches.
func matchPositions(_ query: String, _ text: String) -> Set<Int> {
    let t = Array(text.lowercased()), words = query.lowercased().split(separator: " ").map(Array.init)
    var hits = Set<Int>()
    for w in words where !w.isEmpty {
        guard w.count <= t.count else { continue }
        if let start = (0...(t.count - w.count)).first(where: { Array(t[$0..<$0 + w.count]) == w }) { hits.formUnion(start..<start + w.count) }
    }
    if !hits.isEmpty { return hits }
    var ti = 0
    for c in query.lowercased() where c != " " {
        guard ti < t.count, let idx = t[ti...].firstIndex(of: c) else { return [] }
        hits.insert(idx); ti = idx + 1
    }
    return hits
}

@MainActor
final class BarModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selected = 0 } } }
    @Published var selected = 0
    @Published var hovered: Int?
    let all: [BarItem]
    var target: BarTarget?
    var onRun: (BarItem) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(all: [BarItem], target: BarTarget? = nil) { self.all = all; self.target = target }

    /// The selected row changes the target window: the footer brings its name forward.
    var selectedActsOnWindow: Bool { let r = results; return r.indices.contains(selected) && r[selected].actsOnWindow }

    static let startActions = ["Make wider", "Full width", "Focus mode", "Undo"]

    /// Commands typed with a value: "wid 75" / "75%" → Width 75 %, "desk 3" → Go to / Send to Desktop 3.
    var valueItems: [BarItem] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "%" }).map(String.init)
        guard let n = words.last.flatMap(Int.init) else { return [] }
        let verb = words.dropLast().joined(separator: " ")
        let name = target?.app
        var out: [BarItem] = []
        // A window held outside the ribbon has sizes of its own, not a percentage.
        if (verb.isEmpty && query.contains("%")) || (!verb.isEmpty && "width".hasPrefix(verb)) || verb == "w", (5...100).contains(n), target?.held != true {
            out.append(BarItem(id: "value:width", title: WidthPresets.title(Double(n) / 100), subtitle: name.map { "Resize \($0)" } ?? "Resize the window",
                               icon: nil, symbol: "arrow.left.and.right.square", action: .setWidth(Double(n) / 100)))
        }
        // "window 3" / "go to 3": the third column, numbered as the strip numbers them (the keys are ⌃⌥⇧⌘1…9).
        if !verb.isEmpty, ["window", "go to window", "goto window"].contains(where: { $0.hasPrefix(verb) }), (1...9).contains(n) {
            out.append(BarItem(id: "value:go-window", title: "Go to window \(n)", subtitle: "", icon: nil, symbol: "macwindow",
                               action: .commandArg("focus_index", n)))
        }
        if !verb.isEmpty, "desktop".hasPrefix(verb) || "send".hasPrefix(verb) || "move".hasPrefix(verb), (1...9).contains(n) {
            let go = BarItem(id: "value:go-desk", title: "Go to Desktop \(n)", subtitle: "", icon: nil, symbol: "rectangle.stack",
                             action: .commandArg("switch_desktop", n))
            let send = BarItem(id: "value:send-desk", title: "Send to Desktop \(n)", subtitle: name.map { "Move \($0) there" } ?? "",
                               icon: nil, symbol: "arrow.right.doc.on.clipboard", action: .commandArg("move_to_desktop", n))
            out += "desktop".hasPrefix(verb) ? [go, send] : [send, go]
        }
        return out
    }

    /// Window rows get ⌘1–⌘9 in the order they are listed.
    func quickNumber(at i: Int, in rows: [BarItem]) -> Int? {
        guard rows.indices.contains(i), rows[i].isWindow else { return nil }
        let n = rows[...i].filter(\.isWindow).count
        return n <= 9 ? n : nil
    }

    func runQuick(_ n: Int) {
        let r = results
        if let i = r.indices.first(where: { quickNumber(at: $0, in: r) == n }) { selected = i; onRun(r[i]) }
    }

    var results: [BarItem] {
        if query.isEmpty {
            let starters = Self.startActions.compactMap { t in all.first { !$0.isWindow && $0.title == t } }
            // The current window is shown above the list, so the list starts with where you could go next.
            let here = target.map { "win:\($0.id)" }
            return Array(all.filter { $0.isWindow && $0.id != here }.prefix(5)) + starters
        }
        let q = query.lowercased()
        let scored = all.compactMap { item -> (BarItem, Int)? in
            // A window's app is a name of its own: "terminal" scores the same however long the window's title is.
            let app = item.isWindow ? fuzzyScore(query, item.app) : nil
            guard let s = [fuzzyScore(query, item.title), fuzzyScore(query, item.searchText), app].compactMap({ $0 }).max() else { return nil }
            let title = item.title.lowercased()
            var score = s + Int(min(Frecency.score(item.frecencyKey) * 4, 30))   // below the +100 prefix bonus
            if title.hasPrefix(q) || item.hasKeyword(prefix: q) { score += 100 }
            if item.searchText.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { score += 40 }
            return (item, score)
        }
        let windowScores = Dictionary(scored.filter { $0.0.isWindow }.map { ($0.0.id, $0.1) }, uniquingKeysWith: max)
        return scored.map { item, score in (item, item.about.flatMap { windowScores["win:\($0)"] }.map { min(score, $0 - 1) } ?? score) }
            .enumerated().sorted { l, r in
            if l.element.1 != r.element.1 { return l.element.1 > r.element.1 }
            if l.element.0.isWindow != r.element.0.isWindow { return l.element.0.isWindow }   // windows win ties only
            return l.offset < r.offset
        }.prefix(8).map(\.element.0).filter { r in !valueItems.contains { $0.title == r.title } }
            .reduce(into: valueItems) { $0.append($1) }.prefix(8).map { $0 }
    }

    func move(_ d: Int) { let n = results.count; if n > 0 { selected = (selected + d + n) % n } }
    func runSelected() { let r = results; if r.indices.contains(selected) { onRun(r[selected]) } }

    /// The built-in rows; `specs` adds what the running edition's features contribute.
    private static let baseSpecs: [(String, String, BarAction)] = [
        ("Back to last window", "arrow.uturn.backward.circle", .command("focus_previous")),
        ("Go to first window", "arrow.left.to.line", .command("focus_first")),
        ("Go to last window", "arrow.right.to.line", .command("focus_last")),
        ("Move column to the start", "arrow.left.to.line.compact", .command("move_first")),
        ("Move column to the end", "arrow.right.to.line.compact", .command("move_last")),
        ("Make wider", "arrow.left.and.right", .command("cycle_width")),
        ("Make narrower", "arrow.right.and.line.vertical.and.arrow.left", .command("cycle_width_back")),
        ("Nudge wider", "rectangle.arrowtriangle.2.outward", .command("grow_width")),
        ("Nudge narrower", "rectangle.arrowtriangle.2.inward", .command("shrink_width")),
        ("Change height", "arrow.up.and.down", .command("cycle_height")),
        ("Nudge taller", "rectangle.expand.vertical", .command("grow_height")),
        ("Nudge shorter", "rectangle.compress.vertical", .command("shrink_height")),
        ("Make heights equal", "equal.square", .command("equalize_heights")),
        ("Full width", "arrow.up.left.and.arrow.down.right", .command("toggle_full")),
        ("Center", "align.horizontal.center", .command("center")),
        ("Stack with the window on the left", "square.stack", .command("stack")),
        ("Stack with the window on the right", "square.stack.3d.down.right", .command("stack_right")),
        ("Take out of stack", "square.and.arrow.up", .command("unstack")),
        ("Move window up", "arrow.up.square", .command("move_up")),
        ("Move window down", "arrow.down.square", .command("move_down")),
        ("Make tabs / toggle tabs", "rectangle.topthird.inset.filled", .command("toggle_tabs")),
        ("Add to tabs on the left", "arrow.left.square", .command("add_tab_left")),
        ("Add to tabs on the right", "arrow.right.square", .command("add_tab_right")),
        ("Next tab", "chevron.right.square", .command("next_tab")),
        ("Previous tab", "chevron.left.square", .command("prev_tab")),
        ("Dim other windows", "circle.lefthalf.filled", .command("toggle_dim")),
        ("Focus mode", "scope", .command("toggle_focus")),
        ("Back to last desktop", "arrow.triangle.2.circlepath", .command("switch_desktop_back")),
        ("Undo", "arrow.uturn.backward", .command("undo")),
        ("Redo", "arrow.uturn.forward", .command("redo")),
        ("In or out of the ribbon", "rectangle.on.rectangle", .command("toggle_float")),
        ("Move window to other display", "rectangle.2.swap", .command("move_to_other_display")),
        ("Focus other display", "display.2", .command("focus_other_display")),
        ("Pause for now", "pause.circle", .pause),
        ("Show my windows", "rectangle.split.3x1", .showMap),
        ("Show Shortcuts", "keyboard", .shortcuts),
    ]

    private static var specs: [(String, String, BarAction)] { FeatureRegistry.shared.barRows(merging: baseSpecs) }

    static var specTitles: [String] { specs.map(\.0) }

    /// Keycaps for an action, derived from the hotkey table and the current modifier. Empty when it has no hotkey.
    @MainActor static func keys(for action: BarAction, store: ShortcutStore) -> [String] {
        let hk = Hotkeys.table.first { hk in
            switch (action, hk.action) {
            case (.command(let a), .command(let b, _)): return a == b
            case (.commandArg(let a, let n), .command(let b, let m)): return a == b && n == m
            case (.pause, .pause): return true
            default: return false
            }
        }
        guard let hk else { return [] }
        return store.keys(for: hk)
    }

    /// Rows for minimized / hidden windows: tagged, searchable by the tag ("minimized"), choosing one restores it.
    static func shelfItems(_ shelf: [ShelfItem], icon: (ShelfItem) -> NSImage?) -> [BarItem] {
        shelf.map { s in
            BarItem(id: "win:\(s.id)", title: s.title.isEmpty ? s.app : s.title, subtitle: s.hidden ? "Hidden" : "Minimized",
                    icon: icon(s), symbol: "macwindow", action: .restoreWindow(s.id), badge: s.hidden ? "Hidden" : "Minimized", app: s.app)
        }
    }

    /// The second line of an action: what it will do, named after the window it changes. "%@" is that window's app.
    private static let baseDetails: [String: String] = [
        "Make wider": "Next width for %@", "Make narrower": "Previous width for %@",
        "Nudge wider": "A little more width for %@", "Nudge narrower": "A little less width for %@",
        "Change height": "Next height in the stack", "Make heights equal": "Share the column's height evenly",
        "Nudge taller": "A little more height in the stack", "Nudge shorter": "A little less height in the stack",
        "Move column to the start": "%@'s column goes to the front of the ribbon", "Move column to the end": "%@'s column goes to the end of the ribbon",
        "Move window up": "%@ swaps places with the one above (or the tab before)", "Move window down": "%@ swaps places with the one below (or the tab after)",
        "Full width": "%@ fills the screen, or goes back", "Center": "Put %@ in the middle of the screen",
        "Stack with the window on the left": "%@ joins the column on its left", "Take out of stack": "%@ gets its own column",
        "Stack with the window on the right": "%@ joins the column on its right",
        "Make tabs / toggle tabs": "The column's windows share one frame", "Dim other windows": "Everything but %@ dims",
        "Focus mode": "Blur everything except %@", "In or out of the ribbon": "%@ floats above the ribbon, or rejoins it",
        "Move window to other display": "Send %@ to the other screen", "Undo": "Take back the last change", "Redo": "Do it again",
        "Back to last window": "The window you were in before", "Pause for now": "Ribbon stops arranging until you resume",
    ]

    @MainActor static func actions(store: ShortcutStore, target: BarTarget? = nil, registry: FeatureRegistry = .shared) -> [BarItem] {
        let widths = WidthPresets.current().enumerated().map { (i, f) in
            (WidthPresets.title(f), "arrow.left.and.right.square", BarAction.commandArg("width_step", i + 1))
        }
        let app = target?.app ?? "the window"
        let held = target?.held == true
        // A held column's share is measured from whole pixels (⅕ can come as 0.1999), so one at its own size is named by that size:
        // rounded down, the measured share would read one low.
        let now = target?.width.map { f in " · now \(WidthPresets.percent(held ? registry.nominalHeldWidth(f) : f))" } ?? ""
        let details = baseDetails.merging(registry.barDetails) { mine, _ in mine }
        let standIns = registry.standInTitles, keywords = registry.barKeywords
        return (registry.barRows(merging: baseSpecs) + widths).filter { !$0.0.hasSuffix("other display") || NSScreen.screens.count > 1 }
            .filter { target == nil || !standIns.contains($0.0) }   // a window in front gets the rows its feature makes for it
            .filter { !held || !$0.2.isRibbonOnly }.map { spec in
            var detail = details[spec.0].map { $0.replacingOccurrences(of: "%@", with: app) } ?? ""
            if case .commandArg("width_step", _) = spec.2 { detail = "Resize \(app)" }
            if ["Make wider", "Make narrower", "Nudge wider", "Nudge narrower"].contains(spec.0) || detail.hasPrefix("Resize") { detail += now }
            detail = detail.prefix(1).uppercased() + detail.dropFirst()
            return BarItem(id: "action:\(spec.0)", title: spec.0, subtitle: detail, icon: nil, symbol: spec.1, action: spec.2,
                           keys: keys(for: spec.2, store: store), keywords: standIns.contains(spec.0) ? keywords[spec.0] ?? "" : "")
        }
    }
}

struct CommandBarView: View {
    @ObservedObject var model: BarModel
    @FocusState private var focused: Bool
    @State var appeared = false
    @State private var pressed: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        panelBody
            .frame(width: 640)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .top).opacity(appeared ? 1 : 0)
            .animation(reduceMotion ? Theme.reduced : Theme.panelSpring, value: appeared)
            .animation(Theme.micro, value: model.selected)
            .onAppear { appeared = true; focused = true }
    }

    private var panelBody: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.muted)
                TextField("Find a window or action", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .medium, design: .rounded))
                    .focused($focused)
                    .onSubmit { model.runSelected() }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    // Esc clears what you typed first, then closes.
                    .onKeyPress(.escape) { if model.query.isEmpty { model.onClose() } else { model.query = "" }; return .handled }
                    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                        guard press.modifiers == .command, let n = Int(press.characters), n >= 1 else { return .ignored }
                        model.runQuick(n); return .handled
                    }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            if let t = model.target { targetRow(t, active: model.selectedActsOnWindow) }

            let results = model.results
            if results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                        if i == 0 || results[i - 1].isWindow != item.isWindow { section(item.isWindow ? "Windows" : "Actions") }
                        row(item, index: i, quick: model.quickNumber(at: i, in: results), selected: i == model.selected)
                    }
                }
            }
            footer
        }
        .padding(8)
        .readingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.muted)
            Text("No windows or actions match \u{201C}\(model.query)\u{201D}").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("Try an app name like Safari, or a command like \u{201C}width 50\u{201D}.").font(Theme.caption).foregroundStyle(Theme.muted)
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 22)
    }

    /// The window you are in, shown under the search field: it is where you are and what the actions change.
    /// It lights up while an action that changes it is selected.
    private func targetRow(_ t: BarTarget, active: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = t.icon { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: "macwindow").foregroundStyle(Theme.accent) }
            }.frame(width: 20, height: 20)
            Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(t.tag.map { "\(t.app) · \($0)" } ?? t.app).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 8)
            Text(active ? "Action applies here" : "You\u{2019}re here").font(Theme.caption).foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.muted))
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            shape.fill(active ? Theme.accent.opacity(colorScheme == .dark ? 0.22 : 0.09) : Color.primary.opacity(0.05))
                .overlay(shape.strokeBorder(Theme.accent.opacity(active ? 0.35 : 0), lineWidth: 0.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current window: \(t.title), \(t.app)\(t.tag.map { ", \($0)" } ?? ""). Actions apply to this window.")
    }

    /// Every hint is a keycap, so the footer reads like the rest of the app.
    private var footer: some View {
        HStack(spacing: 14) {
            hint(["↵"], "Go"); hint(["↑", "↓"], "Move"); hint(["⌘", "1–9"], "Jump"); hint(["esc"], model.query.isEmpty ? "Close" : "Clear")
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Return to go, arrow keys to move, Command and a number to jump to a window, Escape to \(model.query.isEmpty ? "close" : "clear")")
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 5) { KeyCaps(keys: keys, metrics: .small, gap: 3); Text(text).font(Theme.caption).foregroundStyle(Theme.muted) }
    }

    /// The title with the letters you typed brought forward.
    private func highlighted(_ title: String) -> Text {
        let hits = model.query.isEmpty ? [] : matchPositions(model.query, title)
        guard !hits.isEmpty else { return Text(title) }
        var out = AttributedString()
        for (i, ch) in title.enumerated() {
            var a = AttributedString(String(ch))
            if hits.contains(i) { a.foregroundColor = Theme.accent; a.font = .system(size: 15, weight: .bold) }
            out += a
        }
        return Text(out)
    }

    private func row(_ item: BarItem, index i: Int, quick: Int?, selected: Bool) -> some View {
        let hovered = model.hovered == i
        return HStack(spacing: 12) {
            Group {
                if let icon = item.icon { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: item.symbol).font(.system(size: 16)).foregroundStyle(Theme.accent) }
            }.frame(width: 28, height: 28).opacity(item.badge == nil ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                highlighted(item.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if !item.subtitle.isEmpty { Text(item.subtitle).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            .opacity(item.badge == nil ? 1 : 0.6)
            Spacer(minLength: 8)
            if let b = item.badge {
                Text(b).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6).frame(height: 18).background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
            }
            if let quick { KeyCaps(keys: ["⌘", "\(quick)"], metrics: .small, gap: 3).opacity(selected || hovered ? 1 : 0.55) }
            else if !item.keys.isEmpty { KeyCaps(keys: item.keys, metrics: .small, gap: 3) }
            if item.checked {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.accent))   // accent on the accent fill would fade
                    .accessibilityLabel("On")
            }
        }
        .padding(.horizontal, 12).frame(height: item.subtitle.isEmpty ? 40 : 48)
        .contentShape(Rectangle())
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            if selected {
                // Plain translucent fill: the bar itself is the only glass layer.
                shape.fill(Theme.accent.opacity(colorScheme == .dark ? 0.42 : 0.18))   // dark keeps the accent: it must not read as slate
                    .overlay(shape.strokeBorder(Theme.accent.opacity(colorScheme == .dark ? 0.7 : 0.35), lineWidth: colorScheme == .dark ? 1 : 0.5))
            } else if hovered {
                shape.fill(Color.primary.opacity(pressed == i ? 0.1 : 0.05))
            }
        }
        .scaleEffect(pressed == i && !reduceMotion ? 0.98 : 1)
        .animation(Theme.micro, value: pressed)
        .onHover { inside in if inside { model.hovered = i } else if model.hovered == i { model.hovered = nil } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = i }
            .onEnded { _ in pressed = nil; model.selected = i; model.runSelected() })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Floating, non-activating panel: the previous app stays "behind" while you type.
@MainActor
final class CommandBarController: NSObject {
    let store: ShortcutStore
    init(store: ShortcutStore) { self.store = store }
    var windowsProvider: () -> [BarItem] = { [] }
    var desktopsProvider: () -> [BarItem] = { [] }
    /// Context actions (e.g. "Always float <App>" for the focused window).
    var contextProvider: () -> [BarItem] = { [] }
    /// The focused window, named in the footer as the one the actions apply to.
    var targetProvider: () -> BarTarget? = { nil }
    var onAction: (BarAction) -> Void = { _ in }
    private var panel: KeyPanel?
    private var clickMonitor: Any?
    private var keeper: KeyKeeper?
    /// The app that was in front when the bar opened: Esc hands the keyboard back to it if the bar had to activate Ribbon.
    private var previousApp: NSRunningApplication?
    private var sizeObserver: AnyCancellable?
    var isOpen: Bool { panel != nil }
    /// The open bar's model; QA scripts type into it and run its selection.
    private(set) var model: BarModel?

    func toggle() { isOpen ? close(handBack: true) : show() }

    /// QA: type `text` into the open bar one key at a time, at a person's pace.
    func qaType(_ text: String) {
        Task { @MainActor [weak self] in
            for c in text {
                try? await Task.sleep(for: .milliseconds(110))
                self?.model?.query.append(c)
            }
        }
    }

    func show() {
        close()
        let target = targetProvider()
        let model = BarModel(all: windowsProvider() + desktopsProvider() + contextProvider() + BarModel.actions(store: store, target: target),
                             target: target)
        model.onClose = { [weak self] in self?.close(handBack: true) }
        model.onRun = { [weak self] item in Frecency.record(item.frecencyKey); self?.close(); self?.onAction(item.action) }
        self.model = model
        let host = NSHostingView(rootView: CommandBarView(model: model))
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        let p = KeyPanel.make(size: CGSize(width: 640, height: 200))
        p.contentView = host
        guard let f = (Screens.focused ?? NSScreen.main)?.visibleFrame else { return }
        let top = f.maxY - 120
        // Size to content so the panel never swallows clicks below the results.
        let fit = { [weak p, weak host] in
            guard let p, let host else { return }
            let h = host.fittingSize.height
            p.setFrame(NSRect(x: f.midX - 320, y: top - h, width: 640, height: h), display: true)
        }
        fit()
        sizeObserver = model.objectWillChange.sink { _ in DispatchQueue.main.async { fit() } }
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        p.makeKeyAndOrderFront(nil)
        panel = p
        // Losing key is not leaving: a notification or another app's panel can borrow it for a moment. Only a click elsewhere,
        // a real app switch (⌘Tab, Dock) or Esc closes the bar; otherwise it takes the keyboard back.
        let k = KeyKeeper(panel: { [weak self] in self?.panel }, holding: { [weak self] in self?.panel != nil }, onLeft: { [weak self] in self?.close() })
        k.start(window: p)
        keeper = k
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    /// `handBack`: Esc / toggle. If the bar had to activate Ribbon to keep typing, give the keyboard back to the app that was in front.
    func close(handBack: Bool = false) {
        sizeObserver = nil
        model = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        let activated = keeper?.activatedRibbon == true
        keeper?.stop(); keeper = nil
        let p = panel; panel = nil
        p?.delegate = nil; p?.orderOut(nil); p?.close()
        if handBack, activated, NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }
}
