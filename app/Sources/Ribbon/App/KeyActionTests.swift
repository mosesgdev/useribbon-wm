import AppKit
import Carbon.HIToolbox

/// Go to window n, first / last place, the width and height nudges, stack right and reordering inside a stack: their hotkeys
/// (defaults free under every modifier preset), their command bar rows, and a round trip of each through the real core.
enum KeyActionTests {
    static func run(_ check: (Bool, String) -> Void) {
        hotkeys(check)
        MainActor.assumeIsolated { bar(check) }
        engine(check)
    }

    /// Action id, key, shift: the actions that follow the preset's modifier.
    private static let presetKeys: [(String, Int, Bool)] = [
        ("move_first", kVK_Home, true), ("move_last", kVK_End, true), ("move_up", kVK_UpArrow, true), ("move_down", kVK_DownArrow, true),
        ("grow_width", kVK_ANSI_W, false), ("shrink_width", kVK_ANSI_W, true), ("grow_height", kVK_ANSI_H, false),
        ("shrink_height", kVK_ANSI_H, true), ("stack_right", kVK_ANSI_G, false),
    ]
    private static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private static func hotkeys(_ check: (Bool, String) -> Void) {
        let byId = Dictionary(Hotkeys.table.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        check(presetKeys.allSatisfy { id, key, shift in byId[id].map { $0.key == key && $0.shift == shift && !$0.allMods && !$0.widthKey && $0.isRecordable } == true },
              "key actions: first / last, reorder, nudges and stack right are on their keys and recordable")
        check((1...9).allSatisfy { n in byId["focus_index#\(n)"].map { $0.key == digits[n - 1] && $0.allMods && $0.isRecordable && $0.title == "Go to window \(n)" } == true },
              "key actions: go to window 1…9 is on the digits, individually recordable (unlike the desktop groups)")
        check(byId["switch_desktop#1"]?.isRecordable == false && byId["move_to_desktop#1"]?.isRecordable == false, "key actions: desktops are still customised as a group")
        MainActor.assumeIsolated {
            let suite = "ribbon.keyactions.\(getpid())"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            let st = ShortcutStore(defaults: d, layout: [:], translate: { _ in nil }, systemKeys: { [] })
            let all4 = controlKey | optionKey | shiftKey | cmdKey
            let mine = (presetKeys.map(\.0) + (1...9).map { "focus_index#\($0)" }).compactMap { byId[$0] }
            for m in ModifierChoice.allCases {
                d.set(m.rawValue, forKey: "modifier"); st.reload()
                // A default that is bound is held by nothing else (the whole table is also checked for duplicates per preset).
                check(mine.allSatisfy { hk in st.effective(hk).map { st.conflict($0, excluding: hk.id) == nil && st.verdict($0, for: hk.id) == .unchanged } ?? true },
                      "key actions: no default collides with another action under \(m.rawValue)")
                let bound = mine.filter { st.effective($0) != nil }.count
                check(bound == (m == .hyper ? presetKeys.count : presetKeys.count + 9), "key actions: \(m.rawValue) binds \(m == .hyper ? "the nine preset keys and no digit" : "all eighteen")")
            }
            d.set(ModifierChoice.ctrlOpt.rawValue, forKey: "modifier"); st.reload()
            check(presetKeys.allSatisfy { id, key, shift in st.effective(byId[id]!) == KeyBinding(keyCode: key, modifiers: controlKey | optionKey | (shift ? shiftKey : 0)) },
                  "key actions: the preset keys are ⌃⌥ (+⇧) by default")
            let three = byId["focus_index#3"]!
            check(st.effective(three) == KeyBinding(keyCode: kVK_ANSI_3, modifiers: all4) && st.keys(for: three) == ["⌃", "⌥", "⇧", "⌘", "3"], "key actions: go to window 3 is ⌃⌥⇧⌘3")
            d.set(ModifierChoice.ctrlCmd.rawValue, forKey: "modifier"); st.reload()
            check(st.effective(three)?.modifiers == all4 && st.effective(byId["grow_width"]!)?.modifiers == controlKey | cmdKey, "key actions: ⌃⌥⇧⌘3 under ⌃⌘ too, the others follow the preset")
            d.set(ModifierChoice.hyper.rawValue, forKey: "modifier"); st.reload()
            check(st.effective(three) == nil && st.keys(for: three).isEmpty, "key actions: go to window has no default under Hyper (its chord sends windows to desktops there)")
            let desk3 = KeyBinding(keyCode: kVK_ANSI_3, modifiers: controlKey | optionKey | cmdKey)   // Hyper's go to desktop 3
            check(st.verdict(desk3, for: "focus_index#3") == .usedBy(id: "switch_desktop#3", title: "Go to desktop 3"), "key actions: recording onto a desktop key asks first")
            let free = KeyBinding(keyCode: kVK_ANSI_8, modifiers: controlKey | cmdKey)
            st.set("focus_index#3", free)
            check(st.effective(three) == free && st.isCustom(three) && st.effective(byId["focus_index#4"]!) == nil, "key actions: a recorded go-to-window combo is stored for that digit only (also under Hyper)")
            st.reset("focus_index#3")
            check(st.effective(three) == nil && !st.isCustom(three), "key actions: reset goes back to no default under Hyper")
        }
    }

    @MainActor private static func bar(_ check: (Bool, String) -> Void) {
        let suite = "ribbon.keyactions.bar.\(getpid())"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: d, layout: [:], translate: { _ in nil }, systemKeys: { [] })
        let ribbonTarget = BarTarget(id: 1, title: "Notes window", app: "Notes", icon: nil, width: 0.5)
        let pinnedTarget = BarTarget(id: 3, title: "Inbox", app: "Buzz", icon: nil, width: 0.25, pinned: true)
        let rows = BarModel.actions(store: store, target: ribbonTarget)
        let byTitle = Dictionary(rows.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = ["Move column to the start", "Move column to the end", "Nudge wider", "Nudge narrower", "Nudge taller", "Nudge shorter",
                      "Stack with the window on the right", "Move window up", "Move window down"]
        check(wanted.allSatisfy { byTitle[$0] != nil }, "command bar: first / last, nudges, stack right and reorder are listed")
        check(byTitle["Nudge wider"]?.keys == ["⌃", "⌥", "W"] && byTitle["Nudge narrower"]?.keys == ["⌃", "⌥", "⇧", "W"]
              && byTitle["Nudge taller"]?.keys == ["⌃", "⌥", "H"] && byTitle["Stack with the window on the right"]?.keys == ["⌃", "⌥", "G"]
              && byTitle["Move column to the end"]?.keys == ["⌃", "⌥", "⇧", "↘"] && byTitle["Move window up"]?.keys == ["⌃", "⌥", "⇧", "↑"],
              "command bar: and show their live shortcuts")
        check(byTitle["Nudge wider"]?.subtitle == "A little more width for Notes · now 50\u{00A0}%" && byTitle["Make wider"]?.subtitle == "Next width for Notes · now 50\u{00A0}%",
              "command bar: a width nudge names the window and its width, and is told apart from the next-width action")
        check(wanted.allSatisfy { byTitle[$0]?.actsOnWindow == true }, "command bar: they act on the window in front")
        check(Set(rows.map(\.title)).count == rows.count, "command bar: titles stay unique")
        let pinned = Set(BarModel.actions(store: store, target: pinnedTarget).map(\.title))
        check(["Move column to the start", "Move column to the end", "Stack with the window on the right"].allSatisfy { !pinned.contains($0) }
              && ["Nudge wider", "Nudge narrower", "Nudge taller", "Nudge shorter", "Move window up", "Move window down"].allSatisfy(pinned.contains),
              "command bar: a pinned window loses the column moves and keeps what works inside the pin")
        let m = BarModel(all: [], target: ribbonTarget)
        func goes(_ q: String, to n: Int?, in model: BarModel) -> Bool {
            model.query = q
            let items = model.valueItems.filter { $0.id == "value:go-window" }
            guard let n else { return items.isEmpty }
            guard items.count == 1, case .commandArg("focus_index", let k) = items[0].action else { return false }
            return k == n && items[0].title == "Go to window \(n)"
        }
        check(goes("window 3", to: 3, in: m) && goes("win 9", to: 9, in: m) && goes("go to 1", to: 1, in: m) && goes("goto 2", to: 2, in: m),
              "command bar: “window 3”, “go to 1” and friends offer Go to window n")
        check(goes("go to window 3", to: 3, in: m) && goes("goto window 4", to: 4, in: m) && goes("go to w 5", to: 5, in: m),
              "command bar: the row's own title, “go to window 3”, offers it too")
        check(goes("window 0", to: nil, in: m) && goes("window 10", to: nil, in: m) && goes("window", to: nil, in: m) && goes("desk 3", to: nil, in: m) && goes("wid 75", to: nil, in: m),
              "command bar: a number outside 1…9, no number, or another verb offers none")
        check(goes("window 4", to: 4, in: BarModel(all: [], target: pinnedTarget)), "command bar: a pinned window can go to a ribbon window too")
    }

    private static func engine(_ check: (Bool, String) -> Void) {
        let e = Engine()
        _ = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1000, height: 800)))
        for id in 1...4 { _ = e.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: 1, app: "A", title: "w\(id)", frame: .zero, floating: false))) }
        let cols = { (p: Plan) in p.map.columns.map { $0.windows.map(\.id) } }
        var p = e.handle(.command("focus_index", arg: 2))
        check(p.focus == 2 && p.map.focusedIndex == 1, "engine: focus_index 2 goes to the second column")
        p = e.handle(.command("move_first"))
        check(cols(p) == [[2], [1], [3], [4]] && p.toast == "Moved to the start" && p.error == nil && p.focus == nil, "engine: move_first carries the column to the start")
        p = e.handle(.command("move_first"))
        check(p.toast == "Already first" && cols(p) == [[2], [1], [3], [4]], "engine: and says so when it is there")
        p = e.handle(.command("move_last"))
        check(cols(p) == [[1], [3], [4], [2]] && p.toast == "Moved to the end" && p.map.focusedIndex == 3, "engine: move_last carries it to the end")
        p = e.handle(.command("grow_width"))
        check(p.toast == "Width 55\u{00A0}%" && abs(p.map.columns[3].widthFrac - 0.55) < 0.001, "engine: grow_width is 5 % of the width")
        p = e.handle(.command("shrink_width"))
        check(p.toast == "Width 50\u{00A0}%" && abs(p.map.columns[3].widthFrac - 0.5) < 0.001, "engine: shrink_width takes it back")
        p = e.handle(.command("stack_right"))
        check(p.toast == "No more windows on the right" && cols(p) == [[1], [3], [4], [2]], "engine: stack right at the last column does nothing")
        _ = e.handle(.command("focus_index", arg: 1))
        p = e.handle(.command("stack_right"))
        check(cols(p) == [[1, 3], [4], [2]] && p.toast == "Stacked", "engine: stack_right joins the column on the right, at its top")
        p = e.handle(.command("move_down"))
        check(cols(p) == [[3, 1], [4], [2]] && p.toast == "Moved down", "engine: move_down reorders inside the stack")
        p = e.handle(.command("grow_height"))
        check(p.toast == "Height 55\u{00A0}%" && p.error == nil, "engine: grow_height steps the window's share")
        check(ToastDiagram.make(toast: p.toast ?? "", map: p.map, focus: p.focus) == .height(0.55), "toast: a height nudge draws its share")
        check(ToastDiagram.make(toast: "Height 66\u{00A0}%", map: p.map, focus: p.focus) == .height(0.66), "toast: a height preset reads by its percent too")
        p = e.handle(.command("shrink_height"))
        check(p.toast == "Height 50\u{00A0}%", "engine: shrink_height takes it back")
        p = e.handle(.command("undo"))
        check(p.toast == "Undid: height", "engine: a nudge is one undo step, labelled")
        // Every new hotkey's command is one the core knows.
        let known = (presetKeys.map(\.0) + ["focus_index"]).allSatisfy { name in
            let fresh = Engine()
            _ = fresh.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1000, height: 800)))
            return fresh.handle(.command(name, arg: 1)).error == nil
        }
        check(known, "engine: the core accepts every new hotkey command")
    }
}
