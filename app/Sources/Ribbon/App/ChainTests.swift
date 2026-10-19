import Foundation
import Carbon.HIToolbox

/// Pure-logic self tests: conflict detection, session matching and storage, float rules, new hotkeys, engine round trips.
enum ChainTests {
    static func run(_ check: (Bool, String) -> Void) {
        conflicts(check)
        floatRules(check)
        sessionMatching(check)
        sessionFile(check)
        sessionPin(check)
        hotkeys(check)
        engineRoundTrips(check)
    }

    private static func conflicts(_ check: (Bool, String) -> Void) {
        func detect(_ r: [RunningThing], sm: Bool = false, dismissed: Set<String> = []) -> [String] {
            ConflictCheck.detect(running: r, stageManagerOn: sm, dismissed: dismissed).map(\.key)
        }
        let rect = RunningThing(bundleID: "com.knollsoft.Rectangle", name: "Rectangle", pid: 5)
        check(detect([]).isEmpty, "conflicts: nothing running, nothing reported")
        check(detect([rect, RunningThing(bundleID: "com.apple.finder", name: "Finder")]) == ["rectangle"], "conflicts: Rectangle found by bundle id")
        check(detect([RunningThing(bundleID: "com.knollsoft.rectangle", name: "x")]) == ["rectangle"], "conflicts: bundle ids match case-insensitively")
        check(detect([RunningThing(bundleID: "com.example.Loop", name: "Loop")]).isEmpty, "conflicts: an unrelated app named Loop is not a conflict")
        check(detect([RunningThing(bundleID: nil, name: "yabai", pid: 9)]) == ["yabai"], "conflicts: a bare daemon matches by process name")
        check(detect([RunningThing(bundleID: "com.MrKai77.Loop", name: "Loop"), RunningThing(bundleID: "com.barut.OmniWM", name: "OmniWM"),
                      RunningThing(bundleID: "com.manytricks.Moom", name: "Moom")]) == ["moom", "omniwm", "loop"], "conflicts: several at once, in catalog order")
        check(detect([rect], dismissed: ["rectangle"]).isEmpty, "conflicts: Keep both is remembered per app")
        check(detect([rect, RunningThing(bundleID: "com.manytricks.Moom", name: "Moom")], dismissed: ["rectangle"]) == ["moom"], "conflicts: a dismissal does not hide other apps")
        check(detect([], sm: true) == ["stage-manager"] && detect([], sm: true, dismissed: ["stage-manager"]).isEmpty, "conflicts: Stage Manager, dismissable")
        check(detect([rect], sm: true) == ["rectangle", "stage-manager"], "conflicts: Stage Manager listed after apps")
        let want = ["Rectangle", "Magnet", "Moom", "BetterSnapTool", "Amethyst", "yabai", "AeroSpace", "OmniWM", "ChainYourMac", "Loop", "Divvy", "Spectacle"]
        check(ConflictCheck.catalog.map(\.name) == want, "conflicts: the catalog names all twelve tools")
        check(Set(ConflictCheck.catalog.map(\.key)).count == ConflictCheck.catalog.count, "conflicts: catalog keys are unique")
        let extra = ConflictCheck.extra("FakeTiler=Fake Tiler,com.example.x")
        check(ConflictCheck.detect(running: [RunningThing(bundleID: nil, name: "FakeTiler", pid: 3)], stageManagerOn: false, dismissed: [],
                                   catalog: extra).map(\.name) == ["Fake Tiler"], "conflicts: debug entries match by process name")
        check(extra.last?.bundleIDs == ["com.example.x"], "conflicts: debug entries with a dot are bundle ids")
        check(ConflictCopy.title(Conflict(kind: .app, key: "rectangle", name: "Rectangle")) == "Rectangle is also moving your windows", "conflicts: card names the app")
        // "Keep both" is remembered: stored under the conflict's own key, read back by a fresh monitor, and the conflict stays away.
        MainActor.assumeIsolated {
            let suite = "ribbon.selftest.conflicts.\(getpid())"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            let extra = ConflictCheck.extra("RibbonDummy=Fake Tiler")
            d.set(["debug:FakeTiler"], forKey: ConflictMonitor.dismissedKey)
            let first = ConflictMonitor(defaults: d)
            let c = ConflictCheck.detect(running: [RunningThing(bundleID: nil, name: "RibbonDummy", pid: 3)], stageManagerOn: false,
                                         dismissed: first.dismissed, catalog: extra).first
            check(c?.key == "debug:RibbonDummy", "conflicts: the card's conflict carries the debug key")
            if let c { first.keep(c) }
            let second = ConflictMonitor(defaults: d)   // a restart
            check(second.dismissed == ["debug:FakeTiler", "debug:RibbonDummy"], "conflicts: keep both is stored next to earlier choices")
            check(ConflictCheck.detect(running: [RunningThing(bundleID: nil, name: "RibbonDummy", pid: 3)], stageManagerOn: false,
                                       dismissed: second.dismissed, catalog: extra).isEmpty, "conflicts: a kept conflict stays dismissed after restart")
            let sm = Conflict(kind: .stageManager, key: ConflictCheck.stageManagerKey, name: "Stage Manager")
            second.keep(sm)
            check(ConflictMonitor(defaults: d).dismissed.contains(ConflictCheck.stageManagerKey), "conflicts: keep it on (Stage Manager) is stored too")
            // The card's buttons answer the first click: the card is never key before it.
            let host = SheetHostingView(rootView: ConflictCardView(conflict: sm))
            check(host.acceptsFirstMouse(for: nil), "conflicts: the card takes the first click")
        }
        // Keeping the keyboard: the bar and the recording sheet only let go when the user really left.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func left(click: Double = 99, sw: Double = 99) -> Bool {
            KeyKeeper.userLeft(now: t0, lastOutsideClick: t0.addingTimeInterval(-click), lastAppSwitch: t0.addingTimeInterval(-sw))
        }
        check(!left(), "keykeeper: a banner taking key (no click, no switch) is not leaving")
        check(left(click: 0.4), "keykeeper: a click elsewhere just now is leaving")
        check(left(sw: 0.3), "keykeeper: ⌘Tab / Dock to another app just now is leaving")
        check(!left(click: 1.5, sw: 2), "keykeeper: an old click or switch is not the cause")
        check(KeyKeeper.isTransient(bundleID: "com.apple.notificationcenterui", regular: true, isSelf: false), "keykeeper: Notification Center is transient")
        check(KeyKeeper.isTransient(bundleID: "com.apple.screensharing.agent", regular: false, isSelf: false), "keykeeper: the screen sharing banner is transient")
        check(KeyKeeper.isTransient(bundleID: "com.example.helper", regular: false, isSelf: false), "keykeeper: an accessory helper is transient")
        check(KeyKeeper.isTransient(bundleID: nil, regular: true, isSelf: true), "keykeeper: Ribbon itself is not a switch")
        check(!KeyKeeper.isTransient(bundleID: "com.apple.Safari", regular: true, isSelf: false), "keykeeper: a regular app is a real switch")
        // A toast stays up long enough to read, and a strip shown again without one does not wipe it.
        var clock = ToastClock()
        check(clock.resolve(new: "First window", current: nil, now: t0, lingerMs: 1800) == "First window" && clock.remainingMs(now: t0) == 1800, "toast: a new toast starts its clock")
        check(clock.resolve(new: nil, current: "First window", now: t0.addingTimeInterval(0.5), lingerMs: 1800) == "First window", "toast: a refresh without one keeps it")
        check(clock.remainingMs(now: t0.addingTimeInterval(1.0)) == 800, "toast: a key release waits out the rest")
        check(clock.resolve(new: nil, current: "First window", now: t0.addingTimeInterval(2.0), lingerMs: 1800) == nil && clock.remainingMs(now: t0.addingTimeInterval(2.0)) == 0,
              "toast: gone after its time")
        // The shortcuts sheet scrolls from the keyboard: arrows, Page, Home/End, and never a modified key.
        check(SheetKeys.key(code: 121, modifiers: []) != nil && SheetKeys.key(code: 125, modifiers: []) != nil && SheetKeys.key(code: 119, modifiers: []) != nil, "sheet: scroll keys are recognised")
        check(SheetKeys.key(code: 125, modifiers: [.command]) == nil && SheetKeys.key(code: 0, modifiers: []) == nil, "sheet: modified keys and letters are not scroll keys")
    }

    private static func floatRules(_ check: (Bool, String) -> Void) {
        let rules = FloatRules.defaults
        check(FloatRules.matches(bundleID: "com.apple.calculator", app: "Calculator", rules: rules), "float: Calculator floats by default")
        check(FloatRules.matches(bundleID: "COM.APPLE.CALCULATOR", app: "x", rules: rules), "float: bundle id match ignores case")
        check(!FloatRules.matches(bundleID: "com.apple.Safari", app: "Safari", rules: rules), "float: other apps tile")
        check(FloatRules.matches(bundleID: nil, app: "Tool", rules: [FloatRule(id: "Tool", name: "Tool")]), "float: no bundle id falls back to the app name")
        check(!FloatRules.matches(bundleID: "com.apple.Safari", app: "Calculator", rules: rules), "float: a bundle id wins over the name")
        let added = FloatRules.adding(FloatRule(id: "com.x.y", name: "Y"), to: rules)
        check(added.count == rules.count + 1 && FloatRules.adding(FloatRule(id: "COM.X.Y", name: "Y"), to: added) == added, "float: adding is idempotent")
        check(FloatRules.removing(id: "com.x.y", from: added) == rules, "float: removing restores the list")
        check(FloatRules.defaults.count <= 4, "float: the built-in list stays small")
        let suite = "ribbon.selftest.float.\(getpid())"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        check(FloatRules.load(d) == FloatRules.defaults, "float: defaults until the user edits")
        FloatRules.save([], d)
        check(FloatRules.load(d).isEmpty, "float: an emptied list stays empty")
        FloatRules.save(added, d)
        check(FloatRules.load(d) == added, "float: the list round-trips through UserDefaults")
    }

    private static func win(_ id: UInt32, _ pid: Int32, _ key: String, _ title: String) -> SessionWindow { SessionWindow(id: id, pid: pid, key: key, title: title) }
    private static func live(_ id: UInt32, _ pid: Int32, _ key: String, _ title: String) -> LiveWindow { LiveWindow(id: id, pid: pid, key: key, title: title) }

    private static func sessionMatching(_ check: (Bool, String) -> Void) {
        let saved = [win(1, 10, "app.a", "One"), win(2, 10, "app.a", "Two"), win(3, 20, "app.b", "Three")]
        // an app that kept running keeps pid and ids
        check(SessionMatcher.match(saved: saved, live: [live(3, 20, "app.b", "x"), live(2, 10, "app.a", "y"), live(1, 10, "app.a", "z")]) == [1: 1, 2: 2, 3: 3],
              "session: same pid and window id match first, whatever the titles")
        // app restarted: new pid and ids, titles identical but discovered in another order
        check(SessionMatcher.match(saved: saved, live: [live(40, 55, "app.b", "Three"), live(31, 50, "app.a", "Two"), live(30, 50, "app.a", "One")]) == [1: 30, 2: 31, 3: 40],
              "session: restarted app matches by app key and exact title")
        // titles changed: falls back to order within the app
        check(SessionMatcher.match(saved: saved, live: [live(31, 50, "app.a", "Inbox"), live(30, 50, "app.a", "Draft"), live(40, 55, "app.b", "Doc")]) == [1: 31, 2: 30, 3: 40],
              "session: no title match falls back to the app's order")
        // pid reuse after a reboot must not match another app's window
        check(SessionMatcher.match(saved: [win(1, 10, "app.a", "One")], live: [live(1, 10, "app.z", "One")]).isEmpty, "session: same pid and id but another app is no match")
        // a live window is used once; extra saved windows stay unmatched
        let two = SessionMatcher.match(saved: saved, live: [live(30, 50, "app.a", "One")])
        check(two == [1: 30], "session: each live window is matched once, the rest stay unmatched")
        // mix: id match is not stolen by a title match
        check(SessionMatcher.match(saved: [win(1, 10, "a", "T"), win(2, 10, "a", "T")], live: [live(2, 10, "a", "T"), live(9, 11, "a", "T")]) == [2: 2, 1: 9],
              "session: exact id matches are settled before title matches")
        check(SessionMatcher.match(saved: [], live: [live(1, 1, "a", "t")]).isEmpty, "session: empty session matches nothing")
    }

    /// The pinned column is saved with its windows' identities and comes back re-keyed, per display.
    private static func sessionPin(_ check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pin = CorePin(windows: [5, 6], heights: nil, tabbed: true, active: 1, side: .right, fraction: 0.25, desktop: 1, everyDesktop: true,
                          home: 2, homeDesktop: 1, width: CoreWidth(kind: "frac", value: 0.5), suspended: false, need: 0)
        let core = CoreSession(active: 1, desktops: [CoreDesk(index: 1, columns: [CoreColumn(windows: [1], width: CoreWidth(kind: "frac", value: 0.5), heights: nil)],
                                                              floating: [], focus: 6, scroll: 0)], pin: pin)
        let names: [UInt32: String] = [1: "Safari", 5: "Buzz", 6: "WhatsApp"]
        let file = SessionFile.make(from: core, identify: { id in names[id].map { SessionWindow(id: id, pid: 7, key: "app.\($0)", title: $0) } }, now: now)
        check(file.pin?.windows.map(\.title) == ["Buzz", "WhatsApp"] && file.pin?.side == .right && file.pin?.tabbed == true, "session pin: saved with its windows, side and tabs")
        check(file.windowsInOrder.first?.title == "Buzz", "session pin: its windows are matched first")
        let all = [live(201, 70, "app.Safari", "Safari"), live(205, 70, "app.Buzz", "Buzz"), live(206, 70, "app.WhatsApp", "WhatsApp")]
        let r = file.restoreEvent(live: all)
        check(r?.session.pin?.windows == [205, 206] && r?.session.pin?.active == 1 && r?.session.pin?.home == 2, "session pin: re-keyed to live ids with its home slot")
        check(r?.session.desktops[0].focus == 206, "session pin: a pinned focus is re-keyed too")
        let half = file.restoreEvent(live: [all[0], all[1]])
        check(half?.session.pin?.windows == [205] && half?.session.pin?.tabbed == nil, "session pin: a group missing a window keeps the rest, without its tabs")
        check(file.restoreEvent(live: [all[0]])?.session.pin == nil, "session pin: no window of it back, no pin")
        let data = try? JSONEncoder().encode(file)
        check(data.flatMap { try? JSONDecoder().decode(SessionFile.self, from: $0) } == file, "session pin: survives a JSON round trip")
        // Per display: the pin travels with its display's slice.
        let other = SessionFile(savedAt: now, active: 1, desks: [])
        let both = SessionFile.combine([("A", file), ("B", other)], primary: "B", now: now)
        check(both?.pin == nil && both?.slice(for: "A", primary: "B")?.pin == file.pin && both?.slice(for: "B", primary: "B")?.pin == nil,
              "session pin: each display keeps its own pin")
        let legacy = #"{"version":1,"savedAt":0,"active":1,"desks":[]}"#
        check((try? JSONDecoder().decode(SessionFile.self, from: Data(legacy.utf8)))?.pin == nil, "session pin: older files load without one")
    }

    private static func sessionFile(_ check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let core = CoreSession(active: 2, desktops: [
            CoreDesk(index: 1, columns: [CoreColumn(windows: [1, 2], width: CoreWidth(kind: "frac", value: 0.5), heights: [0.3, 0.7]),
                                         CoreColumn(windows: [3], width: CoreWidth(kind: "px", value: 640), heights: nil)], floating: [9], focus: 2, scroll: 40),
            CoreDesk(index: 2, columns: [], floating: [], focus: nil, scroll: 0),
            CoreDesk(index: 3, columns: [CoreColumn(windows: [4], width: CoreWidth(kind: "frac", value: 1), heights: nil)], floating: [], focus: 4, scroll: 0)])
        let names: [UInt32: String] = [1: "A", 2: "B", 3: "C", 4: "D", 9: "F"]
        let file = SessionFile.make(from: core, identify: { id in names[id].map { SessionWindow(id: id, pid: 7, key: "app.\($0)", title: $0) } }, now: now)
        check(file.desks.map(\.index) == [1, 3] && file.active == 2, "session: empty desktops are not saved")
        check(file.desks[0].columns[0].heights == [0.3, 0.7] && file.desks[0].focus == 2, "session: heights, focus and scroll are kept")
        // restoring after everything got new ids (apps restarted)
        let liveWins = [live(101, 70, "app.A", "A"), live(102, 70, "app.B", "B"), live(103, 70, "app.C", "C"), live(104, 70, "app.D", "D"), live(109, 70, "app.F", "F")]
        let r = file.restoreEvent(live: liveWins)
        check(r?.matched == 5, "session: every window is matched back")
        check(r?.session.desktops[0].columns.map(\.windows) == [[101, 102], [103]] && r?.session.desktops[0].focus == 102, "session: columns and focus are re-keyed to live ids")
        check(r?.session.desktops[0].floating == [109] && r?.session.desktops[1].columns.first?.windows == [104], "session: floating windows and later desktops survive")
        // a stack that lost a window drops its heights, a column with no match disappears
        let partial = file.restoreEvent(live: [live(101, 70, "app.A", "A"), live(103, 70, "app.C", "C")])
        check(partial?.session.desktops[0].columns.map(\.windows) == [[101], [103]] && partial?.session.desktops[0].columns[0].heights == nil, "session: partial stacks drop their heights")
        check(partial?.session.desktops[0].focus == nil && partial?.session.desktops[1].columns.isEmpty == true, "session: unmatched focus and columns are left out")
        check(file.restoreEvent(live: []) == nil, "session: nothing to match means no restore event")
        // freshness
        check(file.isFresh(now: now.addingTimeInterval(23 * 3600)), "session: still fresh after 23 hours")
        check(!file.isFresh(now: now.addingTimeInterval(24 * 3600 + 1)), "session: expires after 24 hours")
        var old = file; old.version = 99
        check(!old.isFresh(now: now), "session: other versions are ignored")
        // disk round trip, change detection and expiry on load
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ribbon-session-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        MainActor.assumeIsolated {
            let store = SessionStore(url: url, delay: 0.01)
            var current: SessionFile? = file
            store.provider = { current }
            store.flush()
            let first = try? Data(contentsOf: url)
            check(first != nil, "session: flush writes session.json (creating the folder)")
            check(SessionStore(url: url).load(now: now.addingTimeInterval(60)) == file, "session: the file loads back identical")
            check(SessionStore(url: url).load(now: now.addingTimeInterval(25 * 3600)) == nil, "session: a day-old file is not loaded")
            current?.savedAt = now.addingTimeInterval(500)
            try? FileManager.default.removeItem(at: url)
            store.flush()
            check(!FileManager.default.fileExists(atPath: url.path), "session: an unchanged layout is not rewritten")
            current?.active = 1
            store.flush()
            check(FileManager.default.fileExists(atPath: url.path), "session: a changed layout is written")
            current = nil
            try? FileManager.default.removeItem(at: url)
            store.flush()
            check(!FileManager.default.fileExists(atPath: url.path), "session: nothing to save writes nothing")
            let off = SessionStore(url: nil, delay: 0.01)
            off.provider = { file }
            off.flush()
            check(off.load(now: now) == nil, "session: with no file (QA mode) nothing is loaded or written")
            try? Data("garbage".utf8).write(to: url)
            check(SessionStore(url: url).load(now: now) == nil, "session: a corrupt file is ignored")
        }
    }

    private static func hotkeys(_ check: (Bool, String) -> Void) {
        for (id, key, shift) in [("focus_first", kVK_Home, false), ("focus_last", kVK_End, false), ("equalize_heights", kVK_ANSI_E, false)] {
            let hk = Hotkeys.table.first { $0.id == id }
            check(hk?.key == key && hk?.shift == shift && hk?.isRecordable == true, "hotkeys: \(id) is in the recordable table")
        }
        check(!Hotkeys.table.contains { $0.key == kVK_ANSI_E && $0.id != "equalize_heights" }, "hotkeys: E is used once")
        let titles = MainActor.assumeIsolated {
            Set(BarModel.actions(store: ShortcutStore(defaults: UserDefaults(suiteName: "ribbon.selftest.bar")!)).map(\.title))
        }
        check(["Go to first window", "Go to last window", "Make heights equal"].allSatisfy(titles.contains), "command bar: first, last and equalize actions exist")
    }

    private static func engineRoundTrips(_ check: (Bool, String) -> Void) {
        let e = Engine(config: EngineConfig(scroll: "center_on_overflow"))
        _ = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        for id in 1...4 {
            _ = e.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: 1, app: "A", title: "w\(id)", frame: .zero, floating: id == 4)))
        }
        _ = e.handle(.command("focus_first"))
        var p = e.handle(.command("focus_last"))
        check(p.focus == 3 && p.toast == "Last window", "engine: focus_last moves to the last tiled column and toasts")
        p = e.handle(.command("focus_first"))
        check(p.focus == 1 && p.toast == "First window", "engine: focus_first moves home")
        p = e.handle(.command("focus_first"))
        check(p.toast == "No more windows on the left", "engine: no move, the end-of-ribbon toast")
        _ = e.handle(.command("focus_last")); _ = e.handle(.command("stack"))
        p = e.handle(.command("equalize_heights"))
        check(p.toast == "Already even", "engine: equalize on an even stack changes nothing")
        let snap = e.handle(.snapshot, log: false).session
        check(snap?.desktops.first?.floating == [4] && snap?.desktops.first?.columns.count == 2, "engine: snapshot decodes through the FFI")
        let fresh = Engine()
        _ = fresh.handle(.display(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        for id in 1...4 { _ = fresh.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: 1, app: "A", title: "w\(id)", frame: .zero, floating: false))) }
        _ = fresh.handle(snap.map(Event.restoreSession)!)
        let again = fresh.handle(.snapshot, log: false).session
        check(again?.desktops.first?.columns == snap?.desktops.first?.columns, "engine: restore_session rebuilds the snapshot's columns over the FFI")
    }
}
