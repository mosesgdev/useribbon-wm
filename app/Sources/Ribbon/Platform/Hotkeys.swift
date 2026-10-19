import AppKit
import Carbon.HIToolbox

enum ModifierChoice: String, CaseIterable, Identifiable {
    case ctrlOpt, ctrlCmd, hyper
    var id: String { rawValue }
    var label: String { switch self { case .ctrlOpt: "⌃⌥"; case .ctrlCmd: "⌃⌘"; case .hyper: "Hyper (⌃⌥⌘)" } }
    var glyphs: String { switch self { case .ctrlOpt: "⌃⌥"; case .ctrlCmd: "⌃⌘"; case .hyper: "⌃⌥⌘" } }
    /// The same keys in words, for people who do not read the glyphs.
    var words: String { switch self { case .ctrlOpt: "Control + Option"; case .ctrlCmd: "Control + Command"; case .hyper: "Control + Option + Command" } }
    var carbon: UInt32 {
        switch self {
        case .ctrlOpt: UInt32(controlKey | optionKey)
        case .ctrlCmd: UInt32(controlKey | cmdKey)
        case .hyper: UInt32(controlKey | optionKey | cmdKey)
        }
    }
}

enum HotkeyAction: Equatable {
    case command(String, Int? = nil)
    case commandBar, pause
}

struct Hotkey {
    /// ANSI virtual keycode: used as is for arrows/Tab/Space/digits, and as the fallback for letters.
    let key: Int, shift: Bool, keyLabel: String, action: HotkeyAction, title: String, group: String
    /// Display moves and the go-to-window digits use ⌃⌥⇧⌘ whatever the preset (⌃⌥⌘ is the Hyper preset's plain modifier and
    /// ⌃⌥⌘⇧ its shifted one, so under Hyper they have no default key; the command bar still has them).
    var allMods = false
    /// Direct width keys add ⌘ to the preset (⌃⌥⌘1…6 by default); under Hyper every digit combination is taken, so no default.
    var widthKey = false

    /// The letter this shortcut is named after ("Z" for undo). Letters are resolved by the character the
    /// user's keyboard layout prints on the key, so ⌃⌥Z is the key labelled Z on QWERTZ too (not the one labelled Y).
    var letter: Character? {
        guard keyLabel.count == 1, let c = keyLabel.first, c.isASCII, c.isLetter else { return nil }
        return c
    }

    /// Stable action id, the key for saved overrides ("center", "unstack"; numbered actions get "#n").
    var id: String {
        switch action {
        case .command(let name, let n?): return "\(name)#\(n)"
        case .command(let name, nil): return name
        case .commandBar: return "command_bar"
        case .pause: return "pause"
        }
    }

    /// Desktops 1–9 and ⇧1–9 are customised as a group (by the preset), not one by one.
    /// The width steps and the go-to-window digits are individually recordable.
    var isRecordable: Bool { if case .command(let name, _?) = action { return name == "width_step" || name == "focus_index" }; return true }

    /// The virtual keycode to register on the given layout map.
    func keycode(in map: [Character: Int]) -> Int {
        letter.map { KeyLayout.keycode(for: $0, fallback: key, map: map) } ?? key
    }
}

/// Character -> keycode resolution for letter hotkeys. The map building and lookup are pure
/// (the keycode -> character translation is injected) so they can be tested without a keyboard.
enum KeyLayout {
    /// Keycodes that can type letters on any Mac layout (main block, ANSI and ISO), excluding the keypad.
    static let letterKeycodes = Array(0...50)

    /// `translate(keycode)` = the unshifted character that key types, or nil. Lowest keycode wins on duplicates.
    static func buildMap(translate: (Int) -> String?) -> [Character: Int] {
        var map: [Character: Int] = [:]
        for code in letterKeycodes {
            guard let s = translate(code), s.count == 1, let c = s.lowercased().first, c.isASCII, c.isLetter else { continue }
            if map[c] == nil { map[c] = code }
        }
        return map
    }

    static func keycode(for letter: Character, fallback: Int, map: [Character: Int]) -> Int {
        Character(letter.lowercased()).isASCII ? (map[Character(letter.lowercased())] ?? fallback) : fallback
    }

    /// Map for the current keyboard layout; letters it cannot type (e.g. Cyrillic layouts) come from the
    /// ASCII-capable layout instead, so every letter still lands on some key.
    static func currentMap() -> [Character: Int] {
        var map: [Character: Int] = [:]
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() { map = buildMap(translate: translator(src)) }
        if map.count < 26, let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            map.merge(buildMap(translate: translator(src))) { mine, _ in mine }
        }
        return map
    }

    /// keycode -> character on the current layout (nil when the layout has no key data).
    static func currentTranslator() -> (Int) -> String? {
        if let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) != nil { return translator(src) }
        if let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() { return translator(src) }
        return { _ in nil }
    }

    private static func translator(_ source: TISInputSource) -> (Int) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return { _ in nil } }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        return { code in
            guard let ptr = CFDataGetBytePtr(data) else { return nil }
            return ptr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
                return status == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len) : nil
            }
        }
    }
}

enum Hotkeys {
    /// Single source of truth: registration, the shortcuts sheet and the onboarding cheat sheet all read this.
    static let table: [Hotkey] = {
        var t: [Hotkey] = [
            Hotkey(key: kVK_LeftArrow, shift: false, keyLabel: "←", action: .command("focus_left"), title: "Glide left", group: "Move around"),
            Hotkey(key: kVK_RightArrow, shift: false, keyLabel: "→", action: .command("focus_right"), title: "Glide right", group: "Move around"),
            Hotkey(key: kVK_Tab, shift: false, keyLabel: "Tab", action: .command("focus_previous"), title: "Back to last window", group: "Move around"),
            Hotkey(key: kVK_UpArrow, shift: false, keyLabel: "↑", action: .command("focus_up"), title: "Up in a stack", group: "Move around"),
            Hotkey(key: kVK_DownArrow, shift: false, keyLabel: "↓", action: .command("focus_down"), title: "Down in a stack", group: "Move around"),
            // Home / End: first and last window. Not ←/→ with ⌘ added (display work uses those), and no letters left that read as "first".
            Hotkey(key: kVK_Home, shift: false, keyLabel: "↖", action: .command("focus_first"), title: "Go to first window", group: "Move around"),
            Hotkey(key: kVK_End, shift: false, keyLabel: "↘", action: .command("focus_last"), title: "Go to last window", group: "Move around"),
            Hotkey(key: kVK_LeftArrow, shift: true, keyLabel: "←", action: .command("move_left"), title: "Move column left", group: "Rearrange"),
            Hotkey(key: kVK_RightArrow, shift: true, keyLabel: "→", action: .command("move_right"), title: "Move column right", group: "Rearrange"),
            // ⇧Home / ⇧End carry the column to the start / end of the ribbon, as Home / End glide there; ⇧↑ / ⇧↓ move the window within its stack
            // (or the tab within its tab group), as ⇧← / ⇧→ move the column.
            Hotkey(key: kVK_Home, shift: true, keyLabel: "↖", action: .command("move_first"), title: "Move column to the start", group: "Rearrange"),
            Hotkey(key: kVK_End, shift: true, keyLabel: "↘", action: .command("move_last"), title: "Move column to the end", group: "Rearrange"),
            Hotkey(key: kVK_UpArrow, shift: true, keyLabel: "↑", action: .command("move_up"), title: "Move window up (in a stack)", group: "Rearrange"),
            Hotkey(key: kVK_DownArrow, shift: true, keyLabel: "↓", action: .command("move_down"), title: "Move window down (in a stack)", group: "Rearrange"),
            Hotkey(key: kVK_ANSI_R, shift: false, keyLabel: "R", action: .command("cycle_width"), title: "Next width", group: "Resize"),
            Hotkey(key: kVK_ANSI_R, shift: true, keyLabel: "R", action: .command("cycle_width_back"), title: "Previous width", group: "Resize"),
            // Nudges: W for wider, H for height, ⇧ for the other way (as ⇧R is the other way round). Letters rather than the = and -
            // keys: no shortcut uses punctuation (those keys sit elsewhere on other layouts, with other labels), and letters follow the layout.
            Hotkey(key: kVK_ANSI_W, shift: false, keyLabel: "W", action: .command("grow_width"), title: "Nudge wider", group: "Resize"),
            Hotkey(key: kVK_ANSI_W, shift: true, keyLabel: "W", action: .command("shrink_width"), title: "Nudge narrower", group: "Resize"),
            Hotkey(key: kVK_ANSI_V, shift: false, keyLabel: "V", action: .command("cycle_height"), title: "Change height (in a stack)", group: "Resize"),
            Hotkey(key: kVK_ANSI_H, shift: false, keyLabel: "H", action: .command("grow_height"), title: "Nudge taller (in a stack)", group: "Resize"),
            Hotkey(key: kVK_ANSI_H, shift: true, keyLabel: "H", action: .command("shrink_height"), title: "Nudge shorter (in a stack)", group: "Resize"),
            Hotkey(key: kVK_ANSI_E, shift: false, keyLabel: "E", action: .command("equalize_heights"), title: "Make heights equal (in a stack)", group: "Resize"),
            Hotkey(key: kVK_ANSI_F, shift: false, keyLabel: "F", action: .command("toggle_full"), title: "Full width", group: "Resize"),
            // Focus mode: blur everything but the window you are in. B for blur (F is Full width, and the F-row is theirs).
            Hotkey(key: kVK_ANSI_B, shift: false, keyLabel: "B", action: .command("toggle_focus"), title: "Focus mode (blur the rest)", group: "Ribbon"),
            Hotkey(key: kVK_ANSI_C, shift: false, keyLabel: "C", action: .command("center"), title: "Center", group: "Resize"),
            Hotkey(key: kVK_ANSI_S, shift: false, keyLabel: "S", action: .command("stack"), title: "Stack with the window on the left", group: "Rearrange"),
            Hotkey(key: kVK_ANSI_S, shift: true, keyLabel: "S", action: .command("unstack"), title: "Take out of stack", group: "Rearrange"),
            // G sits to the right of S on the keyboard: S stacks into the column on the left, G into the one on the right.
            Hotkey(key: kVK_ANSI_G, shift: false, keyLabel: "G", action: .command("stack_right"), title: "Stack with the window on the right", group: "Rearrange"),
            Hotkey(key: kVK_ANSI_Z, shift: false, keyLabel: "Z", action: .command("undo"), title: "Undo", group: "Oops"),
            Hotkey(key: kVK_ANSI_Z, shift: true, keyLabel: "Z", action: .command("redo"), title: "Redo", group: "Oops"),
            // Tabs took ⌃⌥T; Float / tile moved to its shifted sibling.
            Hotkey(key: kVK_ANSI_T, shift: false, keyLabel: "T", action: .command("toggle_tabs"), title: "Make tabs / toggle tabs", group: "Rearrange"),
            Hotkey(key: kVK_ANSI_T, shift: true, keyLabel: "T", action: .command("toggle_float"), title: "In or out of the ribbon", group: "Rearrange"),
            // ⌃⌥Tab is "back to last window", so tabs cycle on Page Down / Page Up (fn ↓ / ↑ on a laptop), like Home / End.
            // In a tabbed column ⌃⌥Tab / ⌃⌥⇧Tab step through the tabs (Controller turns "back to last window" into "next tab" there).
            Hotkey(key: kVK_Tab, shift: true, keyLabel: "Tab", action: .command("prev_tab_key"), title: "Previous tab (in a tabbed column)", group: "Move around"),
            Hotkey(key: kVK_PageDown, shift: false, keyLabel: "⇟", action: .command("next_tab"), title: "Next tab", group: "Move around"),
            Hotkey(key: kVK_PageUp, shift: false, keyLabel: "⇞", action: .command("prev_tab"), title: "Previous tab", group: "Move around"),
            Hotkey(key: kVK_Space, shift: false, keyLabel: "Space", action: .commandBar, title: "Find anything", group: "Find"),
            Hotkey(key: kVK_ANSI_P, shift: false, keyLabel: "P", action: .pause, title: "Pause for now", group: "Oops"),
        ]
        // Virtual desktops (OmniWM-style): ⌃⌥1…9 go there, ⌃⌥⇧1…9 send the window, ⌃⌥D toggles back.
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, k) in digits.enumerated() {
            t.append(Hotkey(key: k, shift: false, keyLabel: "\(i + 1)", action: .command("switch_desktop", i + 1), title: "Go to desktop \(i + 1)", group: "Desktops"))
        }
        for (i, k) in digits.enumerated() {
            t.append(Hotkey(key: k, shift: true, keyLabel: "\(i + 1)", action: .command("move_to_desktop", i + 1), title: "Send window to desktop \(i + 1)", group: "Desktops"))
        }
        // Direct widths: ⌃⌥⌘1 = the first step of the width list (25 %, or ⅓ in Simple) … ⌃⌥⌘6 = the sixth. The titles are
        // generic here; the shortcuts sheet and the command bar name the step the active list really has.
        for (i, k) in digits.prefix(6).enumerated() {
            t.append(Hotkey(key: k, shift: false, keyLabel: "\(i + 1)", action: .command("width_step", i + 1), title: "Width step \(i + 1)", group: "Resize", widthKey: true))
        }
        // Go to window n (the nth column of the ribbon, as the strip counts them): ⌃⌥⇧⌘1…9, the displays' chord. Every shorter
        // chord with a digit is taken (desktops, send to desktop, widths), and under Hyper this one too (its ⇧ digits send to a desktop),
        // so Hyper has no default; the command bar ("window 3") and recording still work.
        for (i, k) in digits.enumerated() {
            t.append(Hotkey(key: k, shift: false, keyLabel: "\(i + 1)", action: .command("focus_index", i + 1), title: "Go to window \(i + 1)", group: "Move around", allMods: true))
        }
        t.append(Hotkey(key: kVK_LeftArrow, shift: true, keyLabel: "←", action: .command("move_to_display_left"), title: "Move window to display on the left", group: "Displays", allMods: true))
        t.append(Hotkey(key: kVK_RightArrow, shift: true, keyLabel: "→", action: .command("move_to_display_right"), title: "Move window to display on the right", group: "Displays", allMods: true))
        t.append(Hotkey(key: kVK_ANSI_D, shift: false, keyLabel: "D", action: .command("switch_desktop_back"), title: "Back to last desktop", group: "Desktops"))
        // What the running edition's features add (Plus/ registers them; the free edition has none).
        return FeatureRegistry.shared.hotkeys(merging: t)
    }()
}

/// Carbon global hotkeys (no Input Monitoring permission needed).
@MainActor
final class HotkeyCenter {
    nonisolated(unsafe) fileprivate static var current: HotkeyCenter?
    var onAction: ((HotkeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private var store: ShortcutStore?
    private var suspended = false
    private var layoutObserver: NSObjectProtocol?
    /// Called after the hotkeys were re-registered because the keyboard layout changed.
    var onReregistered: (() -> Void)?
    /// Labels of shortcuts another app already owns (from the last `register`).
    private(set) var failures: [String] = []

    func register(_ store: ShortcutStore) {
        self.store = store
        if layoutObserver == nil {
            layoutObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let s = self.store else { return }
                    s.refreshLayout()
                    self.register(s)
                    self.onReregistered?()
                }
            }
        }
        unregister()
        guard !suspended else { return }
        installHandler()
        HotkeyCenter.current = self
        failures = []
        for (i, hk) in Hotkeys.table.enumerated() {
            guard let b = store.effective(hk) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5242_4E31), id: UInt32(i))
            let status = RegisterEventHotKey(UInt32(b.keyCode), UInt32(b.modifiers), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { failures.append(store.text(b)) }
        }
        if !failures.isEmpty { NSLog("ribbon: hotkeys unavailable (taken by another app): \(failures.joined(separator: ", "))") }
    }

    func unregister() { refs.forEach { UnregisterEventHotKey($0) }; refs = [] }

    /// Recording: let combos through to the sheet instead of firing actions.
    func suspend() { suspended = true; unregister() }
    func resume() { suspended = false; if let store { register(store) } }

    /// Can this combo be registered right now? (Registers and immediately releases it.)
    static func probe(_ b: KeyBinding) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(b.keyCode), UInt32(b.modifiers), EventHotKeyID(signature: OSType(0x5242_4E32), id: 0),
                                         GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    fileprivate func fire(index: Int) {
        guard Hotkeys.table.indices.contains(index) else { return }
        onAction?(Hotkeys.table[index].action)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.current?.fire(index: Int(id.id)) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotkeySelfTest {
    /// Registers the hotkeys, posts a synthetic ⌃⌥→ and waits up to 1s for the Carbon handler.
    /// Returns the exit code: 0 ok, 1 fail, 2 skipped (cannot post events: no TCC access or secure input).
    @MainActor
    static func run() -> Int32 {
        _ = NSApplication.shared
        let center = HotkeyCenter()
        var fired = false
        center.onAction = { if $0 == .command("focus_right") { fired = true } }
        center.register(ShortcutStore(defaults: UserDefaults(suiteName: "ribbon.hotkey-selftest")!))
        let blocked = !CGPreflightPostEventAccess() ? "no post-event permission" : IsSecureEventInputEnabled() ? "secure input / screen locked" : nil
        if let blocked {
            print("hotkey SKIP (\(blocked); real key presses needed)")
            return 2
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: down)
            e?.flags = [.maskControl, .maskAlternate]
            e?.post(tap: .cgSessionEventTap)
        }
        let deadline = Date().addingTimeInterval(1)
        while !fired && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        print(fired ? "hotkey ok" : "hotkey FAIL")
        return fired ? 0 : 1
    }
}
