import Foundation
import CoreGraphics

// Pure pieces of the three-finger swipe (no AppKit, no AX): easy to unit-test from `SelfTest`.

/// Very light smoothing of the finger position: one pole, so the output trails the raw value by about a quarter of a
/// sample at the touch rate (~2ms). Calms the last sub-pixel of contact noise without any perceptible lag
/// (the 1-euro filter this replaces cost 20-40ms while the fingers moved).
struct LightSmoother {
    var alpha = 0.8
    private var x: Double?
    mutating func filter(_ v: Double) -> Double { let o = x.map { $0 + alpha * (v - $0) } ?? v; x = o; return o }
    mutating func reset() { x = nil }
}

/// Decides which events to swallow so a Ribbon three-finger swipe does not also reach the app under the pointer
/// (Dia and Arc switch profile/space on horizontal scrolls). Fed from two threads (touch frames, the event tap); cheap.
///
/// - three or more fingers down: hot; stays hot while two remain (lifting one finger of a swipe), until fewer than two.
/// - a short grace after the last hot moment covers scroll events that trail the touch frames.
/// - a scroll stream that began (or was joined) while hot is tainted: its remaining and momentum events are swallowed
///   until the momentum ends; a new stream starts clean, so two-finger scrolling is never touched.
final class SwipeGate: @unchecked Sendable {
    static let shared = SwipeGate()
    static let grace = 0.05, staleAfter = 1.5, momentumLimit = 3.0

    private let lock = NSLock()
    private var fingers = 0
    /// How many fingers drive the ribbon (3 or 4).
    var needed = 3
    private var wasThree = false
    private var lastHot = -Double.infinity
    private var lastFrame = -Double.infinity
    private var tainted = false
    private var taintedAt = -Double.infinity

    /// Touching contacts in one multitouch frame.
    func contacts(_ n: Int, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        fingers = n; lastFrame = now
        if n >= needed { wasThree = true }
        if n < 2 { wasThree = false }
        if hotLocked(now) { lastHot = now }
    }

    private func hotLocked(_ now: Double) -> Bool { wasThree && fingers >= 2 && now - lastFrame < Self.staleAfter }
    private func swallowNowLocked(_ now: Double) -> Bool { hotLocked(now) || now - lastHot <= Self.grace }

    /// `phase`/`momentum` are the CGEvent scroll fields (phase: 1 began, 2 changed, 4 ended, 8 cancelled, 128 may-begin;
    /// momentum: 0 none, 1 begin, 2 continue, 3 end). Returns true to swallow the event.
    func swallowScroll(phase: Int, momentum: Int, at now: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let hot = swallowNowLocked(now)
        if momentum != 0 {
            let s = tainted && now - taintedAt < Self.momentumLimit
            if momentum == 3 || !s { tainted = false }
            return s
        }
        if phase == 0 { return hot }                       // plain wheel
        if phase == 1 || phase == 128 { tainted = hot } else if hot { tainted = true }
        if tainted { taintedAt = now }
        return tainted
    }

    /// Gesture, magnify, swipe, rotate, begin/end-gesture events.
    func swallowGesture(at now: Double) -> Bool { lock.lock(); defer { lock.unlock() }; return swallowNowLocked(now) }

    func reset() { lock.lock(); fingers = 0; wasThree = false; tainted = false; lastHot = -.infinity; lock.unlock() }
}

/// Latest wins: one pending value per key; a newer post replaces an older, never queues.
struct LatestWins<K: Hashable, V> {
    private(set) var pending: [K: V] = [:]
    mutating func post(_ k: K, _ v: V) { pending[k] = v }
    mutating func take(_ keys: some Sequence<K>) -> [K: V] {
        var out: [K: V] = [:]
        for k in keys { if let v = pending.removeValue(forKey: k) { out[k] = v } }
        return out
    }
    var isEmpty: Bool { pending.isEmpty }
    mutating func removeAll() { pending = [:] }
}

/// Which positions to write this frame: only windows whose rounded target moved by at least 1px since the last write,
/// and only for apps that are not still busy with their previous write (their newest target waits for the next frame).
struct WritePlanner {
    private(set) var sent: [UInt32: CGPoint] = [:]
    static func rounded(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x.rounded(), y: p.y.rounded()) }

    mutating func next(targets: [UInt32: CGPoint], pid: (UInt32) -> pid_t, busy: (pid_t) -> Bool) -> [pid_t: [(id: UInt32, pos: CGPoint)]] {
        var out: [pid_t: [(id: UInt32, pos: CGPoint)]] = [:]
        for (id, t) in targets.sorted(by: { $0.key < $1.key }) {
            let r = Self.rounded(t)
            if let s = sent[id], abs(s.x - r.x) < 1, abs(s.y - r.y) < 1 { continue }
            let p = pid(id)
            if busy(p) { continue }
            out[p, default: []].append((id, r))
            sent[id] = r
        }
        return out
    }
    mutating func record(_ id: UInt32, _ p: CGPoint) { sent[id] = p }
    mutating func forget(_ id: UInt32) { sent[id] = nil }
    mutating func forgetAll() { sent = [:] }
    func lastSent(_ id: UInt32) -> CGPoint? { sent[id] }
}

/// Critically damped spring toward `target` from `from` with initial velocity `v0` (all px, px/s). Closed form, so frame-rate independent.
/// Velocity toward the target is capped so it never overshoots.
struct CriticalSpring {
    let from: Double, target: Double, omega: Double, a: Double, b: Double
    init(from: Double, target: Double, velocity: Double, omega: Double = 15) {
        self.from = from; self.target = target; self.omega = omega
        a = from - target
        var v = velocity
        if a != 0, v * a < 0 { v = min(abs(v), omega * abs(a)) * (v < 0 ? -1 : 1) }
        b = v + omega * a
    }
    /// A release: `velocity` is kept only while it heads toward `target`. A tile that would be carried further away first (the layers
    /// lead the core by the finger prediction, or the plan settles back the way the fingers came) starts from rest, so a release
    /// never kicks outward and returns.
    init(releasing from: Double, target: Double, velocity: Double, omega: Double = 15) {
        self.init(from: from, target: target, velocity: (target - from) * velocity < 0 ? 0 : velocity, omega: omega)
    }
    func value(at t: Double) -> Double { target + (a + b * t) * exp(-omega * t) }
    /// Speed at `t` (px/s, + = right): a new target mid-glide starts from it, so the motion bends instead of restarting.
    func velocity(at t: Double) -> Double { (b - omega * (a + b * t)) * exp(-omega * t) }
    /// True when within half a pixel and (almost) not moving.
    func settled(at t: Double) -> Bool { settled(at: t, within: 0.5, slower: 8) }
    /// How close and how slow a tile must be for the eye to take it as arrived: the overlay may fade while the last pixels still move.
    static let landedWithin = 1.5, landedSlower = 60.0
    func landed(at t: Double) -> Bool { settled(at: t, within: Self.landedWithin, slower: Self.landedSlower) }
    private func settled(at t: Double, within px: Double, slower speed: Double) -> Bool { abs(value(at: t) - target) < px && abs(velocity(at: t)) < speed }
}

/// The overlay's tiles gliding to their final places: one critically damped spring per tile, all on one clock. Pure; `SwipeOverlay`
/// puts the positions it hands out on its layers. Positions are the display-relative x of the tile layers.
///
/// - The clock starts at the first frame (`step`) after a glide that starts from rest, no earlier than one frame before it: the
///   display link of a keyboard move wakes up some time after the key, and a clock that ran meanwhile would have the first frame
///   jump over half the way. So the first frame covers what any frame of a glide does, at most a tenth of the way at 60 Hz, however
///   late it comes, and the glide shows movement from that very frame. The frame time is the time the frame reaches the screen
///   (the link's target timestamp), so a late tick is not a bigger step.
/// - A command while tiles glide continues from where their springs are at that moment (position and speed), not from the last
///   frame drawn, so the distance since that frame is not lost. It takes effect no earlier than the newest frame already handed out.
/// - A glide begun by a release (the fingers were moving the tiles, the display link is running) can start its clock at once.
struct TileGlide {
    struct Frame {
        /// Where every gliding tile is at this frame.
        var x: [UInt32: Double]
        /// Close enough and slow enough to count as arrived (`CriticalSpring.landed`): the overlay may start to fade.
        var landed: Bool
        /// Every spring has settled to the pixel: the positions are the finals and nothing glides any more.
        var done: Bool
    }
    private(set) var springs: [UInt32: CriticalSpring] = [:]
    /// The clock of the springs (the ring's follows it); nil until the first frame of a glide that started from rest.
    private(set) var origin: Double?
    /// The time of the command a clock that still waits for its first frame will not start before.
    private var pending: Double?
    /// When the newest frame handed out was due on screen.
    private(set) var lastFrame: Double?
    var omega = SwipeOverlay.springOmega

    var isGliding: Bool { !springs.isEmpty }
    /// Where each tile is heading.
    var targets: [UInt32: Double] { springs.mapValues(\.target) }

    mutating func cancel() { springs = [:]; origin = nil; pending = nil; lastFrame = nil }

    /// A tile leaves the glide (its layer is gone, or it was put where it belongs); the others carry on.
    mutating func drop(_ id: UInt32) {
        springs[id] = nil
        if springs.isEmpty { cancel() }
    }

    /// The glide ends at once: where each tile was heading, and nothing glides any more.
    mutating func land() -> [UInt32: Double] {
        let finals = targets
        cancel()
        return finals
    }

    /// When a command at `now` takes effect on the springs that run, nil when no frame has been drawn yet (the clock is still waiting).
    func retargetTime(_ now: Double) -> Double? { origin == nil ? nil : max(now, lastFrame ?? now) }

    /// Where the tile gliding to `id` is at `time` (nil when it does not glide).
    func position(of id: UInt32, at time: Double) -> Double? {
        springs[id].map { $0.value(at: origin.map { max(0, time - $0) } ?? 0) }
    }

    /// Glide to `targets` from `rendered` (where the tile layers are now); `velocity` is the release speed of tiles that do not glide
    /// yet (px/s, + = right), kept only toward their target. Tiles that glide continue with their own. `lazyClock`: a glide from rest
    /// starts its clock at the first frame, else at `now`.
    mutating func retarget(to targets: [UInt32: Double], from rendered: [UInt32: Double], velocity: Double, at now: Double, lazyClock: Bool) {
        let running = !springs.isEmpty
        let at = retargetTime(now) ?? now
        let t = origin.map { max(0, at - $0) } ?? 0               // no frame yet: the springs are still at their start
        var next: [UInt32: CriticalSpring] = [:]
        for (id, target) in targets {
            if let sp = springs[id] {
                next[id] = CriticalSpring(from: sp.value(at: t), target: target, velocity: sp.velocity(at: t), omega: omega)
            } else if let x = rendered[id], abs(x - target) >= 0.25 {
                next[id] = CriticalSpring(releasing: x, target: target, velocity: velocity, omega: omega)
            }
        }
        springs = next
        if next.isEmpty { cancel(); return }
        if !running { origin = lazyClock ? nil : now; pending = lazyClock ? now : nil; lastFrame = nil }
        else if origin != nil { origin = at }                     // a glide on its way carries on
        else { pending = now }                                    // one still waiting for its first frame keeps waiting, from the newer command
    }

    /// The frame due on screen at `time`; `interval`: how long a frame lasts (the display's refresh period).
    mutating func step(at time: Double, interval: Double = 1.0 / 60) -> Frame {
        guard !springs.isEmpty else { return Frame(x: [:], landed: true, done: true) }
        if origin == nil { origin = max(pending ?? time, time - interval); pending = nil }
        let t = max(0, time - origin!)
        lastFrame = time
        let landed = t > 1.0 || springs.values.allSatisfy { $0.landed(at: t) }
        let done = t > 1.0 || springs.values.allSatisfy { $0.settled(at: t) }
        let x = springs.mapValues { done ? $0.target : $0.value(at: t) }
        if done { cancel() }
        return Frame(x: x, landed: landed, done: done)
    }
}

/// Decides which touching contacts count as a swipe. A resting thumb or palm must never count: only contacts that moved
/// at least 0.5% of the pad within the last ~60ms (from their own position history, by contact identifier) do, and they
/// must all move the same way horizontally (same sign of dx, |dx| > |dy|). Exactly `needed` such contacts start a swipe;
/// the swipe then keeps those contacts (so slowing down or pausing does not end it) until one lifts.
struct ContactFilter {
    var needed = 3
    static let window = 0.06, minMove = 0.005
    typealias Contact = (id: Int32, pos: SIMD2<Double>)
    private var hist: [Int32: [(t: Double, p: SIMD2<Double>)]] = [:]
    private var sticky: Set<Int32> = []
    private var tail: Set<Int32> = []

    /// `gate`: contacts to report to `SwipeGate` (0 when nothing qualifies). `swipe`: positions of the swipe's contacts.
    /// `travel`: on the frame that starts the swipe, how far (pad widths, signed) the contacts had already moved.
    mutating func feed(_ cs: [Contact], at t: Double) -> (gate: Int, swipe: [SIMD2<Double>]?, travel: Double) {
        let ids = Set(cs.map(\.id))
        hist = hist.filter { ids.contains($0.key) }
        var moves: [Int32: SIMD2<Double>] = [:]
        for c in cs {
            var h = hist[c.id] ?? []
            h.append((t, c.pos))
            h.removeAll { t - $0.t > Self.window }
            hist[c.id] = h
            if let first = h.first, t - first.t >= 0.012 { moves[c.id] = c.pos - first.p }
        }
        let pos = Dictionary(cs.map { ($0.id, $0.pos) }, uniquingKeysWith: { $1 })
        if !sticky.isEmpty {
            if sticky.isSubset(of: ids) { return (sticky.count, sticky.sorted().map { pos[$0]! }, 0) }
            tail = sticky.intersection(ids); sticky = []                      // one finger lifted: the rest linger until fewer than two
        }
        if !tail.isEmpty {
            tail.formIntersection(ids)
            if tail.count >= 2 { return (tail.count, nil, 0) }
            tail = []
        }
        let movers = moves.filter { $0.value.x * $0.value.x + $0.value.y * $0.value.y >= Self.minMove * Self.minMove }
        guard movers.count == needed else { return (0, nil, 0) }
        let sign = movers.values.first!.x < 0 ? -1.0 : 1.0
        guard movers.values.allSatisfy({ $0.x * sign > 0 && abs($0.x) > abs($0.y) }) else { return (0, nil, 0) }
        sticky = Set(movers.keys)
        let travel = movers.values.map(\.x).reduce(0, +) / Double(needed)   // already covered when the swipe is recognised: not lost
        return (needed, sticky.sorted().map { pos[$0]! }, travel)
    }

    mutating func reset() { hist = [:]; sticky = []; tail = [] }
}

// MARK: - Snapshot swipe: pure pieces

/// Lifecycle of the snapshot overlay around one or more swipes. The overlay appears when the fingers start moving, the
/// snapshots follow them, and after release it stays up until BOTH the settle spring is over and the real windows have been
/// written to their final frames (or `writeTimeout` passed since the spring ended); then it fades out.
/// A new swipe at any point continues from the overlay's current positions; writes of an older commit are ignored by generation.
struct CommitMachine {
    enum Phase: Equatable { case idle, gesture, settling, fading }
    enum Action: Equatable { case none, showOverlay, startFade, removeOverlay, resumeFromFade }
    static let writeTimeout = 0.3, fadeDuration = 0.12

    private(set) var phase = Phase.idle
    private(set) var generation = 0
    private var springDone = false, writesDone = false
    private var springEndedAt = 0.0

    /// Fingers started moving.
    mutating func begin() -> Action {
        switch phase {
        case .idle: phase = .gesture; generation += 1; return .showOverlay
        case .gesture: return .none
        case .settling: phase = .gesture; generation += 1; return .none        // continue from where the layers are
        case .fading: phase = .gesture; generation += 1; return .resumeFromFade
        }
    }
    /// Fingers lifted: returns the generation the commit belongs to (pass it back to `writesFinished`).
    mutating func release() -> Int {
        guard phase == .gesture else { return generation }
        phase = .settling; springDone = false; writesDone = false
        return generation
    }
    mutating func springFinished(at now: Double) -> Action {
        guard phase == .settling, !springDone else { return .none }
        springDone = true; springEndedAt = now
        return fadeIfReady(now)
    }
    mutating func writesFinished(generation g: Int, at now: Double) -> Action {
        guard phase == .settling, g == generation else { return .none }
        writesDone = true
        return fadeIfReady(now)
    }
    /// Called every frame while the machine is not idle: covers the write timeout.
    mutating func tick(at now: Double) -> Action { phase == .settling ? fadeIfReady(now) : .none }
    mutating func fadeFinished() -> Action {
        guard phase == .fading else { return .none }
        phase = .idle; return .removeOverlay
    }
    private mutating func fadeIfReady(_ now: Double) -> Action {
        guard phase == .settling, springDone, writesDone || now - springEndedAt >= Self.writeTimeout else { return .none }
        phase = .fading; return .startFade
    }
    var overlayUp: Bool { phase != .idle }
}

/// Which windows' images are kept and when one must be captured again. Pure bookkeeping (no images): cheap to invalidate.
/// An entry is fresh while it is not dirty, not older than `maxAge`, and the window kept its size. A stale image is still
/// usable (the first frame never waits for a capture) as long as the size is close; otherwise a placeholder tile is shown.
struct SnapshotLedger {
    static let maxAge = 6.0, usableSizeSlack = 12.0
    /// How many pictures are kept: a ribbon of that many windows (or the nearest of a longer one) can be slid whole by the overlay.
    static let defaultCapacity = 14
    var capacity = SnapshotLedger.defaultCapacity
    private struct Entry { var size: CGSize; var scale: Double; var at: Double; var dirty: Bool; var used: Double }
    private var entries: [UInt32: Entry] = [:]

    enum Use: Equatable { case fresh, stale, none }

    /// `scale`: the resolution wanted (the display's backing scale, parked windows in reach included: they slide in sharp); a sharper image than that is fine.
    func use(_ id: UInt32, size: CGSize, scale: Double = 1, now: Double, maxAge: Double = SnapshotLedger.maxAge) -> Use {
        guard let e = entries[id], abs(e.size.width - size.width) <= Self.usableSizeSlack, abs(e.size.height - size.height) <= Self.usableSizeSlack else { return .none }
        let exact = abs(e.size.width - size.width) <= 1 && abs(e.size.height - size.height) <= 1
        return e.dirty || !exact || e.scale < scale || now - e.at > maxAge ? .stale : .fresh
    }
    func needsCapture(_ id: UInt32, size: CGSize, scale: Double = 1, now: Double, maxAge: Double = SnapshotLedger.maxAge) -> Bool { use(id, size: size, scale: scale, now: now, maxAge: maxAge) != .fresh }
    /// Seconds since the window's picture was taken (nil: none).
    func age(_ id: UInt32, now: Double) -> Double? { entries[id].map { now - $0.at } }

    mutating func stored(_ id: UInt32, size: CGSize, scale: Double = 1, now: Double) {
        entries[id] = Entry(size: size, scale: scale, at: now, dirty: false, used: now)
    }
    mutating func touch(_ id: UInt32, now: Double) { entries[id]?.used = now }
    mutating func markDirty(_ id: UInt32) { entries[id]?.dirty = true }
    mutating func markAllDirty() { for k in entries.keys { entries[k]?.dirty = true } }
    mutating func forget(_ id: UInt32) { entries[id] = nil }
    mutating func removeAll() { entries = [:] }
    var ids: Set<UInt32> { Set(entries.keys) }
    var count: Int { entries.count }

    /// Drops windows that are gone, then the least recently used beyond `capacity`; returns what was dropped.
    mutating func trim(alive: Set<UInt32>) -> [UInt32] {
        var dropped = entries.keys.filter { !alive.contains($0) }
        for id in dropped { entries[id] = nil }
        if entries.count > capacity {
            let extra = entries.sorted { $0.value.used < $1.value.used }.prefix(entries.count - capacity).map(\.key)
            for id in extra { entries[id] = nil }
            dropped += extra
        }
        return dropped
    }
}

/// Which windows take part in a swipe, from their logical x extent relative to the display (px).
enum SwipeRange {
    /// Snapshot layers: the viewport plus 1.5 viewport widths each side.
    static let snapshotReach = 1.5
    static func inSnapshotRange(lx: Double, w: Double, display: CGRect) -> Bool {
        lx + w > display.minX - snapshotReach * display.width && lx < display.maxX + snapshotReach * display.width
    }
    /// Direct mode: only windows within one column of the viewport are moved (the others are parked and stay put).
    static func inDirectRange(lx: Double, w: Double, display: CGRect) -> Bool {
        lx + w > display.minX - w && lx < display.maxX + w
    }
}

/// The windows on a display that the ribbon does not move: a floating window, one of an app the ribbon leaves alone, a dialog.
/// They stay where they are while the tiles slide, so the overlay draws each as a tile of its own that does not move, instead
/// of baking them into the backdrop (where a window above a tile vanished at the first frame, and a window that has since
/// moved or closed lingered as a ghost). Pure, from the window server's front-to-back order.
enum OverlayFloaters {
    /// At most this many are drawn (the frontmost): each is a texture.
    static let maxCount = 4
    /// A window showing less than this on the display is a parked sliver or a helper window, no floater.
    static let minVisible: CGFloat = 32

    /// `stack`: the on-screen windows front to back. `tiled`: every window some ribbon lays out right now (they are tiles, or parked).
    /// Normal-level windows only: the Dock, menus and banners stay live above the overlay. A sheet, popover or drawer inside a tiled
    /// window of its own app moves with it, so it is left to the backdrop. `above`: in front of every tiled window, so it is drawn
    /// over the ribbon; any window of the ribbon in front of it puts it beneath the tiles (a floating window the user has covered).
    static func pick(stack: [WindowStack.Entry], tiled: Set<UInt32>, ownPID: pid_t, display: CGRect) -> [SwipeOverlay.FloaterSpec] {
        let tiledAt = stack.indices.filter { tiled.contains(UInt32(truncatingIfNeeded: stack[$0].id)) }
        var out: [SwipeOverlay.FloaterSpec] = []
        for i in stack.indices {
            let e = stack[i]
            guard e.layer == 0, e.pid != ownPID, e.id >= 0, !tiled.contains(UInt32(truncatingIfNeeded: e.id)) else { continue }
            let seen = e.bounds.intersection(display)
            guard !seen.isNull, seen.width >= minVisible, seen.height >= minVisible else { continue }
            if tiledAt.contains(where: { stack[$0].pid == e.pid && stack[$0].bounds.insetBy(dx: -2, dy: -2).contains(e.bounds) }) { continue }
            out.append(SwipeOverlay.FloaterSpec(id: UInt32(truncatingIfNeeded: e.id), rect: e.bounds, pid: e.pid, above: tiledAt.allSatisfy { i < $0 }))
            if out.count == maxCount { break }
        }
        return out
    }
}

/// Notices when the windows a ribbon lays out change (one opened, closed, floated or tiled), so what the backdrop leaves out is
/// captured again. Per display.
struct TiledSet {
    private var sets: [String: Set<UInt32>] = [:]
    /// True when `ids` differ from the last call for this display (and the first time).
    mutating func changed(_ ids: Set<UInt32>, on display: String) -> Bool {
        defer { sets[display] = ids }
        return sets[display] != ids
    }
}

/// A small visual lead for the overlay layers: the frame is shown `target - now` seconds from now and the newest finger data
/// is already a little old, so the layers lead the core's position by the finger velocity times that time. Capped in px and
/// in seconds so a noisy sample can never throw a layer far; never accumulated (the core stays the source of truth); zero for
/// the first sample of a swipe and whenever the fingers did not move.
struct SwipePredictor {
    static let maxLead = 0.012          // seconds of look-ahead at most (about one 90 Hz frame)
    static let maxOffset = 8.0          // px, whatever the velocity
    static let smoothing = 0.5          // weight of the newest velocity sample
    private var velocity = 0.0          // px/s, smoothed
    private var lastAt: Double?

    mutating func reset() { velocity = 0; lastAt = nil }

    /// Seconds to look ahead for a frame that will be on screen at `target` (display link targetTimestamp; nil without one).
    static func lead(now: Double, target: Double?, fallback: Double = 1.0 / 120) -> Double {
        let t = target.map { $0 - now } ?? fallback
        return min(max(t, 0), maxLead)
    }

    /// `dx`: viewport px moved since the previous call (+ = same direction as the core's scroll). Returns the extra viewport px
    /// the layers should lead by (same sign as `dx`).
    mutating func offset(dx: Double, at now: Double, target: Double?) -> Double {
        defer { lastAt = now }
        guard let last = lastAt, now > last, dx.isFinite else { velocity = 0; return 0 }
        let dt = now - last
        guard dt < 0.1, dx != 0 else { velocity = 0; return 0 }       // a pause or a stall: no extrapolation across it
        let v = dx / dt
        velocity = velocity * (1 - Self.smoothing) + v * Self.smoothing      // ramps in from zero: a restart leads gently
        let off = velocity * Self.lead(now: now, target: target)
        return min(max(off, -Self.maxOffset), Self.maxOffset)
    }
}

/// Which display the swipe's frame pacer follows: the display being swiped (so a 120 Hz and a 60 Hz screen each run at their
/// own rate), else the main display, else the first.
enum DisplayLinkChoice {
    struct Candidate: Equatable { let uuid: String; let displayID: UInt32 }
    static func pick(target: String?, in screens: [Candidate], main: UInt32?) -> Candidate? {
        if let target, let c = screens.first(where: { $0.uuid == target }) { return c }
        if let main, let c = screens.first(where: { $0.displayID == main }) { return c }
        return screens.first
    }
}

// MARK: - Keyboard navigation through the overlay: pure pieces

/// The tiles of one display's active desktop at one moment: every tiled window at its logical rect (AX space, parked ones too),
/// without the hidden tabs of tabbed columns. The overlay slides these when a keyboard command moves the ribbon.
struct NavLayout: Equatable {
    var desktop = 0
    var specs: [SwipeOverlay.TileSpec] = []
    var edge: PinEdge?
    /// The tabs a tabbed column does not show: no tiles, but the plan writes them along with their column.
    var hidden: Set<UInt32> = []

    /// What the overlay needs to show a move from `old` to `new`.
    struct Slide: Equatable {
        /// The tiles that take part, at their OLD rects: every window that can be seen while the move runs (on the display
        /// before, after or anywhere in between), and one column of margin beyond.
        var staging: [SwipeOverlay.TileSpec]
        /// Of them, the ones the layers lack: they are placed at their old rects, the others are left where they are.
        var add: [SwipeOverlay.TileSpec]
        /// Where each of them ends (absolute AX x).
        var finals: [UInt32: Double]
        /// Of them, the ones that cross the display while the move runs: each must show a real picture, never a placeholder.
        var seen: Set<UInt32>
        /// Layers that sit this move out (out of sight before, after and in between): put where the layout has them at once.
        var snap: [UInt32: Double] = [:]
        /// Layers to take off: windows that are no longer in the layout (closed since the layers were staged), and tiles that
        /// went far out of reach.
        var drop: Set<UInt32> = []

        /// The move with only the tiles that have a picture. Nil when a tile that is seen has none: a gray placeholder card would
        /// slide across the display, so the move takes another road. A margin tile without one just stays out of this move.
        func pictured(_ has: (UInt32) -> Bool) -> Slide? {
            guard seen.allSatisfy(has) else { return nil }
            var s = self
            let missing = Set(staging.map(\.id).filter { !has($0) })
            for id in missing { s.finals[id] = nil; s.snap[id] = finals[id] }
            s.staging.removeAll { missing.contains($0.id) }
            s.add.removeAll { missing.contains($0.id) }
            return s
        }
    }

    /// The move as a slide of rigid tiles, or nil when it is more than that: another desktop, a window that came or went, a
    /// change of size or y, a different pin edge, or nothing that shows. `changed`: the windows the plan writes; all must be tiles (or hidden tabs).
    /// `layers`: where the overlay's layers are right now (a glide may still be running). A tile moves from its layer's place
    /// to its final one, so a tile that crosses the display on the way is staged however far it started and ends; without
    /// a layer it starts at its old rect.
    static func slide(from old: NavLayout, to new: NavLayout, changed: [UInt32], display: CGRect, layers: [UInt32: CGRect] = [:]) -> Slide? {
        guard old.desktop == new.desktop, old.edge == new.edge, old.specs.count == new.specs.count else { return nil }
        let was = Dictionary(old.specs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard was.count == old.specs.count, changed.allSatisfy({ was[$0] != nil || old.hidden.contains($0) || new.hidden.contains($0) }) else { return nil }
        func onDisplay(_ r: CGRect) -> Bool { r.maxX > display.minX && r.minX < display.maxX }
        var out = Slide(staging: [], add: [], finals: [:], seen: [])
        var visible = false
        for n in new.specs {
            guard let o = was[n.id], o.held == n.held, o.pid == n.pid,
                  abs(o.rect.width - n.rect.width) < 0.5, abs(o.rect.height - n.rect.height) < 0.5, abs(o.rect.minY - n.rect.minY) < 0.5 else { return nil }
            let from = layers[n.id]?.minX ?? o.rect.minX
            let w = n.rect.width, lo = min(from, n.rect.minX), hi = max(from, n.rect.minX) + w
            if hi > display.minX && lo < display.maxX { out.seen.insert(n.id) }
            if hi > display.minX - w && lo < display.maxX + w {
                out.staging.append(o); out.finals[n.id] = n.rect.minX
                if layers[n.id] == nil { out.add.append(o) }
            } else if layers[n.id] != nil {
                // Out of sight before, after and on the way: parked where the layout has it, or let go when far beyond any reach.
                if SwipeRange.inSnapshotRange(lx: n.rect.minX, w: w, display: display) { out.snap[n.id] = n.rect.minX } else { out.drop.insert(n.id) }
            }
            if abs(from - n.rect.minX) >= 0.5, onDisplay(CGRect(x: from, y: o.rect.minY, width: w, height: o.rect.height)) || onDisplay(n.rect) { visible = true }
        }
        out.drop.formUnion(Set(layers.keys).subtracting(was.keys))
        return visible ? out : nil
    }

    /// The kept layers still show `old` (every one sits at its tile's rect): a move can run on them without staging again.
    /// A layer of a window that is gone does not count (the slide drops it), but layers that share no window with the layout at all
    /// are another display's: they are staged again.
    static func layersAgree(_ have: [UInt32: CGRect], with old: NavLayout) -> Bool {
        let rects = Dictionary(old.specs.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        guard have.isEmpty || have.keys.contains(where: { rects[$0] != nil }) else { return false }
        return have.allSatisfy { id, h in
            guard let r = rects[id] else { return true }
            return abs(h.minX - r.minX) < 0.5 && abs(h.minY - r.minY) < 0.5 && abs(h.width - r.width) < 0.5 && abs(h.height - r.height) < 0.5
        }
    }
}

/// Whether a keyboard move may run on the overlay: everything it needs, and nothing it cannot draw. Deliberately without the
/// "Swipe to scroll the ribbon" setting: the layers and the pictures only need Screen Recording, with or without swiping.
struct NavGate: Equatable {
    /// Not forced onto the AX glide (QA).
    var enabled = true
    var started = true
    /// Screen Recording is granted.
    var permitted = true
    /// The plan is for the focused display.
    var focusedDisplay = true
    /// The plan moves no window by hand (skip moves).
    var plain = true
    /// No finger swipe, drag or gesture is in progress.
    var idle = true
    /// The plan is a glide and not a jump (a new window, another desktop).
    var glides = true
    /// No Dim, Blur or Focus mode: the overlay would cover their dim panel.
    var undimmed = true
    /// Reduce Motion is off.
    var motion = true

    var open: Bool { enabled && started && permitted && focusedDisplay && plain && idle && glides && undimmed && motion }

    /// After a keyboard glide on the AX road without Screen Recording, the one-time card offers the smoother one.
    static func offersPermission(glided: Bool, permitted: Bool, enabled: Bool) -> Bool { glided && !permitted && enabled }
}

/// When the picture sweep fires. The sooner of two requests wins (a window that just opened is pictured within a moment, not
/// after the second of quiet every plan asks for); the sweep itself still waits for the quiet when it fires.
struct SweepClock: Equatable {
    private(set) var due = Double.infinity

    /// A sweep is wanted `delay` from `now`: true when it must be armed, false when one at least as soon is armed already.
    mutating func arm(after delay: Double, at now: Double) -> Bool {
        guard now + delay < due - 0.02 else { return false }
        due = now + delay
        return true
    }
    /// The armed sweep fired (or was dropped): the next request arms again.
    mutating func fired() { due = .infinity }
}

/// What the overlay does with a new picture of a window. While it is up a tile is not touched mid-motion (a texture swap would
/// hitch), except the windows whose title bars change with the focus: their new picture waits for the glide to land and goes in
/// right before the fade, so the live window does not pop in when the overlay clears.
enum PictureSwap {
    enum Verdict: Equatable {
        /// The overlay's own rule: a placeholder takes it, a tile out of sight takes it, a tile on screen does not.
        case normal
        /// A tile of the focus pair that is still moving: keep the picture for the landing.
        case wait
        /// A tile of the focus pair that holds still: swap it in now.
        case swap
    }
    static func verdict(overlayUp: Bool, focusPair: Bool, hasPicture: Bool, moving: Bool) -> Verdict {
        guard overlayUp, focusPair else { return .normal }
        return hasPicture && moving ? .wait : .swap
    }
}

/// How the focused window's picture follows the user while they work: taken again about every ¾ s while keys, clicks or the
/// pointer were used in the last two seconds, so a keyboard move starts from what is on screen (typed text, terminal output),
/// and watched until ten idle seconds have passed.
enum LiveRefresh {
    static let every = 0.75, activeWithin = 2.0, watchWithin = 10.0
    /// `idle`: seconds since the last input anywhere. `age`: seconds since the window's picture was taken (nil: none).
    static func takes(idle: Double, age: Double?) -> Bool { idle < activeWithin && (age ?? .infinity) > every - 0.05 }
    static func keepsWatching(idle: Double) -> Bool { idle < watchWithin }
}

/// Which windows deserve a picture: every tile of the ribbon, nearest the display first, as many as the ledger holds. A
/// keyboard move on a long ribbon can reach tiles far beyond a swipe's reach (focus first, focus last, go to window n, or a quick
/// run of key presses), and a tile without a picture sends the move down the AX road.
enum SnapshotReach {
    struct Pick: Equatable { let id: UInt32; let onScreen: Bool; let maxAge: Double }
    /// How old a picture of a tile beyond the swipe's reach may get.
    static let farAge = 20.0

    /// `tiles`: x extent and whether the plan has the window on screen. Ties keep the ribbon's order.
    static func wanted(_ tiles: [(id: UInt32, lx: Double, w: Double, onScreen: Bool)], display: CGRect, limit: Int) -> [Pick] {
        func gap(_ t: (id: UInt32, lx: Double, w: Double, onScreen: Bool)) -> Double { max(0, display.minX - (t.lx + t.w), t.lx - display.maxX) }
        return tiles.enumerated().sorted { (gap($0.element), $0.offset) < (gap($1.element), $1.offset) }.prefix(limit).map { _, t in
            let near = SwipeRange.inSnapshotRange(lx: t.lx, w: t.w, display: display)
            return Pick(id: t.id, onScreen: t.onScreen, maxAge: t.onScreen ? 2 : near ? SnapshotLedger.maxAge : farAge)
        }
    }
}

/// The focus ring inside the overlay: it sits on the window it frames and, when focus moves, glides from where it was to the new
/// window's tile on a spring like the tiles'. It is stored as an offset from the tile's rect that decays to zero, so the ring
/// keeps travelling with the tile it is heading for. Pure math.
struct RingCarry: Equatable {
    /// Origin and size difference between the ring's rect and the target tile's rect (zero once arrived).
    var offset = CGRect.zero
    /// When the glide began; nil while it waits for the first frame (the ring stays where it was, like the tiles).
    var start: Double?
    static let omega = 30.0
    /// By this long after it started the ring has landed on its tile (to a few hundredths of a point).
    static let settleTime = 0.45

    /// Fraction of the way (0...1) `t` seconds after the start: a critically damped spring from rest.
    static func progress(_ t: Double) -> Double { t <= 0 ? 0 : 1 - (1 + omega * t) * exp(-omega * t) }

    /// A ring that is at `current` now and heads for `base`; its clock starts at `now`, or at the first frame when nil.
    static func from(_ current: CGRect, to base: CGRect, at now: Double?) -> RingCarry {
        RingCarry(offset: CGRect(x: current.minX - base.minX, y: current.minY - base.minY, width: current.width - base.width, height: current.height - base.height), start: now)
    }
    func rect(on base: CGRect, at now: Double) -> CGRect {
        let k = 1 - Self.progress(start.map { now - $0 } ?? 0)
        return CGRect(x: base.minX + offset.minX * k, y: base.minY + offset.minY * k, width: base.width + offset.width * k, height: base.height + offset.height * k)
    }
}

/// The order in which windows that all change frame in one step are written, so that none is ever shown over a window that has
/// not moved yet: a window whose new frame covers another one's current frame waits for that one. Only what shows counts (`within`,
/// the display: a parked window's frame reaches far past its edge), and a window that does not move neither waits nor is waited
/// for. Windows that cannot be put in such an order (two that swap places) keep their id order. Pure.
enum WriteOrder {
    /// Each window's place in the order, from 1; a window missing from `old` or `new`, or that does not move, has none and is written first.
    static func rank(old: [UInt32: CGRect], new: [UInt32: CGRect], within: CGRect = .infinite) -> [UInt32: Int] {
        func moves(_ id: UInt32) -> Bool {
            guard let o = old[id], let n = new[id] else { return false }
            return abs(o.minX - n.minX) >= 1 || abs(o.minY - n.minY) >= 1 || StripMove.resizes(o, n)
        }
        let ids = new.keys.filter(moves).sorted()
        func covers(_ w: UInt32, _ v: UInt32) -> Bool {
            let i = new[w]!.intersection(within).intersection(old[v]!.intersection(within))
            return !i.isNull && i.width > 2 && i.height > 2
        }
        var waitsFor: [UInt32: Set<UInt32>] = [:]
        for w in ids { waitsFor[w] = Set(ids.filter { $0 != w && covers(w, $0) }) }
        var rank: [UInt32: Int] = [:], left = ids
        while !left.isEmpty {
            let next = left.first { waitsFor[$0]!.allSatisfy { rank[$0] != nil } } ?? left[0]
            rank[next] = rank.count + 1
            left.removeAll { $0 == next }
        }
        return rank
    }
}

/// Which windows to capture first when the keyboard has been quiet: the focused one, then the ones on screen, then the rest in reach.
enum SnapshotOrder {
    static func sorted(_ ids: [(id: UInt32, onScreen: Bool)], focus: UInt32?) -> [UInt32] {
        func rank(_ e: (id: UInt32, onScreen: Bool)) -> Int { e.id == focus ? 0 : e.onScreen ? 1 : 2 }
        return ids.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element.id)
    }
}
