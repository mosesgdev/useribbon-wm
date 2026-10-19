import Foundation
import CoreGraphics

/// The command bar's search and its rows for a window of the ribbon: what stays true whichever edition runs.
enum BarSearchTests {
    static func run(_ check: (Bool, String) -> Void) {
        MainActor.assumeIsolated {
            let suite = "ribbon.selftest.barsearch.\(getpid())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ShortcutStore(defaults: defaults, layout: [:], translate: { _ in nil }, systemKeys: { [] })
            let ribbonTarget = BarTarget(id: 1, title: "Notes window", app: "Notes", icon: nil, width: 0.5)
            check(fuzzyScore("wider", "Make wider") == 24 && fuzzyScore("w", "Make wider") == 0 && fuzzyScore("mw", "Make wider") == nil,
                  "pin search: scores of matches the bar already found are unchanged")
            let ribbonOnly = BarModel(all: [], target: ribbonTarget)
            ribbonOnly.query = "wid 75"
            check(ribbonOnly.valueItems.count == 1, "pin bar: a ribbon window still gets “wid 75”")
            let ribbonActs = BarModel.actions(store: store, target: ribbonTarget).map(\.title)
            check(["Full width", "Center", "Stack with the window on the left", "Take out of stack"].allSatisfy(ribbonActs.contains), "pin bar: a ribbon window keeps every ribbon row")
        }
    }
}
