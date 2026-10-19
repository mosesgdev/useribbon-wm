import Foundation
import CoreGraphics
import RibbonCoreFFI

// MARK: - Wire types (mirror core/src/model.rs)

struct Rect: Codable, Equatable {
    var x, y, w, h: Double
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; w = r.size.width; h = r.size.height }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct EngineConfig: Codable, Equatable {
    var gap = 12.0
    var outerGap = 12.0
    var defaultWidth = 0.5
    var newWindow = "right_of_focused"   // or "end"
    var scroll = "keep_visible"          // or "center_on_overflow"
    /// Width cycle (⌃⌥R). Default: 25 / 33 / 50 / 66 / 75 / 100 %; "Simple" in Settings is ⅓ ½ ⅔ full.
    var widthPresets = WidthPresets.rich
}

enum WidthPresets {
    static let rich = [0.25, 0.333, 0.5, 0.667, 0.75, 1.0]
    static let simple = [0.333, 0.5, 0.667, 1.0]
    /// UserDefaults key and values of the Settings picker.
    static let key = "widthPresets"
    static func list(for choice: String?) -> [Double] { choice == "simple" ? simple : rich }
}

// MARK: - Session wire types (mirror SessionDesk / Session in core/src/model.rs)

struct CoreWidth: Codable, Equatable { var kind: String; var value: Double }
struct CoreColumn: Codable, Equatable {
    var windows: [UInt32]; var width: CoreWidth; var heights: [Double]?
    /// Tabbed column and the index of its active tab (absent in older sessions).
    var tabbed: Bool? = nil
    var active: Int? = nil
}
struct CoreDesk: Codable, Equatable {
    var index: Int
    var columns: [CoreColumn] = []
    var floating: [UInt32] = []
    var focus: UInt32?
    var scroll = 0.0
}
/// The pinned column of a session (mirrors `SessionPin`). `suspended`: it folded into the ribbon on a display too narrow
/// for it (or its windows were minimized) and pins itself again once there is room; `need` is the px it needs then.
struct CorePin: Codable, Equatable {
    var windows: [UInt32]
    var heights: [Double]? = nil
    var tabbed: Bool? = nil
    var active: Int? = nil
    var side: PinSide = .left
    var fraction: Double
    /// 1-based desktop it shows on, and the desktop and column index it was pinned from.
    var desktop: Int
    var everyDesktop: Bool? = nil
    var home: Int? = nil
    var homeDesktop: Int? = nil
    /// Its ribbon width, for when it is unpinned.
    var width: CoreWidth? = nil
    var suspended: Bool? = nil
    var need: Double? = nil
}
struct CoreSession: Codable, Equatable {
    var active: Int; var desktops: [CoreDesk]
    var pin: CorePin? = nil
}

/// One flat struct keeps encoding trivial: only the fields set for a given `type` are sent.
struct Event: Encodable {
    var type: String
    var id: UInt32?
    var pid: Int32?
    var app: String?
    var title: String?
    var frame: Rect?
    var floating: Bool?
    var name: String?
    var arg: CmdArg?
    var widthHint: Double?
    /// `window_added` and `app_shown`; absent means the window takes focus (today's behaviour), `false` joins the ribbon without it.
    var takeFocus: Bool?
    var dx: Double?
    /// `scroll_to` only: the logical x the window `id` is put at.
    var x: Double?
    var front: UInt32?
    var velocity: Double?
    var active: Int?
    var desktops: [CoreDesk]?
    var pin: CorePin?
    var old: UInt32?
    var new: UInt32?

    static func display(id: UInt32, frame: CGRect) -> Event { Event(type: "display", id: id, frame: Rect(frame)) }
    /// `takeFocus` false: an app in the background opened it. It joins where it would go; focus and viewport stay put.
    static func windowAdded(_ w: ManagedWindow, widthHint: Double? = nil, takeFocus: Bool = true) -> Event {
        Event(type: "window_added", id: w.id, pid: w.pid, app: w.app, title: w.title, frame: Rect(w.frame), floating: w.floating, widthHint: widthHint,
              takeFocus: takeFocus ? nil : false)
    }
    static func windowRemoved(_ id: UInt32) -> Event { Event(type: "window_removed", id: id) }
    /// A native tab group showed another of its windows: `w` takes over everything `old` had in the layout, written in place.
    static func windowReplaced(old: UInt32, _ w: ManagedWindow) -> Event { Event(type: "window_replaced", pid: w.pid, app: w.app, title: w.title, old: old, new: w.id) }
    /// Yellow button: the core shelves the window (desktop, width) so its return lands where it left.
    static func windowMinimized(_ id: UInt32) -> Event { Event(type: "window_minimized", id: id) }
    /// ⌘H: the core shelves every managed window of the app.
    static func appHidden(_ pid: Int32) -> Event { Event(type: "app_hidden", pid: pid) }
    /// Unhide: the core restores the app's hidden windows; `front` is the one to focus. `takeFocus` false (unhidden while the user is
    /// in another app): they come back to their places, but focus, desktop and viewport stay put.
    static func appShown(_ pid: Int32, front: UInt32?, takeFocus: Bool = true) -> Event {
        Event(type: "app_shown", pid: pid, takeFocus: takeFocus ? nil : false, front: front)
    }
    static func windowFocused(_ id: UInt32) -> Event { Event(type: "window_focused", id: id) }
    static func windowTitle(_ id: UInt32, _ title: String) -> Event { Event(type: "window_title", id: id, title: title) }
    static func windowResized(_ id: UInt32, _ frame: CGRect) -> Event { Event(type: "window_resized", id: id, frame: Rect(frame)) }
    static func windowRefused(_ id: UInt32, _ frame: CGRect) -> Event { Event(type: "window_refused", id: id, frame: Rect(frame)) }
    static func command(_ name: String, arg: Int? = nil) -> Event { Event(type: "command", name: name, arg: arg.map(CmdArg.int)) }
    /// `set_width`: the focused column to this fraction of the display (undoable; the toast says "Width 66 %").
    static func setWidth(_ fraction: Double) -> Event { Event(type: "command", name: "set_width", arg: .double(fraction)) }
    static func command(_ c: HUDCommand) -> Event { Event(type: "command", name: c.name, arg: c.arg) }
    /// Trackpad scroll: viewport moves by `dx` px (positive = towards later columns). No focus change.
    static func scrollBy(_ dx: Double) -> Event { Event(type: "scroll_by", dx: dx) }
    /// Moves the viewport so the tiled window `id` sits at logical x `x` (a plan frame's `lx`), unresisted: the core joins tiles
    /// that are still gliding without the rubber band's resistance.
    static func scrollTo(_ id: UInt32, x: Double) -> Event { Event(type: "scroll_to", id: id, x: x) }
    /// Fingers lifted: the viewport rests on a column start (or the ribbon's end); `velocity` is the viewport's px/s at release.
    static func scrollEnd(velocity: Double) -> Event { Event(type: "scroll_end", velocity: velocity) }
    static let query = Event(type: "query")
    /// Ask for the layout of every desktop (`Plan.session`).
    static let snapshot = Event(type: "snapshot")
    /// Rebuild the layout from a saved session whose window ids were already mapped to the current ones.
    static func restoreSession(_ s: CoreSession) -> Event { Event(type: "restore_session", active: s.active, desktops: s.desktops, pin: s.pin) }
}

struct PlanFrame: Codable { var id: UInt32; var x, y, w, h: Double; var onScreen: Bool
    /// Where the window sits in the ribbon ignoring parking (the swipe overlay slides snapshots by it); very negative for inactive desktops.
    var lx: Double? = nil
    /// A window of the pinned column: its frame never moves with the ribbon, and it stays above the ribbon's windows.
    var pinned: Bool? = nil
    var isPinned: Bool { pinned == true }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    /// `lx`, or nil when the window is not part of the visible desktop's ribbon.
    var logicalX: Double? { lx.flatMap { $0 > -1e15 ? $0 : nil } }
    var logicalRect: CGRect? { logicalX.map { CGRect(x: $0, y: y, width: w, height: h) } } }
struct MapWindow: Codable, Equatable { var id: UInt32; var app: String; var title: String }
struct MapColumn: Codable, Equatable {
    var windows: [MapWindow]; var widthFrac: Double; var focused: Bool; var visible: Bool
    /// Tabbed column (one window shows at a time) and the index of the active tab.
    var tabbed = false
    var active: Int? = nil
    /// The window that stands for the column: its active tab, else its top window.
    var lead: UInt32? { windows.indices.contains(active ?? 0) ? windows[active ?? 0].id : windows.first?.id }

    init(windows: [MapWindow], widthFrac: Double, focused: Bool, visible: Bool, tabbed: Bool = false, active: Int? = nil) {
        self.windows = windows; self.widthFrac = widthFrac; self.focused = focused; self.visible = visible
        self.tabbed = tabbed; self.active = active
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        windows = try c.decode([MapWindow].self, forKey: .windows); widthFrac = try c.decode(Double.self, forKey: .widthFrac)
        focused = try c.decode(Bool.self, forKey: .focused); visible = try c.decode(Bool.self, forKey: .visible)
        tabbed = try c.decodeIfPresent(Bool.self, forKey: .tabbed) ?? false; active = try c.decodeIfPresent(Int.self, forKey: .active)
    }
}
/// One tab of a column's tab bar.
struct TabItem: Codable, Equatable { var id: UInt32; var app: String; var title: String }
/// The tab bar of a tabbed column: where it sits (AX space, top-left origin) and its tabs.
struct TabBar: Codable, Equatable {
    var column: Int
    var x, y, w, h: Double
    var onScreen: Bool
    var active: UInt32
    var focused: Bool
    var tabs: [TabItem]
    /// The pinned column's bar: `column` is then `map.columns.count`, so it never names a ribbon column.
    var pinned: Bool? = nil
    var isPinned: Bool { pinned == true }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
struct Viewport: Codable { var start: Double; var end: Double }
struct DesktopInfo: Codable, Equatable { var index: Int; var count: Int; var active: Bool; var windows: [UInt32] }
/// A minimized or hidden window the core remembers (mirrors `ShelfItem`).
struct ShelfItem: Codable, Equatable { var id: UInt32; var app: String; var title: String; var desk: Int; var hidden: Bool }
/// Which display edge a pinned column sits against.
enum PinSide: String, Codable, Equatable {
    case left, right
    var other: PinSide { self == .left ? .right : .left }
    var label: String { rawValue }
}
/// The pinned column (mirrors `MapPin`): `column.widthFrac` is a fraction of the whole display (⅕, ¼ or ⅓, or the next
/// one up when an app in it needs more); `column.focused` when the pin has focus. Only set while it shows on this desktop.
struct MapPin: Codable, Equatable {
    var side: PinSide
    var column: MapColumn
    var everyDesktop: Bool
}
struct RibbonMap: Codable {
    var columns: [MapColumn]
    var viewport: Viewport
    var focusedIndex: Int?
    /// Active desktop (1-based) and all nine desktops with their window counts.
    var desktop = 1
    var desktops: [DesktopInfo] = []
    /// The pinned column on this desktop, if any; `columns` stays the ribbon only.
    var pin: MapPin? = nil
    /// The edge `pin` would put the focused ribbon column against (nil while focus is not in the ribbon).
    var nearEdge: PinSide? = nil
    /// Window ids of the pinned column.
    var pinnedIDs: Set<UInt32> { Set(pin?.column.windows.map(\.id) ?? []) }
    var pinFocused: Bool { pin?.column.focused == true }
}
struct Plan: Codable {
    var frames: [PlanFrame]
    var focus: UInt32?
    var changed: [UInt32]
    var map: RibbonMap
    var showMap: Bool
    var error: String?
    var toast: String?
    /// Apply frames without animation (desktop switch).
    var jump: Bool
    /// Floating windows on inactive desktops: Swift parks them (the plan has no frame for them).
    var floatingParked: [UInt32]
    /// Minimized and hidden windows, most recently shelved first.
    var shelf: [ShelfItem] = []
    /// Only set in answer to `snapshot`.
    var session: CoreSession?
    /// Tab bars of the tabbed columns on the active desktop.
    var tabBars: [TabBar] = []

    init(frames: [PlanFrame], focus: UInt32?, changed: [UInt32], map: RibbonMap, showMap: Bool, error: String?, toast: String?,
         jump: Bool, floatingParked: [UInt32], shelf: [ShelfItem] = [], session: CoreSession? = nil, tabBars: [TabBar] = []) {
        self.frames = frames; self.focus = focus; self.changed = changed; self.map = map; self.showMap = showMap; self.error = error
        self.toast = toast; self.jump = jump; self.floatingParked = floatingParked; self.shelf = shelf; self.session = session; self.tabBars = tabBars
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        frames = try c.decode([PlanFrame].self, forKey: .frames); focus = try c.decodeIfPresent(UInt32.self, forKey: .focus)
        changed = try c.decode([UInt32].self, forKey: .changed); map = try c.decode(RibbonMap.self, forKey: .map)
        showMap = try c.decode(Bool.self, forKey: .showMap); error = try c.decodeIfPresent(String.self, forKey: .error)
        toast = try c.decodeIfPresent(String.self, forKey: .toast); jump = try c.decode(Bool.self, forKey: .jump)
        floatingParked = try c.decode([UInt32].self, forKey: .floatingParked)
        shelf = try c.decodeIfPresent([ShelfItem].self, forKey: .shelf) ?? []
        session = try c.decodeIfPresent(CoreSession.self, forKey: .session)
        tabBars = try c.decodeIfPresent([TabBar].self, forKey: .tabBars) ?? []
    }
}

// MARK: - Engine

/// Thin wrapper around the C ABI. Not thread-safe: use from the main actor only.
final class Engine {
    private var handle: OpaquePointer?
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()

    /// Every raw plan JSON line, for the QA plan log.
    var onPlanJSON: ((String) -> Void)?

    init(config: EngineConfig = EngineConfig()) {
        let json = (try? encoder.encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        handle = ribbon_engine_new(json)
    }

    deinit { if let handle { ribbon_engine_free(handle) } }

    func handle(_ event: Event, log: Bool = true) -> Plan {
        guard let data = try? encoder.encode(event), let json = String(data: data, encoding: .utf8) else {
            return Self.failed("could not encode event")
        }
        return handle(rawJSON: json, log: log)
    }

    /// Settings changed: the new config goes live over the layout as it is (`set_config`). Stacks, tabs, widths, floating
    /// windows and the pin stay; the plan moves only what the new gap or scroll mode moves. Not undoable.
    func setConfig(_ config: EngineConfig, log: Bool = true) -> Plan {
        guard let data = try? encoder.encode(config), let arg = String(data: data, encoding: .utf8) else {
            return Self.failed("could not encode config")
        }
        return handle(rawJSON: "{\"type\":\"command\",\"name\":\"set_config\",\"arg\":\(arg)}", log: log)
    }

    /// Raw event JSON (used by the QA fifo).
    func handle(rawJSON json: String, log: Bool = true) -> Plan {
        guard let handle, let out = ribbon_engine_handle(handle, json) else { return Self.failed("engine returned null") }
        defer { ribbon_string_free(out) }
        let text = String(cString: out)
        if log { onPlanJSON?(text) }
        guard let plan = try? decoder.decode(Plan.self, from: Data(text.utf8)) else { return Self.failed("bad plan JSON: \(text.prefix(200))") }
        return plan
    }

    private static func failed(_ msg: String) -> Plan {
        Plan(frames: [], focus: nil, changed: [], map: RibbonMap(columns: [], viewport: Viewport(start: 0, end: 1), focusedIndex: nil),
             showMap: false, error: msg, toast: nil, jump: false, floatingParked: [])
    }
}
