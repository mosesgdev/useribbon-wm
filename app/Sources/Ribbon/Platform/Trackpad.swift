import AppKit

/// Three-finger horizontal scroll from raw trackpad contacts, via the private MultitouchSupport.framework
/// (dlopen'd; if anything is missing the feature is simply unavailable). Optional and non-essential.
///
/// Callbacks arrive on a private thread. The gesture state machine runs there under a lock; results are
/// delivered on the main queue, where the display-paced swipe pipeline sums them per frame.
///
/// Contact layout (64-bit, from the long-known reverse-engineered `MTTouch` struct): 96 bytes per contact,
/// state (Int32) at offset 20 (4 = touching), normalized position (Float x, y; 0...1, x grows to the right
/// from the user's point of view) at offsets 32 / 36. Every read is bounds- and sanity-checked.
final class TrackpadScroller: @unchecked Sendable {
    /// Fraction of the pad width the fingers moved since the last delivery (+ = fingers moved right).
    var onScroll: (@Sendable (Double) -> Void)?
    /// Fingers recognised as a swipe, with the (device) time of the first frame the contacts qualified at. Delivered right before the first `onScroll`.
    var onBegin: (@Sendable (Double) -> Void)?
    /// The configured number of fingers rests on the pad (once per touch): time to get the overlay ready.
    var onTouch: (@Sendable () -> Void)?
    /// Fingers lifted after a scroll; velocity in pad widths per second (+ = right).
    var onEnd: (@Sendable (Double) -> Void)?

    static let shared = TrackpadScroller()

    // MARK: availability

    private typealias Device = UnsafeMutableRawPointer
    private typealias Callback = @convention(c) (Device?, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias PlainCallback = @convention(c) (Device?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterRefcon = @convention(c) (Device, Callback, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterPlain = @convention(c) (Device, PlainCallback) -> Void
    private typealias Start = @convention(c) (Device, Int32) -> Void
    private typealias Stop = @convention(c) (Device) -> Void

    private struct API {
        let createList: CreateList
        let registerRefcon: RegisterRefcon?
        let registerPlain: RegisterPlain?
        let start: Start
        let stop: Stop?
    }

    private static let api: API? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let list = sym("MTDeviceCreateList", CreateList.self), let start = sym("MTDeviceStart", Start.self) else { return nil }
        let refcon = sym("MTRegisterContactFrameCallbackWithRefcon", RegisterRefcon.self)
        let plain = sym("MTRegisterContactFrameCallback", RegisterPlain.self)
        guard refcon != nil || plain != nil else { return nil }
        return API(createList: list, registerRefcon: refcon, registerPlain: plain, start: start, stop: sym("MTDeviceStop", Stop.self))
    }()

    /// False when the framework or a needed symbol is missing (the Settings toggle then reads "Not available").
    static var isAvailable: Bool { api != nil && !stalled }
    /// Set when the self-check saw the user use the pad for a while but MultitouchSupport delivered no frames at all.
    nonisolated(unsafe) static var stalled = false
    private let countLock = NSLock()
    private var frameTotal = 0
    /// Contact frames received since launch (any number of fingers). Zero while the pad is being used = no touch data.
    var receivedFrames: Int { countLock.lock(); defer { countLock.unlock() }; return frameTotal }

    // MARK: lifecycle (main thread)

    private var devices: CFArray?
    private var running = false

    func start() {
        guard !running, let api = Self.api, let list = api.createList()?.takeRetainedValue() else { return }
        devices = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            if let reg = api.registerRefcon {
                reg(dev, { _, touches, n, t, _, _ in TrackpadScroller.shared.frame(touches, Int(n), t); return 0 }, nil)
            } else if let reg = api.registerPlain {
                reg(dev, { _, touches, n, t, _ in TrackpadScroller.shared.frame(touches, Int(n), t); return 0 })
            }
            api.start(dev, 0)
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        if let api = Self.api, let list = devices {
            for i in 0..<CFArrayGetCount(list) {
                if let raw = CFArrayGetValueAtIndex(list, i) { api.stop?(UnsafeMutableRawPointer(mutating: raw)) }
            }
        }
        devices = nil
        lock.lock(); resetLocked(); lock.unlock()
    }

    /// Devices can stop delivering after sleep; restart them.
    func restart() { guard running else { return }; stop(); start() }

    // MARK: gesture state machine (callback thread)

    private enum Phase { case idle, armed }
    private let lock = NSLock()
    private var phase = Phase.idle
    private var last = SIMD2<Double>(0, 0)
    private var samples: [(t: Double, x: Double)] = []
    /// Fingers that drive the ribbon (3 or 4); set before `start()`.
    var fingerCount: Int { get { SwipeGate.shared.needed } set { SwipeGate.shared.needed = newValue } }
    private var contactFilter = ContactFilter()
    private var smoother = LightSmoother()
    private var lastSmoothed = 0.0
    private var pendingDx = 0.0
    private var pendingBegin: Double?
    private var pendingEnd: Double?
    private var flushScheduled = false
    private var touchReported = false

    private func frame(_ touches: UnsafeMutableRawPointer?, _ count: Int, _ time: Double) {
        countLock.lock(); frameTotal += 1; countLock.unlock()
        var pts: [ContactFilter.Contact] = [], fingerIDs: [Int32] = []
        if let touches, count > 0, count <= 16 {
            for i in 0..<count {
                let base = touches + i * 96
                let state = base.loadUnaligned(fromByteOffset: 20, as: Int32.self)
                guard state == 4 else { continue }
                let x = Double(base.loadUnaligned(fromByteOffset: 32, as: Float.self))
                let y = Double(base.loadUnaligned(fromByteOffset: 36, as: Float.self))
                guard x.isFinite, y.isFinite, (-0.2...1.2).contains(x), (-0.2...1.2).contains(y) else { pts = []; break }
                // MTTouch: identifier (Int32) at 16 and fingerId at 24 are stable while a finger stays down.
                pts.append((base.loadUnaligned(fromByteOffset: 16, as: Int32.self), SIMD2(x, y)))
                fingerIDs.append(base.loadUnaligned(fromByteOffset: 24, as: Int32.self))
            }
            if Set(pts.map(\.id)).count != pts.count, Set(fingerIDs).count == pts.count {   // identifiers unusable
                pts = zip(fingerIDs, pts).map { ($0, $1.pos) }
            }
        }
        process(pts, time)
    }

    /// The gesture state machine proper, fed with the touching contacts of one frame (also fed by `qa_swipe`).
    func process(_ contacts: [ContactFilter.Contact], _ time: Double) {
        lock.lock()
        defer { lock.unlock() }
        contactFilter.needed = fingerCount
        if contacts.count >= fingerCount { if !touchReported { touchReported = true; DispatchQueue.main.async { [self] in onTouch?() } } }
        else if contacts.count < 2 { touchReported = false }
        let r = contactFilter.feed(contacts, at: time)
        SwipeGate.shared.contacts(r.gate, at: CACurrentMediaTime())
        guard let pts = r.swipe, pts.count == fingerCount else {
            if phase == .armed { finishLocked(time) }
            phase = .idle; samples = []
            return
        }
        // The contacts' centroid drives the ribbon; no filtering beyond a very light smoother, so the content follows the fingers.
        let c = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
        switch phase {
        case .idle:
            // Recognised as soon as the contacts moved together (0.5% of the pad): start now, with the travel so far.
            phase = .armed; last = c; smoother.reset()
            let fx = smoother.filter(c.x)
            samples = [(time, fx - r.travel), (time, fx)]
            pendingBegin = CACurrentMediaTime()      // arrival time of the qualifying frame (same clock as the screen)
            pendingDx += r.travel; lastSmoothed = fx
            scheduleFlushLocked()
        case .armed:
            let fx = smoother.filter(c.x)
            pendingDx += fx - lastSmoothed
            lastSmoothed = fx; last = c
            samples.append((time, fx))
            samples.removeAll { time - $0.t > 0.1 }
            scheduleFlushLocked()
        }
    }

    private func finishLocked(_ now: Double) {
        // Velocity over the last ~100ms of three-finger motion; fingers that stopped before lifting give 0.
        var v = 0.0
        if let a = samples.first, let b = samples.last, b.t > a.t, now - b.t < 0.08 { v = (b.x - a.x) / (b.t - a.t) }
        pendingEnd = v
        samples = []
        scheduleFlushLocked()
    }

    private func resetLocked() { phase = .idle; samples = []; pendingDx = 0; pendingBegin = nil; pendingEnd = nil; smoother.reset(); contactFilter.reset() }

    /// Deliveries coalesce while the main queue is busy; the display-paced consumer sums them, so nothing is lost.
    /// An end flushes straight away (after any pending movement).
    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [self] in
            lock.lock()
            let dx = pendingDx, end = pendingEnd, begin = pendingBegin
            pendingDx = 0; pendingEnd = nil; pendingBegin = nil; flushScheduled = false
            lock.unlock()
            if let begin { onBegin?(begin) }
            if dx != 0 { onScroll?(dx) }
            if let end { onEnd?(end) }
        }
    }
}
