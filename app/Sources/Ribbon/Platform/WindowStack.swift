import AppKit

/// The on-screen windows front to back (public CGWindowList: ids, layers, bounds and owner pids need no permission).
struct WindowStack {
    struct Entry { var id: Int; var layer: Int; var pid: pid_t; var bounds: CGRect }
    var entries: [Entry]

    static func current() -> WindowStack {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return WindowStack(entries: info.compactMap { d in
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return Entry(id: id, layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                         pid: pid_t((d[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0), bounds: bounds)
        })
    }
    func index(of id: Int) -> Int? { entries.firstIndex { $0.id == id } }
}
