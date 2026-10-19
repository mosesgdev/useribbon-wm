import Foundation

/// "Always float these apps": windows of these apps are added to the ribbon floating.
struct FloatRule: Codable, Equatable, Hashable {
    var id: String      // bundle id
    var name: String
}

enum FloatRules {
    static let key = "floatApps"

    /// Small, editable starting list: utilities that read as popups, not as columns.
    static let defaults: [FloatRule] = [
        FloatRule(id: "com.apple.calculator", name: "Calculator"),
        FloatRule(id: "com.apple.archiveutility", name: "Archive Utility"),
        FloatRule(id: "com.apple.systempreferences", name: "System Settings"),
    ]

    /// Saved list, or the defaults until the user edits it (an emptied list stays empty).
    static func load(_ d: UserDefaults = .standard) -> [FloatRule] {
        guard let raw = d.array(forKey: key) as? [[String: String]] else { return defaults }
        return raw.compactMap { r in r["id"].map { FloatRule(id: $0, name: r["name"] ?? $0) } }
    }

    static func save(_ rules: [FloatRule], _ d: UserDefaults = .standard) {
        d.set(rules.map { ["id": $0.id, "name": $0.name] }, forKey: key)
    }

    /// Bundle id match; apps without a bundle id match by name.
    static func matches(bundleID: String?, app: String, rules: [FloatRule]) -> Bool {
        rules.contains { r in bundleID.map { $0.caseInsensitiveCompare(r.id) == .orderedSame } ?? (r.id == app) }
    }

    static func adding(_ rule: FloatRule, to rules: [FloatRule]) -> [FloatRule] {
        rules.contains { $0.id.caseInsensitiveCompare(rule.id) == .orderedSame } ? rules : rules + [rule]
    }

    static func removing(id: String, from rules: [FloatRule]) -> [FloatRule] {
        rules.filter { $0.id.caseInsensitiveCompare(id) != .orderedSame }
    }

    /// The rule id of a window's app: bundle id, else its name.
    static func ruleID(bundleID: String?, app: String) -> String { SessionFile.key(bundleID: bundleID, app: app) }
}

/// Floating windows as the core lays them out: which windows float, and where one goes when it leaves the ribbon.
enum Floating {
    /// Every window a plan knows, and whether it floats. A plan has a frame for every tiled window (every desktop's, and the
    /// pin), and none for a floating one.
    static func states(in plan: Plan) -> [UInt32: Bool] {
        let tiled = Set(plan.frames.map(\.id))
        var out: [UInt32: Bool] = [:]
        for d in plan.map.desktops { for id in d.windows { out[id] = !tiled.contains(id) } }
        return out
    }

    /// Windows that left the ribbon (`floated`) or joined it (`tiled`) since `known`, which then holds the plan's states.
    /// A window `known` has never seen is neither: it floats or tiles from the start.
    static func changes(_ known: inout [UInt32: Bool], plan: Plan) -> (floated: [UInt32], tiled: [UInt32]) {
        var floated: [UInt32] = [], tiled: [UInt32] = []
        for (id, floats) in states(in: plan).sorted(by: { $0.key < $1.key }) {
            switch (known.updateValue(floats, forKey: id), floats) {
            case (false?, true): floated.append(id)
            case (true?, false): tiled.append(id)
            default: break
            }
        }
        return (floated, tiled)
    }

    /// Windows with a planned frame that the plan no longer lays out: they float now, and a planned frame would read as "a tile
    /// lives here". `keep`: windows that are not this plan's to judge (another display's, a parked float). A failed call
    /// (an error and no frames) says nothing.
    static func stale(_ planned: some Sequence<UInt32>, plan: Plan, keep: (UInt32) -> Bool) -> [UInt32] {
        guard !(plan.frames.isEmpty && plan.error != nil) else { return [] }
        let tiled = Set(plan.frames.map(\.id))
        return planned.filter { !tiled.contains($0) && !keep($0) }.sorted()
    }

    /// Where a window that just left the ribbon goes: where it last floated, else where it was before Ribbon took it in, else
    /// a window-sized rectangle in the middle of the display. Never the full-height column it had, which covers the ribbon.
    static func frame(remembered: CGRect?, original: CGRect?, visible: CGRect) -> CGRect {
        func fits(_ r: CGRect, tallest: Double) -> Bool { r.width >= 100 && r.height >= 100 && r.width <= visible.width && r.height <= tallest }
        let pick = remembered.flatMap { fits($0, tallest: visible.height) ? $0 : nil } ?? original.flatMap { fits($0, tallest: visible.height * 0.9) ? $0 : nil }
        if let r = pick {   // its own size, pulled onto this display
            return CGRect(x: min(max(r.minX, visible.minX), visible.maxX - r.width), y: min(max(r.minY, visible.minY), visible.maxY - r.height),
                          width: r.width, height: r.height)
        }
        let w = min(visible.width * 0.5, 1200), h = min(visible.height * 0.7, 900)
        return CGRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    /// How far outside its frame a window can still be grabbed: macOS's resize zone reaches past the edge.
    static let grabMargin: CGFloat = 6

    /// The floating window a press at `p` may move or resize: the frontmost window under the pointer (within its resize zone),
    /// when Ribbon floats it. A press on any other window, even one above a floating window's edge, follows nothing.
    /// `windows`: the window server's list, front to back (Ribbon's own panels left out). Normal windows (layer 0) and the
    /// windows Ribbon manages take a press: a managed window may be kept on top (layer 3), while the Dock, the menu bar and
    /// overlays above every window never do.
    static func pressed(at p: CGPoint, windows: [(id: UInt32, layer: Int, frame: CGRect)], managed: (UInt32) -> Bool,
                        floating: (UInt32) -> Bool) -> UInt32? {
        guard let top = windows.first(where: { ($0.layer == 0 || managed($0.id)) && $0.frame.insetBy(dx: -grabMargin, dy: -grabMargin).contains(p) })
        else { return nil }
        return floating(top.id) ? top.id : nil
    }
}

/// A floating window under the pressed mouse button, followed every display frame: macOS reports a dragged or resized window
/// to accessibility only about ten times a second, so a ring that waited for those reports trailed the window. The frame comes
/// from the window server, which has it the moment it is on screen.
struct FloatFollow {
    enum Step: Equatable {
        case none            // nothing moved since the last frame
        case move(CGPoint)   // the window only moved, its top-left corner is here now
        case place(CGRect)   // the window is here now: the first frame, or its size changed
        case end             // the button is up, or the window is gone: follow no more
    }

    private(set) var id: UInt32?
    /// Where the window was at the last frame (nil until the first).
    private(set) var frame: CGRect?

    mutating func start(_ id: UInt32) { self.id = id; frame = nil }
    mutating func stop() { id = nil; frame = nil }

    /// One display frame: whether the button is still down, and the followed window's frame as the window server has it.
    mutating func tick(buttonDown: Bool, frame now: CGRect?) -> Step {
        guard id != nil else { return .none }
        guard buttonDown, let now else { stop(); return .end }
        if now == frame { return .none }
        defer { frame = now }
        return frame?.size == now.size ? .move(now.origin) : .place(now)
    }
}
