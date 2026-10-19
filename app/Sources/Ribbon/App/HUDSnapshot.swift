import SwiftUI
import AppKit

/// `Ribbon --hud-snapshot <dir>` renders the ribbon map offscreen from fake map data (no windows are touched).
@MainActor
enum HUDSnapshot {
    private static let apps: [(name: String, bundle: String, title: String)] = [
        ("Safari", "com.apple.Safari", "Apple"), ("Terminal", "com.apple.Terminal", "ribbon — zsh"),
        ("Notes", "com.apple.Notes", "Shopping list"), ("Hermes", "com.apple.iCal", "Chat with Claude"),
        ("Mail", "com.apple.mail", "Inbox"), ("Xcode", "com.apple.dt.Xcode", "Ribbon.xcodeproj"),
        ("Messages", "com.apple.MobileSMS", "Mum"), ("Music", "com.apple.Music", "Library"),
        ("Photos", "com.apple.Photos", "Library"), ("Finder", "com.apple.finder", "Downloads"),
        ("Preview", "com.apple.Preview", "scan.pdf"), ("Maps", "com.apple.Maps", "Berlin"),
        ("Reminders", "com.apple.reminders", "Today"), ("Podcasts", "com.apple.podcasts", "Up Next"),
    ]

    /// Column widths cycle through a realistic mix, so the to-scale tiles show.
    private static let mix = [0.5, 0.33, 0.66, 0.5, 1.0, 0.5, 0.4]

    private static func model(columns: [[Int]], focus: Int, visible: ClosedRange<Int>, desktop: Int = 1, used: [Int] = [], hover: UInt32? = nil,
                              drag: HUDDrag? = nil, toast: String? = nil, fracs: [Double]? = nil, tabbed: Set<Int> = [], focusWindow: Int? = nil,
                              hoverDesk: Int? = nil) -> HUDModel {
        let m = HUDModel()
        m.map = RibbonMap(columns: columns.enumerated().map { i, c in
            MapColumn(windows: c.map { MapWindow(id: UInt32($0 + 1), app: apps[$0].name, title: apps[$0].title) },
                      widthFrac: (fracs ?? mix)[i % (fracs ?? mix).count], focused: i == focus, visible: visible.contains(i),
                      tabbed: tabbed.contains(i), active: tabbed.contains(i) ? 0 : nil)
        }, viewport: Viewport(start: 0, end: 0.5), focusedIndex: columns.isEmpty ? nil : focus, desktop: desktop,
        desktops: (1...9).map { DesktopInfo(index: $0, count: used.contains($0) ? 2 : 0, active: $0 == desktop, windows: []) })
        m.focusID = columns.isEmpty ? nil : UInt32((focusWindow ?? columns[focus][0]) + 1)
        m.hoverID = hover; m.drag = drag; m.toast = toast; m.hoverDesk = hoverDesk
        m.visible = true
        m.icon = { wid in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: apps[Int(wid) - 1].bundle) else { return nil }
            // Flatten to a plain bitmap: raw multi-rep app icons wash out the offscreen render.
            let src = NSWorkspace.shared.icon(forFile: url.path)
            let flat = NSImage(size: NSSize(width: 128, height: 128))
            flat.lockFocus()
            src.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero, operation: .sourceOver, fraction: 1)
            flat.unlockFocus()
            return flat
        }
        return m
    }

    static func run(dir: String) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var failed = false
        // Every case at every strip size: "seven-medium-dark.png".
        for size in StripSize.allCases {
            HUDLayout.size = size
            if !render(dir: dir, suffix: size.rawValue) { failed = true }
        }
        HUDLayout.size = .medium
        return failed ? 1 : 0
    }

    private static func render(dir: String, suffix: String) -> Bool {
        let seven = (0..<7).map { [$0] }
        let stacked: [[Int]] = [[0], [1], [2, 8], [3], [4, 5, 9], [6], [7]]
        let cases: [(String, HUDModel)] = [
            ("seven", model(columns: seven, focus: 3, visible: 2...4)),
            ("stack", model(columns: stacked, focus: 3, visible: 2...4)),
            ("stack-focused", model(columns: stacked, focus: 4, visible: 3...5)),
            ("dragging", model(columns: seven, focus: 3, visible: 2...4, drag: HUDDrag(from: 3, dx: (HUDLayout.tileWidth(frac: 0.5) + HUDLayout.gap) * 1.7))),
            ("hover", model(columns: seven, focus: 3, visible: 2...4, hover: 1)),
            ("desktops", model(columns: seven, focus: 3, visible: 2...4, desktop: 2, used: [1, 2, 4])),
            ("few", model(columns: [[0], [1]], focus: 1, visible: 0...1)),
            ("overflow", model(columns: (0..<12).map { [$0] }, focus: 6, visible: 5...7)),
            ("overflow-both", model(columns: (0..<14).map { [$0] }, focus: 7, visible: 6...8, fracs: [0.5])),
            ("tabs", model(columns: [[0], [1, 4, 6], [2], [3]], focus: 1, visible: 0...2, tabbed: [1])),
            ("stack-three", model(columns: [[0], [1, 2, 3], [4]], focus: 1, visible: 0...2, focusWindow: 2)),
            ("stack-deep", model(columns: [[0], [1, 2, 3, 5, 6], [4]], focus: 1, visible: 0...2, focusWindow: 6)),
            ("single", model(columns: [[5]], focus: 0, visible: 0...0, fracs: [1.0])),
            ("empty", model(columns: [], focus: 0, visible: 0...0, desktop: 3, used: [1, 2])),
            ("desktops-four", model(columns: seven, focus: 3, visible: 2...4, desktop: 2, used: [1, 2, 4])),
            ("hover-desk", model(columns: seven, focus: 3, visible: 2...4, desktop: 2, used: [1, 2, 4], hoverDesk: 4)),
        ]
        var failed = false
        for (name, m) in cases {
            for dark in [true, false] {
                let size = CGSize(width: HUDLayout.u(700), height: HUDLayout.pillHeight(hasTiles: true) + 60)
                let r = ImageRenderer(content: SnapshotBackdrop(size: size, dark: dark) {
                    RibbonMapView(model: m).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 24)
                }
                .environment(\.flatGlass, true).environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.disablesAnimations = true })
                r.scale = 2
                let file = "\(name)-\(suffix)-\(dark ? "dark" : "light").png"
                guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { print("FAIL \(file)"); failed = true; continue }
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
                print("wrote \(dir)/\(file)")
            }
        }
        return !failed
    }
}
