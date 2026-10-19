import Foundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox

/// FFI round trip with a synthetic display + 3 windows. No AX, no UI. Exit 0 = pass.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  FAIL \(what)"); if !ok { failures += 1 } }
        func summary(_ p: Plan) -> String {
            let f = p.frames.map { "#\($0.id)@\(Int($0.x)),\(Int($0.y)) \(Int($0.w))x\(Int($0.h))\($0.onScreen ? "" : " (off)")" }.joined(separator: " ")
            return "focus=\(p.focus.map(String.init) ?? "-") changed=\(p.changed) map=\(p.map.columns.count) cols [\(f)]"
        }

        let engine = Engine()
        var plan = engine.handle(.display(id: 1, frame: CGRect(x: 0, y: 38, width: 1440, height: 862)))
        for id in 1...3 {
            plan = engine.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: 100, app: "App\(id)", title: "Window \(id)",
                                                            frame: CGRect(x: 50, y: 50, width: 600, height: 500), floating: false)))
            print("add \(id): \(summary(plan))")
        }
        check(plan.error == nil, "no error")
        check(plan.frames.count == 3, "three frames")
        check(plan.focus == 3, "newest window focused")
        check(plan.map.columns.count == 3, "three columns")
        check(plan.showMap, "map shown")
        let before = plan.frames

        plan = engine.handle(.command("focus_left")); print("focus_left: \(summary(plan))")
        check(plan.focus == 2, "focus_left -> window 2")
        plan = engine.handle(.command("cycle_width")); print("cycle_width: \(summary(plan))")
        check(plan.changed.contains(2), "cycle_width changes window 2")
        plan = engine.handle(.command("undo")); print("undo: \(summary(plan))")
        plan = engine.handle(.command("undo")); print("undo: \(summary(plan))")
        check(plan.frames.map(\.id) == before.map(\.id) && zip(plan.frames, before).allSatisfy { $0.x == $1.x && $0.w == $1.w },
              "undo x2 restores the layout")
        plan = engine.handle(.command("focus_index", arg: 1)); print("focus_index 1: \(summary(plan))")
        check(plan.focus == 1, "focus_index 1")
        plan = engine.handle(.windowRemoved(1)); print("remove 1: \(summary(plan))")
        check(plan.frames.count == 2 && plan.focus != nil, "removal keeps a focus")
        plan = engine.handle(.query)
        check(plan.changed.isEmpty, "query changes nothing")
        // A Settings change goes live over the layout: the stack stays, the new gap moves the columns, no undo step.
        plan = engine.handle(.command("focus_window", arg: 3)); plan = engine.handle(.command("stack"))
        let stacked = plan.map.columns.map { $0.windows.map(\.id) }
        var wider = EngineConfig(); wider.gap = 30; wider.outerGap = 30
        plan = engine.setConfig(wider, log: false); print("set_config gap 30: \(summary(plan))")
        check(plan.error == nil && plan.map.columns.map { $0.windows.map(\.id) } == stacked && stacked.contains { $0.count == 2 },
              "set_config keeps the stack")
        check(plan.frames.map(\.x).min() == 30, "set_config: the new outer gap is live")
        plan = engine.handle(.command("undo"))
        check(plan.map.columns.count == stacked.count + 1, "undo after set_config undoes the stack, not the setting")
        // Crash-safe restore: a second run recovers the first run's originals, and a clean quit removes the file.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ribbon-selftest-\(getpid())/originals.json")
        let win = ManagedWindow(id: 9, pid: 100, app: "App", title: "t", frame: CGRect(x: 10, y: 20, width: 600, height: 500), floating: false)
        let moved = ManagedWindow(id: 9, pid: 100, app: "App", title: "t", frame: CGRect(x: 0, y: 0, width: 100, height: 100), floating: false)
        let el = AXUIElementCreateApplication(100)
        MainActor.assumeIsolated {
            let first = Restore(url: tmp)
            first.remember(win, element: el)
            first.flush()
            let second = Restore(url: tmp)
            second.remember(moved, element: el)
            check(second.original(9) == win.frame, "crashed run's originals are recovered")
            second.discardFile()
            check(!FileManager.default.fileExists(atPath: tmp.path), "clean quit deletes originals.json")
            try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
        }
        // Layout-aware letter hotkeys: pure resolution over injected tables (QWERTZ swaps Z and Y).
        let ansi: [Int: String] = [kVK_ANSI_A: "a", kVK_ANSI_S: "s", kVK_ANSI_D: "d", kVK_ANSI_Z: "z", kVK_ANSI_Y: "y", kVK_ANSI_LeftBracket: "["]
        var qwertz = ansi; qwertz[kVK_ANSI_Z] = "y"; qwertz[kVK_ANSI_Y] = "z"; qwertz[kVK_ANSI_LeftBracket] = "ü"
        let mapANSI = KeyLayout.buildMap { ansi[$0] }, mapZ = KeyLayout.buildMap { qwertz[$0] }
        check(KeyLayout.keycode(for: "Z", fallback: -1, map: mapANSI) == kVK_ANSI_Z, "ANSI: Z types on the Z keycode")
        check(KeyLayout.keycode(for: "Z", fallback: -1, map: mapZ) == kVK_ANSI_Y, "QWERTZ: Z is the keycode ANSI calls Y")
        check(KeyLayout.keycode(for: "Y", fallback: -1, map: mapZ) == kVK_ANSI_Z, "QWERTZ: Y is the keycode ANSI calls Z")
        check(KeyLayout.keycode(for: "S", fallback: -1, map: mapZ) == kVK_ANSI_S, "QWERTZ: S unchanged")
        check(KeyLayout.keycode(for: "R", fallback: 77, map: mapZ) == 77, "missing letter falls back to the ANSI keycode")
        check(mapZ["ü"] == nil && mapZ.count == 5, "only a-z letters are mapped")
        let undo = Hotkeys.table.first { $0.action == .command("undo") }!
        check(undo.keycode(in: mapZ) == kVK_ANSI_Y && undo.keycode(in: [:]) == kVK_ANSI_Z, "Hotkey resolves via the layout map")
        let arrow = Hotkeys.table.first { $0.key == kVK_RightArrow }!
        check(arrow.keycode(in: mapZ) == kVK_RightArrow, "arrows stay keycode-based")
        var seen = Set<String>(); var dup = false
        for hk in Hotkeys.table { if !seen.insert("\(hk.key)-\(hk.shift)-\(hk.allMods)-\(hk.widthKey)").inserted { dup = true } }
        check(!dup, "no two hotkeys share a key + shift")
        check(!Hotkeys.table.contains { ["[", "]", "`"].contains($0.keyLabel) }, "no punctuation hotkeys")
        // Recordable shortcuts: pure resolution, conflicts, clearing, reset, storage and labels (injected layout/system keys).
        MainActor.assumeIsolated {
            let suite = "ribbon.selftest.\(getpid())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var kb = ansi; kb[kVK_ANSI_C] = "c"; kb[kVK_ANSI_F] = "f"; kb[kVK_ANSI_K] = "k"; kb[kVK_ANSI_J] = "j"
            let mapKB = KeyLayout.buildMap { kb[$0] }
            let sys = [SystemKey(keyCode: kVK_Space, modifiers: cmdKey)]
            @MainActor func makeStore() -> ShortcutStore {
                ShortcutStore(defaults: defaults, layout: mapKB, translate: { kb[$0] }, systemKeys: { sys })
            }
            let store = makeStore()
            let center = Hotkeys.table.first { $0.id == "center" }!, full = Hotkeys.table.first { $0.id == "toggle_full" }!
            let defCenter = KeyBinding(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey)
            check(center.id == "center" && Hotkeys.table.first { $0.action == .pause }!.id == "pause", "hotkeys have stable action ids")
            check(Set(Hotkeys.table.map(\.id)).count == Hotkeys.table.count, "action ids are unique")
            check(store.effective(center) == defCenter,
                  "no override: default = preset + layout letter")
            let k = KeyBinding(keyCode: kVK_ANSI_J, modifiers: controlKey | optionKey)   // a free key
            store.set("center", k)
            check(store.effective(center) == k && store.isCustom(center), "override wins over the default")
            check(store.effective(full) == store.defaultBinding(full), "other actions keep their default")
            defaults.set(ModifierChoice.hyper.rawValue, forKey: "modifier"); store.reload()
            check(store.effective(center) == k && store.effective(full)?.modifiers == Int(ModifierChoice.hyper.carbon),
                  "changing the preset moves defaults, not custom bindings")
            defaults.removeObject(forKey: "modifier"); store.reload()
            check(KeyBinding(encoded: k.encoded) == k && makeStore().effective(center) == k, "encoding round-trips through UserDefaults")
            let stored = defaults.dictionary(forKey: ShortcutStore.defaultsKey)?["center"] as? [String: Int]
            check(stored?["keyCode"] == kVK_ANSI_J && stored?["modifiers"] == controlKey | optionKey, "stored as {keyCode, modifiers} by action id")
            check(store.conflict(k, excluding: "toggle_full")?.id == "center" && store.conflict(k, excluding: "center") == nil, "conflict names the other action")
            check(store.verdict(KeyBinding(keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey), for: "center") == .usedBy(id: "toggle_full", title: "Full width"),
                  "verdict: used by another action")
            check(store.verdict(k, for: "center") == .unchanged && store.verdict(defCenter, for: "center") == .save, "verdict: unchanged / free")
            check(store.verdict(KeyBinding(keyCode: kVK_Space, modifiers: cmdKey), for: "center") == .system, "verdict: system shortcut")
            store.replace(KeyBinding(keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey), for: "center", taking: "toggle_full")
            check(store.effective(full) == nil && store.effective(center)?.keyCode == kVK_ANSI_F, "replace takes the combo and unbinds the other")
            store.clear("center")
            check(store.effective(center) == nil && store.keys(for: center).isEmpty && store.isCustom(center), "clearing leaves the action unbound")
            check(makeStore().effective(center) == nil, "a cleared binding survives a restart")
            store.reset("center")
            check(store.effective(center) == store.defaultBinding(center) && !store.isCustom(center), "reset restores the default")
            store.set("center", store.defaultBinding(center))
            check(store.overrides["center"] == nil, "recording the default itself stores nothing")
            store.resetAll()
            check(store.overrides.isEmpty && defaults.dictionary(forKey: ShortcutStore.defaultsKey) == nil, "reset all clears every override")
            check(!KeyBinding(keyCode: kVK_ANSI_K, modifiers: 0).isAcceptable && !KeyBinding(keyCode: kVK_ANSI_K, modifiers: shiftKey).isAcceptable
                  && KeyBinding(keyCode: kVK_ANSI_K, modifiers: cmdKey).isAcceptable && KeyBinding(keyCode: kVK_F5, modifiers: 0).isAcceptable,
                  "needs one of ⌃⌥⌘ (F-keys excepted)")
            check(store.verdict(KeyBinding(keyCode: kVK_ANSI_K, modifiers: 0), for: "center") == .needsModifier, "verdict: modifier required")
            let label = { (c: Int) in KeyBinding.keyLabel(c, translate: { qwertz[$0] }) }
            check(store.label(k) == ["⌃", "⌥", "J"], "label: modifiers then key")
            check(label(kVK_ANSI_Y) == "Z" && label(kVK_ANSI_Z) == "Y", "label follows the layout: physical Y key reads Z on QWERTZ")
            check(label(kVK_F5) == "F5" && label(kVK_RightArrow) == "→" && label(kVK_Space) == "Space" && label(999) == "Key 999", "label: F-keys, arrows, fallback")
            check(KeyBinding.glyphs(controlKey | optionKey | shiftKey | cmdKey) == ["⌃", "⌥", "⇧", "⌘"], "modifier glyph order is ⌃⌥⇧⌘")
        }
        // Display moves: ⌃⌥⇧⌘ + arrows under the ⌃⌥ and ⌃⌘ presets, no default under Hyper (it would collide with focus/move).
        MainActor.assumeIsolated {
            let suite = "ribbon.selftest.disp.\(getpid())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let st = ShortcutStore(defaults: defaults, layout: [:], translate: { _ in nil }, systemKeys: { [] })
            let mv = Hotkeys.table.first { $0.id == "move_to_display_right" }!
            let all4 = controlKey | optionKey | shiftKey | cmdKey
            check(st.effective(mv) == KeyBinding(keyCode: kVK_RightArrow, modifiers: all4) && st.keys(for: mv) == ["⌃", "⌥", "⇧", "⌘", "→"], "hotkeys: move to display is ⌃⌥⇧⌘→")
            defaults.set(ModifierChoice.ctrlCmd.rawValue, forKey: "modifier"); st.reload()
            check(st.effective(mv)?.modifiers == all4, "hotkeys: move to display is ⌃⌥⇧⌘→ under ⌃⌘ too")
            defaults.set(ModifierChoice.hyper.rawValue, forKey: "modifier"); st.reload()
            check(st.effective(mv) == nil, "hotkeys: no default under Hyper (collides), command bar only")
            let defaultsAll = Hotkeys.table.compactMap { st.effective($0) }
            check(defaultsAll.count == Set(defaultsAll.map { "\($0.keyCode)-\($0.modifiers)" }).count, "hotkeys: no two defaults collide under Hyper")
            for m in ModifierChoice.allCases {
                defaults.set(m.rawValue, forKey: "modifier"); st.reload()
                let b = Hotkeys.table.compactMap { st.effective($0) }
                check(b.count == Set(b.map { "\($0.keyCode)-\($0.modifiers)" }).count, "hotkeys: no two defaults collide under \(m.rawValue)")
            }
        }
        BarSearchTests.run(check)
        DragTests.run(check)
        DisplayTests.run(check)
        ChainTests.run(check)
        Chain2Tests.run(check)
        FocusTests.run(check)
        ForegroundTests.run(check)
        HUDLogicTests.run(check)
        SwipeTests.run(check)
        ScrollRestTests.run(check)
        OverlayNavTests.run(check)
        OverlayMotionTests.run(check)
        OverlayLayerTests.run(check)
        TabRideTests.run(check)
        SwipeChromeTests.run(check)
        StabilityTests.run(check)
        FloatTests.run(check)
        KeyActionTests.run(check)
        BarRankTests.run(check)
        NativeTabTests.run(check)
        // What the running edition's features bring (Plus: the pin's shortcuts, rows, menus, curtain and toasts).
        for featureTests in FeatureRegistry.shared.selfTests { featureTests(check) }
        EditionTests.run(check)
        check(!Updater.feedConfigured([:]) && !Updater.feedConfigured(["SUFeedURL": "https://example.com/appcast.xml"])
              && !Updater.feedConfigured(["SUFeedURL": "", "SUPublicEDKey": "k"]) && Updater.feedConfigured(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "k"]),
              "updater: runs only when the bundle carries both a feed URL and a public key")
        print(failures == 0 ? "selftest passed" : "selftest FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
