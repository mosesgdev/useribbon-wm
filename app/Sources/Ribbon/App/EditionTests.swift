import Foundation
import SwiftUI
import Carbon.HIToolbox

/// The edition check and the feature registry's slots, tried with a feature made for the purpose (the registry the app uses holds
/// whatever the running edition registers). The edition check FAILS when the app and its core are not the same edition.
enum EditionTests {
    /// A feature that fills every slot once.
    private struct DemoFeature: RibbonFeature {
        let id = "demo"
        var hotkeys: [FeatureHotkey] {
            [FeatureHotkey(hotkey: Hotkey(key: kVK_ANSI_Q, shift: false, keyLabel: "Q", action: .command("demo"), title: "Do the demo", group: "Demo group"), after: "center"),
             FeatureHotkey(hotkey: Hotkey(key: kVK_ANSI_Q, shift: true, keyLabel: "Q", action: .command("demo_back"), title: "Undo the demo", group: "Demo group"), after: "demo")]
        }
        var windowCommands: [String] { ["demo", "demo_back"] }
        var barRows: [FeatureBarRow] {
            [FeatureBarRow(title: "Do the demo", symbol: "star", action: .command("demo"), detail: "Demo for %@", keywords: "demo sample", standIn: true, after: "Center")]
        }
        var menuItems: [FeatureMenuItem] { [FeatureMenuItem(title: "Demo", command: "demo", after: "Focus mode")] }
        var settingsTabs: [FeatureSettingsTab] { [FeatureSettingsTab(title: "Demo", subtitle: "Everything about the demo.", view: { AnyView(EmptyView()) })] }
        var settingsRows: [FeatureSettingsRow] { [FeatureSettingsRow(tab: "General", view: { AnyView(EmptyView()) })] }
        var shortcutGroups: [FeatureShortcutGroup] { [FeatureShortcutGroup(name: "Demo group", column: 1)] }
    }

    static func run(_ check: (Bool, String) -> Void) {
        print("edition: app \(Edition.built), core \(Edition.core), running \(Edition.running)")
        check(Edition.matches, "edition: the app (\(Edition.built)) and its core (\(Edition.core)) are the same edition")
        if Edition.running == "free" {
            check(FeatureRegistry.shared.isEmpty && !Hotkeys.table.contains { $0.id.hasPrefix("pin") }, "features: the free edition registers no feature, so no shortcut of one either")
        } else {
            check(FeatureRegistry.shared.features.map(\.id) == ["pin"] && Hotkeys.table.contains { $0.id == "pin" }, "features: the plus edition registers the pin and its shortcuts")
        }

        let none = FeatureRegistry(features: []), demo = FeatureRegistry(features: [DemoFeature()])
        let base = Hotkeys.table
        // Hotkeys: after the row they name, in the order given; none registered, none added.
        let ids = demo.hotkeys(merging: base).map(\.id)
        let at = ids.firstIndex(of: "center")
        check(none.hotkeys(merging: base).map(\.id) == base.map(\.id) && at != nil && ids[(at ?? 0) + 1] == "demo" && ids[(at ?? 0) + 2] == "demo_back"
              && ids.count == base.count + 2, "features: a shortcut goes right after the row it names, and an empty registry adds none")
        check(Set(demo.hotkeys(merging: []).map(\.id)) == ["demo", "demo_back"], "features: a shortcut with nothing to follow goes at the end")
        check(demo.windowCommands == ["demo", "demo_back"] && none.windowCommands.isEmpty, "features: window commands come from the registry")
        // Command bar rows.
        let defaults = UserDefaults(suiteName: "ribbon.selftest.edition.\(getpid())")!
        defer { defaults.removePersistentDomain(forName: "ribbon.selftest.edition.\(getpid())") }
        MainActor.assumeIsolated {
            let store = ShortcutStore(defaults: defaults, layout: [:], translate: { _ in nil }, systemKeys: { [] })
            let bare = BarModel.actions(store: store, target: nil, registry: demo)
            let row = bare.first { $0.title == "Do the demo" }
            let titles = bare.map(\.title)
            check(row?.subtitle == "Demo for the window" && row?.keywords == "demo sample" && titles.firstIndex(of: "Do the demo") == titles.firstIndex(of: "Center").map { $0 + 1 },
                  "features: a command bar row goes after the row it names, with its detail and keywords")
            let target = BarTarget(id: 1, title: "Notes window", app: "Notes", icon: nil, width: 0.5)
            check(!BarModel.actions(store: store, target: target, registry: demo).contains { $0.title == "Do the demo" }
                  && !BarModel.actions(store: store, target: nil, registry: none).contains { $0.title == "Do the demo" },
                  "features: a stand-in row shows only when the bar names no window, and an empty registry adds none")
        }
        // Menu bar items.
        let menu = ["Desktop 1", "", "Show my windows", "Shortcuts", "Focus mode", "", "Pause for now"]
        check(demo.menuItems.first?.index(in: menu) == 5 && FeatureMenuItem(title: "Last", command: "x").index(in: menu) == menu.count
              && FeatureMenuItem(title: "Unknown place", command: "x", after: "Nowhere").index(in: menu) == menu.count && none.menuItems.isEmpty,
              "features: a menu item goes after the item it names, else at the end")
        // Settings.
        check(SettingsTab.all(none) == SettingsTab.builtIn && SettingsTab.all(demo).map(\.id) == ["General", "Layout", "Input", "Apps", "Demo"]
              && SettingsTab(id: "Demo").subtitle(demo) == "Everything about the demo." && SettingsTab.general.subtitle(demo) == SettingsTab.general.subtitle(none),
              "features: a settings tab joins the built-in ones with its own subtitle")
        check(demo.settingsRows(in: "General").count == 1 && demo.settingsRows(in: "Layout").isEmpty && none.settingsRows(in: "General").isEmpty,
              "features: a settings control goes into the tab it names")
        // Shortcuts sheet.
        check(demo.shortcutGroups(inColumn: 1) == ["Demo group"] && demo.shortcutGroups(inColumn: 0).isEmpty && none.shortcutGroups(inColumn: 1).isEmpty,
              "features: a shortcuts sheet group goes in its column")
        // Saved shortcuts of actions this edition does not have (a Plus build wrote them): no row, no count, nothing lost.
        MainActor.assumeIsolated {
            let suite = "ribbon.selftest.edition.keys.\(getpid())"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            let k1 = KeyBinding(keyCode: kVK_ANSI_J, modifiers: controlKey | optionKey), k2 = KeyBinding(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey)
            d.set(["center": k1.encoded, "gone_feature": k2.encoded], forKey: ShortcutStore.defaultsKey)
            let store = ShortcutStore(defaults: d, layout: [:], translate: { _ in nil }, systemKeys: { [] })
            check(store.overrides.keys.sorted() == ["center"], "features: a saved shortcut of an action this edition lacks is not a row")
            store.reset("center")
            check(d.dictionary(forKey: ShortcutStore.defaultsKey)?.keys.sorted() == ["gone_feature"], "features: and it stays in the saved file when others change")
            store.resetAll()
            check(store.overrides.isEmpty && d.dictionary(forKey: ShortcutStore.defaultsKey)?.keys.sorted() == ["gone_feature"],
                  "features: reset to defaults does not count it, and keeps it for the edition that has the action")
        }
    }
}
