import Foundation

// Session restore: a lightweight snapshot of the ribbon (every desktop's columns, widths, stacks, focus and scroll)
// that survives a Ribbon restart. The core is pure, so the snapshot's identity model lives here: windows are saved by
// (pid, window id) plus (app key, title) and matched back to live windows when Ribbon starts.

/// How a window is recognised again: pid + id survive while the app keeps running; the app key (bundle id, else the
/// app name) with the title or the order covers apps that were restarted.
struct SessionWindow: Codable, Equatable {
    var id: UInt32
    var pid: Int32
    var key: String
    var title: String
}

struct SavedColumn: Codable, Equatable {
    var windows: [SessionWindow]
    var width: CoreWidth
    var heights: [Double]?
    /// Tabbed column and its active tab (index); absent in older files.
    var tabbed: Bool? = nil
    var active: Int? = nil
}

struct SavedDesk: Codable, Equatable {
    var index: Int
    var columns: [SavedColumn]
    var floating: [SessionWindow]
    /// Id (in this file) of the focused window.
    var focus: UInt32?
    var scroll: Double
}

/// The pinned column (mirrors `CorePin`, with windows saved by identity). Absent in older files.
struct SavedPin: Codable, Equatable {
    var windows: [SessionWindow]
    var heights: [Double]? = nil
    var tabbed: Bool? = nil
    var active: Int? = nil
    var side: PinSide
    var fraction: Double
    var desktop: Int
    var everyDesktop: Bool? = nil
    var home: Int? = nil
    var homeDesktop: Int? = nil
    var width: CoreWidth? = nil
    var suspended: Bool? = nil
    var need: Double? = nil
}

/// One display's ribbon in the session (keyed by display UUID, so it is found again after a reconnect).
struct SavedDisplay: Codable, Equatable {
    var uuid: String
    var active: Int
    var desks: [SavedDesk]
    var pin: SavedPin? = nil
}

struct LiveWindow: Equatable {
    var id: UInt32
    var pid: Int32
    var key: String
    var title: String
}

struct SessionFile: Codable, Equatable {
    static let version = 1
    static let lifetime: TimeInterval = 24 * 3600
    var version = SessionFile.version
    var savedAt: Date
    var active: Int
    var desks: [SavedDesk]
    /// Every display's ribbon. `active`/`desks` above hold the primary display's, which is what older files and older
    /// builds read. nil = a single-display file.
    var displays: [SavedDisplay]? = nil
    /// The primary display's pin (each display's own is in `displays`).
    var pin: SavedPin? = nil

    /// One file for all the display engines (`parts`: UUID + that display's single-display snapshot).
    static func combine(_ parts: [(uuid: String, file: SessionFile)], primary: String, now: Date) -> SessionFile? {
        guard let lead = parts.first(where: { $0.uuid == primary }) ?? parts.first else { return nil }
        var f = SessionFile(savedAt: now, active: lead.file.active, desks: lead.file.desks, pin: lead.file.pin)
        f.displays = parts.map { SavedDisplay(uuid: $0.uuid, active: $0.file.active, desks: $0.file.desks, pin: $0.file.pin) }
        return f
    }

    /// The single-display session for a display: its own entry, else (an older single-display file) the primary's layout.
    func slice(for uuid: String, primary: String) -> SessionFile? {
        guard let displays else { return uuid == primary ? self : nil }
        guard let d = displays.first(where: { $0.uuid == uuid }) else { return nil }
        return SessionFile(savedAt: savedAt, active: d.active, desks: d.desks, pin: d.pin)
    }

    /// The app key of a window: the bundle id when it has one, else the app's name.
    static func key(bundleID: String?, app: String) -> String { bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? app }

    func isFresh(now: Date) -> Bool {
        version == Self.version && now.timeIntervalSince(savedAt) < Self.lifetime && now >= savedAt.addingTimeInterval(-60)
    }

    /// Windows in layout order: the pinned column, then per desktop, columns top to bottom, then floating windows.
    var windowsInOrder: [SessionWindow] {
        (pin?.windows ?? []) + desks.flatMap { d in d.columns.flatMap(\.windows) + d.floating }
    }

    /// Core snapshot -> file. Windows the host cannot identify are dropped (the core ignores gaps on restore).
    static func make(from core: CoreSession, identify: (UInt32) -> SessionWindow?, now: Date) -> SessionFile {
        let desks = core.desktops.map { d -> SavedDesk in
            let columns = d.columns.compactMap { c -> SavedColumn? in
                let ws = c.windows.compactMap(identify)
                guard !ws.isEmpty else { return nil }
                // Heights only describe the full stack.
                let whole = ws.count == c.windows.count
                return SavedColumn(windows: ws, width: c.width, heights: whole ? c.heights : nil,
                                   tabbed: whole && c.tabbed == true ? true : nil, active: whole && c.tabbed == true ? c.active : nil)
            }
            return SavedDesk(index: d.index, columns: columns, floating: d.floating.compactMap(identify), focus: d.focus, scroll: d.scroll)
        }.filter { !$0.columns.isEmpty || !$0.floating.isEmpty }
        let pin = core.pin.flatMap { p -> SavedPin? in
            let ws = p.windows.compactMap(identify)
            guard !ws.isEmpty else { return nil }
            let whole = ws.count == p.windows.count
            return SavedPin(windows: ws, heights: whole ? p.heights : nil, tabbed: whole ? p.tabbed : nil, active: whole ? p.active : nil,
                            side: p.side, fraction: p.fraction, desktop: p.desktop, everyDesktop: p.everyDesktop, home: p.home,
                            homeDesktop: p.homeDesktop, width: p.width, suspended: p.suspended, need: p.need)
        }
        return SessionFile(savedAt: now, active: core.active, desks: desks, pin: pin)
    }

    /// What the core needs: the saved layout with every saved window replaced by its live match. Saved windows without
    /// a match are left out, so the core appends the unmatched live windows after the restored columns.
    func restoreEvent(live: [LiveWindow]) -> (session: CoreSession, matched: Int)? {
        let map = SessionMatcher.match(saved: windowsInOrder, live: live)
        guard !map.isEmpty else { return nil }
        let desktops = desks.map { d -> CoreDesk in
            let columns = d.columns.compactMap { c -> CoreColumn? in
                let ids = c.windows.compactMap { map[$0.id] }
                guard !ids.isEmpty else { return nil }
                let whole = ids.count == c.windows.count
                return CoreColumn(windows: ids, width: c.width, heights: whole ? c.heights : nil,
                                  tabbed: whole && c.tabbed == true ? true : nil, active: whole && c.tabbed == true ? c.active : nil)
            }
            return CoreDesk(index: d.index, columns: columns, floating: d.floating.compactMap { map[$0.id] },
                            focus: d.focus.flatMap { map[$0] }, scroll: d.scroll)
        }
        let pin = self.pin.flatMap { p -> CorePin? in
            let ids = p.windows.compactMap { map[$0.id] }
            guard !ids.isEmpty else { return nil }
            // As for columns: a stack's heights and tabs only describe it whole.
            let whole = ids.count == p.windows.count
            return CorePin(windows: ids, heights: whole ? p.heights : nil, tabbed: whole ? p.tabbed : nil, active: whole ? p.active : nil,
                           side: p.side, fraction: p.fraction, desktop: p.desktop, everyDesktop: p.everyDesktop, home: p.home,
                           homeDesktop: p.homeDesktop, width: p.width, suspended: p.suspended, need: p.need)
        }
        return (CoreSession(active: active, desktops: desktops, pin: pin), map.count)
    }
}

enum SessionMatcher {
    /// saved window id -> live window id. Each live window is used once.
    /// 1. same pid and id (an app that kept running keeps its window ids), 2. same app key and exact title,
    /// 3. same app key, in order. `saved` is in layout order; `live` in discovery order.
    static func match(saved: [SessionWindow], live: [LiveWindow]) -> [UInt32: UInt32] {
        var result: [UInt32: UInt32] = [:]
        var taken = Set<UInt32>()
        func pass(_ ok: (SessionWindow, LiveWindow) -> Bool) {
            for s in saved where result[s.id] == nil {
                if let l = live.first(where: { !taken.contains($0.id) && ok(s, $0) }) {
                    result[s.id] = l.id
                    taken.insert(l.id)
                }
            }
        }
        pass { s, l in s.pid == l.pid && s.id == l.id && s.key == l.key }
        pass { s, l in s.key == l.key && s.title == l.title }
        pass { s, l in s.key == l.key }
        return result
    }
}

/// Reads and writes ~/Library/Application Support/Ribbon/session.json. Saves are debounced and skipped when nothing changed.
@MainActor
final class SessionStore {
    private let url: URL?
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?
    private var lastWritten: Data?
    /// Produces the current snapshot, or nil when there is nothing worth saving (paused, no windows).
    var provider: () -> SessionFile? = { nil }

    /// nil = session restore is off: QA runs (RIBBON_ONLY_PIDS) must not inherit or leave a layout, unless
    /// RIBBON_SESSION_FILE names one on purpose.
    nonisolated static var defaultURL: URL? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["RIBBON_SESSION_FILE"] { return URL(fileURLWithPath: p) }
        if env["RIBBON_ONLY_PIDS"] != nil || env["RIBBON_ONLY_BUNDLES"] != nil { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ribbon/session.json")
    }

    init(url: URL? = SessionStore.defaultURL, delay: TimeInterval = 1.5) { self.url = url; self.delay = delay }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// The saved session if it is readable, current-format and younger than 24 hours.
    func load(now: Date = Date()) -> SessionFile? {
        guard let url, let data = try? Data(contentsOf: url), let f = try? Self.coder().1.decode(SessionFile.self, from: data), f.isFresh(now: now) else { return nil }
        lastWritten = Self.content(f)
        return f
    }

    /// Something changed: save shortly, once things are quiet.
    func touch() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Write now (quit). Does nothing when the layout is unchanged since the last write.
    func flush() {
        pending?.cancel(); pending = nil
        guard url != nil, let file = provider() else { return }
        let content = Self.content(file)
        guard let url, content != lastWritten, let data = try? Self.coder().0.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil { lastWritten = content }
    }

    /// The layout without its timestamp: what "changed" means.
    static func content(_ f: SessionFile) -> Data {
        var g = f; g.savedAt = Date(timeIntervalSince1970: 0)
        return (try? coder().0.encode(g)) ?? Data()
    }
}
