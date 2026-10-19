import Foundation
import CoreGraphics

/// Self tests for native tab groups: which vanished window a new one replaces (pure pairing by app, frame and tab bar), the
/// hold-and-pair state machine in either order of events, and the replace event through the core.
enum NativeTabTests {
    static func run(_ check: (Bool, String) -> Void) {
        pairing(check)
        spaces(check)
        goneInfo(check)
        sequences(check)
        core(check)
        flows(check)
        actions(check)
        log(check)
    }

    private static let group = CGRect(x: 12, y: 37, width: 976, height: 776)
    private static let other = CGRect(x: 1000, y: 37, width: 480, height: 776)
    /// The tab bar a tab group shows: the windows of these tests are titled "Tab <id>".
    private static let bar = ["Tab 1", "Tab 2", "Tab 3"]
    private static func gone(_ id: UInt32, pid: pid_t = 10, at f: CGRect = group, hidden: Bool = false, successor: Bool = false, server: CGRect? = nil,
                             title: String? = nil) -> NativeTabs.Gone {
        NativeTabs.Gone(id: id, pid: pid, frame: f, title: title ?? "Tab \(id)", hidden: hidden, serverFrame: server, successor: successor)
    }
    private static func shown(_ id: UInt32, pid: pid_t = 10, at f: CGRect = group, siblings: Set<UInt32> = [], tabs: [String] = bar) -> NativeTabs.Shown {
        NativeTabs.Shown(id: id, pid: pid, frame: f, siblings: siblings, tabs: tabs)
    }
    private static func pairs(_ g: [NativeTabs.Gone], _ s: [NativeTabs.Shown], loose: Bool = true) -> [[UInt32]] {
        NativeTabs.pairs(gone: g, shown: s, loose: loose).map { [$0.old, $0.new] }
    }

    // MARK: pure pairing

    private static func pairing(_ check: (Bool, String) -> Void) {
        check(pairs([gone(1, hidden: true)], [shown(2)]) == [[1, 2]], "tabs: a hidden tab and a newcomer at its frame pair")
        check(pairs([gone(1, successor: true)], [shown(2, at: group.offsetBy(dx: 3, dy: -2))]) == [[1, 2]], "tabs: a closed tab's successor within a few points pairs")
        check(pairs([gone(1, successor: true)], [shown(2, at: group.offsetBy(dx: 14, dy: 0))]).isEmpty, "tabs: a newcomer a cascade step away is not the successor")
        check(pairs([gone(1, at: other, hidden: true, server: group)], [shown(2)]) == [[1, 2]], "tabs: the window server's frame counts when Ribbon's last frame is stale")
        // A hidden tab whose frame went stale is still the app's one hidden tab: it pairs with the app's one newcomer.
        check(pairs([gone(1, at: other, hidden: true)], [shown(2)]) == [[1, 2]], "tabs: a lone hidden tab pairs with a lone newcomer even at another frame")
        check(pairs([gone(1, at: other, hidden: true)], [shown(2)], loose: false).isEmpty, "tabs: ... but not when only exact frames may pair")
        check(pairs([gone(1, at: other, successor: true)], [shown(2)]).isEmpty, "tabs: a closed window without hidden tabs needs the frame to match")
        check(NativeTabs.sameCorner(group, CGRect(x: group.minX + 2, y: group.minY, width: group.width - 300, height: group.height)),
              "tabs: a hidden sibling tab keeps the size it was last shown at but shares the group's corner")
        check(!NativeTabs.sameCorner(group, group.offsetBy(dx: 22, dy: 22)), "tabs: a cascaded window is not at the group's corner")

        // Not tabs.
        check(pairs([gone(1)], [shown(2, at: other)]).isEmpty, "tabs: closing one window and opening another at a different frame never pairs")
        check(pairs([gone(1, at: other)], [shown(2, at: other.offsetBy(dx: 22, dy: 22))]).isEmpty, "tabs: a cascaded new window is not a replacement")
        check(pairs([gone(1, hidden: true), gone(2, at: other, hidden: true), gone(3, at: other.offsetBy(dx: 500, dy: 0), hidden: true)], []).isEmpty,
              "tabs: ⌘H (every window vanishes, none appears) pairs nothing")
        check(pairs([gone(1, hidden: true), gone(2, at: other, hidden: true), gone(3, at: other.offsetBy(dx: 500, dy: 0), hidden: true)],
                    [shown(9, at: CGRect(x: 40, y: 60, width: 500, height: 400))]).isEmpty, "tabs: ⌘H plus an unrelated new window is ambiguous, so nothing pairs")
        check(pairs([gone(1, pid: 10, hidden: true)], [shown(2, pid: 11)]).isEmpty, "tabs: another app's window is never a replacement")

        // Several at once.
        let a = group, b = CGRect(x: 1000, y: 37, width: 500, height: 776)
        check(pairs([gone(1, pid: 10, hidden: true), gone(3, pid: 11, hidden: true)], [shown(2, pid: 10), shown(4, pid: 11)]) == [[1, 2], [3, 4]],
              "tabs: two switches in different apps pair each with its own app")
        check(pairs([gone(1, pid: 10, at: a, hidden: true), gone(3, pid: 11, at: a, hidden: true)], [shown(4, pid: 11, at: a), shown(2, pid: 10, at: a)]) == [[1, 2], [3, 4]],
              "tabs: identical frames in two apps still pair by app, whatever the order")
        check(pairs([gone(1, at: a, hidden: true), gone(3, at: b, hidden: true)], [shown(4, at: b), shown(2, at: a)]) == [[1, 2], [3, 4]],
              "tabs: two groups of one app switching together pair by frame")
        check(pairs([gone(1, at: a, hidden: true), gone(3, at: a, hidden: true)], [shown(2, at: a)]).count == 1, "tabs: one newcomer replaces at most one window")
        check(pairs([gone(1, at: a, hidden: true), gone(3, at: b, hidden: true)], [shown(2, at: CGRect(x: 40, y: 60, width: 500, height: 400))]).isEmpty,
              "tabs: two hidden tabs and a newcomer matching neither is ambiguous")
        check(pairs([gone(1, at: a, hidden: true), gone(3, at: b, hidden: true)], [shown(2, at: a.offsetBy(dx: 1, dy: 0))]) == [[1, 2]],
              "tabs: the frame decides between two hidden tabs")
        check(pairs([gone(1, at: a, hidden: true)], [shown(2, at: a), shown(3, at: a)]).count == 1, "tabs: the lower id of two equal newcomers pairs, the other stays new")
        check(pairs([], [shown(2)]).isEmpty && pairs([gone(1, hidden: true)], []).isEmpty, "tabs: nothing to pair")
        check(NativeTabs.near(group, group.offsetBy(dx: 6, dy: -6)) && !NativeTabs.near(group, group.offsetBy(dx: 7, dy: 0)) && !NativeTabs.near(group, CGRect(x: 12, y: 37, width: 1020, height: 776)),
              "tabs: 'the same frame' is a few points on every edge")
        // A terminal lands a character cell or two off the size Ribbon wrote, at the same corner.
        let cells = CGRect(x: group.minX, y: group.minY, width: group.width - 7, height: group.height - 13)
        check(NativeTabs.near(group, cells) && !NativeTabs.near(group, CGRect(x: group.minX, y: group.minY, width: group.width, height: group.height - 40)),
              "tabs: the same corner and a size a cell or two off is still the same frame, a much smaller window is not")
        check(!NativeTabs.near(group, cells.offsetBy(dx: 10, dy: 0)), "tabs: ... but only at the same corner")
        check(pairs([gone(1, successor: true)], [shown(2, at: cells)]) == [[1, 2]], "tabs: a closed terminal tab's successor pairs although the planned height was a row off")
        check(pairs([gone(1, successor: true)], [shown(2, at: CGRect(x: group.minX, y: group.minY, width: group.width, height: group.height - 40))]).isEmpty, "tabs: ... a window clearly smaller at that corner is not the successor")
        // An unrelated close and open at one frame cannot be told from a close with its successor in a single snapshot (the newcomer is
        // itself a window at the frame): the new window takes the column, which is also what the user sees.
        check(pairs([gone(1, successor: true)], [shown(2)]) == [[1, 2]], "tabs: a close and an open at the very same frame keep the column")
    }

    // MARK: Spaces and other windows that vanish alive

    /// A Spaces switch takes the windows of the Space left off screen (alive, like hidden tabs) and lists the windows of the Space
    /// entered, often at the very frames: a ribbon lays every Space out alike. Only a tab bar on the newcomer tells a tab apart.
    private static func spaces(_ check: (Bool, String) -> Void) {
        check(pairs([gone(1, hidden: true)], [shown(2, tabs: [])]).isEmpty, "tabs spaces: a window on another Space is not replaced by a plain window at its frame")
        check(pairs([gone(1, at: other, hidden: true, server: group)], [shown(2, tabs: [])]).isEmpty, "tabs spaces: ... nor at its place in the window server")
        check(pairs([gone(1, at: other, hidden: true)], [shown(2, tabs: [])]).isEmpty, "tabs spaces: ... nor elsewhere (the loose rule)")
        check(pairs([gone(1, hidden: true)], [shown(2, tabs: ["Tab 2"])]).isEmpty, "tabs spaces: a bar with a single tab cannot hold the hidden window too")
        check(pairs([gone(1, hidden: true), gone(3, at: other, hidden: true)], [shown(2, tabs: []), shown(4, at: other, tabs: [])]).isEmpty,
              "tabs spaces: several windows of one app across a Spaces switch pair nothing")
        check(pairs([gone(1, successor: true)], [shown(2, tabs: [])]) == [[1, 2]], "tabs spaces: a closed tab's successor needs no tab bar (it may be the group's last tab)")

        // The loose rule (frames that do not match) needs the bar to name the vanished window.
        let doc1 = gone(1, at: other, hidden: true, title: "doc1.txt")
        check(pairs([doc1], [shown(2, tabs: ["doc2.txt", "doc3.txt"])]).isEmpty, "tabs spaces: a tab group of the other Space does not take a lone hidden window loosely")
        check(pairs([doc1], [shown(2, tabs: ["doc1.txt", "doc2.txt"])]) == [[1, 2]], "tabs spaces: ... a bar that names it does")
        check(pairs([gone(1, at: other, hidden: true, title: "doc1.txt — Edited")], [shown(2, tabs: ["doc1.txt", "doc2.txt"])]) == [[1, 2]],
              "tabs spaces: a tab is named without its window's '— Edited' suffix")
        check(pairs([gone(1, at: other, hidden: true, title: "doc1")], [shown(2, tabs: ["doc1.txt", "doc2.txt"])]).isEmpty, "tabs spaces: ... but a title is not named by a longer one")
        check(pairs([gone(1, at: other, hidden: true, title: "")], [shown(2, tabs: ["", "x"])]).isEmpty, "tabs spaces: an untitled window is never named")
        let zsh = ["~ — -zsh", "/tmp — -zsh"]
        check(pairs([gone(1, at: other, hidden: true, title: "admin — -zsh — 80×24")], [shown(2, tabs: zsh)]).isEmpty, "tabs spaces: a Terminal tab is titled unlike its window: no loose pair")
        check(pairs([gone(1, hidden: true, title: "admin — -zsh — 80×24")], [shown(2, tabs: zsh)]) == [[1, 2]], "tabs spaces: ... a Terminal tab switch at the group's frame still pairs")
        check(NativeTabs.mayReplace(gone(1, hidden: true), shown(2)) && !NativeTabs.mayReplace(gone(1, hidden: true), shown(2, tabs: [])) && NativeTabs.mayReplace(gone(1), shown(2, tabs: [])),
              "tabs spaces: only a window that lives on needs the tab bar")
    }

    // MARK: what the window server says about a window that left its app's list

    private static func goneInfo(_ check: (Bool, String) -> Void) {
        typealias I = WindowServer.Info
        let narrow = CGRect(x: group.minX, y: group.minY, width: 500, height: 400)
        func info(_ server: [I], destroyed: Bool = false, unmanaged: Set<UInt32> = [2, 3]) -> NativeTabs.Gone {
            NativeTabs.gone(id: 1, pid: 10, at: group, title: "Tab 1", server: server, destroyed: destroyed, unmanaged: { unmanaged.contains($0) })
        }
        let g = info([I(id: 1, frame: group, onScreen: false), I(id: 2, frame: group, onScreen: true)])
        check(g.hidden && g.serverFrame == group && g.successor && g.title == "Tab 1" && g.frame == group, "tabs gone: alive off screen is hidden; an unmanaged window on screen at its frame is its successor")
        let d = info([I(id: 1, frame: group, onScreen: false), I(id: 2, frame: group, onScreen: true)], destroyed: true)
        check(!d.hidden && d.serverFrame == group && d.successor, "tabs gone: a destroyed window is never hidden, whatever the window server still lists")
        let c = info([])
        check(!c.hidden && c.serverFrame == nil && !c.successor, "tabs gone: a window the server no longer has, with nothing at its frame, is just closed")
        check(info([I(id: 3, frame: narrow, onScreen: false)]).successor, "tabs gone: a hidden sibling at the group's corner (another size) is a successor")
        check(!info([I(id: 3, frame: narrow.offsetBy(dx: 30, dy: 0), onScreen: false)]).successor, "tabs gone: ... one elsewhere is not")
        check(!info([I(id: 2, frame: group, onScreen: true)], unmanaged: []).successor, "tabs gone: a managed window at its frame is no successor")
        check(!info([I(id: 1, frame: group, onScreen: true)]).hidden, "tabs gone: a window still on screen is not hidden")
    }

    // MARK: hold and pair, in either order

    private static func sequences(_ check: (Bool, String) -> Void) {
        typealias R = TabPairing.Result
        let rep = { (o: UInt32, n: UInt32, added: Bool) in TabPairing.Replacement(old: o, new: n, added: added) }
        // A tab that was switched away from: still alive off screen, and the tab now shown sits on screen at its frame.
        func tab(_ id: UInt32, pid: pid_t = 10, at f: CGRect = group) -> NativeTabs.Gone { gone(id, pid: pid, at: f, hidden: true, successor: true) }

        // Both noticed in one scan.
        var t = TabPairing()
        check(t.step(gone: [tab(1)], shown: [shown(2)], now: 0) == R(replaced: [rep(1, 2, false)]), "tabs: vanish and appear in one scan is a replace; nothing is added or removed")
        check(!t.holding, "tabs: nothing is held after a pair")

        // The vanish first (destroyed notification before the scan), then the newcomer.
        t = TabPairing()
        check(t.step(gone: [gone(1, successor: true)], shown: [], now: 0) == R(), "tabs: a window whose successor is already on screen is held, not removed")
        check(t.holding && t.nextDeadline == NativeTabs.grace, "tabs: the hold lasts the grace period")
        check(t.step(gone: [], shown: [], now: 0.2) == R() && t.holding, "tabs: ... and is still held a little later")
        check(t.step(gone: [gone(1, successor: true)], shown: [shown(2)], now: 0.3) == R(replaced: [rep(1, 2, false)]), "tabs: the newcomer then takes the held window's place")
        check(t.step(gone: [], shown: [], now: 2) == R(), "tabs: nothing is removed afterwards")

        // The newcomer first (already added), then the vanish.
        t = TabPairing()
        check(t.step(gone: [], shown: [shown(2)], now: 0) == R(add: [2]), "tabs: a newcomer with nothing vanished is added at once")
        check(t.step(gone: [gone(1, successor: true)], shown: [], now: 0.2) == R(replaced: [rep(1, 2, true)]), "tabs: a window vanishing right after merges into the newcomer already added")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        check(t.step(gone: [tab(1)], shown: [], now: 0.2) == R(replaced: [rep(1, 2, true)]), "tabs: ... also for a hidden tab")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        check(t.step(gone: [gone(1, at: other, hidden: true)], shown: [], now: 0.2) == R(remove: [1]), "tabs: a hidden window at another frame is not merged into a newcomer already added")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        let late = t.step(gone: [gone(1, successor: true)], shown: [], now: 0.7)
        check(late.replaced.isEmpty && t.holding, "tabs: a newcomer older than the grace period is no longer a candidate")

        // The newcomer's add re-laid the ribbon, so the old tab no longer sits where the newcomer appeared: its sibling set decides.
        let moved = group.offsetBy(dx: 1899, dy: 0)
        func shift(_ id: UInt32) -> NativeTabs.Gone { gone(id, at: moved, hidden: true, successor: true, server: moved) }
        t = TabPairing()
        check(t.step(gone: [], shown: [shown(2, siblings: [1])], now: 0) == R(add: [2]), "tabs: a newcomer with siblings is added at once")
        check(t.step(gone: [shift(1)], shown: [], now: 0.2) == R(replaced: [rep(1, 2, true)]), "tabs: the sibling that vanishes next merges into the newcomer wherever the ribbon has put it")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2, siblings: [1])], now: 0)
        check(t.step(gone: [shift(5)], shown: [], now: 0.2).replaced.isEmpty, "tabs: a window that was not beside the newcomer is not merged into it")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2, siblings: [1])], now: 0)
        check(t.step(gone: [shift(1)], shown: [], now: 0.7).replaced.isEmpty, "tabs: ... nor after the grace period")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2, pid: 11, siblings: [1])], now: 0)
        check(t.step(gone: [shift(1)], shown: [], now: 0.2).replaced.isEmpty, "tabs: ... nor from another app")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2, siblings: [1, 3]), shown(4, at: other, siblings: [3])], now: 0)
        check(t.step(gone: [shift(1), shift(3)], shown: [], now: 0.2) == R(replaced: [rep(1, 2, true), rep(3, 4, true)]), "tabs: two siblings and two newcomers pair one to one")

        // A newcomer that shows no tab bar yet is no tab for a window vanishing alive, even beside it; one that joined the group since
        // (its bar read again by the next scan) is.
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2, siblings: [1], tabs: [])], now: 0)
        check(t.step(gone: [shift(1)], shown: [], now: 0.2) == R() && t.heldIDs == [1], "tabs: a sibling vanishing alive is not merged into a newcomer without a tab bar, it waits")
        check(t.recentIDs == [2], "tabs: the newcomer is still a candidate")
        t.refresh(tabs: [2: ["Tab 1", "Tab 2"], 9: ["Tab 9", "Tab 10"]])
        check(t.step(gone: [], shown: [], now: 0.3) == R(replaced: [rep(1, 2, true)]) && !t.holding, "tabs: once its bar lists the group, the held sibling merges into it")
        check(t.recentIDs.isEmpty, "tabs: a refresh never makes a candidate of a window that was not one")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2, tabs: [])], now: 0)
        check(t.step(gone: [tab(1)], shown: [], now: 0.2) == R() && t.step(gone: [], shown: [], now: 0.8) == R(remove: [1]),
              "tabs: ... and a window nothing names is removed when its hold runs out")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2, tabs: [])], now: 0)
        check(t.step(gone: [gone(1, successor: true)], shown: [], now: 0.2) == R(replaced: [rep(1, 2, true)]), "tabs: a closed tab merges into its successor without a tab bar")

        // A close that is not a tab: nothing is delayed.
        t = TabPairing()
        check(t.heldIDs.isEmpty, "tabs: nothing is held at first")
        _ = t.step(gone: [gone(1, successor: true)], shown: [], now: 0)
        check(t.heldIDs == [1], "tabs: a held window is named")
        t = TabPairing()
        check(t.step(gone: [gone(1)], shown: [], now: 0) == R(remove: [1]), "tabs: an ordinary close is removed at once")
        check(t.step(gone: [], shown: [shown(2, at: other)], now: 0.1) == R(add: [2]), "tabs: an unrelated window opening afterwards is added")
        t = TabPairing()
        check(t.step(gone: [gone(1)], shown: [shown(2, at: other)], now: 0) == R(add: [2], remove: [1]), "tabs: close and open in one scan stay a remove and an add")
        t = TabPairing()
        check(t.step(gone: [gone(1, hidden: true)], shown: [], now: 0) == R(remove: [1]) && !t.holding, "tabs: a window its app kept hidden (close to the menu bar, ⌘H) is removed at once, not held")
        check(t.step(gone: [gone(1, hidden: true), gone(2, at: other, hidden: true), gone(3, at: other.offsetBy(dx: 500, dy: 0), hidden: true)], shown: [], now: 1)
              == R(remove: [1, 2, 3]), "tabs: ⌘H-like vanishes without a newcomer are all removed at once")

        // A held window nobody replaces is removed when the grace period is over, once.
        t = TabPairing()
        _ = t.step(gone: [gone(1, successor: true)], shown: [], now: 0)
        _ = t.step(gone: [gone(1, successor: true)], shown: [], now: 0.3)   // the same window reported again does not extend the hold
        check(t.step(gone: [], shown: [], now: 0.4) == R(), "tabs: still held before the deadline")
        check(t.step(gone: [], shown: [], now: 0.6) == R(remove: [1]), "tabs: removed once the grace period is over")
        check(!t.holding && t.step(gone: [], shown: [], now: 1) == R(), "tabs: and only once")
        t = TabPairing()
        _ = t.step(gone: [gone(1, successor: true), gone(2, at: other, successor: true)], shown: [], now: 0)
        check(t.step(gone: [], shown: [], now: 0.6) == R(remove: [1, 2]), "tabs: several holds run out together")

        // It came back, the app went away.
        t = TabPairing()
        _ = t.step(gone: [gone(1, successor: true)], shown: [], now: 0)
        t.cancel(1)
        check(t.step(gone: [], shown: [], now: 1) == R() && !t.holding, "tabs: a window listed again is no longer held")
        t = TabPairing()
        _ = t.step(gone: [gone(1, pid: 10, successor: true), gone(5, pid: 11, successor: true)], shown: [], now: 0)
        t.drop(pid: 10)
        check(t.step(gone: [], shown: [], now: 1) == R(remove: [5]), "tabs: a hidden or quit app's holds are dropped, other apps keep theirs")
        t = TabPairing()
        _ = t.step(gone: [gone(1, successor: true)], shown: [], now: 0)
        t.forget(1)
        check(!t.holding, "tabs: a window that was closed for real is forgotten")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        t.forget(2)
        check(t.step(gone: [gone(1, successor: true)], shown: [], now: 0.2).replaced.isEmpty, "tabs: a newcomer that closed again is not merged into")

        // A newcomer that vanishes again within the grace period is removed (or held), never paired with itself.
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        check(t.step(gone: [gone(2)], shown: [], now: 0.2) == R(remove: [2]), "tabs: a newcomer closing at its own frame is removed, not replaced by itself")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        check(t.step(gone: [gone(2, at: other, hidden: true, server: group)], shown: [], now: 0.2) == R(remove: [2]), "tabs: ... also hidden at its own place")
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        check(t.step(gone: [gone(2, successor: true)], shown: [], now: 0.2) == R() && t.heldIDs == [2], "tabs: ... and with a successor it waits for it like any window")
        // A newcomer that was replaced is no candidate for what vanishes next.
        t = TabPairing()
        _ = t.step(gone: [], shown: [shown(2)], now: 0)
        check(t.step(gone: [tab(2)], shown: [shown(3)], now: 0.1) == R(replaced: [rep(2, 3, false)]), "tabs: a newcomer's tab is switched away from")
        check(t.step(gone: [gone(3)], shown: [], now: 0.2) == R(remove: [3]), "tabs: the tab shown in its place is not merged back into it")

        // Switching back and forth.
        t = TabPairing()
        check(t.step(gone: [tab(1)], shown: [shown(2)], now: 0) == R(replaced: [rep(1, 2, false)]), "tabs: switch to the second tab")
        check(t.step(gone: [tab(2)], shown: [shown(1)], now: 1) == R(replaced: [rep(2, 1, false)]), "tabs: and back to the first")
        // A replace in one app does not disturb a hold in another.
        t = TabPairing()
        _ = t.step(gone: [gone(7, pid: 11, successor: true)], shown: [], now: 0)
        check(t.step(gone: [tab(1)], shown: [shown(2)], now: 0.1) == R(replaced: [rep(1, 2, false)]) && t.holding, "tabs: another app's hold is untouched by a replace")
        check(t.step(gone: [], shown: [shown(8, pid: 11)], now: 0.2) == R(replaced: [rep(7, 8, false)]), "tabs: ... and pairs with its own newcomer")
    }

    // MARK: scan outcomes through the pairing into the core, as the tracker and controller chain them

    /// Three windows of three apps; the middle one (a tab group of app 11) is widened to 2/3. Scans are fed to the pairing and its
    /// outcome is sent to the engine exactly as `WindowTracker.finishScan` and `Controller.trackerEvent` do (the pairing's own
    /// `actions`, the sibling set read from the plan before the add re-lays the ribbon).
    private final class Flow {
        let engine = Engine()
        var pairing = TabPairing()
        var plan: Plan
        var managed: Set<UInt32> = [1, 2, 3]
        init() {
            _ = engine.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 2000, height: 800)))
            for (id, pid) in [(1, 10), (2, 11), (3, 12)] {
                _ = engine.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: Int32(pid), app: "App\(pid)", title: "W\(id)", frame: CGRect(x: 0, y: 0, width: 600, height: 500), floating: false)))
            }
            _ = engine.handle(.windowFocused(2))
            _ = engine.handle(.command("cycle_width"))
            plan = engine.handle(.query)
        }
        func window(_ id: UInt32) -> ManagedWindow { ManagedWindow(id: id, pid: 11, app: "App11", title: "Tab \(id)", frame: CGRect(x: 0, y: 0, width: 600, height: 500), floating: false) }
        /// Where the plan has put a window.
        func frame(of id: UInt32) -> CGRect? { plan.frames.first { $0.id == id }?.cg }
        /// One observation, at `now`; `gone` / `shown` are ids of app 11, shown at `at`.
        func scan(gone: [NativeTabs.Gone] = [], shown: [UInt32] = [], at: CGRect = group, tabs: [String] = ["Tab 2", "Tab 12"], now: Double) {
            let beside = Set(managed.filter { $0 == 2 || $0 > 10 }.filter { id in frame(of: id).map { NativeTabs.sameCorner($0, at) } == true })
            let r = pairing.step(gone: gone, shown: shown.map { NativeTabs.Shown(id: $0, pid: 11, frame: at, siblings: beside, tabs: tabs) }, now: now)
            for a in r.actions(fresh: shown, pairable: Set(shown), managed: managed) {
                switch a {
                case .replace(let old, let new, _):
                    managed.remove(old); managed.insert(new)
                    plan = engine.handle(.windowReplaced(old: old, window(new)))
                case .add(let id): managed.insert(id); plan = engine.handle(.windowAdded(window(id)))
                case .remove(let id): managed.remove(id); plan = engine.handle(.windowRemoved(id))
                }
            }
        }
        var columns: [[UInt32]] { plan.map.columns.map { $0.windows.map(\.id) } }
        var width: Double? { plan.map.columns.first { $0.windows.contains { $0.id == 2 || $0.id > 10 } }?.widthFrac }
    }

    private static func flows(_ check: (Bool, String) -> Void) {
        func tab(_ id: UInt32) -> NativeTabs.Gone { NativeTabs.Gone(id: id, pid: 11, frame: group, hidden: true, serverFrame: group, successor: true) }
        let wide = Flow().width
        check(wide != nil && wide! > 0.6, "tabs flow: setup, the tab group's column is at 2/3")

        let a = Flow()   // a tab click: the old tab vanishes and the new one is listed in the same scan
        a.scan(gone: [tab(2)], shown: [12], now: 0)
        check(a.columns == [[1], [12], [3]] && a.width == wide && a.plan.jump && a.plan.changed == [12], "tabs flow: a tab click keeps the column, its width, and writes only the new tab in place")

        let b = Flow()   // the vanish is noticed first (a destroyed notification), the newcomer a scan later
        b.scan(gone: [NativeTabs.Gone(id: 2, pid: 11, frame: group, successor: true)], now: 0)
        check(b.columns == [[1], [2], [3]], "tabs flow: a closed tab with a successor on screen stays in its column while it waits")
        b.scan(gone: [NativeTabs.Gone(id: 2, pid: 11, frame: group, successor: true)], shown: [12], now: 0.1)
        check(b.columns == [[1], [12], [3]] && b.width == wide, "tabs flow: ... and the successor then takes the column with its width")

        let c = Flow()   // the newcomer is noticed first and already added, the old tab vanishes later
        c.scan(shown: [12], now: 0)
        check(c.columns == [[1], [2], [12], [3]], "tabs flow: a newcomer seen first is added next to the focused column")
        c.scan(gone: [tab(2)], now: 0.2)
        check(c.columns == [[1], [12], [3]] && c.width == wide && c.plan.map.focusedIndex == 1, "tabs flow: ... and the old tab vanishing right after merges it back into the old column, focus included")

        let d = Flow()   // nothing replaces the held window: it goes after the grace period
        d.scan(gone: [NativeTabs.Gone(id: 2, pid: 11, frame: group, successor: true)], now: 0)
        d.scan(now: 0.6)
        check(d.columns == [[1], [3]], "tabs flow: a held window nobody replaced is removed after the grace period")

        let e = Flow()   // an ordinary close and an unrelated open: remove at once, add as new (default width)
        e.scan(gone: [NativeTabs.Gone(id: 2, pid: 11, frame: group)], now: 0)
        check(e.columns == [[1], [3]], "tabs flow: an ordinary close removes the column at once")
        e.scan(shown: [30], now: 0.1)
        check(e.columns.count == 3 && e.width != wide, "tabs flow: an unrelated window opening afterwards gets a column of its own at the default width")

        let g = Flow()   // the newcomer first, and its add scrolled the ribbon before the old tab vanished
        let at = g.frame(of: 2)!
        g.scan(shown: [12], at: at, now: 0)
        let moved = g.frame(of: 2)!
        check(!NativeTabs.near(at, moved) && !NativeTabs.sameCorner(at, moved), "tabs flow: setup, the add moved the old tab away from where the newcomer appeared")
        g.scan(gone: [NativeTabs.Gone(id: 2, pid: 11, frame: moved, hidden: true, serverFrame: moved, successor: true)], now: 0.2)
        check(g.columns == [[1], [12], [3]] && g.width == wide && g.plan.map.focusedIndex == 1, "tabs flow: ... the old tab still merges into the newcomer, with its column, width and focus")

        let h = Flow()   // a Spaces switch: app 11's window goes off screen alive, a plain window of app 11 shows at its frame
        h.scan(gone: [NativeTabs.Gone(id: 2, pid: 11, frame: group, hidden: true, serverFrame: group, successor: true)], shown: [12], tabs: [], now: 0)
        check(h.columns == [[1], [2], [12], [3]], "tabs flow: a Spaces switch adds the other Space's window as new while the old one waits")
        h.scan(now: 0.6)
        check(h.columns == [[1], [12], [3]] && h.width != wide, "tabs flow: ... then the old one goes, and the newcomer keeps the default width")

        let f = Flow()   // two switches in a row, then undo/redo still work on the replaced window
        f.scan(gone: [tab(2)], shown: [12], now: 0)
        f.scan(gone: [tab(12)], shown: [22], now: 1)
        check(f.columns == [[1], [22], [3]] && f.width == wide, "tabs flow: switching again keeps the column")
        _ = f.engine.handle(.command("undo"))
        let undone = f.engine.handle(.query)
        check(undone.map.columns.map { $0.windows.map(\.id) } == [[1], [22], [3]] && undone.map.columns[1].widthFrac < wide!, "tabs flow: undo of the width step applies to the tab shown now")
    }

    // MARK: the host's work after a step

    private static func actions(_ check: (Bool, String) -> Void) {
        typealias R = TabPairing.Result
        typealias A = TabPairing.Action
        let rep = { (o: UInt32, n: UInt32, added: Bool) in TabPairing.Replacement(old: o, new: n, added: added) }
        func acts(_ r: R, fresh: [UInt32] = [], pairable: Set<UInt32>? = nil, managed: Set<UInt32> = []) -> [A] {
            r.actions(fresh: fresh, pairable: pairable ?? Set(fresh), managed: managed)
        }
        check(acts(R(replaced: [rep(1, 2, false)]), fresh: [2], managed: [1]) == [.replace(old: 1, new: 2, fresh: true)], "tabs actions: a pair in one scan manages the newcomer in the old window's place")
        check(acts(R(replaced: [rep(1, 2, true)]), managed: [1, 2]) == [.replace(old: 1, new: 2, fresh: false)], "tabs actions: a newcomer added earlier is only swapped")
        check(acts(R(replaced: [rep(1, 2, false)]), fresh: [2], managed: []) == [.add(2)], "tabs actions: a replacement whose old window nobody holds is an add")
        check(acts(R(add: [2], remove: [1]), fresh: [2], managed: [1]) == [.add(2), .remove(1)], "tabs actions: adds come before removals")
        check(acts(R(), fresh: [5], pairable: [], managed: []) == [.add(5)], "tabs actions: a window that did not take part in the pairing (shelved, coming back) is added")
        check(acts(R(replaced: [rep(1, 2, false)], add: [3]), fresh: [2, 3], managed: [1]) == [.replace(old: 1, new: 2, fresh: true), .add(3)], "tabs actions: one pair and one plain newcomer")
        check(acts(R(), managed: [1]).isEmpty, "tabs actions: nothing happened")
    }

    // MARK: QA-only console lines

    private static func log(_ check: (Bool, String) -> Void) {
        check(!QALog.enabled([:]) && !QALog.enabled(["HOME": "/Users/x", "RIBBON_ONLY_PIDS": "1"]), "qa log: silent in everyday use")
        check(QALog.enabled(["RIBBON_PLAN_LOG": "/tmp/p.jsonl"]) && QALog.enabled(["RIBBON_QA_OUT": "/tmp/q.jsonl"]), "qa log: on in QA runs")
    }

    // MARK: through the core

    private static func core(_ check: (Bool, String) -> Void) {
        let engine = Engine()
        _ = engine.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1000, height: 800)))
        for id in 1...3 {
            _ = engine.handle(.windowAdded(ManagedWindow(id: UInt32(id), pid: 100 + Int32(id), app: "App\(id)", title: "Doc \(id)", frame: CGRect(x: 50, y: 50, width: 600, height: 500), floating: false)))
        }
        _ = engine.handle(.windowFocused(2))
        _ = engine.handle(.command("cycle_width"))
        let before = engine.handle(.query)
        let old = before.frames.first { $0.id == 2 }!
        let fresh = ManagedWindow(id: 20, pid: 102, app: "App2", title: "Doc 20", frame: CGRect(x: 300, y: 80, width: 700, height: 600), floating: false)
        let plan = engine.handle(.windowReplaced(old: 2, fresh))
        let f = plan.frames.first { $0.id == 20 }
        check(plan.error == nil && f != nil && [f!.x, f!.y, f!.w, f!.h] == [old.x, old.y, old.w, old.h] && f!.onScreen == old.onScreen, "tabs core: the new window gets the old window's frame")
        check(plan.frames.map(\.id).sorted() == [1, 3, 20] && plan.changed == [20], "tabs core: the old id is gone and only the new window is written")
        check(plan.jump && plan.focus == nil && !plan.showMap, "tabs core: written without gliding, no focus request, no HUD")
        check(plan.map.columns[1].windows.map(\.title) == ["Doc 20"] && plan.map.columns[1].widthFrac == before.map.columns[1].widthFrac && plan.map.columns[1].focused,
              "tabs core: the column keeps its width and focus, the title comes from the new window")
        let ghost = engine.handle(.windowReplaced(old: 77, fresh))
        check(ghost.error == nil && ghost.changed.isEmpty && ghost.frames.count == 3, "tabs core: an unknown old window is ignored")
        let undo = engine.handle(.command("undo"))
        check(undo.frames.map(\.id).sorted() == [1, 3, 20] && (undo.frames.first { $0.id == 20 }!.w < old.w), "tabs core: undo still works on the replaced window")
        check(engine.handle(rawJSON: #"{"type":"window_replaced","old":20,"new":2,"pid":102,"app":"App2","title":"Doc 2"}"#).frames.map(\.id).sorted() == [1, 2, 3],
              "tabs core: the event's JSON shape")
    }
}
