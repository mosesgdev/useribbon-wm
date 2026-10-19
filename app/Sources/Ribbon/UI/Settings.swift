import SwiftUI
import ServiceManagement

/// User settings, persisted in UserDefaults (@AppStorage keys below).
struct RibbonSettings: Equatable {
    var modifier: ModifierChoice
    var gap: Double
    var defaultWidth: Double
    var newWindow: String
    var focusRing: Bool
    var threeFingerScroll: Bool
    var swipeFingers: Int
    var holdToShow: Bool
    /// nil = automatic: on when the displays touch only at a corner (or not at all).
    var mouseWarp: Bool?
    var centerOnOverflow: Bool
    /// "rich" (25 · 33 · 50 · 66 · 75 · 100) or "simple" (⅓ ½ ⅔ full).
    var widthPresets = "rich"
    /// "normal", "dim" or "blur": what happens to the windows you are not in.
    var otherWindows = "normal"
    var dimLevel = "subtle"
    var stripSize = StripSize.medium

    static func load() -> RibbonSettings {
        let d = UserDefaults.standard
        return RibbonSettings(
            modifier: ModifierChoice(rawValue: d.string(forKey: "modifier") ?? "") ?? .ctrlOpt,
            gap: d.object(forKey: "gap") as? Double ?? 12,
            defaultWidth: d.object(forKey: "defaultWidth") as? Double ?? 0.5,
            newWindow: d.string(forKey: "newWindow") ?? "right_of_focused",
            focusRing: d.object(forKey: "focusRing") as? Bool ?? true,
            threeFingerScroll: d.object(forKey: "threeFingerScroll") as? Bool ?? true,
            swipeFingers: d.integer(forKey: "swipeFingers") == 4 ? 4 : 3,
            holdToShow: d.object(forKey: "holdToShow") as? Bool ?? true,
            mouseWarp: d.object(forKey: "mouseWarp") as? Bool,
            centerOnOverflow: d.object(forKey: "centerOnOverflow") as? Bool ?? false,
            widthPresets: d.string(forKey: WidthPresets.key) ?? "rich",
            otherWindows: OtherWindows.resolve(stored: d.string(forKey: OtherWindows.key), legacyDim: d.bool(forKey: DimPrefs.enabledKey)).rawValue,
            dimLevel: d.string(forKey: DimPrefs.levelKey) ?? "subtle",
            stripSize: StripSize.from(d.string(forKey: StripSize.key)))
    }

    var engineConfig: EngineConfig {
        EngineConfig(gap: gap, outerGap: gap, defaultWidth: defaultWidth, newWindow: newWindow,
                     scroll: centerOnOverflow ? "center_on_overflow" : "keep_visible", widthPresets: WidthPresets.list(for: widthPresets))
    }
}

/// Launch at login is on by default: enabled once when onboarding finishes; Settings can turn it off for good.
enum LoginItem {
    private static let key = "loginItemAutoEnabled"

    static func enableOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: key) else { return }
        d.set(true, forKey: key)
        do { try SMAppService.mainApp.register() }
        catch { NSLog("ribbon: login item not registered: \(error)") }   // e.g. app not in /Applications
    }
}

/// Settings tabs: one calm sentence each says what lives there. A feature can add a tab of its own (`FeatureSettingsTab`);
/// its title is its id.
struct SettingsTab: Hashable, Identifiable {
    let id: String
    static let general = SettingsTab(id: "General"), layout = SettingsTab(id: "Layout")
    static let input = SettingsTab(id: "Input"), apps = SettingsTab(id: "Apps")
    static let builtIn = [general, layout, input, apps]

    /// The built-in tabs, then the running edition's feature tabs.
    static func all(_ registry: FeatureRegistry = .shared) -> [SettingsTab] { builtIn + registry.settingsTabs.map { SettingsTab(id: $0.title) } }

    func subtitle(_ registry: FeatureRegistry = .shared) -> String {
        switch self {
        case .general: "The basics: your keys, and how Ribbon starts."
        case .layout: "How wide your windows sit and how they line up."
        case .input: "How you move around: trackpad and displays."
        case .apps: "Apps that should stay out of the ribbon."
        default: registry.settingsTabs.first { $0.title == id }?.subtitle ?? ""
        }
    }
}

/// The controls features added to a built-in tab, at the end of its first group: each view is a row of the group.
private struct FeatureRows: View {
    let tab: SettingsTab
    var body: some View {
        let rows = FeatureRegistry.shared.settingsRows(in: tab.id)
        ForEach(rows.indices, id: \.self) { rows[$0].view() }
    }
}

/// A rounded group of rows with hairline dividers. Every child view becomes a row, so a new setting is just a new view in the pane.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subs in
                ForEach(Array(subs.enumerated()), id: \.offset) { i, sub in
                    if i > 0 { Divider().padding(.leading, 14) }
                    sub.padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Title (and an optional quiet line) on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body)
                if let detail { Text(detail).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

struct SettingsView: View {
    @AppStorage("modifier") private var modifier = ModifierChoice.ctrlOpt.rawValue
    @AppStorage("gap") private var gap = 12.0
    @AppStorage("defaultWidth") private var defaultWidth = 0.5
    @AppStorage("newWindow") private var newWindow = "right_of_focused"
    @AppStorage("focusRing") private var focusRing = true
    @AppStorage("threeFingerScroll") private var threeFingerScroll = true
    @AppStorage("swipeFingers") private var swipeFingers = 3
    @AppStorage("holdToShow") private var holdToShow = true
    @AppStorage(StripSize.key) private var stripSize = StripSize.medium
    @State private var displays = Screens.all()
    @AppStorage("centerOnOverflow") private var centerOnOverflow = false
    @State private var floatRules = FloatRules.load()
    @State private var macOSSwipe = SystemSwipe.conflicts(fingers: UserDefaults.standard.integer(forKey: "swipeFingers") == 4 ? 4 : 3)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State var tab: SettingsTab = .general
    @State private var contentH: CGFloat = 0
    /// Told the window's natural height whenever it changes (tab switch, a longer list): the window follows, animated.
    var onHeight: (CGFloat) -> Void = { _ in }
    @State private var screenOK = ScreenRecording.granted
    @State private var askedScreen = false

    init(tab: SettingsTab = .general, onHeight: @escaping (CGFloat) -> Void = { _ in }) {
        _tab = State(initialValue: tab); self.onHeight = onHeight
    }

    /// The pane is as tall as its content, up to what the display allows; beyond that it scrolls.
    private var paneCap: CGFloat { max(200, (Screens.focused?.visibleFrame.height ?? 700) - 220) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) { ForEach(SettingsTab.all()) { Text($0.id).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Text(tab.subtitle()).font(.system(size: 14)).foregroundStyle(Theme.muted)
            pane
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
        .frame(width: 480, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in displays = Screens.all() }
        .onAppear { macOSSwipe = SystemSwipe.conflicts(fingers: swipeFingers) }
        .onChange(of: swipeFingers) { _, n in macOSSwipe = SystemSwipe.conflicts(fingers: n) }
    }

    @ViewBuilder private var pane: some View {
        let body = VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case .general: general
            case .layout: layout
            case .input: input
            case .apps: floatSection
            default: featureTab
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentH = $0 }
        if contentH > paneCap { ScrollView { body }.frame(height: paneCap) } else { body }
    }

    /// A tab a feature added.
    @ViewBuilder private var featureTab: some View {
        if let t = FeatureRegistry.shared.settingsTabs.first(where: { $0.title == tab.id }) { t.view() }
    }

    @ViewBuilder private var general: some View {
        let mod = ModifierChoice(rawValue: modifier) ?? .ctrlOpt
        SettingsGroup {
            SettingsRow(title: "Hold these keys", detail: mod.words) {
                Picker("Hold these keys", selection: $modifier) { ForEach(ModifierChoice.allCases) { Text($0.label).tag($0.rawValue) } }
                    .labelsHidden().fixedSize()
            }
            SettingsRow(title: "Hold \(mod.glyphs) to see all your windows") { Toggle("", isOn: $holdToShow).labelsHidden().toggleStyle(.switch) }
            SettingsRow(title: "Window strip size", detail: "The row of your windows at the bottom of the screen") {
                Picker("Window strip size", selection: $stripSize) { ForEach(StripSize.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            SettingsRow(title: "Highlight the window I'm in") { Toggle("", isOn: $focusRing).labelsHidden().toggleStyle(.switch) }
            OtherWindowsRow()
            DimStrengthRow()
            SettingsRow(title: "Start Ribbon when I log in") {
                Toggle("", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("login item: \(error)") }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                })).labelsHidden().toggleStyle(.switch)
            }
            FeatureRows(tab: .general)
        }
    }

    @ViewBuilder private var layout: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Space between windows").font(Theme.body); Spacer(); Text("\(Int(gap)) pt").font(Theme.body.monospacedDigit()).foregroundStyle(Theme.muted) }
                Slider(value: $gap, in: 0...40, step: 2).accessibilityLabel("Space between windows")
            }
            SettingsRow(title: "New window width") {
                Picker("New window width", selection: $defaultWidth) {
                    Text("One third").tag(0.333); Text("Half").tag(0.5); Text("Two thirds").tag(0.667); Text("Full").tag(1.0)
                }.labelsHidden().fixedSize()
            }
            WidthStepsRow()
            SettingsRow(title: "New windows appear") {
                Picker("New windows appear", selection: $newWindow) {
                    Text("Next to the current one").tag("right_of_focused"); Text("At the end").tag("end")
                }.labelsHidden().fixedSize()
            }
            SettingsRow(title: "Center windows that are too wide") { Toggle("", isOn: $centerOnOverflow).labelsHidden().toggleStyle(.switch) }
            FeatureRows(tab: .layout)
        }
    }

    @ViewBuilder private var input: some View {
        SettingsGroup {
            if TrackpadScroller.isAvailable {
                SettingsRow(title: "Swipe to scroll the ribbon") { Toggle("", isOn: $threeFingerScroll).labelsHidden().toggleStyle(.switch) }
                SettingsRow(title: "Swipe with") {
                    Picker("Swipe with", selection: $swipeFingers) { Text("3 fingers").tag(3); Text("4 fingers").tag(4) }
                        .labelsHidden().pickerStyle(.segmented).fixedSize().disabled(!threeFingerScroll)
                }
            } else {
                SettingsRow(title: "Swipe to scroll the ribbon", detail: "Not available on this Mac") { Toggle("", isOn: .constant(false)).labelsHidden().toggleStyle(.switch).disabled(true) }
            }
            // Screen Recording smooths keyboard moves as well as swipes, so it is offered with or without a trackpad.
            if screenOK {
                SettingsRow(title: "Smooth motion is on") { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            } else {
                SettingsRow(title: "Smooth motion needs Screen Recording", detail: ScreenRecording.note) {
                    HStack(spacing: 6) {
                        if askedScreen { Button("Reopen Ribbon") { ScreenRecording.reopen() } }
                        Button(askedScreen ? "Open list" : "Turn on") { ScreenRecording.turnOn(); askedScreen = true }
                            .buttonStyle(.glassProminent).tint(Theme.accent)   // the row's one real action
                    }
                }
            }
            if displays.count > 1 {
                SettingsRow(title: "Move the pointer between displays at the edges",
                            detail: DisplayGeometry.warpDefault(displays) ? "Your displays only touch at a corner, so the pointer cannot cross on its own." : nil) {
                    Toggle("", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "mouseWarp") as? Bool ?? DisplayGeometry.warpDefault(displays) },
                        set: { UserDefaults.standard.set($0, forKey: "mouseWarp") })).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear { screenOK = ScreenRecording.granted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in screenOK = ScreenRecording.granted }
        if TrackpadScroller.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Text(macOSSwipe ? Self.swipeNote(swipeFingers) : "Ribbon keeps its swipe out of the app under the pointer while you scroll the ribbon.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if macOSSwipe { Button("Open Trackpad Settings") { SystemSwipe.openTrackpadSettings() } }
            }.padding(.horizontal, 4)
        }
        if displays.count > 1, !Screens.separateSpaces {
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn on “Displays have separate Spaces” in System Settings → Desktop & Dock, then log out and back in.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("Open Desktop & Dock Settings") { Screens.openSpacesSettings() }
            }.padding(.horizontal, 4)
        }
    }

    /// Apps whose windows stay out of the ribbon (they float).
    @ViewBuilder private var floatSection: some View {
        SettingsGroup {
            if floatRules.isEmpty {
                Text("No exceptions. Every app joins the ribbon.").font(Theme.body).foregroundStyle(Theme.muted)
            }
            ForEach(floatRules, id: \.id) { rule in
                HStack(spacing: 10) {
                    Image(nsImage: Self.icon(rule.id)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                    Text(rule.name).font(Theme.body)
                    Spacer()
                    Button { update(FloatRules.removing(id: rule.id, from: floatRules)) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.muted).help("Let \(rule.name) join the ribbon")
                        .accessibilityLabel("Let \(rule.name) join the ribbon")
                }
            }
            Menu("Add a running app") {
                let candidates = Self.runningCandidates(excluding: floatRules)
                if candidates.isEmpty { Text("No other apps are open") }
                ForEach(candidates, id: \.id) { c in Button(c.name) { update(FloatRules.adding(c, to: floatRules)) } }
            }.fixedSize()
        }
        Text("Windows from these apps float on top of the ribbon, not in it. Adding or removing an app moves its open windows too.").font(Theme.caption).foregroundStyle(Theme.muted).padding(.horizontal, 4)
    }

    /// Plain and short; the same idea as SystemSwipe.message, in the voice of the rest of Settings.
    private static func swipeNote(_ fingers: Int) -> String {
        fingers == 4 ? "macOS uses four-finger swipes too. Turn that off in Trackpad settings so they don't fight."
                     : "macOS uses three-finger swipes too. Set macOS to four fingers so they don't fight."
    }

    private func update(_ rules: [FloatRule]) { floatRules = rules; FloatRules.save(rules) }

    private static func icon(_ bundleID: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    static func runningCandidates(excluding rules: [FloatRule]) -> [FloatRule] {
        let have = Set(rules.map { $0.id.lowercased() })
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let all = apps.compactMap { a -> FloatRule? in
            guard let id = a.bundleIdentifier, !have.contains(id.lowercased()) else { return nil }
            return FloatRule(id: id, name: a.localizedName ?? id)
        }
        return Array(Set(all)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var shown = false

    static func show(tab: SettingsTab? = nil) {
        if tab != nil { window?.close(); window = nil }   // a fresh pane opens on the asked tab
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(tab: tab ?? .general, onHeight: { height in MainActor.assumeIsolated { fit(height) } }))
            host.sizingOptions = [.intrinsicContentSize]   // the window itself is sized in fit(), per tab, with an animation
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Ribbon Settings"; w.isReleasedWhenClosed = false
            w.contentView = host
            host.layoutSubtreeIfNeeded()
            let h = host.fittingSize.height
            w.setContentSize(NSSize(width: 480, height: h > 50 ? h : 360))
            window = w
        }
        shown = false
        place()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        shown = true
    }

    private static func place() {
        guard let w = window, let f = Screens.focused?.visibleFrame else { window?.center(); return }
        w.setFrameOrigin(NSPoint(x: (f.midX - w.frame.width / 2).rounded(), y: max(f.minY, f.maxY - w.frame.height - f.height * 0.1).rounded()))
    }

    /// Resize to the content, keeping the top edge where it is.
    private static func fit(_ height: CGFloat) {
        guard let w = window, height > 1 else { return }
        let target = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 480, height: height)).size
        guard abs(target.height - w.frame.height) > 0.5 else { return }
        var frame = w.frame
        frame.origin.y += frame.height - target.height
        frame.size = target
        let animate = shown && w.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        w.setFrame(frame, display: true, animate: animate)
    }
}
