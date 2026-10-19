import CoreGraphics
import Foundation

/// Pure rules for the "refused size" reconcile pass.
enum Reconcile {
    /// Slack for rounding and window-server snapping, in points.
    static let slack: CGFloat = 2

    /// A window may have its live size adopted as its column width only while both its planned and its live frame lie fully
    /// inside the managed display. Partly off-screen windows (scrolled past an edge, straddling the next display) get
    /// clamped or reshaped by macOS and their apps; adopting that would silently resize neighbours of a new window.
    static func eligible(planned: CGRect, live: CGRect, display: CGRect) -> Bool {
        let box = display.insetBy(dx: -slack, dy: -slack)
        return box.contains(planned) && box.contains(live)
    }

    /// What was last reported to the core for a mismatching window.
    struct Attempt: Equatable { var live: CGSize; var plannedWidth: CGFloat }

    /// Whether a window whose live size differs from its plan should be reported (`.windowRefused`) again. The same live size
    /// against the same planned width was already tried (no write loops); a changed planned width is a new situation.
    static func shouldRefuse(last: Attempt?, live: CGSize, plannedWidth: CGFloat) -> Bool {
        last != Attempt(live: live, plannedWidth: plannedWidth)
    }

    /// Last line of defence against write loops: a window reported as refusing more than `burst` times inside `window`
    /// seconds is left alone (whatever the reason the plan keeps changing under it). `times` are its recent reports.
    static let burst = 6, burstWindow: TimeInterval = 3
    static func throttled(_ times: [Date], now: Date) -> Bool {
        times.filter { now.timeIntervalSince($0) < burstWindow }.count >= burst
    }

    // MARK: periodic check (stability)

    /// How far (points) a window's position may sit from its plan before it counts as drift.
    static let driftTolerance: CGFloat = 8

    /// Windows whose live position is off the plan on two checks in a row. One bad reading is only a suspect (an app
    /// mid-animation, a drag in progress); a drift that persists is corrected. `suspects` feeds the next call as `previous`.
    static func drifted(planned: [UInt32: CGRect], live: [UInt32: CGRect], previous: Set<UInt32>) -> (fix: [UInt32], suspects: Set<UInt32>) {
        var fix: [UInt32] = [], suspects = Set<UInt32>()
        for (id, want) in planned.sorted(by: { $0.key < $1.key }) {
            guard let now = live[id] else { continue }
            guard abs(now.minX - want.minX) > driftTolerance || abs(now.minY - want.minY) > driftTolerance else { continue }
            if previous.contains(id) { fix.append(id) } else { suspects.insert(id) }
        }
        return (fix, suspects)
    }

    /// A periodic check never competes with the user or with our own motion.
    static func mayCheck(started: Bool, paused: Bool, writing: Bool, scrolling: Bool, overlayUp: Bool, mouseDown: Bool) -> Bool {
        started && !paused && !writing && !scrolling && !overlayUp && !mouseDown
    }

    /// The window's size differs from the plan by more than rounding.
    static func sizeDrifted(planned: CGRect, live: CGRect) -> Bool {
        abs(live.width - planned.width) > 1.5 || abs(live.height - planned.height) > 1.5
    }
}
