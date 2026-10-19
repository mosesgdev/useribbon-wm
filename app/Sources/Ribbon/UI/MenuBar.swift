import AppKit

@MainActor
final class MenuBar: NSObject {
    var onTogglePause: () -> Void = {}
    var onShowMap: () -> Void = {}
    var onShortcuts: () -> Void = {}
    var onToggleFocus: () -> Void = {}
    var onSettings: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var onQuit: () -> Void = {}
    var onConflict: () -> Void = {}
    /// A menu item a feature added was chosen: the engine command it names.
    var onFeatureCommand: (String) -> Void = { _ in }
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let pauseItem = NSMenuItem()
    private let focusItem = NSMenuItem(title: "Focus mode", action: nil, keyEquivalent: "")
    private let desktopItem = NSMenuItem()
    private let conflictItem = NSMenuItem()
    private let clashItem = NSMenuItem()
    /// Hidden until the updater runs: dev builds have none.
    private let updatesItem = NSMenuItem(title: MenuBar.checkTitle, action: nil, keyEquivalent: "")
    private static let checkTitle = "Check for Updates…"
    private let menu = NSMenu()
    private var desktop = 1
    private var updatePending = false

    override init() {
        super.init()
        let glyph = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Ribbon")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        glyph?.isTemplate = true   // follows the menu bar's light/dark tint
        item.button?.image = glyph
        item.button?.imagePosition = .imageLeading
        setDesktop(1)
        // Three short groups: look around, tune, leave. The first line names the number beside the glyph.
        desktopItem.isEnabled = false
        menu.addItem(desktopItem)
        menu.addItem(.separator())
        for (title, sel, key) in [("Show my windows", #selector(showMap), ""), ("Shortcuts", #selector(shortcuts), "")] {
            let m = NSMenuItem(title: title, action: sel, keyEquivalent: key); m.target = self; menu.addItem(m)
        }
        focusItem.target = self; focusItem.action = #selector(focus)
        menu.addItem(focusItem)
        addFeatureItems(FeatureRegistry.shared.menuItems)
        menu.addItem(.separator())
        pauseItem.target = self; pauseItem.action = #selector(pause)
        menu.addItem(pauseItem)
        let s = NSMenuItem(title: "Settings…", action: #selector(settings), keyEquivalent: ","); s.target = self; menu.addItem(s)
        updatesItem.target = self; updatesItem.action = #selector(checkForUpdates); updatesItem.isHidden = true
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit Ribbon", action: #selector(quit), keyEquivalent: "q"); q.target = self; menu.addItem(q)
        item.menu = menu
        setPaused(false)
    }

    /// What the running edition's features add: each item goes after the item it names (by title), else at the end of the menu so far.
    func addFeatureItems(_ items: [FeatureMenuItem]) {
        for it in items {
            let m = NSMenuItem(title: it.title, action: #selector(featureItem(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = it.command
            if let symbol = it.symbol { m.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.insertItem(m, at: it.index(in: menu.items.map(\.title)))
        }
    }

    /// The active desktop number sits next to the glyph, always, so you know where you are at a glance.
    func setDesktop(_ n: Int) {
        desktop = n
        item.button?.attributedTitle = NSAttributedString(
            string: " \(n)" + (updatePending ? " •" : ""), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        item.button?.setAccessibilityLabel("Ribbon, desktop \(n)")
        item.button?.toolTip = "Ribbon · Desktop \(n)"
        desktopItem.title = "Desktop \(n)"
    }

    func setUpdatesAvailable(_ on: Bool) { updatesItem.isHidden = !on }

    /// A scheduled check found an update: the line says so, and a dot follows the desktop number, until it is looked at.
    func setUpdatePending(_ on: Bool) {
        updatePending = on
        updatesItem.title = on ? "Update available…" : MenuBar.checkTitle
        setDesktop(desktop)
    }

    /// Focus mode is blurring the other windows (checkmark). `keys` = its shortcut, shown in the item's tooltip.
    func setFocusMode(_ on: Bool, keys: String?) {
        focusItem.state = on ? .on : .off
        focusItem.toolTip = keys.map { "Blur everything but this window (\($0))" } ?? "Blur everything but this window"
    }

    func setPaused(_ paused: Bool) {
        pauseItem.title = paused ? "Resume Ribbon" : "Pause for now"
        item.button?.alphaValue = paused ? 0.5 : 1
    }

    /// Shows a disabled notice at the top of the menu when some shortcuts could not be registered.
    func setShortcutConflicts(_ keys: [String]) {
        if conflictItem.menu != nil { menu.removeItem(conflictItem) }
        guard !keys.isEmpty else { return }
        conflictItem.title = "Another app uses some of these keys: " + keys.joined(separator: " ")
        conflictItem.isEnabled = false
        menu.insertItem(conflictItem, at: 0)
    }

    /// A conflicting app or Stage Manager is around: a menu line that brings the card back. nil removes it.
    func setClash(_ title: String?) {
        if clashItem.menu != nil { menu.removeItem(clashItem) }
        guard let title else { return }
        clashItem.title = title + "…"
        clashItem.target = self; clashItem.action = #selector(clash)
        menu.insertItem(clashItem, at: 0)
    }

    @objc private func clash() { onConflict() }
    @objc private func focus() { onToggleFocus() }
    @objc private func pause() { onTogglePause() }
    @objc private func showMap() { onShowMap() }
    @objc private func shortcuts() { onShortcuts() }
    @objc private func settings() { onSettings() }
    @objc private func checkForUpdates() { onCheckForUpdates() }
    @objc private func quit() { onQuit() }
    @objc private func featureItem(_ item: NSMenuItem) { if let command = item.representedObject as? String { onFeatureCommand(command) } }
}
