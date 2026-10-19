import AppKit
import Carbon.HIToolbox

/// A physical key plus Carbon modifier bits (controlKey | optionKey | cmdKey | shiftKey).
/// `keyCode == -1` is the "cleared" marker: the action has no shortcut.
struct KeyBinding: Equatable {
    var keyCode: Int
    var modifiers: Int

    static let cleared = KeyBinding(keyCode: -1, modifiers: 0)
    var isCleared: Bool { keyCode < 0 }

    static let fKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                  kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    /// A shortcut needs one of ⌃ ⌥ ⌘ (⇧ alone would eat typing); F-keys may stand alone.
    var isAcceptable: Bool {
        !isCleared && (modifiers & (controlKey | optionKey | cmdKey) != 0 || KeyBinding.fKeys.contains(keyCode))
    }

    // UserDefaults form: {keyCode, modifiers}.
    var encoded: [String: Int] { ["keyCode": keyCode, "modifiers": modifiers] }
    init(keyCode: Int, modifiers: Int) { self.keyCode = keyCode; self.modifiers = modifiers }
    init?(encoded: Any?) {
        guard let d = encoded as? [String: Any], let k = d["keyCode"] as? Int, let m = d["modifiers"] as? Int else { return nil }
        self.init(keyCode: k, modifiers: m)
    }

    static func carbon(_ f: NSEvent.ModifierFlags) -> Int {
        (f.contains(.control) ? controlKey : 0) | (f.contains(.option) ? optionKey : 0)
            | (f.contains(.command) ? cmdKey : 0) | (f.contains(.shift) ? shiftKey : 0)
    }

    /// Modifier glyphs in the macOS order ⌃⌥⇧⌘.
    static func glyphs(_ m: Int) -> [String] {
        (m & controlKey != 0 ? ["⌃"] : []) + (m & optionKey != 0 ? ["⌥"] : []) + (m & shiftKey != 0 ? ["⇧"] : []) + (m & cmdKey != 0 ? ["⌘"] : [])
    }

    /// The label for a physical key. `translate` = what the current layout types on that keycode (injected for tests).
    static func keyLabel(_ code: Int, translate: (Int) -> String?) -> String {
        let named: [Int: String] = [kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Tab: "Tab",
                                    kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "Esc", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                                    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤"]
        if let n = named[code] { return n }
        let fs = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                  kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let i = fs.firstIndex(of: code) { return "F\(i + 1)" }
        if let s = translate(code), !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.value > 32 }) { return s.uppercased() }
        return "Key \(code)"
    }
}

/// A shortcut macOS itself owns (from CopySymbolicHotKeys).
struct SystemKey: Equatable { var keyCode: Int; var modifiers: Int }

enum SystemShortcuts {
    /// Enabled symbolic hotkeys, with modifiers converted from NSEvent bits to Carbon bits.
    static func current() -> [SystemKey] {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr, let list = raw?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = d[kHISymbolicHotKeyCode as String] as? Int, code >= 0, code < 0xFFFF,
                  let flags = d[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            return SystemKey(keyCode: code, modifiers: KeyBinding.carbon(NSEvent.ModifierFlags(rawValue: UInt(flags))))
        }
    }
}

/// What happens to a combo the user just pressed while recording.
enum ShortcutVerdict: Equatable {
    case save
    case unchanged
    case needsModifier
    case system
    case usedBy(id: String, title: String)
}

/// Per-action overrides of the default shortcut (global modifier preset + layout-aware letter).
/// Defaults are never stored, so changing the preset moves every non-overridden shortcut and leaves custom ones alone.
@MainActor
final class ShortcutStore: ObservableObject {
    static let defaultsKey = "shortcutOverrides"

    @Published private(set) var overrides: [String: KeyBinding] = [:]
    /// Saved overrides of actions this edition has no row for (an edition with more features wrote them). They are not shown,
    /// counted or registered, but stay in the saved file untouched, so they are back if that edition returns.
    private var foreign: [String: KeyBinding] = [:]
    @Published private(set) var modifier: ModifierChoice
    /// Recording state for the sheet: the action being recorded, held modifiers, and one inline note.
    @Published private(set) var recording: String?
    @Published private(set) var held: [String] = []
    @Published private(set) var notice: Notice?
    enum Notice: Equatable { case warning(String); case replace(KeyBinding, otherID: String, otherTitle: String) }

    private let defaults: UserDefaults
    private(set) var layout: [Character: Int]
    private let translate: (Int) -> String?
    private let systemKeys: () -> [SystemKey]
    private var monitor: Any?

    /// Called after any change so the controller can re-register the global hotkeys.
    var onChange: (() -> Void)?
    /// Recording pauses Ribbon's own global hotkeys so the combo reaches the sheet; resumed on every exit path.
    var suspendHotkeys: () -> Void = {}
    var resumeHotkeys: () -> Void = {}
    /// Recording needs the keyboard: the sheet is made key (and the app active) before the hotkeys are released to it.
    var ensureKey: () -> Void = {}
    /// Can this combo be registered globally right now (is another app holding it)?
    var canRegister: (KeyBinding) -> Bool = { HotkeyCenter.probe($0) }

    init(defaults: UserDefaults = .standard, layout: [Character: Int]? = nil,
         translate: ((Int) -> String?)? = nil, systemKeys: (() -> [SystemKey])? = nil) {
        self.defaults = defaults
        self.layout = layout ?? KeyLayout.currentMap()
        self.translate = translate ?? KeyLayout.currentTranslator()
        self.systemKeys = systemKeys ?? SystemShortcuts.current
        self.modifier = ModifierChoice(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .ctrlOpt
        reload()
    }

    /// Re-read the preset and the saved overrides (Settings changed, or first load).
    func reload() {
        modifier = ModifierChoice(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .ctrlOpt
        let stored = (defaults.dictionary(forKey: Self.defaultsKey) ?? [:]).compactMapValues { KeyBinding(encoded: $0) }
        let known = Set(Hotkeys.table.map(\.id))
        overrides = stored.filter { known.contains($0.key) }
        foreign = stored.filter { !known.contains($0.key) }
    }

    func refreshLayout() { layout = KeyLayout.currentMap() }

    // MARK: resolution

    func defaultBinding(_ hk: Hotkey) -> KeyBinding {
        if hk.widthKey {
            return modifier == .hyper ? .cleared : KeyBinding(keyCode: hk.keycode(in: layout), modifiers: controlKey | optionKey | cmdKey)
        }
        if hk.allMods {
            return modifier == .hyper ? .cleared
                : KeyBinding(keyCode: hk.keycode(in: layout), modifiers: controlKey | optionKey | shiftKey | cmdKey)
        }
        return KeyBinding(keyCode: hk.keycode(in: layout), modifiers: Int(modifier.carbon) | (hk.shift ? shiftKey : 0))
    }

    /// The binding in force: the override if there is one (possibly cleared), else the default. nil = no shortcut.
    func effective(_ hk: Hotkey) -> KeyBinding? {
        let b = overrides[hk.id] ?? defaultBinding(hk)
        return b.isCleared ? nil : b
    }

    func isCustom(_ hk: Hotkey) -> Bool { overrides[hk.id] != nil }

    /// Keycap strings for UI ("⌃","⌥","K"); empty when unbound. Defaults keep their table label, so a layout without
    /// Latin letters still reads "Z"; recorded keys are named by what the current layout types on that physical key.
    func keys(for hk: Hotkey) -> [String] {
        guard let b = effective(hk) else { return [] }
        if overrides[hk.id] == nil, hk.widthKey { return ["⌃", "⌥", "⌘", hk.keyLabel] }
        if overrides[hk.id] == nil, hk.allMods { return ["⌃", "⌥", "⇧", "⌘", hk.keyLabel] }
        if overrides[hk.id] == nil { return modifier.keys(shift: hk.shift, hk.keyLabel) }
        return label(b)
    }

    func label(_ b: KeyBinding) -> [String] { KeyBinding.glyphs(b.modifiers) + [KeyBinding.keyLabel(b.keyCode, translate: translate)] }
    func text(_ b: KeyBinding) -> String { label(b).joined() }

    // MARK: checks

    /// The other Ribbon action that already uses this combo.
    func conflict(_ b: KeyBinding, excluding id: String) -> Hotkey? {
        Hotkeys.table.first { $0.id != id && effective($0) == b }
    }

    func verdict(_ b: KeyBinding, for id: String) -> ShortcutVerdict {
        guard b.isAcceptable else { return .needsModifier }
        if let hk = Hotkeys.table.first(where: { $0.id == id }), effective(hk) == b { return .unchanged }
        if systemKeys().contains(where: { $0.keyCode == b.keyCode && $0.modifiers == b.modifiers }) { return .system }
        if let other = conflict(b, excluding: id) { return .usedBy(id: other.id, title: other.title) }
        return .save
    }

    // MARK: edits (each persists and notifies)

    func set(_ id: String, _ b: KeyBinding) {
        guard let hk = Hotkeys.table.first(where: { $0.id == id }) else { return }
        if b == defaultBinding(hk) { overrides[id] = nil } else { overrides[id] = b }
        persist()
    }
    func clear(_ id: String) { set(id, .cleared) }
    func reset(_ id: String) { overrides[id] = nil; persist() }
    func resetAll() { overrides = [:]; persist() }
    func replace(_ b: KeyBinding, for id: String, taking otherID: String) { overrides[otherID] = .cleared; set(id, b) }

    private func persist() {
        let all = overrides.merging(foreign) { mine, _ in mine }
        if all.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else { defaults.set(all.mapValues(\.encoded), forKey: Self.defaultsKey) }
        onChange?()
    }

    // MARK: recording

    func beginRecording(_ id: String) {
        if recording == id { endRecording(); return }
        ensureKey()
        if recording == nil {
            suspendHotkeys()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
                guard let self else { return e }
                return MainActor.assumeIsolated { self.handle(e) }
            }
        }
        recording = id; notice = nil; held = []
    }

    /// Every way out of recording ends here: save, cancel, clear, sheet closed, focus lost.
    func endRecording() {
        guard recording != nil else { return }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = nil; notice = nil; held = []
        resumeHotkeys()
    }

    func confirmReplace() {
        guard let id = recording, case .replace(let b, let other, _)? = notice else { return }
        replace(b, for: id, taking: other)
        endRecording()
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let id = recording else { return e }
        if e.type == .flagsChanged { held = KeyBinding.glyphs(KeyBinding.carbon(e.modifierFlags)); return e }
        if e.isARepeat { return nil }
        let mods = KeyBinding.carbon(e.modifierFlags)
        let code = Int(e.keyCode)
        if mods == 0 {
            if code == kVK_Escape { endRecording(); return nil }
            if code == kVK_Delete || code == kVK_ForwardDelete { clear(id); endRecording(); return nil }
        }
        capture(KeyBinding(keyCode: code, modifiers: mods), for: id)
        return nil
    }

    /// Apply a pressed combo to the action being recorded.
    func capture(_ b: KeyBinding, for id: String) {
        switch verdict(b, for: id) {
        case .needsModifier: notice = .warning("Add ⌃, ⌥ or ⌘ to the shortcut")
        case .system: notice = .warning("macOS already uses \(text(b))")
        case .usedBy(let other, let title): notice = .replace(b, otherID: other, otherTitle: title)
        case .unchanged: endRecording()
        case .save:
            if canRegister(b) { set(id, b); endRecording() }
            else { notice = .warning("Another app already uses \(text(b))") }
        }
    }
}
