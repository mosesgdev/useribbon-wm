import AppKit

/// The command bar's ranking when you type a window's name: its window first, the actions named after it ("Make a tab group with
/// Quill", "Move column right · Swap places with Quill") after it, however long the window's title is.
enum BarRankTests {
    static func run(_ check: (Bool, String) -> Void) {
        MainActor.assumeIsolated { rank(check) }
    }

    @MainActor private static func rank(_ check: (Bool, String) -> Void) {
        let suite = "ribbon.barrank.\(getpid())"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: d, layout: [:], translate: { _ in nil }, systemKeys: { [] })
        let target = BarTarget(id: 1, title: "Notes window", app: "Notes", icon: nil, width: 0.5)
        // Rows as the controller builds them: two windows of one app with long titles, and the neighbour rows named after the first.
        func window(_ id: UInt32, _ title: String, column: Int) -> BarItem {
            BarItem(id: "win:\(id)", title: title, subtitle: "Quill · Column \(column)", icon: nil, symbol: "macwindow", action: .focusWindow(id), app: "Quill")
        }
        let neighbour = window(7, "Draft — Chapter notes for the second part of the long book", column: 2)
        let other = window(8, "Outline of every scene in the book, by chapter and by character", column: 4)
        let tab = BarItem(id: "tab-with-right", title: "Make a tab group with Quill", subtitle: "On the right", icon: nil,
                          symbol: "rectangle.topthird.inset.filled", action: .commandArg("tab_with", 1), about: 7)
        let move = BarItem(id: "move-right", title: "Move column right", subtitle: "Swap places with Quill", icon: nil,
                           symbol: "arrow.right.to.line.compact", action: .command("move_right"), about: 7)
        let model = BarModel(all: [neighbour, other] + [tab, move] + BarModel.actions(store: store, target: target), target: target)
        func ask(_ q: String) -> [String] { model.query = q; return model.results.map(\.id) }

        let app = ask("quill")
        check(Array(app.prefix(3)) == ["win:7", "win:8", "tab-with-right"],
              "command bar: an app's name lists its windows first, the tab group named after it next (got \(app.prefix(4)))")
        check(app.contains("move-right") && app.firstIndex(of: "move-right")! > app.firstIndex(of: "win:7")!,
              "command bar: the column swap named after a window stays below it too")
        let title = ask("chapter")
        let named = BarItem(id: "tab-with-right", title: "Make a tab group with Chapter notes", subtitle: "On the right · Quill", icon: nil,
                            symbol: "rectangle.topthird.inset.filled", action: .commandArg("tab_with", 1), about: 7)
        let sameApp = BarModel(all: [named, neighbour, other], target: target)
        sameApp.query = "chapter"
        let byTitle = sameApp.results.map(\.id)
        check(title.first == "win:7" && byTitle.first == "win:7" && byTitle.firstIndex(of: "tab-with-right") == byTitle.firstIndex(of: "win:7")! + 1,
              "command bar: a window's title lists the window first, even when the tab group row is named after that title (got \(byTitle))")
        // With no window matching, the row is ranked on its own words.
        let make = ask("make")
        check(make.contains("tab-with-right") && !make.contains("win:7"), "command bar: the tab group row is still found by its own words")
    }
}
