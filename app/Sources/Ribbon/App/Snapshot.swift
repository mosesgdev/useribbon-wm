import SwiftUI
import AppKit

/// `Ribbon --snapshot <dir>` renders the main views offscreen with fake data (glass may render flat).
@MainActor
enum Snapshot {
    static func run(dir: String) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let hud = HUDModel()
        let cols = [("Safari", 0.5), ("Terminal", 0.333), ("Notes", 0.5), ("Mail", 0.5), ("Xcode", 0.667)]
        var id: UInt32 = 0
        hud.map = RibbonMap(columns: cols.enumerated().map { i, c in
            id += 1
            return MapColumn(windows: [MapWindow(id: id, app: c.0, title: c.0)], widthFrac: c.1, focused: i == 1, visible: i < 3)
        }, viewport: Viewport(start: 0.0, end: 0.5), focusedIndex: 1, desktop: 2,
        desktops: (1...9).map { DesktopInfo(index: $0, count: [3, 5, 0, 2, 0, 0, 0, 0, 0][$0 - 1], active: $0 == 2, windows: []) })
        hud.focusID = 2
        let snapshotStore = ShortcutStore(defaults: UserDefaults(suiteName: "ribbon.snapshot")!)
        let bundleIDs = ["com.apple.Safari", "com.apple.Terminal", "com.apple.Notes", "com.apple.mail", "com.apple.dt.Xcode"]
        hud.icon = { wid in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIDs[Int(wid) - 1]) else { return nil }
            // Flatten to a plain bitmap: raw multi-rep app icons wash out the offscreen render.
            let src = NSWorkspace.shared.icon(forFile: url.path)
            let flat = NSImage(size: NSSize(width: 52, height: 52))
            flat.lockFocus()
            src.draw(in: NSRect(x: 0, y: 0, width: 52, height: 52), from: .zero, operation: .sourceOver, fraction: 1)
            flat.unlockFocus()
            return flat
        }
        hud.visible = true

        let bar = BarModel(all: [
            BarItem(id: "1", title: "Inbox — Mail", subtitle: "Mail · Column 1", icon: nil, symbol: "envelope", action: .focusWindow(1)),
            BarItem(id: "2", title: "ribbon — zsh", subtitle: "Terminal · Column 3, below Notes", icon: nil, symbol: "terminal", action: .focusWindow(2)),
            BarItem(id: "3", title: "Dia", subtitle: "Dia · Tab 2 in column 4", icon: nil, symbol: "globe", action: .focusWindow(3)),
        ] + BarModel.actions(store: snapshotStore, target: BarTarget(id: 9, title: "", app: "Safari", icon: nil, width: 0.5)),
            target: BarTarget(id: 9, title: "Scrollable tiling — Niri wiki", app: "Safari", icon: hud.icon(1), width: 0.5))
        bar.selected = 4   // "Full width": the footer names the window it changes

        func pill(_ text: String, _ hint: String?, _ d: ToastDiagram?) -> AnyView {
            let m = ToastModel(); m.text = text; m.hint = hint; m.diagram = d; m.visible = true
            return AnyView(ToastPillView(model: m))
        }
        let items: [(String, CGSize, AnyView)] = [
            ("toast-width", CGSize(width: 360, height: 90), pill("Width 66\u{00A0}%", nil, .width(0.667))),
            ("toast-tabs", CGSize(width: 460, height: 90), pill("Tab group: Safari + Mail", "⌃⌥Tab to switch", .tabs)),
            ("toast-tabs-long", CGSize(width: 700, height: 90), pill("Tab group: Visual Studio Code + Google Chrome + Microsoft PowerPoint", "⌃⌥Tab to switch", .tabs)),
            ("toast-tabs-longest", CGSize(width: 700, height: 90), pill("Tab group: Final Cut Pro + Adobe Photoshop 2026 + Microsoft Word + Sublime Text + Xcode", "⌃⌥Tab to switch", .tabs)),
            ("toast-desk", CGSize(width: 460, height: 90), pill("Desktop 3 is empty", "Open a window to start", .desk(3, empty: true))),
            ("hud", CGSize(width: 700, height: 150), AnyView(RibbonMapView(model: hud))),
            ("commandbar", CGSize(width: 700, height: 640), AnyView(CommandBarView(model: bar, appeared: true))),
            ("onboarding", CGSize(width: 560, height: 480), AnyView(OnboardingView(pollTrust: false))),
            ("onboarding-cheatsheet", CGSize(width: 560, height: 480), AnyView(OnboardingView(stage: .cheatSheet, pollTrust: false))),
            ("shortcuts", CGSize(width: 900, height: 700), AnyView(ShortcutsView(store: snapshotStore))),
            ("settings-general", CGSize(width: 560, height: 360), AnyView(SettingsView(tab: .general))),
            ("settings-layout", CGSize(width: 560, height: 360), AnyView(SettingsView(tab: .layout))),
            ("settings-input", CGSize(width: 560, height: 360), AnyView(SettingsView(tab: .input))),
            ("settings-apps", CGSize(width: 560, height: 360), AnyView(SettingsView(tab: .apps))),
            ("conflict", CGSize(width: 440, height: 200), AnyView(ConflictCardView(conflict: Conflict(kind: .app, key: "k", name: "Rectangle")))),
            ("conflict-stage", CGSize(width: 440, height: 200), AnyView(ConflictCardView(conflict: Conflict(kind: .stageManager, key: "stage", name: "Stage Manager")))),
        ]
        var failed = false
        let dark: Set<String> = ["toast-width", "toast-tabs", "hud", "commandbar", "onboarding", "onboarding-cheatsheet", "shortcuts", "settings-general", "settings-layout", "settings-input", "settings-apps", "conflict"]
        let variants = items.flatMap { item in
            [(item.0, item.1, item.2, false)] + (dark.contains(item.0) ? [(item.0 + "-dark", item.1, item.2, true)] : [])
        }
        for (name, size, view, isDark) in variants {
            let r = ImageRenderer(content: SnapshotBackdrop(size: size, dark: isDark) { view }
                .environment(\.flatGlass, true).environment(\.colorScheme, isDark ? .dark : .light)
                .transaction { $0.disablesAnimations = true })
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("FAIL \(name)"); failed = true; continue }
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            print("wrote \(dir)/\(name).png")
        }
        return failed ? 1 : 0
    }
}
