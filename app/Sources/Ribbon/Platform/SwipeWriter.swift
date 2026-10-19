import AppKit
import ApplicationServices

/// Drives the display-paced AX writes of a three-finger swipe and its settle.
///
/// - One write batch per display frame. Targets are latest-wins: a newer position replaces an older one that was not
///   written yet; nothing queues up.
/// - Writes run concurrently across apps (one serial queue per pid, so a slow app only delays itself). An app whose previous
///   batch is still running is skipped this frame and gets its newest position next frame.
/// - Only windows whose rounded position moved by at least 1px are written; windows that stay parked off-screen are written once.
/// - After release the windows glide to the core's settled layout on a critically damped spring, through the same writer; a
///   window that ends parked keeps sliding off until it reaches its sliver, one that appears slides in when the strip reaches it.
/// - A keyboard move (`glide`) rides the same clock and writer: every window follows its logical x on a critically damped
///   spring started at the same moment, so the strip stays rigid, and a newer command retargets from the springs' position
///   and velocity.
///
/// `post`/`step`/`settle` run on the main thread; the pid queues only call `setPosition`.
final class SwipeWriter: @unchecked Sendable {
    struct Target { let el: AXUIElement; let pid: pid_t; var pos: CGPoint; var onScreen: Bool; var posted: Double }

    private var latest = LatestWins<UInt32, Target>()
    private var planner = WritePlanner()
    private var shown: [UInt32: Bool] = [:]            // last posted onScreen per window (main thread)
    /// A window sliding to its settled place. `lo`/`hi`: the parked edges it is held at while its logical x is beyond them (a window
    /// that parks stops at its sliver; one that appears stays there until the strip reaches it).
    private struct Spring { let x: CriticalSpring; let lo: Double?, hi: Double?; let final: Target }
    private var springs: [UInt32: Spring] = [:]
    private var settleStart = 0.0
    private var settling = false
    private var strips: [UInt32: Strip] = [:]          // keyboard glides in flight
    private var quieted = Set<pid_t>()                 // apps whose AXEnhancedUserInterface is off for the glide (main thread)
    private var enhancedWas = Set<pid_t>()             // ... and had it on (lock)
    private var glideSeq = 0                           // one number per `glide` call: its new strips share a clock
    var onSettled: (() -> Void)?
    /// Unresponsive apps are skipped and every write result is reported (set by FrameApplier).
    var health: AXHealth?
    /// The position write itself, on the app's queue (the self test swaps it for a recorder).
    var write: @Sendable (UInt32, AXUIElement, CGPoint) -> AXError = { $1.setPosition($2) }
    /// Switches the app's AXEnhancedUserInterface off for a glide, on its queue. True when it was on (to be put back), false when
    /// it was off, nil when the app did not answer (the self test swaps it).
    var quiet: @Sendable (pid_t) -> Bool? = { pid in
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &ref) != .cannotComplete else { return nil }
        guard (ref as? NSNumber)?.boolValue == true else { return false }
        app.set("AXEnhancedUserInterface", kCFBooleanFalse)
        return true
    }

    private let lock = NSLock()
    private var inflight: [pid_t: Int] = [:]
    private var queues: [pid_t: DispatchQueue] = [:]
    private let group = DispatchGroup()
    private var wroteAt: [UInt32: Double] = [:]
    private var lastAny = -1.0
    private var timeoutSet = Set<UInt32>()

    // MARK: state queries

    /// True while there is anything left to do (glide running, undelivered targets, writes in flight).
    var active: Bool { lock.lock(); defer { lock.unlock() }; return settling || !strips.isEmpty || !latest.isEmpty || !inflight.isEmpty }
    var isSettling: Bool { settling }
    /// A keyboard glide is moving this window.
    func isGliding(_ id: UInt32) -> Bool { strips[id] != nil }
    /// A keyboard glide, or the settle after a swipe, is moving this window.
    func rides(_ id: UInt32) -> Bool { strips[id] != nil || springs[id] != nil }
    /// Where the window really is (last position written), for the focus ring.
    func position(_ id: UInt32) -> CGPoint? { planner.lastSent(id) }
    /// Whether the window was last written shown (not parked); nil when this writer has not placed it.
    func isShown(_ id: UInt32) -> Bool? { shown[id] }
    /// A move/resize notification for `id` shortly after one of our writes is our own echo.
    func isEcho(_ id: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return wroteAt[id].map { CACurrentMediaTime() - $0 < 0.25 } ?? false }
    /// A glide whose display link stopped (display change, sleep) must not read as busy forever: past its longest run it is stale.
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        return settling || strips.values.contains { now - $0.born < 2 } || !inflight.isEmpty || !latest.isEmpty || now - lastAny < 0.25
    }

    // MARK: input (main thread)

    func post(_ id: UInt32, el: AXUIElement, rect: CGRect, onScreen: Bool, at now: Double) {
        if timeoutSet.insert(id).inserted { AXUIElementSetMessagingTimeout(el, 0.25) }   // a hung app only stalls its own queue, briefly
        latest.post(id, Target(el: el, pid: el.pid, pos: rect.origin, onScreen: onScreen, posted: now))
        shown[id] = onScreen
    }

    /// Someone else moved windows: forget what we wrote, drop the glide (the caller's plan wins).
    func interrupt(_ ids: [UInt32]) {
        guard !ids.isEmpty else { return }
        for id in ids { _ = latest.take([id]); planner.forget(id); shown[id] = nil; springs[id] = nil; strips[id] = nil }
        if springs.isEmpty { settling = false }
        _ = group.wait(timeout: .now() + 1.5)   // a hung app must not freeze the caller
    }

    /// The window is gone (closed, minimized, hidden): nothing more to write for it.
    func forget(_ id: UInt32) { strips[id] = nil; springs[id] = nil; _ = latest.take([id]); planner.forget(id) }

    /// Fingers are down again: land the glide where the core put it, so the new scroll continues from consistent positions.
    func cancelSettle(at now: Double) {
        for (id, s) in strips { var t = s.final; t.posted = now; latest.post(id, t) }
        strips = [:]
        guard settling else { return }
        for (id, s) in springs { var t = s.final; t.posted = now; latest.post(id, t) }
        springs = [:]; settling = false
    }

    /// Glide to the core's settled layout. `velocity` is the windows' px/s at release (+ = right). `moves`: the windows that slide
    /// there on the spring, in the ribbon's logical space (`StripMove.release`): a window that ends parked keeps sliding off
    /// until it reaches its sliver, one that appears waits at its sliver until the strip reaches it, so the strip stays rigid and
    /// nothing hangs in the way of its neighbours. Every other changed window is written at once.
    func settle(to targets: [UInt32: Target], moves: [UInt32: StripMove], velocity: Double, at now: Double) {
        springs = [:]
        for id in targets.keys { strips[id] = nil }
        for (id, t) in targets {
            if let m = moves[id] {
                if timeoutSet.insert(id).inserted { AXUIElementSetMessagingTimeout(t.el, 0.25) }
                if planner.lastSent(id) == nil { planner.record(id, WritePlanner.rounded(m.from)) }   // a window the swipe never moved
                springs[id] = Spring(x: CriticalSpring(from: m.lxFrom, target: m.lxTo, velocity: velocity), lo: m.lo, hi: m.hi, final: t)
                shown[id] = t.onScreen
                continue
            }
            if let cur = planner.lastSent(id), abs(cur.x - t.pos.x) < 1, abs(cur.y - t.pos.y) < 1 { continue }
            latest.post(id, t); shown[id] = t.onScreen
        }
        settleStart = now
        settling = !springs.isEmpty
        if !settling { DispatchQueue.main.async { [self] in onSettled?() } }
    }

    // MARK: frame

    /// One display frame: advance the glide, then write what moved.
    func step(at now: Double) {
        if !strips.isEmpty { advanceStrips(at: now) }
        if settling {
            let t = now - settleStart
            let done = t > 1.2 || springs.values.allSatisfy { $0.x.settled(at: t) }
            for (id, s) in springs {
                var tg = s.final
                tg.pos = done ? s.final.pos : CGPoint(x: StripMove.hold(s.x.value(at: t), lo: s.lo, hi: s.hi), y: s.final.pos.y)
                tg.posted = now
                latest.post(id, tg)
            }
            if done {
                springs = [:]; settling = false
                DispatchQueue.main.async { [self] in onSettled?() }
            }
        }
        flush(at: now)
        if strips.isEmpty, latest.isEmpty, !quieted.isEmpty { restoreEnhancedUI() }
    }

    // MARK: keyboard glide

    /// One window riding the strip. Its logical x (the ribbon's own coordinate, parking ignored) and y follow springs that
    /// started at the same moment; the shown x is the logical one held at the parked edges.
    private struct Strip {
        let el: AXUIElement, pid: pid_t
        let x: CriticalSpring, y: CriticalSpring
        let lo: Double?, hi: Double?
        let final: Target
        let born: Double
        let group: Int
        var t0: Double?        // nil until the clock of its move starts (`startClocks`): the motion starts there, not at the keypress (a move that joins glides in flight starts at once)
        func shown(at t: Double) -> CGPoint { CGPoint(x: StripMove.hold(x.value(at: t), lo: lo, hi: hi), y: y.value(at: t)) }
    }

    /// Stiffness of the keyboard glide: ~95% of a move in 150 ms, settled to the pixel in ~330 ms, and no display frame (60 Hz)
    /// covers more than a fifth of the way.
    static let glideOmega = 30.0
    /// The longest a move waits for its apps to be ready before it starts anyway: a slow or hung app must not hold the others back.
    static let startWait = 0.08

    /// Starts (or retargets) the glide of these windows, all on the clock `now`. A window that is already gliding continues
    /// from where its springs are, with the velocity they have (no restart from zero, nothing is read from the app); one that
    /// was settling after a swipe continues from that spring. Windows of one move move rigidly because they share the
    /// moment and the stiffness, whatever their app's write latency. A window that joins ones already gliding (a held key
    /// retargets on every press, and brings the next window in) moves as they do: it takes their moment, and a parked one
    /// starts where the strip has carried it since the layout it was parked in, at the strip's speed. Starting it where that
    /// layout left it, a frame later, put it over its neighbour by what the strip still had to travel. `moves` must not
    /// contain windows the caller also writes.
    func glide(_ moves: [(id: UInt32, el: AXUIElement, move: StripMove)], at now: Double) {
        glideSeq += 1
        let moves = moves.sorted(by: { $0.id < $1.id })
        let strip = moves.lazy.compactMap { self.riding($0.id, at: now) }.first      // before the loop replaces the springs it reads
        for m in moves {
            var mv = m.move, vx = 0.0, vy = 0.0
            let continuing = strips[m.id] != nil || springs[m.id] != nil
            let pid = m.el.pid
            if let p = strips[m.id] {
                let t = max(0, now - (p.t0 ?? now))
                (mv.lxFrom, vx, mv.yFrom, vy) = (p.x.value(at: t), p.x.velocity(at: t), p.y.value(at: t), p.y.velocity(at: t))
                (mv.lo, mv.hi) = (mv.lo ?? p.lo, mv.hi ?? p.hi)   // a window held at an edge stays held until its logical x returns
            } else {
                if let sp = springs[m.id] {
                    let t = now - settleStart
                    (mv.lxFrom, vx) = (sp.x.value(at: t), sp.x.velocity(at: t))
                    (mv.lo, mv.hi) = (mv.lo ?? sp.lo, mv.hi ?? sp.hi)   // so is one still held at its sliver
                } else {
                    if let s = strip, mv.parked {
                        (mv.lxFrom, vx) = (mv.lxFrom + s.away, s.v)     // parked: only its logical place counts, and the strip has moved it
                    }
                    planner.record(m.id, WritePlanner.rounded(mv.from))  // (a settling window is where the writer last put it, not where it was planned)
                }
            }
            springs[m.id] = nil; _ = latest.take([m.id])
            if timeoutSet.insert(m.id).inserted { AXUIElementSetMessagingTimeout(m.el, 0.25) }
            let ω = Self.glideOmega
            strips[m.id] = Strip(el: m.el, pid: pid,
                                 x: CriticalSpring(from: mv.lxFrom, target: mv.lxTo, velocity: vx, omega: ω),
                                 y: CriticalSpring(from: mv.yFrom, target: mv.yTo, velocity: vy, omega: ω),
                                 lo: mv.lo, hi: mv.hi, final: Target(el: m.el, pid: pid, pos: mv.to, onScreen: mv.onScreen, posted: now), born: now, group: glideSeq, t0: continuing || strip != nil ? now : nil)
            shown[m.id] = mv.onScreen
            if quieted.insert(pid).inserted { quietEnhancedUI(pid) }
        }
        if springs.isEmpty { settling = false }
    }

    /// How far the strip a window rides is from the layout it was gliding to (the window's logical x against that target) and how
    /// fast it moves, now. Nil when the window rides nothing.
    private func riding(_ id: UInt32, at now: Double) -> (away: Double, v: Double)? {
        if let p = strips[id] { let t = max(0, now - (p.t0 ?? now)); return (p.x.value(at: t) - p.x.target, p.x.velocity(at: t)) }
        if let sp = springs[id] { let t = now - settleStart; return (sp.x.value(at: t) - sp.x.target, sp.x.velocity(at: t)) }
        return nil
    }

    /// Drops every glide where it is (pause, quit). Windows are left as they are; the caller reconciles.
    func cancelGlide() { strips = [:]; if latest.isEmpty { restoreEnhancedUI() } }

    private func advanceStrips(at now: Double) {
        startClocks(at: now)
        for (id, s) in strips {
            if health?.isQuarantined(s.pid) == true { strips[id] = nil; _ = latest.take([id]); continue }   // reconciled once it answers
            guard let t0 = s.t0 else { continue }   // its move is still waiting for its apps
            let t = max(0, now - t0)
            let done = t > 1.2 || (s.x.settled(at: t) && s.y.settled(at: t))
            var tg = s.final
            tg.pos = done ? s.final.pos : s.shown(at: t)
            tg.posted = now
            latest.post(id, tg)
            if done { strips[id] = nil }
        }
        if strips.isEmpty, !settling { DispatchQueue.main.async { [self] in onSettled?() } }
    }

    /// The clock of a move starts on the first display frame at which every app it writes is ready: the enhanced-UI switch done,
    /// the writes of earlier glides landed. Starting it on the first frame whatever the apps were doing let the app with a slow
    /// first batch skip a frame while the others stepped, so one window ran a step ahead of its neighbours. All its strips take
    /// the same moment, so the move stays rigid; an app that has not answered after `startWait` no longer holds it back.
    private func startClocks(at now: Double) {
        var waiting: [Int: [UInt32]] = [:]
        for (id, s) in strips where s.t0 == nil { waiting[s.group, default: []].append(id) }
        guard !waiting.isEmpty else { return }
        lock.lock(); let busy = Set(inflight.keys); lock.unlock()
        for ids in waiting.values {
            let ready = ids.allSatisfy { id in strips[id].map { !busy.contains($0.pid) || health?.isQuarantined($0.pid) == true } ?? true }
            if ready || now - (strips[ids[0]]?.born ?? now) >= Self.startWait { for id in ids { strips[id]?.t0 = now } }
        }
    }

    /// Apps with AXEnhancedUserInterface on animate every position write themselves, which fights a per-frame glide: switch it
    /// off once per glide on the app's queue and put it back after the last write. The look is also the first thing the app is
    /// asked, which wakes an idle one. The move's clock waits for it (it counts as a write in flight), so the first write no
    /// longer queues behind it; an app that does not answer counts towards being unresponsive.
    private func quietEnhancedUI(_ pid: pid_t) {
        lock.lock(); inflight[pid, default: 0] += 1; lock.unlock()
        group.enter()
        let quiet = quiet
        queue(pid).async { [self] in
            let was = quiet(pid)
            if was == nil { health?.record(pid, .cannotComplete) }   // it did not answer: counts towards the app being unresponsive
            lock.lock()
            if was == true { enhancedWas.insert(pid) }
            finish(pid); lock.unlock()
            group.leave()
        }
    }

    private func restoreEnhancedUI() {
        for pid in quieted {
            queue(pid).async { [self] in
                lock.lock(); let was = enhancedWas.remove(pid) != nil; lock.unlock()
                if was { AXUIElementCreateApplication(pid).set("AXEnhancedUserInterface", kCFBooleanTrue) }
            }
        }
        quieted = []
    }

    private func queue(_ pid: pid_t) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let e = queues[pid] { return e }
        let q = DispatchQueue(label: "ribbon.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    private func flush(at now: Double) {
        guard !latest.isEmpty else { return }
        let pending = latest.pending
        let stats = SwipeStats.shared
        let batches = planner.next(targets: pending.mapValues(\.pos), pid: { pending[$0]!.pid }, busy: { pid in
            if health?.isQuarantined(pid) == true { return true }   // left alone until it answers again
            lock.lock(); defer { lock.unlock() }
            let b = inflight[pid, default: 0] > 0; if b { stats?.skip() }
            return b
        })
        // Targets now equal to what was last written are done; the rest (busy apps) wait for the next frame.
        for (id, t) in pending {
            if let s = planner.lastSent(id), s == WritePlanner.rounded(t.pos) { _ = latest.take([id]) }
        }
        guard !batches.isEmpty else { return }
        let frameNo = stats?.tick() ?? 0
        for (pid, items) in batches {
            let jobs = items.map { (id: $0.id, el: pending[$0.id]!.el, pos: $0.pos, posted: pending[$0.id]!.posted) }
            lock.lock(); inflight[pid, default: 0] += 1
            let q: DispatchQueue
            if let e = queues[pid] { q = e } else { q = DispatchQueue(label: "ribbon.ax.\(pid)", qos: .userInteractive); queues[pid] = q }
            lock.unlock()
            group.enter()
            q.async { [self] in
                for j in jobs {
                    let t0 = CACurrentMediaTime()
                    let err = write(j.id, j.el, j.pos)
                    health?.record(pid, err)
                    let t1 = CACurrentMediaTime()
                    stats?.write(frame: frameNo, id: j.id, x: j.pos.x, posted: j.posted, start: t0, end: t1)
                    lock.lock(); wroteAt[j.id] = t1; lastAny = t1; lock.unlock()
                }
                lock.lock(); finish(pid); lock.unlock()
                group.leave()
            }
        }
    }

    private func finish(_ pid: pid_t) {        // lock held
        let n = inflight[pid, default: 1] - 1
        inflight[pid] = n > 0 ? n : nil
    }

    /// Snapshot mode, fingers lifted: write every given window ONCE to its final position, concurrently per app (one serial
    /// queue per pid, so a slow app delays only itself). `done` runs on the main queue when all writes finished.
    /// Nothing is skipped or rounded away here: the caller already diffed against where the windows really are.
    func commit(_ targets: [UInt32: Target], done: @escaping () -> Void) {
        for id in targets.keys { _ = latest.take([id]); strips[id] = nil }
        settling = false; springs = [:]
        let stats = SwipeStats.shared
        let t0 = CACurrentMediaTime()
        var byPid: [pid_t: [(id: UInt32, el: AXUIElement, pos: CGPoint)]] = [:]
        for (id, t) in targets.sorted(by: { $0.key < $1.key }) {
            if health?.isQuarantined(t.pid) == true { continue }
            let r = WritePlanner.rounded(t.pos)
            planner.record(id, r); shown[id] = t.onScreen
            byPid[t.pid, default: []].append((id, t.el, r))
            if timeoutSet.insert(id).inserted { AXUIElementSetMessagingTimeout(t.el, 0.25) }
        }
        guard !byPid.isEmpty else { DispatchQueue.main.async(execute: done); return }
        let mine = DispatchGroup()
        for (pid, items) in byPid {
            lock.lock(); inflight[pid, default: 0] += 1
            let q: DispatchQueue
            if let e = queues[pid] { q = e } else { q = DispatchQueue(label: "ribbon.ax.\(pid)", qos: .userInteractive); queues[pid] = q }
            lock.unlock()
            group.enter(); mine.enter()
            q.async { [self] in
                AXUIElement.withoutEnhancedUI(pid: pid) {
                    for j in items {
                        let err = write(j.id, j.el, j.pos)
                        health?.record(pid, err)
                        lock.lock(); wroteAt[j.id] = CACurrentMediaTime(); lastAny = wroteAt[j.id]!; lock.unlock()
                    }
                }
                lock.lock(); finish(pid); lock.unlock()
                group.leave(); mine.leave()
            }
        }
        mine.notify(queue: .main) { stats?.commit(windows: targets.count, ms: (CACurrentMediaTime() - t0) * 1000); done() }
    }

    /// Blocks until in-flight writes finished (before another writer touches the same windows).
    func waitIdle() { _ = group.wait(timeout: .now() + 1.5) }

    /// Blocks until the writes already queued for this app finished. Bounded even while a glide keeps writing to other apps.
    func waitIdle(pid: pid_t) {
        lock.lock(); let q = queues[pid]; lock.unlock()
        q?.sync {}
    }
}

/// A keyboard move of one window in the ribbon's logical space (pure, see `SwipeWriter.glide`).
///
/// The whole strip is animated as one rigid sheet: a window's logical x runs from `lxFrom` to `lxTo` on a spring shared by
/// every window of the move, and what is shown is that x held at the parked edges (`lo`/`hi`). A window leaving therefore
/// slides off and stops at its sliver, and one entering appears exactly when the strip reveals it; no window teleports
/// between parked and on screen. y glides on its own spring (a window dropped back into its slot).
struct StripMove {
    var lxFrom: Double, lxTo: Double
    var yFrom: Double, yTo: Double
    /// A window never shows left of `lo` / right of `hi`: the parked edges at either end of the move.
    var lo: Double?, hi: Double?
    /// Real origin now and at the end.
    var from: CGPoint, to: CGPoint
    /// On screen at the end (the swipe writer's `shown` bookkeeping).
    var onScreen: Bool
    /// Parked (not shown) at the start: only its logical x counts until the strip reaches it. Beneath a pinned column a parked
    /// window's logical x can lie well inside the display, so this is not told by the logical x.
    var parked = false

    static func hold(_ x: Double, lo: Double?, hi: Double?) -> Double { min(max(x, lo ?? -.infinity), hi ?? .infinity) }

    /// The size differs: the app has to lay the window out again, so it cannot slide.
    static func resizes(_ old: CGRect, _ new: CGRect) -> Bool { abs(old.width - new.width) >= 1.5 || abs(old.height - new.height) >= 1.5 }

    /// The user sees it change size: it is on screen before or after (a window that stays parked resizes unseen).
    static func resizesVisibly(old: CGRect, wasOn: Bool, new: CGRect, nowOn: Bool) -> Bool { (wasOn || nowOn) && resizes(old, new) }

    /// The slide of a window from where a swipe left it to where the core settled it, or nil when it is written at once.
    /// `origin`: where the window really is (the last position written); `on`: it is shown there, not parked; `lxWas`: its
    /// logical x while it is parked. The same slide as a keyboard move (`make`), so a window that parks keeps sliding off until
    /// it reaches its sliver and one that appears comes in as the strip reaches it. A window nobody sees leave (off the display,
    /// or wholly beneath the pinned column) just goes. A swipe never resizes: `new`'s size stands for the window's.
    static func release(origin: CGPoint, on: Bool, lxWas: Double?, new: CGRect, newLX: Double?, newOn: Bool, visible: CGRect, pin: PinEdge?) -> StripMove? {
        let old = CGRect(origin: origin, size: new.size)
        if on, !newOn {
            let shown = old.maxX > visible.minX + 1.5 && old.minX < visible.maxX - 1.5
            if !shown || pin?.hides(old) == true { return nil }
        }
        return make(old: old, oldLX: on ? origin.x : lxWas, oldOn: on, new: new, newLX: newLX, newOn: newOn, visible: visible)
    }

    private enum Rest { case on, left, right, unknown }

    /// The move from `old` to `new`, or nil when the window must jump instead: its size changes (the app has to resize it),
    /// it is not part of this ribbon at either end (desktop switches, new windows), it parks at both ends on the same side
    /// (nothing to see), or it parks somewhere the strip cannot reach (another display's edge).
    /// `oldLX`/`newLX` are the plan's logical x (nil off the active ribbon); `visible` is the display the core lays out in.
    /// `gliding`: the window is still riding a glide (a held key retargets it before it has parked), so a park on the same side
    /// at both ends is a move too: it goes on with the strip, held at its sliver, instead of being cut short where it is.
    static func make(old: CGRect, oldLX: Double?, oldOn: Bool, new: CGRect, newLX: Double?, newOn: Bool, visible: CGRect, gliding: Bool = false) -> StripMove? {
        guard let l0 = oldLX, let l1 = newLX, !resizes(old, new) else { return nil }
        let left = visible.minX.rounded() - new.width + 1, right = visible.maxX.rounded() - 1   // where the core parks (layout.rs)
        func rest(_ r: CGRect, _ on: Bool) -> Rest {
            on ? .on : abs(r.minX - left) <= 1.5 ? .left : abs(r.minX - right) <= 1.5 ? .right : .unknown
        }
        let (a, b) = (rest(old, oldOn), rest(new, newOn))
        if a == .unknown || b == .unknown || (a == b && a != .on && !gliding) { return nil }
        // A park reflected to the far edge (a neighbouring display sits at the near one) is not where the window travels: the
        // strip would carry it across the neighbour before it lands, so it jumps.
        func agrees(_ r: Rest, _ lx: Double, _ w: Double) -> Bool {
            r == .left ? lx + w <= visible.maxX + 1.5 : r == .right ? lx >= visible.minX - 1.5 : true
        }
        if !agrees(a, l0, old.width) || !agrees(b, l1, new.width) { return nil }
        let dy = new.minY - old.minY
        if (a != .on || b != .on), abs(dy) >= 1 { return nil }          // parking keeps y; a y change with it is not a strip move
        if abs(l1 - l0) < 0.5, abs(dy) < 0.5 { return nil }
        var m = StripMove(lxFrom: l0, lxTo: l1, yFrom: old.minY, yTo: new.minY, lo: nil, hi: nil, from: old.origin, to: new.origin, onScreen: newOn, parked: a != .on)
        for (r, rect) in [(a, old), (b, new)] {
            if r == .left { m.lo = rect.minX } else if r == .right { m.hi = rect.minX }
        }
        return m
    }
}

/// Calls `onTick` once per display refresh (CADisplayLink on the display being swiped) while started; a timer covers displays
/// that never call back (headless VMs). Main thread only.
///
/// The link is created ahead of the gesture (`prepare`, fingers resting on the pad) and only paused between swipes, so the
/// first frame of a swipe does not pay for registering a new link. It is tied to the swiped display's own NSScreen: a 120 Hz
/// ProMotion panel and a 60 Hz external each tick at their own rate.
@MainActor
final class FramePacer: NSObject {
    var onTick: ((Double) -> Void)?
    /// The link's targetTimestamp of the tick being delivered (nil for the fallback timer): when this frame reaches the screen.
    private(set) var targetTimestamp: Double?
    /// The display's refresh period as the link reports it (nil until it has ticked): how long the frame being delivered lasts.
    private(set) var frameInterval: Double?
    private var link: CADisplayLink?
    private var linkUUID: String?
    private var fallback: Timer?
    private var lastTick = 0.0

    private(set) var running = false
    /// Display (UUID) the link is bound to, for tests and stats.
    var linkedDisplay: String? { linkUUID }

    /// Makes sure a (paused) link for display `uuid` exists. `resolve` finds its NSScreen (only called when the link must be built).
    func prepare(uuid: String, resolve: () -> NSScreen?) {
        if link != nil, linkUUID == uuid { return }
        let wasRunning = running
        dropLink()
        guard let screen = resolve() ?? NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(fireLink(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.isPaused = !wasRunning
        l.add(to: .main, forMode: .common)
        link = l; linkUUID = uuid
    }

    func start(uuid: String, resolve: () -> NSScreen?) {
        prepare(uuid: uuid, resolve: resolve)
        guard !running else { return }
        running = true
        // Without a link known to tick on this display, a link that was paused can take a few frames to deliver its first callback:
        // the first tick waits at most about 10 ms for it before the timer steps in.
        lastTick = CACurrentMediaTime() - (frameInterval == nil ? 0.01 : 0)
        link?.isPaused = false
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let s = self, CACurrentMediaTime() - s.lastTick > Self.fallbackGrace(linkTicks: s.frameInterval != nil) { s.fire(target: nil) } }
        }
        RunLoop.main.add(t, forMode: .common)
        fallback = t
    }

    /// Pauses (does not invalidate) the link.
    func stop() {
        running = false
        link?.isPaused = true
        fallback?.invalidate(); fallback = nil
    }

    /// Drops the link (displays changed, Ribbon paused).
    func reset() { stop(); dropLink() }

    private func dropLink() { link?.invalidate(); link = nil; linkUUID = nil; frameInterval = nil }

    /// How long a tick may be overdue before the fallback timer steps in. A link known to tick on this display gets long enough to
    /// recover from a main-thread stall: after one, the link and the timer are both overdue and the timer runs first; its tick
    /// has no screen time, the link's follows within a frame, and a glide's first frames jump. Without such a link (a headless
    /// VM, or before its first tick) the timer is the pacer.
    nonisolated static func fallbackGrace(linkTicks: Bool) -> Double { linkTicks ? 0.1 : 0.02 }

    @objc private func fireLink(_ l: CADisplayLink) {
        let d = l.targetTimestamp - l.timestamp
        if d > 0.002, d < 0.05 { frameInterval = d }
        fire(target: l.targetTimestamp)
    }

    private func fire(target: Double?) {
        let now = CACurrentMediaTime()
        lastTick = now
        targetTimestamp = target
        SwipeStats.shared?.linkTick(now, target: target)
        onTick?(now)
    }
}
