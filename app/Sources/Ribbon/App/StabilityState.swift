import Foundation

/// Mutable state of the periodic check (kept out of Controller). Main thread only.
@MainActor
final class StabilityState {
    /// Windows that were off their planned position on the last check.
    var suspects: Set<UInt32> = []
    /// Floating windows that were ever parked: their remembered "home" is not a plan, so they are never drift-corrected.
    var floats: Set<UInt32> = []
    var timer: Timer?
    var watchingTrackpad = false
}

/// Set from an event-monitor callback, read on main.
final class ActivityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}
