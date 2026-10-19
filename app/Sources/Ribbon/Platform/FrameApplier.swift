import AppKit
import ApplicationServices

/// Applies plans on one serial queue PER APP (`AXQueues`), so an app that stops answering only stalls its own windows.
/// Newer plans supersede queued writes (latest frame per window wins; stale queued writes are dropped), our own AX echoes are
/// recognised for a short window afterwards, and an app that `AXHealth` calls unresponsive is skipped: its newest frames stay
/// queued and are written when it recovers.
///
/// Windows that merely slide (`StripMove`) are not written here: they glide on the display link through `swipe`, all on one
/// clock. What is left (size changes, desktop switches, new windows, Reduce Motion) is written at once, and keyboard focus
/// and raise are issued right away, in parallel with the glide. A plan that resizes a window glides nothing: the resized window
/// and the ones that make room for it or fill the room it leaves are written in the same step, each app's windows in the order
/// in which none lies over one that has not moved yet.
final class FrameApplier: @unchecked Sendable {
    private let lock = NSLock()
    /// `rank`: its place among the windows of a plan that resizes (`WriteOrder`); 0 for the rest, which keep the visible-first order.
    private struct Job { let el: AXUIElement; let rect: CGRect; let onScreen: Bool; var rank = 0 }
    private var jobs = CoalescedJobs<Job>()
    /// Three-finger swipe and keyboard glides: display-paced, per-app concurrent position writes.
    let swipe = SwipeWriter()
    private let health = AXHealth.shared
    private var pendingFocus: AXUIElement?
    private var pendingFocusPID: pid_t = 0
    private var afterFocus: (@MainActor () -> Void)?
    private var draining = Set<pid_t>()
    private var echoUntil = Date.distantPast
    private var lastWritten: [UInt32: CGRect] = [:]
    private var lastWriteAt: [UInt32: Date] = [:]
    private var lastRefusedSize: [UInt32: CGSize] = [:]
    /// Called on the main queue when an app refused our size and settled on `frame` (once per distinct refusal).
    var onRefused: (@Sendable (UInt32, CGRect) -> Void)?

    init() {
        swipe.health = health
        health.onChange { [weak self] pid, change in if change == .recovered { self?.kick(pid) } }
    }

    /// True when an AX resize/move notification for this window is probably the echo of our own write.
    func isEcho(id: UInt32, frame: CGRect) -> Bool {
        if swipe.isEcho(id) { return true }
        lock.lock(); defer { lock.unlock() }
        if let t = lastWriteAt[id], Date().timeIntervalSince(t) < 0.25 { return true }
        guard let w = lastWritten[id] else { return false }
        return abs(w.width - frame.width) < 3 && abs(w.height - frame.height) < 3
    }

    /// True while our own writes are queued, running, or just finished (moves seen now are not the user's).
    var isBusy: Bool {
        if swipe.isBusy { return true }
        lock.lock(); defer { lock.unlock() }
        return !draining.isEmpty || Date() < echoUntil
    }

    /// `glide`: the windows of this plan that slide instead of jumping (the caller starts the display link). `before`: the frames
    /// the windows were planned at, on the display `visible` (only read for a plan that resizes). `afterFocus` runs on the main
    /// queue once the focus raise was issued and the app activated (the pinned column is raised above it again).
    @MainActor
    func apply(_ plan: Plan, elements: [UInt32: AXUIElement], glide: [UInt32: StripMove] = [:], before: [UInt32: CGRect] = [:], visible: CGRect = .infinite,
               afterFocus: (@MainActor () -> Void)? = nil) {
        lock.lock()
        // A write still queued for the window (a resize the app has not seen yet) must land: that window jumps, with the full frame.
        let glide = glide.filter { id, _ in elements[id].map { jobs.pending(id, pid: $0.pid) == nil } ?? false }
        lock.unlock()
        swipe.interrupt(plan.changed.filter { glide[$0] == nil })
        var rank: [UInt32: Int] = [:]
        if !plan.jump {
            let new = Dictionary(plan.frames.filter { f in plan.changed.contains(f.id) && glide[f.id] == nil }.map { ($0.id, $0.cg) }, uniquingKeysWith: { $1 })
            if new.contains(where: { id, r in before[id].map { StripMove.resizes($0, r) } ?? false }) { rank = WriteOrder.rank(old: before, new: new, within: visible) }
        }
        lock.lock()
        for id in plan.changed {
            if glide[id] != nil { jobs.remove(id); continue }   // the glide owns it: whatever was queued for it is stale
            if let f = plan.frames.first(where: { $0.id == id }), let el = elements[id] {
                jobs.post(id, pid: el.pid, Job(el: el, rect: f.cg, onScreen: f.onScreen, rank: rank[id] ?? 0))
            }
        }
        if let id = plan.focus, let el = elements[id] { pendingFocus = el; pendingFocusPID = el.pid; self.afterFocus = afterFocus }
        echoUntil = Date().addingTimeInterval(0.25)
        let start = startable()
        lock.unlock()
        swipe.glide(glide.compactMap { id, move in elements[id].map { (id: id, el: $0, move: move) } }, at: CACurrentMediaTime())
        for pid in start { AXQueues.shared.queue(pid).async { self.drain(pid) } }
    }

    /// Writes these windows to these frames without animation (periodic drift correction). Same queues, same coalescing.
    @MainActor
    func rewrite(_ items: [(id: UInt32, rect: CGRect, onScreen: Bool)], elements: [UInt32: AXUIElement]) {
        lock.lock()
        for it in items { if let el = elements[it.id] { jobs.post(it.id, pid: el.pid, Job(el: el, rect: it.rect, onScreen: it.onScreen)); swipe.forget(it.id) } }
        echoUntil = Date().addingTimeInterval(0.25)
        let start = startable()
        lock.unlock()
        for pid in start { AXQueues.shared.queue(pid).async { self.drain(pid) } }
    }

    /// The user took hold of this window: whatever was queued for it (including frames held back for an unresponsive app) is stale.
    func drop(_ id: UInt32) { lock.lock(); jobs.remove(id); lock.unlock(); swipe.forget(id) }

    /// Apps with work queued that are not being drained and not quarantined (lock held); marks them draining.
    private func startable() -> [pid_t] {
        var pids = jobs.pids
        if pendingFocus != nil { pids.append(pendingFocusPID) }
        var out: [pid_t] = []
        for pid in Set(pids) where !draining.contains(pid) && !health.isQuarantined(pid) { draining.insert(pid); out.append(pid) }
        return out
    }

    /// A quarantined app answered again: write its newest frames.
    private func kick(_ pid: pid_t) {
        lock.lock()
        let go = (jobs.hasPending(pid) || (pendingFocus != nil && pendingFocusPID == pid)) && !draining.contains(pid)
        if go { draining.insert(pid) }
        lock.unlock()
        if go { AXQueues.shared.queue(pid).async { self.drain(pid) } }
    }

    /// Drops queued work and waits (at most ~1.5 s: a hung app must not hold up quitting) for in-flight writes.
    func cancelAndWait() {
        lock.lock(); jobs.removeAll(); pendingFocus = nil; afterFocus = nil; let busy = draining; lock.unlock()
        let g = DispatchGroup()
        for pid in busy { g.enter(); AXQueues.shared.queue(pid).async { g.leave() } }
        _ = g.wait(timeout: .now() + 1.5)
        swipe.cancelGlide()
        swipe.interrupt([])
        swipe.waitIdle()
    }

    /// Runs on the app's queue until nothing is left for it.
    private func drain(_ pid: pid_t) {
        while true {
            lock.lock()
            if health.isQuarantined(pid) { draining.remove(pid); lock.unlock(); return }   // frames stay queued for the recovery
            let batch = jobs.take(pid: pid)
            if batch.isEmpty {
                let focus = pendingFocusPID == pid ? pendingFocus : nil
                if focus == nil { draining.remove(pid); lock.unlock(); return }
                pendingFocus = nil
                let done = afterFocus; afterFocus = nil
                lock.unlock()
                let err = focus!.focusWindowStatus()
                health.record(pid, err)
                DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate(); if let done { MainActor.assumeIsolated { done() } } }
                lock.lock(); echoUntil = Date().addingTimeInterval(0.25); lock.unlock()
                continue
            }
            lock.unlock()
            swipe.waitIdle(pid: pid)
            // Windows that end up visible first, so a desktop switch shows the new desktop before the old one is parked; a plan that
            // resizes puts them in the order in which none lies over a neighbour that has not moved yet.
            for (id, job) in batch.sorted(by: { ($0.value.rank, $0.value.onScreen ? 0 : 1, $0.key) < ($1.value.rank, $1.value.onScreen ? 0 : 1, $1.key) }) {
                if health.isQuarantined(pid) { lock.lock(); jobs.postIfAbsent(id, pid: pid, job); lock.unlock(); continue }
                write(id, job)
            }
            lock.lock(); echoUntil = Date().addingTimeInterval(0.25); lock.unlock()
        }
    }

    /// Writes the frame, reads it back, retries once, then accepts what the app settled on.
    private func write(_ id: UInt32, _ job: Job) {
        func off(_ f: CGRect) -> Bool {
            abs(f.minX - job.rect.minX) > 4 || abs(f.minY - job.rect.minY) > 4
                || abs(f.width - job.rect.width) > 4 || abs(f.height - job.rect.height) > 4
        }
        var settled = job.rect
        let pid = job.el.pid
        lock.lock(); lastWriteAt[id] = Date(); lock.unlock()
        var err = AXError.success
        let ran = AXUIElement.withoutEnhancedUI(pid: pid) {
            if let cur = job.el.size, abs(cur.width - job.rect.width) < 1, abs(cur.height - job.rect.height) < 1 {
                err = job.el.setPosition(job.rect.origin)   // same size (the usual case when parking): one write is enough
            } else {
                err = job.el.setFrame(job.rect)
            }
            guard err == .success, var got = job.el.frame, off(got) else { return }
            usleep(30_000)
            err = job.el.setFrame(job.rect)
            got = job.el.frame ?? got
            if off(got) { settled = got }   // the app refused: remember what it did so the echo is recognised
        }
        health.record(pid, ran == .success ? err : ran)
        if ran != .success || err == .cannotComplete {   // unanswered: keep the frame queued, bookkeeping stays as it was
            lock.lock(); jobs.postIfAbsent(id, pid: pid, job); lock.unlock()
            return
        }
        lock.lock()
        lastWritten[id] = settled; lastWriteAt[id] = Date()
        let sizeRefused = abs(settled.width - job.rect.width) > 1.5 || abs(settled.height - job.rect.height) > 1.5
        let report = sizeRefused && lastRefusedSize[id] != settled.size
        lastRefusedSize[id] = sizeRefused ? settled.size : nil
        lock.unlock()
        if report, let cb = onRefused { DispatchQueue.main.async { cb(id, settled) } }
    }
}
