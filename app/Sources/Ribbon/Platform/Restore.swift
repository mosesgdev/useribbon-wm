import AppKit
import ApplicationServices

/// One remembered window as persisted for crash recovery (pid + app + title identify it again).
struct SavedWindow: Codable, Equatable {
    var id: UInt32
    var pid: Int32
    var app: String
    var title: String
    var x: Double, y: Double, w: Double, h: Double
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct OriginalsFile: Codable {
    var cleanExit: Bool
    var windows: [SavedWindow]
}

/// Remembers each window's first-seen frame so quitting/pausing puts everything back.
/// The frames are mirrored to originals.json (debounced) so a crash does not lose the true pre-Ribbon positions.
@MainActor
final class Restore {
    private(set) var originals: [UInt32: (AXUIElement, CGRect)] = [:]
    private var meta: [UInt32: ManagedWindow] = [:]
    private var inherited: [UInt32: SavedWindow] = [:]   // originals from a run that did not exit cleanly
    private var sources: [DispatchSourceSignal] = []
    private var pendingSave: DispatchWorkItem?
    private let url: URL

    init(url: URL = Restore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(OriginalsFile.self, from: data), !file.cleanExit {
            inherited = Dictionary(file.windows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        }
        scheduleSave()   // rewrite as this run's file
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ribbon/originals.json")
    }

    func remember(_ w: ManagedWindow, element: AXUIElement) {
        guard originals[w.id] == nil else { return }
        var frame = w.frame
        // Left over from a crashed run: the live frame is a Ribbon placement, the saved one is the real original.
        if let old = inherited.removeValue(forKey: w.id), old.pid == w.pid, old.app == w.app { frame = old.frame }
        originals[w.id] = (element, frame)
        meta[w.id] = w
        save(clean: false)   // at once: a crash right after Ribbon first moves a window must still find its real frame
    }

    func forget(_ id: UInt32) { originals[id] = nil; meta[id] = nil; scheduleSave() }

    /// A native tab switch: the window now shown takes over the original frame remembered for the one it replaces (the tab group's,
    /// from before Ribbon first moved it), so quitting still puts the group back.
    func replace(_ old: UInt32, with w: ManagedWindow, element: AXUIElement) {
        guard let (_, frame) = originals[old] else { remember(w, element: element); return }
        originals[old] = nil; meta[old] = nil
        originals[w.id] = (element, frame); meta[w.id] = w
        save(clean: false)
    }
    func original(_ id: UInt32) -> CGRect? { originals[id]?.1 }

    /// Where a remembered frame goes on restore: as it was if it still touches any display, else centred on `fallback`.
    nonisolated static func restoredFrame(_ frame: CGRect, displays: [CGRect], fallback: CGRect) -> CGRect {
        if displays.contains(where: { $0.intersects(frame.insetBy(dx: 40, dy: 40)) }) { return frame }
        var f = frame
        f.origin = CGPoint(x: fallback.midX - f.width / 2, y: fallback.midY - f.height / 2)
        return f
    }

    /// Synchronous. Originals may be on any display; windows first seen off every display are centred on `fallback`.
    func restoreAll(displays: [CGRect], fallback: CGRect) {
        for (el, frame) in originals.values {
            let f = Self.restoredFrame(frame, displays: displays, fallback: fallback)
            AXUIElement.withoutEnhancedUI(pid: el.pid) { el.setFrame(f) }
        }
    }

    /// Everything was put back (pause): remember that, and start empty.
    func forgetAll() { originals = [:]; meta = [:]; inherited = [:]; save(clean: true) }

    /// Write the file now instead of after the debounce.
    func flush() { save(clean: false) }

    /// Clean quit: nothing left to recover.
    func discardFile() {
        pendingSave?.cancel()
        try? FileManager.default.removeItem(at: url)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save(clean: false) } }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func save(clean: Bool) {
        pendingSave?.cancel()
        let windows = originals.keys.sorted().compactMap { id -> SavedWindow? in
            guard let m = meta[id], let f = original(id) else { return nil }
            return SavedWindow(id: id, pid: m.pid, app: m.app, title: m.title, x: f.origin.x, y: f.origin.y, w: f.width, h: f.height)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(OriginalsFile(cleanExit: clean, windows: windows)).write(to: url, options: .atomic)
        } catch { NSLog("ribbon: could not save originals: \(error)") }
    }

    func installSignalHandlers(_ onSignal: @escaping () -> Void) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: onSignal)
            s.resume()
            sources.append(s)
        }
    }
}
