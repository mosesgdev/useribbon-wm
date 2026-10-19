import AppKit
import Darwin

/// Apps (and one system feature) that move windows on their own and so fight a tiling window manager.
struct KnownTiler: Equatable {
    var key: String          // stable id for "Keep both" memory
    var name: String
    var bundleIDs: [String]
    /// Process / app names, for tools with no bundle id (yabai) or an unknown one.
    var names: [String] = []
}

struct RunningThing: Equatable {
    var bundleID: String?
    var name: String
    var pid: Int32 = 0
}

struct Conflict: Equatable {
    enum Kind { case app, stageManager }
    var kind: Kind
    var key: String
    var name: String
    var pid: Int32 = 0
    var bundleID: String?
}

enum ConflictCheck {
    // Bundle ids: Rectangle, Moom, Amethyst, OmniWM, Loop and Divvy were confirmed from Homebrew cask metadata;
    // Magnet, BetterSnapTool, AeroSpace and Spectacle are from the apps' own Info.plists as recalled. Chain's id is
    // unknown, so it is matched by name. Anything unmatched is simply not reported.
    static let catalog: [KnownTiler] = [
        KnownTiler(key: "rectangle", name: "Rectangle", bundleIDs: ["com.knollsoft.Rectangle", "com.knollsoft.Hookshot"], names: ["Rectangle", "Rectangle Pro"]),
        KnownTiler(key: "magnet", name: "Magnet", bundleIDs: ["com.crowdcafe.windowmagnet"], names: ["Magnet"]),
        KnownTiler(key: "moom", name: "Moom", bundleIDs: ["com.manytricks.Moom"], names: ["Moom"]),
        KnownTiler(key: "bettersnaptool", name: "BetterSnapTool", bundleIDs: ["com.hegenberg.BetterSnapTool"], names: ["BetterSnapTool"]),
        KnownTiler(key: "amethyst", name: "Amethyst", bundleIDs: ["com.amethyst.Amethyst"], names: ["Amethyst"]),
        KnownTiler(key: "yabai", name: "yabai", bundleIDs: [], names: ["yabai"]),
        KnownTiler(key: "aerospace", name: "AeroSpace", bundleIDs: ["bobko.aerospace"], names: ["AeroSpace"]),
        KnownTiler(key: "omniwm", name: "OmniWM", bundleIDs: ["com.barut.OmniWM"], names: ["OmniWM"]),
        KnownTiler(key: "chain", name: "ChainYourMac", bundleIDs: [], names: ["ChainYourMac", "Chain"]),
        KnownTiler(key: "loop", name: "Loop", bundleIDs: ["com.MrKai77.Loop"], names: ["Loop"]),
        KnownTiler(key: "divvy", name: "Divvy", bundleIDs: ["com.mizage.Divvy", "com.mizage.direct.Divvy"], names: ["Divvy"]),
        KnownTiler(key: "spectacle", name: "Spectacle", bundleIDs: ["com.divisiblebyzero.Spectacle"], names: ["Spectacle"]),
    ]

    static let stageManagerKey = "stage-manager"

    /// Conflicts among `running` things, minus the ones the user chose to keep. Bundle id first; the name only counts
    /// for things without a bundle id (a bare daemon like yabai), so an unrelated app called "Loop" is not mistaken.
    static func detect(running: [RunningThing], stageManagerOn: Bool, dismissed: Set<String>, catalog: [KnownTiler] = catalog) -> [Conflict] {
        var out: [Conflict] = []
        for t in catalog where !dismissed.contains(t.key) {
            let hit = running.first { r in
                if let b = r.bundleID, !b.isEmpty { return t.bundleIDs.contains { $0.caseInsensitiveCompare(b) == .orderedSame } }
                return t.names.contains { $0.caseInsensitiveCompare(r.name) == .orderedSame }
            }
            if let hit { out.append(Conflict(kind: .app, key: t.key, name: t.name, pid: hit.pid, bundleID: hit.bundleID)) }
        }
        if stageManagerOn, !dismissed.contains(stageManagerKey) {
            out.append(Conflict(kind: .stageManager, key: stageManagerKey, name: "Stage Manager"))
        }
        return out
    }

    /// Debug / QA: `RIBBON_EXTRA_CONFLICTS="FakeTiler=Fake Tiler,com.example.x=Example"` adds catalog entries keyed by
    /// process name or bundle id.
    static func extra(_ spec: String?) -> [KnownTiler] {
        (spec ?? "").split(separator: ",").compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard let id = kv.first, !id.isEmpty else { return nil }
            let name = kv.count > 1 ? kv[1] : id
            return KnownTiler(key: "debug:" + id, name: name, bundleIDs: id.contains(".") ? [id] : [], names: id.contains(".") ? [] : [id])
        }
    }
}

enum ConflictCopy {
    static func title(_ c: Conflict) -> String {
        c.kind == .stageManager ? "Stage Manager is on" : "\(c.name) is also moving your windows"
    }
    static func message(_ c: Conflict) -> String {
        switch c.kind {
        case .stageManager: return "It moves windows around too, so the ribbon jumps. Turn it off in Desktop & Dock to keep things calm."
        case .app: return "\(c.name) also moves your windows, so the ribbon jumps. Quit it to keep things calm."
        }
    }
}

/// Watches for conflicting apps at launch and whenever apps launch or quit, and shows one calm card at a time.
@MainActor
final class ConflictMonitor {
    static let dismissedKey = "dismissedConflicts"
    private let defaults: UserDefaults
    private let card = ConflictCardController()
    private var observers: [NSObjectProtocol] = []
    private var checkSeq = 0
    private var queue: [Conflict] = []
    private var shown = Set<String>()   // conflicts whose card already appeared this run
    private var enabled = false
    private let extraCatalog = ConflictCheck.extra(ProcessInfo.processInfo.environment["RIBBON_EXTRA_CONFLICTS"])
    /// Tells the menu bar what is pending (nil = nothing), so a card that faded can be brought back.
    var onPending: (Conflict?) -> Void = { _ in }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var dismissed: Set<String> { Set(defaults.stringArray(forKey: Self.dismissedKey) ?? []) }

    func start() {
        enabled = true
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            })
        }
        card.onQuit = { [weak self] c in self?.quit(c) }
        card.onKeep = { [weak self] c in self?.keep(c) }
        card.onOpenSettings = { [weak self] _ in
            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") { NSWorkspace.shared.open(url) }
            self?.card.close(); self?.scheduleCheck(after: 1)
        }
        scheduleCheck(after: 1.5)
    }

    /// The pending conflict, shown again (menu bar item).
    func reshow() { if let c = queue.first { card.show(c, more: queue.count - 1) } }

    private func scheduleCheck(after delay: Double = 0.6) {
        guard enabled else { return }
        checkSeq += 1
        let seq = checkSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { if let self, self.checkSeq == seq { self.check() } }
        }
    }

    private func check() {
        let env = ProcessInfo.processInfo.environment
        let found = ConflictCheck.detect(running: Self.runningThings(), stageManagerOn: Self.stageManagerOn(env: env),
                                         dismissed: dismissed, catalog: ConflictCheck.catalog + extraCatalog)
        queue = found
        shown.formIntersection(found.map(\.key))   // a conflict that went away and returns is news again
        onPending(queue.first)
        if let cur = card.current, !found.contains(where: { $0.key == cur.key }) { card.close() }
        guard card.current == nil, let next = queue.first(where: { !shown.contains($0.key) }) else { return }
        shown.insert(next.key)
        card.show(next, more: queue.count - 1)
    }

    private func quit(_ c: Conflict) {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == c.pid || ($0.bundleIdentifier != nil && $0.bundleIdentifier == c.bundleID)
        }
        app?.terminate()
        card.close()
        scheduleCheck(after: 1.2)   // quitting takes a moment; a conflict that stays gets its card back
    }

    /// "Keep both" / "Keep it on": remembered across launches.
    func keep(_ c: Conflict) {
        defaults.set(Array(dismissed.union([c.key])).sorted(), forKey: Self.dismissedKey)
        card.close()
        scheduleCheck(after: 0.3)
    }

    static func stageManagerOn(env: [String: String]) -> Bool {
        if env["RIBBON_FAKE_STAGE_MANAGER"] == "1" { return true }
        return (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool) == true
    }

    /// GUI apps plus bare processes by name (yabai is a daemon, not an app bundle).
    static func runningThings() -> [RunningThing] {
        var out = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }.map {
            RunningThing(bundleID: $0.bundleIdentifier, name: $0.localizedName ?? $0.executableURL?.lastPathComponent ?? "", pid: $0.processIdentifier)
        }
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return out }
        var pids = [Int32](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let known = Set(out.map(\.pid))
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 && !known.contains(pid) {
            var buf = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            out.append(RunningThing(bundleID: nil, name: String(cString: buf), pid: pid))
        }
        return out
    }
}
