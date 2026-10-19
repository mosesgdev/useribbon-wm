import AppKit
import ApplicationServices

// Stability plumbing for apps that stop answering Accessibility calls (an Electron app mid-load, a beachballing app).
//  - `AXQueues`: one serial queue per app, so a hung app only ever blocks its own AX work.
//  - `Quarantine`: pure counter + backoff that decides when an app counts as unresponsive.
//  - `AXHealth`: the thread-safe wrapper the writers report to; it probes quarantined apps and announces changes on main.
//  - `CoalescedJobs`: latest-wins job store per app.

/// One serial queue per pid. Every AX write and heavy read for an app runs on its queue.
final class AXQueues: @unchecked Sendable {
    static let shared = AXQueues()
    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]

    func queue(_ pid: pid_t) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "ribbon.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    func release(_ pid: pid_t) { lock.lock(); queues[pid] = nil; lock.unlock() }
}

/// Pure bookkeeping: consecutive AX failures per app within a window mark it unresponsive; retries back off 1, 2, 4... s up to 30 s.
struct Quarantine {
    static let threshold = 3
    static let window = 5.0
    static let maxBackoff = 30.0
    /// An app is only named once it has stayed unresponsive this long (a probe still fails after it): busy apps hiccup for a
    /// second or two all the time, and Ribbon leaves them alone quietly. With the 1, 2, 4, 8 s probes that is ~15 s of hang.
    static let announceAfter = 10.0
    /// Same app announced again no sooner than this.
    static let announceEvery = 3600.0

    /// `quarantined`: Ribbon stops writing to the app (quietly). `unresponsive`: it is still hung `announceAfter` later, and
    /// the user should hear about it. `recovered`: it answers again.
    enum Change: Equatable { case quarantined, unresponsive, recovered }

    private struct State { var failures: [Double] = []; var down = false; var attempts = 0; var retryAt = 0.0; var since = 0.0; var told = false }
    private var states: [pid_t: State] = [:]
    private var announced: [pid_t: Double] = [:]

    static func backoff(attempt: Int) -> Double { min(maxBackoff, pow(2, Double(max(0, attempt)))) }

    func isQuarantined(_ pid: pid_t) -> Bool { states[pid]?.down ?? false }
    func retryAt(_ pid: pid_t) -> Double? { states[pid].flatMap { $0.down ? $0.retryAt : nil } }
    var quarantined: [pid_t] { states.filter { $0.value.down }.map(\.key) }

    /// An AX call timed out or could not complete. While quarantined this is a failed probe: the next retry moves out.
    mutating func failure(_ pid: pid_t, at now: Double) -> Change? {
        var s = states[pid] ?? State()
        if s.down {
            s.attempts += 1
            s.retryAt = now + Self.backoff(attempt: s.attempts)
            guard !s.told, now - s.since >= Self.announceAfter else { states[pid] = s; return nil }
            s.told = true
            states[pid] = s
            guard announced[pid].map({ now - $0 > Self.announceEvery }) ?? true else { return nil }
            announced[pid] = now
            return .unresponsive
        }
        s.failures = s.failures.filter { now - $0 <= Self.window } + [now]
        guard s.failures.count >= Self.threshold else { states[pid] = s; return nil }
        s.down = true; s.attempts = 0; s.failures = []; s.since = now; s.told = false
        s.retryAt = now + Self.backoff(attempt: 0)
        states[pid] = s
        return .quarantined
    }

    /// An AX call worked: failures are not "consecutive" any more; a quarantined app is back.
    mutating func success(_ pid: pid_t) -> Change? {
        guard let s = states[pid] else { return nil }
        states[pid] = nil
        return s.down ? .recovered : nil
    }

    mutating func forget(_ pid: pid_t) { states[pid] = nil; announced[pid] = nil }
    /// After sleep/wake every app is briefly slow: start from a clean slate.
    mutating func reset() { states = [:] }
}

/// Latest-wins job store, one lane per app. Posting for a window replaces its queued job; taking a lane empties it.
struct CoalescedJobs<Job> {
    private var lanes: [pid_t: [UInt32: Job]] = [:]
    var isEmpty: Bool { lanes.isEmpty }
    func hasPending(_ pid: pid_t) -> Bool { !(lanes[pid]?.isEmpty ?? true) }
    func pending(_ id: UInt32, pid: pid_t) -> Job? { lanes[pid]?[id] }
    var pids: [pid_t] { Array(lanes.keys) }
    mutating func post(_ id: UInt32, pid: pid_t, _ job: Job) { lanes[pid, default: [:]][id] = job }
    mutating func postIfAbsent(_ id: UInt32, pid: pid_t, _ job: Job) { if lanes[pid]?[id] == nil { post(id, pid: pid, job) } }
    mutating func take(pid: pid_t) -> [UInt32: Job] { lanes.removeValue(forKey: pid) ?? [:] }
    mutating func removeAll() { lanes = [:] }
    /// Forgets any queued job for this window (it is being dragged by the user).
    mutating func remove(_ id: UInt32) { for p in lanes.keys { lanes[p]?[id] = nil } }
}

/// Thread-safe front for `Quarantine`. Writers report each AX result; a quarantined app is probed with backoff.
final class AXHealth: @unchecked Sendable {
    static let shared = AXHealth()
    private let lock = NSLock()
    private var q = Quarantine()
    private var probing = Set<pid_t>()
    /// Called on the main queue when an app turns unresponsive (announce: show the toast) or recovers.
    private var listeners: [@Sendable (pid_t, Quarantine.Change) -> Void] = []

    func onChange(_ f: @escaping @Sendable (pid_t, Quarantine.Change) -> Void) { lock.lock(); listeners.append(f); lock.unlock() }

    func isQuarantined(_ pid: pid_t) -> Bool { lock.lock(); defer { lock.unlock() }; return q.isQuarantined(pid) }

    /// Feed an AX result. Only "cannot complete" (timeout, hung app) counts as a failure; other errors say nothing about health.
    func record(_ pid: pid_t, _ err: AXError) {
        switch err {
        case .success: note(pid, success: true)
        case .cannotComplete: note(pid, success: false)
        default: break
        }
    }

    private func note(_ pid: pid_t, success: Bool) {
        let now = CACurrentMediaTime()
        lock.lock()
        let change = success ? q.success(pid) : q.failure(pid, at: now)
        var probeIn: Double?
        if case .quarantined = change { probeIn = max(0, (q.retryAt(pid) ?? now) - now) }
        let fns = listeners
        lock.unlock()
        if let probeIn { schedule(pid, after: probeIn) }
        if let change { DispatchQueue.main.async { fns.forEach { $0(pid, change) } } }
    }

    private func schedule(_ pid: pid_t, after delay: Double) {
        lock.lock(); let fresh = probing.insert(pid).inserted; lock.unlock()
        guard fresh else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            AXQueues.shared.queue(pid).async { self.probe(pid) }
        }
    }

    /// Cheap read on the app's own queue. Success lifts the quarantine; failure pushes the next probe out.
    private func probe(_ pid: pid_t) {
        lock.lock(); probing.remove(pid); let still = q.isQuarantined(pid); lock.unlock()
        guard still else { return }
        if kill(pid, 0) != 0 { forget(pid); return }   // the app is gone
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &ref)
        record(pid, err == .cannotComplete ? .cannotComplete : .success)   // any answer at all means the app is alive
        lock.lock(); let down = q.isQuarantined(pid); let at = q.retryAt(pid); lock.unlock()
        if down, let at { schedule(pid, after: max(0, at - CACurrentMediaTime())) }
    }

    func forget(_ pid: pid_t) { lock.lock(); q.forget(pid); lock.unlock() }

    /// Sleep/wake: forget every count; quarantined apps are told they recovered so queued frames get applied.
    func reset() {
        lock.lock(); let down = q.quarantined; q.reset(); let fns = listeners; lock.unlock()
        DispatchQueue.main.async { for p in down { fns.forEach { $0(p, .recovered) } } }
    }
}
