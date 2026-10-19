import AppKit

/// Pure state machine for "hold the Ribbon modifier to show the map". Driven by timestamps, so it is testable.
/// Idle -> pending (modifier held alone) -> shown after `showDelay` -> hiding on release -> idle after `hideDelay`.
/// Any key while pending cancels (it is a normal hotkey); extra modifiers cancel too, until everything is released.
struct ModifierHoldMachine {
    enum Effect: Equatable { case none, show, hide }
    private enum State: Equatable { case idle, pending(Double), shown, hiding(Double), cancelled }
    var showDelay = 0.35
    var hideDelay = 0.4
    private var state = State.idle

    var isShown: Bool { if case .shown = state { true } else if case .hiding = state { true } else { false } }

    /// `held`: exactly the preset modifiers are down. `any`: some modifier is down.
    mutating func flags(held: Bool, any: Bool, at t: Double) {
        switch state {
        case .idle: if held { state = .pending(t) }
        case .pending: if !held { state = any ? .cancelled : .idle }
        case .shown: if !held { state = .hiding(t) }
        case .hiding: if held { state = .shown }
        case .cancelled: if !any { state = .idle }
        }
    }

    mutating func keyDown(at t: Double) {
        if case .pending = state { state = .cancelled }
    }

    /// Call when the deadline passes.
    mutating func tick(at t: Double) -> Effect {
        switch state {
        case .pending(let s) where t >= s + showDelay: state = .shown; return .show
        case .hiding(let s) where t >= s + hideDelay: state = .idle; return .hide
        default: return .none
        }
    }

    /// When `tick` next has something to do.
    var deadline: Double? {
        switch state {
        case .pending(let s): s + showDelay
        case .hiding(let s): s + hideDelay
        default: nil
        }
    }

    mutating func reset() { state = .idle }
}

extension ModifierChoice {
    var eventFlags: NSEvent.ModifierFlags {
        switch self { case .ctrlOpt: [.control, .option]; case .ctrlCmd: [.control, .command]; case .hyper: [.control, .option, .command] }
    }
}

/// Watches modifier flags and key presses (global + local) and reports hold-to-show / release.
@MainActor
final class ModifierHold {
    var onShow: () -> Void = {}
    var onHide: () -> Void = {}
    /// Asked at show time: false while paused, disabled in Settings, or the command bar is open.
    var isEnabled: () -> Bool = { true }
    var modifier: ModifierChoice = .ctrlOpt
    private var machine = ModifierHoldMachine()
    private var monitors: [Any] = []
    private var timer: Task<Void, Never>?
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let type = e.type, flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(type, flags) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            let type = e.type, flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(type, flags) }
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        timer?.cancel()
        if machine.isShown { onHide() }
        machine.reset()
    }

    /// Hotkeys are Carbon-registered and may never reach the monitors: the controller reports them here.
    func keyPressed() {
        machine.keyDown(at: now)
        reschedule()
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func handle(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) {
        if type == .keyDown { machine.keyDown(at: now) }
        else {
            let f = flags.intersection(Self.relevant)
            machine.flags(held: f == modifier.eventFlags, any: !f.isEmpty, at: now)
        }
        reschedule()
    }

    private func reschedule() {
        timer?.cancel()
        guard let d = machine.deadline else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(d - ProcessInfo.processInfo.systemUptime, 0)))
            guard !Task.isCancelled, let self else { return }
            switch self.machine.tick(at: max(d, self.now)) {
            case .show: if self.isEnabled() { self.onShow() }
            case .hide: self.onHide()
            case .none: break
            }
            self.reschedule()
        }
    }
}
