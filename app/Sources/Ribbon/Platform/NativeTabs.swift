import CoreGraphics
import Foundation

// Native macOS tab groups (Finder, Terminal, TextEdit, Safari ... with their window tabs). Only the shown tab is in the app's AX
// window list; the other tabs are live window-server windows that are not on screen. Switching, opening or closing a tab therefore
// reads as "one window vanished, another appeared at the same frame". These pure rules recognise that, so the column keeps its
// place, width and everything else. Rects are in AX space (global, top-left origin). Time is passed in.

enum NativeTabs {
    /// How far (pt, per edge) two frames may differ and still be one tab group's frame.
    static let tolerance: CGFloat = 6
    /// How far (pt) the size of a window at the same corner may differ and still be the same frame: a character cell or two.
    static let cell: CGFloat = 24
    /// How long a vanished window waits for the tab shown in its place, and an appeared one for the window it replaces:
    /// AX notifications and scans arrive in no fixed order.
    static let grace: TimeInterval = 0.5

    /// A managed window that left its app's window list (minimized ones are not reported here).
    struct Gone: Equatable {
        var id: UInt32
        var pid: pid_t
        /// Where Ribbon last put it.
        var frame: CGRect
        /// Its title, as a tab bar would name it.
        var title = ""
        /// Still alive in the window server but not on screen: it became a hidden tab (or it sits on another Space, or its app hid
        /// it or kept it for later). `serverFrame` is where it sits there.
        var hidden = false
        var serverFrame: CGRect? = nil
        /// An unmanaged window of the app already sits on screen at its frame (the tab shown in its place, not listed yet), or a
        /// hidden one at its corner (a sibling tab, shown next when this tab closes). Worth waiting for; any other window that
        /// vanished is just closed (no delay for ordinary closes, hidden or not).
        var successor = false
    }

    /// A window that appeared in its app's window list.
    struct Shown: Equatable {
        var id: UInt32
        var pid: pid_t
        var frame: CGRect
        /// The managed windows of its app that sat at its corner the moment it appeared (read before its own add re-lays the ribbon).
        /// If its add comes first, the one of them that vanishes next is the tab it replaces, wherever the ribbon has put it since.
        var siblings: Set<UInt32> = []
        /// The tabs its native tab bar lists, by title (empty: it shows no tab bar, or its app did not say).
        var tabs: [String] = []
    }

    struct Pair: Equatable { var old: UInt32, new: UInt32 }

    /// Largest edge difference between the frames (the vanished window's last frame, or its place in the window server, whichever fits).
    private static func distance(_ g: Gone, _ s: Shown) -> CGFloat {
        func d(_ a: CGRect, _ b: CGRect) -> CGFloat { max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY)) }
        return min(d(g.frame, s.frame), g.serverFrame.map { d($0, s.frame) } ?? .infinity)
    }

    /// Whether a window shown at `b` sits where one at `a` was: every edge within `tolerance`, or the same corner and a size within
    /// `cell` (a terminal never lands on the size Ribbon wrote, it snaps to whole character cells).
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY)) <= tolerance
            || (sameCorner(a, b) && abs(a.width - b.width) <= cell && abs(a.height - b.height) <= cell)
    }

    /// Whether two windows share a top-left corner. A tab group's hidden tabs sit at the group's corner but keep the size they
    /// had when last shown, so this (not `near`) is how a hidden tab is recognised as the closed tab's sibling.
    static func sameCorner(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
    }

    /// Whether `s` may be the tab shown in place of `g`. A window switched away from stays in its group, so the newcomer shows the
    /// group's tab bar. A window that lives on off screen without one is on another Space (a Spaces switch hides the windows of the
    /// Space left and lists the ones of the Space entered, at frames a ribbon makes alike), or its app hid it: never a tab switch.
    /// A closed window needs no tab bar: the tab shown after it may be the group's last.
    static func mayReplace(_ g: Gone, _ s: Shown) -> Bool { !g.hidden || s.tabs.count >= 2 }

    /// Whether the newcomer's tab bar names the vanished window. A tab is titled like its window, without the "— Edited"-style
    /// suffix. Some apps title tabs differently (Terminal: "~ — -zsh" in a window "admin — -zsh — 80×24"): no match, no loose pair.
    static func names(_ s: Shown, _ g: Gone) -> Bool {
        !g.title.isEmpty && s.tabs.contains { $0 == g.title || g.title.hasPrefix($0 + " — ") }
    }

    /// Which appeared window takes the place of which vanished one. Same app only, one to one, and a window still alive off screen
    /// only by a newcomer that shows a tab bar (`mayReplace`).
    /// - Frames that are `near` pair (closest first): a closed tab's successor, or a switched-to tab, shows at the group's frame.
    /// - `loose`: of what is left, an app's single hidden tab and single newcomer pair too when the newcomer's tab bar names it (the
    ///   group's frame was not known exactly). Anything ambiguous pairs nothing: that is the plain remove + add it always was.
    /// So an unrelated close + open (other frames, nothing hidden), ⌘H (windows vanish, none appears) and a Spaces switch (windows
    /// vanish alive, others appear without a tab bar naming them) never pair.
    static func pairs(gone: [Gone], shown: [Shown], loose: Bool = true) -> [Pair] {
        var close: [(g: Int, s: Int, d: CGFloat)] = []
        for (i, g) in gone.enumerated() {
            for (j, s) in shown.enumerated() where g.pid == s.pid && mayReplace(g, s) {
                if near(g.frame, s.frame) || g.serverFrame.map({ near($0, s.frame) }) == true { close.append((i, j, distance(g, s))) }
            }
        }
        close.sort { ($0.d, $0.g, $0.s) < ($1.d, $1.g, $1.s) }
        var usedG = Set<Int>(), usedS = Set<Int>()
        var out: [Pair] = []
        for c in close where !usedG.contains(c.g) && !usedS.contains(c.s) {
            usedG.insert(c.g); usedS.insert(c.s)
            out.append(Pair(old: gone[c.g].id, new: shown[c.s].id))
        }
        if loose {
            for pid in Set(gone.map(\.pid)) {
                let g = gone.indices.filter { !usedG.contains($0) && gone[$0].pid == pid && gone[$0].hidden }
                let s = shown.indices.filter { !usedS.contains($0) && shown[$0].pid == pid }
                if g.count == 1, s.count == 1, mayReplace(gone[g[0]], shown[s[0]]), names(shown[s[0]], gone[g[0]]) {
                    out.append(Pair(old: gone[g[0]].id, new: shown[s[0]].id))
                }
            }
        }
        return out.sorted { ($0.old, $0.new) < ($1.old, $1.new) }
    }
}

/// Remembers vanished windows that may yet be replaced (their removal waits) and appeared windows that may yet turn out to
/// replace one, so a tab switch is recognised whichever of the two is noticed first, in one scan or across several.
struct TabPairing {
    /// `new` takes `old`'s place. `added`: `new` had already been reported as a new window (its add came first).
    struct Replacement: Equatable { var old: UInt32, new: UInt32, added: Bool }
    struct Result: Equatable {
        var replaced: [Replacement] = []
        /// Appeared windows nobody replaces: added as usual.
        var add: [UInt32] = []
        /// Vanished windows that stay gone: removed as usual.
        var remove: [UInt32] = []

        /// The host's work after a scan. `fresh`: the unmanaged windows it listed; `pairable`: those among them that took part in the
        /// pairing (a shelved window coming back did not); `managed`: what the host holds right now. A replacement whose old window
        /// the host no longer holds is just an add.
        func actions(fresh: [UInt32], pairable: Set<UInt32>, managed: Set<UInt32>) -> [Action] {
            var out: [Action] = []
            for r in replaced {
                if r.added { out.append(.replace(old: r.old, new: r.new, fresh: false)) }
                else if fresh.contains(r.new) { out.append(managed.contains(r.old) ? .replace(old: r.old, new: r.new, fresh: true) : .add(r.new)) }
            }
            out += fresh.filter { add.contains($0) || !pairable.contains($0) }.map { .add($0) }
            return out + remove.map { .remove($0) }
        }
    }

    /// What the host does with a step's outcome, in this order.
    enum Action: Equatable {
        /// `new` takes `old`'s place. `fresh`: `new` is not managed yet (it was listed in this very scan).
        case replace(old: UInt32, new: UInt32, fresh: Bool)
        /// Manage a fresh window and report it as new.
        case add(UInt32)
        case remove(UInt32)
    }

    private var held: [UInt32: (gone: NativeTabs.Gone, until: TimeInterval)] = [:]
    private var recent: [UInt32: (shown: NativeTabs.Shown, until: TimeInterval)] = [:]

    /// When the oldest held removal runs out.
    var nextDeadline: TimeInterval? { held.values.map(\.until).min() }
    var holding: Bool { !held.isEmpty }
    var heldIDs: Set<UInt32> { Set(held.keys) }
    /// Newcomers that may still turn out to replace a window vanishing later.
    var recentIDs: Set<UInt32> { Set(recent.keys) }

    /// What the tab bars of recent newcomers list now. A window can be shown first and join a tab group a moment later (the tab
    /// it replaces vanishes then), so the bar read when it appeared may be out of date.
    mutating func refresh(tabs: [UInt32: [String]]) {
        for (id, t) in tabs { recent[id]?.shown.tabs = t }
    }

    /// One observation: windows that vanished and windows that appeared (either may be empty; an empty call just expires holds).
    /// A vanished window whose successor is already on screen waits up to `grace` for it to be listed; the caller keeps it
    /// managed meanwhile. Every other vanished window is to be removed at once.
    mutating func step(gone: [NativeTabs.Gone], shown: [NativeTabs.Shown], now: TimeInterval) -> Result {
        var out = Result()
        recent = recent.filter { $0.value.until > now }
        let pool = (held.values.map(\.gone) + gone.filter { held[$0.id] == nil }).sorted { $0.id < $1.id }
        let shown = shown.sorted { $0.id < $1.id }
        // The newcomers of this call first; a vanished window left over may still replace one that was already added.
        let paired = NativeTabs.pairs(gone: pool, shown: shown)
        let left = pool.filter { g in !paired.contains { $0.old == g.id } }
        // A newcomer that vanishes again is a window like any other: it never stands in for itself or for another vanished window's pair.
        let earlier = recent.values.map(\.shown).filter { s in !shown.contains { $0.id == s.id } && !pool.contains { $0.id == s.id } }.sorted { $0.id < $1.id }
        var late = NativeTabs.pairs(gone: left, shown: earlier, loose: false)
        // The add scrolled the ribbon, so the old tab no longer sits where the newcomer appeared: the sibling it was at that moment decides.
        var claimed = Set(late.map(\.new))
        for g in left where !late.contains(where: { $0.old == g.id }) {
            guard let s = earlier.first(where: { $0.pid == g.pid && $0.siblings.contains(g.id) && !claimed.contains($0.id) && NativeTabs.mayReplace(g, $0) }) else { continue }
            late.append(NativeTabs.Pair(old: g.id, new: s.id)); claimed.insert(s.id)
        }
        // The replaced window is a hidden tab now: it is no candidate for what appears later.
        for p in paired { held[p.old] = nil; recent[p.old] = nil; out.replaced.append(Replacement(old: p.old, new: p.new, added: false)) }
        for p in late { held[p.old] = nil; recent[p.old] = nil; recent[p.new] = nil; out.replaced.append(Replacement(old: p.old, new: p.new, added: true)) }
        let taken = Set(paired.map(\.new))
        for s in shown where !taken.contains(s.id) {
            out.add.append(s.id)
            recent[s.id] = (s, now + NativeTabs.grace)
        }
        let settled = Set((paired + late).map(\.old))
        for g in pool where !settled.contains(g.id) {
            recent[g.id] = nil
            if let h = held[g.id] {
                if h.until <= now { held[g.id] = nil; out.remove.append(g.id) }
            } else if g.successor {
                held[g.id] = (g, now + NativeTabs.grace)
            } else {
                out.remove.append(g.id)
            }
        }
        return out
    }

    /// The window is listed again: it was only hidden for a moment.
    mutating func cancel(_ id: UInt32) { held[id] = nil }
    /// The window is gone for good (or released): nothing to pair it with.
    mutating func forget(_ id: UInt32) { held[id] = nil; recent[id] = nil }
    /// The app was hidden (⌘H) or quit: its windows are handled elsewhere.
    mutating func drop(pid: pid_t) {
        held = held.filter { $0.value.gone.pid != pid }
        recent = recent.filter { $0.value.shown.pid != pid }
    }
}

extension NativeTabs {
    /// What the pairing knows of a managed window that left its app's window list. `at`: where Ribbon last put it; `server`: the
    /// app's windows as the window server has them; `unmanaged`: whether a window is neither managed nor shelved. `destroyed`: its
    /// destroyed notification came, so it is closed whatever the window server still shows of it (never a hidden tab).
    static func gone(id: UInt32, pid: pid_t, at: CGRect, title: String, server: [WindowServer.Info], destroyed: Bool,
                     unmanaged: (UInt32) -> Bool) -> Gone {
        let mine = server.first { $0.id == id }
        let offScreen = mine.map { !$0.onScreen } ?? false
        let serverAt = offScreen ? mine?.frame : nil
        // A closed tab's successor is often not on screen yet when the destroyed notification comes, but its hidden siblings are
        // already there at the group's corner.
        let successor = server.contains { s in
            guard s.id != id, unmanaged(s.id) else { return false }
            return s.onScreen ? near(s.frame, at) || serverAt.map { near(s.frame, $0) } == true : sameCorner(s.frame, at)
        }
        return Gone(id: id, pid: pid, frame: at, title: title, hidden: offScreen && !destroyed, serverFrame: serverAt, successor: successor)
    }
}

/// The window server's view of an app's windows, without Accessibility: which of them are alive but not on screen (hidden tabs
/// of a native tab group, minimized windows, windows of other Spaces) and where each sits.
enum WindowServer {
    struct Info: Equatable { var id: UInt32; var frame: CGRect; var onScreen: Bool }

    static func windows(ofPID pid: pid_t) -> [Info] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: b as CFDictionary),
                  frame.width >= 100, frame.height >= 100 else { return nil }
            return Info(id: id, frame: frame, onScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
    }
}
