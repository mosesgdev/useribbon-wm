import Foundation
import CoreGraphics
import ApplicationServices
import QuartzCore

/// The positions a `SwipeWriter` wrote, in order (its writes run on the app queues).
final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private struct Row { let id: UInt32; let pos: CGPoint }
    private var rows: [Row] = []
    func add(_ id: UInt32, _ p: CGPoint) { lock.lock(); rows.append(Row(id: id, pos: p)); lock.unlock() }
    func clear() { lock.lock(); rows = []; lock.unlock() }
    func xs(_ id: UInt32) -> [Double] { lock.lock(); defer { lock.unlock() }; return rows.filter { $0.id == id }.map { $0.pos.x } }
}

/// How often each app was asked something (a stand-in for a slow AX call).
final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n: [pid_t: Int] = [:]
    func bump(_ pid: pid_t) { lock.lock(); n[pid, default: 0] += 1; lock.unlock() }
    subscript(_ pid: pid_t) -> Int { lock.lock(); defer { lock.unlock() }; return n[pid] ?? 0 }
}

/// Selftest for the pure swipe pieces: filter, swallow state machine, latest-wins pacing, spring (run from `SelfTest`).
enum SwipeTests {
    static func run(_ check: (Bool, String) -> Void) {
        do {   // Keyboard glide: the strip is rigid in logical space, parked windows stay at their edge, no teleports.
        let vis = CGRect(x: 0, y: 25, width: 3840, height: 1175), w = 800.0, y = 37.0
        let parkL = -w + 1, parkR = 3839.0
        func rect(_ x: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: 900) }
        func move(_ x0: Double, _ x1: Double, on0: Bool = true, on1: Bool = true, lx0: Double? = nil, lx1: Double? = nil) -> StripMove? {
            StripMove.make(old: rect(x0), oldLX: lx0 ?? x0, oldOn: on0, new: rect(x1), newLX: lx1 ?? x1, newOn: on1, visible: vis)
        }
        func spring(_ m: StripMove, _ t: Double) -> Double {
            StripMove.hold(CriticalSpring(from: m.lxFrom, target: m.lxTo, velocity: 0, omega: SwipeWriter.glideOmega).value(at: t), lo: m.lo, hi: m.hi)
        }
        let shift = move(424, 1236)!, shift2 = move(1236, 2048)!
        check(abs((spring(shift2, 0.05) - spring(shift, 0.05)) - 812) < 1e-6 && abs((spring(shift2, 0.2) - spring(shift, 0.2)) - 812) < 1e-6,
              "glide: windows of one move keep their distance at every instant (rigid strip)")
        let leaving = move(424, parkL, on1: false, lx1: -1500)!, entering = move(parkR, 2048, on0: false, lx0: 5000)!
        check(leaving.lo == parkL && leaving.hi == nil && spring(leaving, 0) == 424 && spring(leaving, 0.01) > 300,
              "glide: a leaving window slides off from where it is (no jump at t=0)")
        check(spring(leaving, 1) == parkL && stride(from: 0.0, through: 1.0, by: 0.01).allSatisfy { spring(leaving, $0) >= parkL },
              "glide: a leaving window stops at its sliver")
        check(entering.hi == parkR && spring(entering, 0) == parkR && spring(entering, 0.01) == parkR && spring(entering, 0.05) < parkR && spring(entering, 0.5) < 3000 && abs(spring(entering, 2) - 2048) < 1,
              "glide: an entering window appears only when the strip reaches the edge, then slides in")
        let wrong = StripMove.make(old: rect(424), oldLX: 424, oldOn: true, new: rect(1500), newLX: -3000, newOn: false, visible: vis)
        check(wrong == nil, "glide: a window parked somewhere the strip cannot reach jumps")
        check(move(424, parkL, on1: false, lx1: 4300) == nil && move(parkR, 424, on0: false, lx0: -1200) == nil,
              "glide: a park reflected to the far edge (a neighbouring display) jumps instead of sliding across the neighbour")
        check(move(424, 424) == nil && move(parkR, parkR, on0: false, on1: false, lx0: 5000, lx1: 6000) == nil, "glide: nothing to glide when nothing moves or both ends are parked on one side")
        check(move(parkL, parkR, on0: false, on1: false, lx0: -900, lx1: 5000).map { $0.lo == parkL && $0.hi == parkR } == true,
              "glide: a window crossing from one parked side to the other is held at both edges")
        check(StripMove.make(old: rect(424), oldLX: 424, oldOn: true, new: CGRect(x: 424, y: y, width: 600, height: 900), newLX: 424, newOn: true, visible: vis) == nil
              && StripMove.make(old: rect(424), oldLX: nil, oldOn: true, new: rect(900), newLX: 900, newOn: true, visible: vis) == nil
              && StripMove.make(old: rect(424), oldLX: 424, oldOn: true, new: rect(900), newLX: nil, newOn: true, visible: vis) == nil,
              "glide: size changes and windows outside the active ribbon jump")
        let drop = StripMove.make(old: CGRect(x: 600, y: 300, width: w, height: 900), oldLX: 600, oldOn: true, new: rect(424), newLX: 424, newOn: true, visible: vis)!
        check(drop.yFrom == 300 && drop.yTo == y && drop.lxFrom == 600 && drop.lxTo == 424, "glide: a window dropped back into its slot glides on both axes")
        check(StripMove.make(old: rect(424), oldLX: 424, oldOn: true, new: CGRect(x: parkR, y: 400, width: w, height: 900), newLX: 5000, newOn: false, visible: vis) == nil,
              "glide: parking never combines with a y change")
        // Retarget: a new spring from the current value and velocity continues the motion (position and speed are continuous).
        let first = CriticalSpring(from: 424, target: 1236, velocity: 0, omega: SwipeWriter.glideOmega), t1 = 0.04
        let (p1, v1) = (first.value(at: t1), first.velocity(at: t1))
        let again = CriticalSpring(from: p1, target: 2048, velocity: v1, omega: SwipeWriter.glideOmega)
        check(abs(again.value(at: 0) - p1) < 1e-9 && abs(again.velocity(at: 0) - v1) < 1e-6 && v1 > 1000,
              "glide: a retarget starts at the current position with the current velocity")
        check((1...50).allSatisfy { again.value(at: Double($0) * 0.01) >= again.value(at: Double($0 - 1) * 0.01) - 1e-9 },
              "glide: a retarget in the same direction never slows down and back up")
        let spring0 = CriticalSpring(from: 0, target: 1900, velocity: 0, omega: SwipeWriter.glideOmega)
        check(spring0.value(at: 1.0 / 60) < 0.2 * 1900 && spring0.settled(at: 0.4) && !spring0.settled(at: 0.05),
              "glide: the first frame covers a fifth of the way at most and the move is over in 400 ms")
        }
        do {   // Release in direct mode: the strip settles rigidly; a window that parks does not hang in its neighbour's way.
        let vis = CGRect(x: 0, y: 25, width: 3840, height: 1175), w = 800.0, y = 37.0
        let parkL = -w + 1, parkR = 3839.0, size = CGSize(width: w, height: 900)
        func release(_ x0: Double, on: Bool = true, lxWas: Double? = nil, _ x1: Double, lx1: Double?, on1: Bool, pin: PinEdge? = nil) -> StripMove? {
            StripMove.release(origin: CGPoint(x: x0, y: y), on: on, lxWas: lxWas, new: CGRect(origin: CGPoint(x: x1, y: y), size: size), newLX: lx1, newOn: on1, visible: vis, pin: pin)
        }
        let leave = release(300, parkL, lx1: -1200, on1: false), come = release(parkR, on: false, lxWas: 4300, 2400, lx1: 2400, on1: true)
        check(leave.map { $0.lxFrom == 300 && $0.lxTo == -1200 && $0.lo == parkL && $0.hi == nil } == true,
              "release: a visible window that parks slides on towards its logical place and is held at its sliver")
        check(come.map { $0.lxFrom == 4300 && $0.lxTo == 2400 && $0.hi == parkR && $0.lo == nil } == true,
              "release: a parked window that appears starts from its logical place, held at the edge until the strip reaches it")
        check(release(-800, parkL, lx1: -1200, on1: false) == nil && release(3900, parkR, lx1: 5000, on1: false) == nil,
              "release: a window already off the display is written at once")
        check(release(300, 1100, lx1: 1100, on1: true).map { $0.lo == nil && $0.hi == nil && $0.lxTo == 1100 } == true
              && release(parkL, on: false, lxWas: nil, 500, lx1: 500, on1: true) == nil && release(300, 300, lx1: 300, on1: true) == nil,
              "release: a window that stays on screen slides unheld; one without a logical place, or that does not move, does not slide")

        // The writer: a window that ends parked leaves on the spring (no freeze, no hop), one without a slide is written at once.
        let writer = SwipeWriter(), me = AXUIElementCreateApplication(getpid()), log = WriteLog()
        writer.write = { id, _, p in log.add(id, p); return .success }
        func frame(_ t: Double) { writer.step(at: t); writer.waitIdle() }
        writer.post(1, el: me, rect: CGRect(x: 300, y: y, width: w, height: 900), onScreen: true, at: 0)
        writer.post(2, el: me, rect: CGRect(x: 1112, y: y, width: w, height: 900), onScreen: true, at: 0)
        writer.post(3, el: me, rect: CGRect(x: parkR, y: y, width: w, height: 900), onScreen: false, at: 0)
        frame(0)
        let parkedPos = CGPoint(x: parkL, y: y)
        let targets: [UInt32: SwipeWriter.Target] = [
            1: SwipeWriter.Target(el: me, pid: me.pid, pos: parkedPos, onScreen: false, posted: 1),
            2: SwipeWriter.Target(el: me, pid: me.pid, pos: CGPoint(x: 424, y: y), onScreen: true, posted: 1),
            3: SwipeWriter.Target(el: me, pid: me.pid, pos: CGPoint(x: 1236, y: y), onScreen: true, posted: 1)]
        log.clear()
        writer.settle(to: targets, moves: [1: leave!, 2: release(1112, 424, lx1: 424, on1: true)!], velocity: 0, at: 1)
        for i in 1...80 { frame(1 + Double(i) / 60) }
        let leaving = log.xs(1), steps = zip([300.0] + leaving, leaving).map { abs($0 - $1) }
        check(log.xs(3) == [1236] && writer.isShown(3) == true, "release: a window with no slide is written at once at its place")
        check(leaving.count > 8 && leaving[1] < 300 && leaving.contains { $0 > parkL + 10 && $0 < 250 } && (steps.max() ?? 0) < 450,
              "release: a leaving window moves from the first frames and never hops (\(leaving.count) writes, largest step \(Int(steps.max() ?? 0)) px)")
        check(leaving.allSatisfy { $0 >= parkL } && leaving.last == parkL && writer.position(1) == parkedPos && log.xs(2).last == 424 && !writer.isSettling,
              "release: it stops at its sliver while its neighbour lands on its place, and the glide is over")
        check(zip(leaving, leaving.dropFirst()).allSatisfy { $0 > $1 }, "release: a leaving window only moves away")

        // A window that closes, or that the user takes hold of, while the others settle is not written any more.
        let rest = SwipeWriter(), restLog = WriteLog()
        rest.write = { id, _, p in restLog.add(id, p); return .success }
        rest.post(1, el: me, rect: CGRect(x: 300, y: y, width: w, height: 900), onScreen: true, at: 0)
        rest.post(2, el: me, rect: CGRect(x: 1112, y: y, width: w, height: 900), onScreen: true, at: 0)
        rest.step(at: 0); rest.waitIdle()
        rest.settle(to: [1: SwipeWriter.Target(el: me, pid: me.pid, pos: parkedPos, onScreen: false, posted: 1),
                         2: SwipeWriter.Target(el: me, pid: me.pid, pos: CGPoint(x: 424, y: y), onScreen: true, posted: 1)],
                    moves: [1: leave!, 2: release(1112, 424, lx1: 424, on1: true)!], velocity: 0, at: 1)
        for i in 1...6 { rest.step(at: 1 + Double(i) / 60); rest.waitIdle() }
        let written = restLog.xs(1).count
        rest.forget(1)
        for i in 7...80 { rest.step(at: 1 + Double(i) / 60); rest.waitIdle() }
        check(written > 1 && restLog.xs(1).count == written && restLog.xs(2).last == 424 && !rest.isSettling,
              "release: a window forgotten mid-settle is not written again, the others still land")

        // A press that parks a window again while it is still settling off after a swipe takes it on to its sliver: its writer knows
        // where the settle left it (not where the plan had it), so the last write is not skipped as "already there".
        let again = SwipeWriter(), againLog = WriteLog()
        again.write = { id, _, p in againLog.add(id, p); return .success }
        again.quiet = { _ in false }
        again.post(1, el: me, rect: CGRect(x: 300, y: y, width: w, height: 900), onScreen: true, at: 0)
        again.step(at: 0); again.waitIdle()
        again.settle(to: [1: SwipeWriter.Target(el: me, pid: me.pid, pos: parkedPos, onScreen: false, posted: 1)], moves: [1: leave!], velocity: 0, at: 1)
        for i in 1...6 { again.step(at: 1 + Double(i) / 60); again.waitIdle() }
        let midway = againLog.xs(1).last ?? 0
        let parkedRect = CGRect(x: parkL, y: y, width: w, height: 900)
        again.glide([(1, me, StripMove.make(old: parkedRect, oldLX: -1200, oldOn: false, new: parkedRect, newLX: -2012, newOn: false, visible: vis, gliding: true)!)], at: 1 + 7.0 / 60)
        for i in 8...50 { again.step(at: 1 + Double(i) / 60); again.waitIdle() }
        check(midway > parkL + 10 && againLog.xs(1).last == parkL && !again.active,
              "release: a window still settling off when a press parks it again ends at its sliver (stopped at \(Int(midway)) px, ends at \(Int(againLog.xs(1).last ?? 0)))")
        }
        do {   // A keyboard glide in direct mode starts its windows together, once every app they live in is ready.
        let vis = CGRect(x: 0, y: 25, width: 3840, height: 1175), w = 800.0, y = 37.0
        func slide(_ x0: Double, _ x1: Double) -> StripMove {
            StripMove.make(old: CGRect(x: x0, y: y, width: w, height: 900), oldLX: x0, oldOn: true, new: CGRect(x: x1, y: y, width: w, height: 900), newLX: x1, newOn: true, visible: vis)!
        }
        let fast = AXUIElementCreateApplication(getpid()), slow = AXUIElementCreateApplication(1)
        let base = CACurrentMediaTime()
        func make() -> (SwipeWriter, WriteLog) { let g = SwipeWriter(), l = WriteLog(); g.write = { id, _, p in l.add(id, p); return .success }; return (g, l) }
        let (g, log) = make(), calls = CallCount(), gate = DispatchSemaphore(value: 0)
        g.quiet = { pid in calls.bump(pid); if pid == 1 { gate.wait() }; return false }     // the app behind window 2 is slow to answer
        g.glide([(1, fast, slide(424, 1236)), (2, slow, slide(1236, 2048))], at: base)
        for i in 1...4 { g.step(at: base + Double(i) / 60) }
        check(log.xs(1).isEmpty && log.xs(2).isEmpty && g.position(1) == CGPoint(x: 424, y: y) && g.position(2) == CGPoint(x: 1236, y: y),
              "glide start: while one app has not answered, no window of the move steps ahead of the others")
        gate.signal(); g.waitIdle()
        g.step(at: base + 4.4 / 60); g.waitIdle()
        check(log.xs(1).isEmpty && log.xs(2).isEmpty, "glide start: the clock starts when the last app is ready (nothing has moved yet at its zero)")
        g.step(at: base + 5.4 / 60); g.waitIdle()
        check(log.xs(1).count == 1 && log.xs(2).count == 1 && abs(log.xs(1)[0] - 424 - (log.xs(2)[0] - 1236)) <= 1 && log.xs(1)[0] > 424 + 20,
              "glide start: both windows take their first step in the same frame, the same distance")
        for i in 7...40 { g.step(at: base + Double(i) / 60); g.waitIdle() }
        check(log.xs(1).last == 1236 && log.xs(2).last == 2048 && !g.active, "glide start: the move lands both windows")

        // An app that is slow past the limit no longer holds the move back.
        let (h, hlog) = make(), fastAsked = DispatchSemaphore(value: 0)
        h.quiet = { pid in if pid == 1 { Thread.sleep(forTimeInterval: 0.8) } else { fastAsked.signal() }; return false }
        h.glide([(1, fast, slide(424, 1236)), (2, slow, slide(1236, 2048))], at: base)
        fastAsked.wait(); Thread.sleep(forTimeInterval: 0.03)      // the app that answers has answered and is idle again, whatever the load
        for i in 1...4 { h.step(at: base + Double(i) / 60) }
        check(hlog.xs(1).isEmpty, "glide start: it waits for a slow app only a moment...")
        h.step(at: base + SwipeWriter.startWait + 0.001); h.step(at: base + SwipeWriter.startWait + 0.02); h.step(at: base + SwipeWriter.startWait + 0.036)
        for _ in 0..<80 where hlog.xs(1).isEmpty { Thread.sleep(forTimeInterval: 0.005) }      // the write runs on the app's queue
        check(!hlog.xs(1).isEmpty && hlog.xs(2).isEmpty, "glide start: ...then the apps that answer go on without it")
        h.waitIdle()

        // Every glide asks each of its apps first (the flag, and a wake-up for an idle app); an app already in a glide is not asked again.
        let before = calls[getpid()]
        g.glide([(1, fast, slide(1236, 424))], at: base + 2)
        g.glide([(1, fast, slide(1236, 800))], at: base + 2.01)
        g.waitIdle()
        check(calls[getpid()] == before + 1, "glide start: an app is asked once before a glide's first write, however often the glide is retargeted")

        // A window that joins a glide already under way takes its moment from the call, like the windows it joins: it is not left
        // behind by what they have travelled while it waited for its first display frame (a held key brings one in per press).
        let (j, jlog) = make()
        j.quiet = { _ in false }
        j.glide([(1, fast, slide(424, 1236))], at: base + 3)
        j.waitIdle()
        j.step(at: base + 3 + 1.0 / 60); j.waitIdle()
        j.glide([(1, fast, slide(424, 1236)), (3, fast, slide(1236, 2048))], at: base + 3.05)
        j.step(at: base + 3.05 + 1.0 / 60); j.waitIdle()
        let owed = 1236 + CriticalSpring(from: 0, target: 812, velocity: 0, omega: SwipeWriter.glideOmega).value(at: 1.0 / 60)
        check(jlog.xs(3).count == 1 && abs(jlog.xs(3)[0] - owed) <= 1, "glide start: a window that joins a glide in flight starts on the clock of its call, not a frame later")

        // A parked window it brings in starts where the strip has carried it since the layout it was parked in, so it keeps its
        // distance from the window before it instead of lying over it by what the strip still had to travel (a held key).
        func stripX(_ i: Int, _ press: Int) -> Double { 12 + 812 * Double(i - 1 - press) }
        func stripRect(_ i: Int, _ press: Int) -> (CGRect, Bool) {
            let l = stripX(i, press)
            return l + w <= 0 ? (CGRect(x: -w + 1, y: y, width: w, height: 900), false) : l >= 3840 ? (CGRect(x: 3839, y: y, width: w, height: 900), false) : (CGRect(x: l, y: y, width: w, height: 900), true)
        }
        func stripMove(_ i: Int, _ a: Int, _ b: Int, gliding: Bool = false) -> (id: UInt32, el: AXUIElement, move: StripMove)? {
            let (r0, on0) = stripRect(i, a), (r1, on1) = stripRect(i, b)
            return StripMove.make(old: r0, oldLX: stripX(i, a), oldOn: on0, new: r1, newLX: stripX(i, b), newOn: on1, visible: vis, gliding: gliding).map { (UInt32(i), fast, $0) }
        }
        let (k, klog) = make()
        k.quiet = { _ in false }
        let t1 = base + 10
        k.glide((1...6).compactMap { stripMove($0, 0, 1) }, at: t1)                       // first press: the strip moves one window
        k.waitIdle()
        for n in 1...4 { k.step(at: t1 + Double(n) / 60); k.waitIdle() }
        k.glide((2...7).compactMap { stripMove($0, 1, 2) }, at: t1 + 4.4 / 60)            // second press, 66 ms later: window 7 comes in
        var gaps: [Double] = []
        for n in 5...34 {
            k.step(at: t1 + Double(n) / 60); k.waitIdle()
            if let x6 = klog.xs(6).last, let x7 = klog.xs(7).last, x7 < 3835 { gaps.append(x7 - x6) }
        }
        check(gaps.count > 5 && gaps.allSatisfy { abs($0 - 812) <= 2 } && klog.xs(7).last == 3260 && klog.xs(6).last == 2448,
              "glide start: a parked window brought in by a retarget keeps its distance from its neighbour (spacing \(Int(gaps.min() ?? 0))...\(Int(gaps.max() ?? 0)) px, 812 expected)")

        // A window still sliding off when the next press parks it where the last one did goes on with the strip, held at its sliver:
        // it neither stops on screen (to be written to its sliver at once) nor trails the windows beside it (a held key).
        check(stripMove(1, 1, 2) == nil && stripMove(1, 1, 2, gliding: true).map { $0.move.lo == -w + 1 && $0.move.hi == nil && $0.move.lxTo == stripX(1, 2) } == true
              && stripMove(1, 2, 3, gliding: true) != nil && stripMove(7, 0, 0, gliding: true) == nil,
              "glide: a window parked on the same side at both ends moves only while it is still gliding, and then follows the strip held at its sliver")
        let (m2, m2log) = make()
        m2.quiet = { _ in false }
        let t2 = base + 30
        m2.glide((1...6).compactMap { stripMove($0, 0, 1) }, at: t2)
        m2.waitIdle()
        for n in 1...2 { m2.step(at: t2 + Double(n) / 60); m2.waitIdle() }
        m2.glide((1...7).compactMap { stripMove($0, 1, 2, gliding: m2.rides(UInt32($0))) }, at: t2 + 2.4 / 60)
        var spacing: [Double] = []
        for n in 3...40 {
            m2.step(at: t2 + Double(n) / 60); m2.waitIdle()
            if let x1 = m2log.xs(1).last, let x2 = m2log.xs(2).last, x1 > -790, x2 > -790 { spacing.append(x2 - x1) }
        }
        check(spacing.count >= 2 && spacing.allSatisfy { abs($0 - 812) <= 2 } && m2log.xs(1).last == -w + 1 && m2log.xs(2).last == -w + 1 && m2log.xs(3).last == 12,
              "glide: a window sliding off when a retarget parks it again keeps its distance from the next window (spacing \(Int(spacing.min() ?? 0))...\(Int(spacing.max() ?? 0)) px, 812 expected) and stops at its sliver")

        // Beneath a pinned column a parked window's logical x can lie well inside the display; it is still parked, and a retarget
        // still carries it where the strip has moved it.
        func ride(_ lx0: Double, _ lx1: Double, from: Double, parked: Bool, lo: Double? = nil, hi: Double? = nil, on: Bool) -> StripMove {
            StripMove(lxFrom: lx0, lxTo: lx1, yFrom: y, yTo: y, lo: lo, hi: hi, from: CGPoint(x: from, y: y), to: CGPoint(x: lx1, y: y), onScreen: on, parked: parked)
        }
        let beneath = StripMove.make(old: CGRect(x: -1423, y: y, width: 1424, height: 900), oldLX: -467, oldOn: false, new: CGRect(x: 969, y: y, width: 1424, height: 900), newLX: 969, newOn: true, visible: vis)
        check(beneath?.parked == true && beneath?.lo == -1423 && stripMove(2, 0, 1)?.move.parked == false && stripMove(7, 1, 2)?.move.parked == true,
              "glide: a move knows whether its window starts parked, also beneath a pinned column")
        let (pw, pwlog) = make()
        pw.quiet = { _ in false }
        let t3 = base + 40
        pw.glide([(1, fast, ride(969, 2405, from: 969, parked: false, on: true))], at: t3)
        pw.waitIdle()
        for n in 1...3 { pw.step(at: t3 + Double(n) / 60); pw.waitIdle() }
        pw.glide([(1, fast, ride(2405, 3841, from: 2405, parked: false, hi: 3839, on: false)), (2, fast, ride(-467, 969, from: -1423, parked: true, lo: -1423, on: true))], at: t3 + 3.4 / 60)
        var beside: [Double] = []
        for n in 4...40 {
            pw.step(at: t3 + Double(n) / 60); pw.waitIdle()
            if let x1 = pwlog.xs(1).last, let x2 = pwlog.xs(2).last, x1 < 3835, x2 > -1420 { beside.append(x1 - x2) }
        }
        check(beside.count > 3 && beside.allSatisfy { abs($0 - 2872) <= 2 } && pwlog.xs(2).last == 969,
              "glide start: a window parked beneath a pinned column is carried with the strip too (spacing \(Int(beside.min() ?? 0))...\(Int(beside.max() ?? 0)) px, 2872 expected)")
        }
        do {   // A step that resizes a window: neighbours move with its edge, in an order in which nothing lies over a window that has not moved.
        func r(_ x: Double, _ w: Double, y: Double = 37, h: Double = 900) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        check(StripMove.resizes(r(0, 500), r(0, 750)) && StripMove.resizes(r(0, 500), r(0, 500, h: 700)) && !StripMove.resizes(r(0, 500), r(300, 501)) && !StripMove.resizes(r(0, 500), r(900, 500, y: 80)),
              "resize: a window whose size changes cannot slide; a move, or a pixel of rounding, can")
        check(StripMove.resizesVisibly(old: r(0, 500), wasOn: true, new: r(0, 750), nowOn: true) && StripMove.resizesVisibly(old: r(0, 500), wasOn: false, new: r(0, 750), nowOn: true)
              && !StripMove.resizesVisibly(old: r(3839, 500), wasOn: false, new: r(3839, 750), nowOn: false) && !StripMove.resizesVisibly(old: r(0, 500), wasOn: true, new: r(300, 500), nowOn: true),
              "resize: only a change of size the user can see stops the neighbours from sliding")
        // Three columns side by side; the middle one widens by 250, the right one makes room: it has to move first.
        let wide = WriteOrder.rank(old: [1: r(12, 494), 2: r(518, 494), 3: r(1024, 494)], new: [1: r(12, 494), 2: r(518, 744), 3: r(1274, 494)])
        check(wide[3]! < wide[2]!, "resize: a window that widens waits for its right neighbour to make room")
        let narrow = WriteOrder.rank(old: [1: r(12, 494), 2: r(518, 744), 3: r(1274, 494)], new: [1: r(12, 494), 2: r(518, 494), 3: r(1024, 494)])
        check(narrow[2]! < narrow[3]!, "resize: a window that narrows goes first, then its neighbour moves into the room")
        let both = WriteOrder.rank(old: [1: r(12, 494), 2: r(518, 494), 3: r(1024, 494), 4: r(1530, 494)], new: [1: r(12, 494), 2: r(518, 744), 3: r(1274, 494), 4: r(1780, 494)])
        check(both[4]! < both[3]! && both[3]! < both[2]!, "resize: a chain of windows pushed aside is written from the far end")
        let swap = WriteOrder.rank(old: [1: r(12, 494), 2: r(518, 494)], new: [1: r(518, 494), 2: r(12, 494)])
        check(swap == [1: 1, 2: 2], "resize: windows that swap places keep their id order")
        let stack = WriteOrder.rank(old: [1: r(12, 494, y: 37, h: 440), 2: r(12, 494, y: 489, h: 448)], new: [1: r(12, 494, y: 37, h: 600), 2: r(12, 494, y: 649, h: 288)])
        check(stack[2]! < stack[1]!, "resize: in a stack the window that grows waits for the one below it to give way")
        check(WriteOrder.rank(old: [1: r(12, 494)], new: [1: r(100, 494), 5: r(600, 494)]) == [1: 1], "resize: a window the order knows nothing about has no place in it")
        // The display: windows parked beside it reach far past its edge and must not tie the windows on it together.
        let disp = CGRect(x: 0, y: 25, width: 3840, height: 1175)
        let pinned = WriteOrder.rank(old: [2: r(969, 1446, y: 42, h: 1056), 3: r(2427, 1424, y: 42, h: 1056), 4: r(3839, 1423, y: 42, h: 1056), 5: r(3839, 1424, y: 42, h: 1056)],
                                     new: [2: r(969, 1903, y: 42, h: 1056), 3: r(2884, 1423, y: 42, h: 1056), 4: r(3839, 1423, y: 42, h: 1056), 5: r(3839, 1424, y: 42, h: 1056)], within: disp)
        check(pinned[3]! < pinned[2]! && pinned[4] == nil && pinned[5] == nil, "resize: parked windows reaching past the display and windows that do not move take no part in the order")
        // The pairs above never overlap at any step of the order: simulate the writes.
        func overlapFree(_ old: [UInt32: CGRect], _ new: [UInt32: CGRect]) -> Bool {
            var now = old
            for id in WriteOrder.rank(old: old, new: new).sorted(by: { $0.value < $1.value }).map(\.key) {
                now[id] = new[id]!
                if now.contains(where: { a in now.contains { b in a.key < b.key && a.value.intersection(b.value).width > 2 && a.value.intersection(b.value).height > 2 } }) { return false }
            }
            return true
        }
        check(overlapFree([1: r(12, 494), 2: r(518, 494), 3: r(1024, 494), 4: r(1530, 494)], [1: r(12, 494), 2: r(518, 744), 3: r(1274, 494), 4: r(1780, 494)])
              && overlapFree([1: r(12, 494), 2: r(518, 744), 3: r(1274, 494)], [1: r(12, 494), 2: r(518, 494), 3: r(1024, 494)])
              && overlapFree([1: r(12, 494), 2: r(518, 494), 3: r(1024, 494)], [1: r(12, 300), 2: r(324, 900), 3: r(1236, 494)]),
              "resize: written in that order, no step shows two windows over each other")
        }
        // The pin's shadow follows the window's own corner, read off the snapshot (2x, a 26 pt continuous-ish corner).
        func rounded(_ r: CGFloat?) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            if let r { ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 400, height: 300), cornerWidth: r * 2, cornerHeight: r * 2, transform: nil)); ctx.setFillColor(gray: 1, alpha: 1); ctx.fillPath() }
            return ctx.makeImage()
        }
        let r26 = rounded(26).flatMap { SwipeOverlay.cornerRadius(of: $0, scale: 2) }, r10 = rounded(10).flatMap { SwipeOverlay.cornerRadius(of: $0, scale: 2) }
        check(r26.map { abs($0 - 26) < 2 } == true && r10.map { abs($0 - 10) < 2 } == true && rounded(nil).flatMap { SwipeOverlay.cornerRadius(of: $0, scale: 2) } == nil,
              "pin edge: the shadow's corner is measured from the window snapshot (26 pt and 10 pt corners; none in a transparent image)")
        // A window that refuses its planned size is drawn as it really is (planned x, real height and size), never fitted.
        let planR = CGRect(x: 1926, y: 42, width: 1902, height: 1056)
        check(SwipeOverlay.look(plan: planR, real: CGRect(x: 3839, y: 30, width: 1902, height: 1182)) == CGRect(x: 1926, y: 30, width: 1902, height: 1182)
              && SwipeOverlay.look(plan: planR, real: CGRect(x: 1927, y: 43, width: 1901, height: 1057)) == planR
              && SwipeOverlay.look(plan: planR, real: nil) == planR,
              "overlay: a window that refuses its planned size keeps its real size and height on the overlay; one that obeys keeps the plan")
        // The backdrop keeps the wallpaper, desktop icons and unmanaged normal windows; the Dock, menu bar and banners stay live above.
        let ws: [(id: UInt32, layer: Int, pid: pid_t?)] = [(1, -2147483624, 90), (2, -2147483603, 91), (3, 0, 92), (4, 0, 93), (5, 20, 90), (6, 24, 94), (7, 23, 95), (8, 2, 77)]
        check(SnapshotStore.backdropHides(ws, managed: [4], ownPID: 77) == [4, 5, 6, 7, 8],
              "overlay backdrop: managed and own windows and everything above the overlay (Dock, menu bar, banners) are left out; wallpaper, desktop and unmanaged windows stay")
        // Light smoother: first sample passes, noise is calmed a little, a ramp is followed within a quarter of a sample.
        var sm = LightSmoother()
        check(sm.filter(0.5) == 0.5, "swipe: smoother passes the first sample")
        var ramp = LightSmoother(), lastOut = 0.0
        for i in 0..<100 { lastOut = ramp.filter(0.2 + 0.01 * Double(i)) }
        check(abs(lastOut - (0.2 + 0.99)) < 0.0026 + 1e-9, "swipe: smoother lags a ramp by a quarter of a sample (no perceptible lag)")

        // Swallow state machine (phases: 1 began, 2 changed, 4 ended; momentum 1/2/3).
        let gate = SwipeGate()
        var t = 100.0
        func tick(_ dt: Double = 0.01) { t += dt }
        check(!gate.swallowScroll(phase: 1, momentum: 0, at: t), "swipe: no fingers, scroll passes")
        gate.contacts(2, at: t); tick()
        check(!gate.swallowScroll(phase: 1, momentum: 0, at: t) && !gate.swallowScroll(phase: 2, momentum: 0, at: t), "swipe: two fingers pass")
        check(!gate.swallowGesture(at: t), "swipe: two-finger gestures pass")
        gate.contacts(0, at: t); tick(0.5)
        gate.contacts(3, at: t); tick()
        check(gate.swallowScroll(phase: 1, momentum: 0, at: t) && gate.swallowScroll(phase: 2, momentum: 0, at: t), "swipe: three fingers swallow scroll")
        check(gate.swallowGesture(at: t), "swipe: three fingers swallow gesture events")
        gate.contacts(2, at: t); tick()
        check(gate.swallowScroll(phase: 2, momentum: 0, at: t), "swipe: one finger lifting keeps swallowing")
        gate.contacts(0, at: t); tick(0.02)
        check(gate.swallowScroll(phase: 4, momentum: 0, at: t), "swipe: trailing end event inside the grace window is swallowed")
        tick(0.2)
        check(gate.swallowScroll(phase: 0, momentum: 1, at: t) && gate.swallowScroll(phase: 0, momentum: 2, at: t), "swipe: momentum after a three-finger gesture is swallowed")
        check(gate.swallowScroll(phase: 0, momentum: 3, at: t), "swipe: momentum end is swallowed too")
        check(!gate.swallowScroll(phase: 0, momentum: 2, at: t + 0.1), "swipe: after momentum end nothing is swallowed")
        tick(0.3)
        gate.contacts(2, at: t); tick()
        check(!gate.swallowScroll(phase: 1, momentum: 0, at: t) && !gate.swallowScroll(phase: 2, momentum: 0, at: t), "swipe: a new two-finger scroll passes")
        // Momentum of a two-finger scroll is never swallowed; a plain wheel passes.
        check(!gate.swallowScroll(phase: 4, momentum: 0, at: t) && !gate.swallowScroll(phase: 0, momentum: 1, at: t) && !gate.swallowScroll(phase: 0, momentum: 0, at: t),
              "swipe: two-finger momentum and mouse wheel pass")
        // Joining a running two-finger scroll with a third finger takes it over; a new stream during old momentum starts clean.
        gate.contacts(0, at: t); tick(0.5)
        gate.contacts(2, at: t); tick()
        _ = gate.swallowScroll(phase: 1, momentum: 0, at: t); gate.contacts(3, at: t); tick()
        check(gate.swallowScroll(phase: 2, momentum: 0, at: t), "swipe: third finger joining a scroll swallows the rest")
        gate.contacts(0, at: t); tick(0.3)
        check(gate.swallowScroll(phase: 0, momentum: 2, at: t), "swipe: ...and its momentum")
        gate.contacts(2, at: t); tick()
        check(!gate.swallowScroll(phase: 128, momentum: 0, at: t) && !gate.swallowScroll(phase: 0, momentum: 2, at: t), "swipe: new stream (may-begin) clears the taint")
        // Safety: frames that stop arriving never leave the gate stuck on.
        let stuck = SwipeGate(); stuck.contacts(3, at: 10)
        check(stuck.swallowScroll(phase: 2, momentum: 0, at: 10.5) && !stuck.swallowScroll(phase: 1, momentum: 0, at: 10 + SwipeGate.staleAfter + SwipeGate.grace + 0.1),
              "swipe: stale touch frames expire")

        // System three-finger swipe detection reads both domains; 1 and 2 are on.
        check(SystemSwipe.conflicts(read: { d, _ in d == SystemSwipe.domains[1] ? 2 : 0 }) && SystemSwipe.conflicts(read: { d, _ in d == SystemSwipe.domains[0] ? 1 : nil })
              && !SystemSwipe.conflicts(read: { _, _ in 0 }) && !SystemSwipe.conflicts(read: { _, _ in nil }) && !SystemSwipe.conflicts(read: { _, _ in 3 }),
              "swipe: macOS three-finger swipe detection")

        // Latest wins: newer posts replace older ones, taking removes only what was taken.
        var box = LatestWins<UInt32, Int>()
        box.post(1, 10); box.post(2, 20); box.post(1, 11)
        check(box.pending[1] == 11 && box.pending.count == 2, "swipe: a newer target replaces the older one")
        check(box.take([1]) == [1: 11] && box.pending == [2: 20], "swipe: take removes only the keys given")

        // Write planning: <1px changes skipped, parked windows written once, busy apps deferred to the next frame.
        var plan = WritePlanner()
        let pid: (UInt32) -> pid_t = { $0 < 10 ? 100 : 200 }
        var w = plan.next(targets: [1: CGPoint(x: 10.2, y: 5), 2: CGPoint(x: -5000, y: 800), 11: CGPoint(x: 3, y: 3)], pid: pid, busy: { _ in false })
        check(w[100]?.map(\.id) == [1, 2] && w[200]?.map(\.id) == [11] && w[100]?.first?.pos == CGPoint(x: 10, y: 5), "swipe: first frame writes everything, rounded, grouped per app")
        w = plan.next(targets: [1: CGPoint(x: 10.4, y: 5), 2: CGPoint(x: -5000, y: 800), 11: CGPoint(x: 3, y: 3)], pid: pid, busy: { _ in false })
        check(w.isEmpty, "swipe: nothing moved by 1px, nothing written (parked stays put)")
        w = plan.next(targets: [1: CGPoint(x: 12, y: 5), 11: CGPoint(x: 9, y: 3)], pid: pid, busy: { $0 == 200 })
        check(w.keys.sorted() == [100] && plan.lastSent(11) == CGPoint(x: 3, y: 3), "swipe: a busy app is skipped this frame")
        w = plan.next(targets: [11: CGPoint(x: 14, y: 3)], pid: pid, busy: { _ in false })
        check(w[200]?.first?.pos.x == 14, "swipe: the skipped window gets its newest position next frame")

        // Spring: starts at `from`, ends at `target`, never overshoots when pushed toward it, carries velocity away from it.
        let s = CriticalSpring(from: 0, target: 300, velocity: 5000)
        let samples = stride(from: 0.0, through: 1.5, by: 0.01).map { s.value(at: $0) }
        check(samples.first == 0 && abs(samples.last! - 300) < 0.5 && samples.allSatisfy { $0 <= 300.0001 }, "swipe: spring lands on the target without overshoot")
        check(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "swipe: spring approaches monotonically")
        check(s.settled(at: 1.5) && !s.settled(at: 0.05), "swipe: spring reports settled")
        let back = CriticalSpring(from: 100, target: 0, velocity: 2000)   // flung away from the target: continues, then returns
        check(back.value(at: 0.05) > 100 && abs(back.value(at: 1.5)) < 0.5, "swipe: fling away from the target overshoots then returns")
        check(CriticalSpring(from: 0, target: 200, velocity: 0).value(at: 0.0) == 0, "swipe: zero velocity starts at rest")

        // Contact filter: a resting thumb never counts; only contacts that really move the same way do.
        typealias P = SIMD2<Double>
        /// Runs 30 frames at 100 Hz; each finger is (id, start, velocity in pad widths/s). Returns the last result.
        func drive(_ fingers: [(Int32, P, P)], gate: SwipeGate, frames: Int = 30) -> (gate: Int, swipe: [P]?, swallowed: Bool) {
            var cf = ContactFilter(); var r: (gate: Int, swipe: [P]?, travel: Double) = (0, nil, 0)
            var anySwipe = false
            for i in 0..<frames {
                let tt = Double(i) / 100
                r = cf.feed(fingers.map { ($0.0, $0.1 + $0.2 * tt) }, at: tt)
                gate.contacts(r.gate, at: 500 + tt)
                if r.swipe != nil { anySwipe = true }
            }
            return (r.gate, anySwipe ? r.swipe ?? [P(0, 0)] : nil, gate.swallowScroll(phase: 2, momentum: 0, at: 500.3))
        }
        let thumb: (Int32, P, P) = (9, P(0.5, 0.1), P(0, 0))
        let a: (Int32, P, P) = (1, P(0.3, 0.5), P(0.6, 0)), b: (Int32, P, P) = (2, P(0.4, 0.55), P(0.6, 0)), c: (Int32, P, P) = (3, P(0.5, 0.6), P(0.6, 0))
        var res = drive([thumb, a, b], gate: SwipeGate())
        check(res.swipe == nil && !res.swallowed && res.gate == 0, "contacts: resting thumb + two scrolling fingers: no swipe, scroll passes")
        res = drive([a, b, c], gate: SwipeGate())
        check(res.swipe?.count == 3 && res.swallowed && res.gate == 3, "contacts: three fingers moving together: swipe and swallow")
        res = drive([thumb, a, b, c], gate: SwipeGate())
        check(res.swipe?.count == 3 && res.swallowed, "contacts: a resting thumb next to a three-finger swipe is ignored")
        var lag = c; lag.2 = P(0.45, 0)   // 2.25% in 50ms: slower, still moving
        res = drive([a, b, lag], gate: SwipeGate())
        check(res.swipe?.count == 3 && res.swallowed, "contacts: one finger lagging slightly still swipes")
        var still = c; still.2 = P(0.05, 0)   // barely drifting
        check(drive([a, b, still], gate: SwipeGate()).swipe == nil, "contacts: a drifting finger does not count")
        var opposite = c; opposite.2 = P(-0.6, 0)
        check(drive([a, b, opposite], gate: SwipeGate()).swipe == nil, "contacts: fingers moving opposite ways do not swipe")
        var up = [a, b, c]; for i in 0..<3 { up[i].2 = P(0.1, 0.6) }
        check(drive(up, gate: SwipeGate()).swipe == nil, "contacts: vertical movement does not swipe")
        check(drive([a, b], gate: SwipeGate()).swipe == nil, "contacts: two fingers never swipe")
        // Start threshold: 0.5% of the pad together within the window starts a swipe (was 2%); less than that is a drift.
        var slow = [a, b, c]; for i in 0..<3 { slow[i].2 = P(0.12, 0) }       // 0.72% in 60ms
        check(drive(slow, gate: SwipeGate()).swipe?.count == 3, "contacts: 0.7% of travel in 60ms already starts the swipe")
        var crawl = [a, b, c]; for i in 0..<3 { crawl[i].2 = P(0.06, 0) }     // 0.36% in 60ms
        check(drive(crawl, gate: SwipeGate()).swipe == nil, "contacts: 0.36% is still a drift, no swipe")
        check(ContactFilter.minMove == 0.005, "contacts: threshold is 0.5% of the pad")
        // The swipe starts within a few frames, and reports the travel that led to it.
        var fast = ContactFilter(); var startedAt: Int?, travel = 0.0
        for i in 0..<30 {
            let tt = Double(i) / 100
            let r = fast.feed([(1, P(0.3 + 0.6 * tt, 0.5)), (2, P(0.4 + 0.6 * tt, 0.55)), (3, P(0.5 + 0.6 * tt, 0.6))], at: tt)
            if r.swipe != nil, startedAt == nil { startedAt = i; travel = r.travel }
        }
        check((startedAt ?? 99) <= 2 && travel > 0.005 && travel < 0.02, "contacts: a normal swipe is recognised within ~20ms, carrying its travel (\(startedAt ?? -1), \(travel))")
        // Fingers landing at once do not count until they have moved; the swipe survives a pause and ends when two are left < 2.
        var cf = ContactFilter()
        check(cf.feed([(1, P(0.3, 0.5)), (2, P(0.4, 0.5)), (3, P(0.5, 0.5))], at: 0).swipe == nil, "contacts: just-landed fingers have not moved")
        for i in 1...12 { _ = cf.feed([(1, P(0.3 + 0.01 * Double(i), 0.5)), (2, P(0.4 + 0.01 * Double(i), 0.5)), (3, P(0.5 + 0.01 * Double(i), 0.5))], at: Double(i) / 100) }
        check(cf.feed([(1, P(0.42, 0.5)), (2, P(0.52, 0.5)), (3, P(0.62, 0.5))], at: 1.0).swipe?.count == 3, "contacts: a started swipe survives a pause")
        check(cf.feed([(1, P(0.42, 0.5)), (2, P(0.52, 0.5))], at: 1.01).gate == 2 && cf.feed([(1, P(0.42, 0.5))], at: 1.02).gate == 0,
              "contacts: lifting one finger keeps the gesture, lifting two ends it")

        // Commit state machine: gesture -> settle -> (spring done AND writes done) -> fade -> idle.
        var m = CommitMachine()
        check(m.phase == .idle && !m.overlayUp, "commit: starts idle")
        check(m.begin() == .showOverlay && m.phase == .gesture && m.overlayUp, "commit: a swipe shows the overlay")
        check(m.begin() == .none, "commit: moving on keeps it")
        var gen = m.release()
        check(m.phase == .settling, "commit: release starts the settle")
        check(m.springFinished(at: 1.0) == .none && m.phase == .settling, "commit: spring alone does not fade (writes pending)")
        check(m.tick(at: 1.2) == .none, "commit: before the timeout nothing happens")
        check(m.writesFinished(generation: gen, at: 1.25) == .startFade && m.phase == .fading, "commit: spring and writes done: fade")
        check(m.fadeFinished() == .removeOverlay && m.phase == .idle, "commit: fade over: overlay removed")
        // Writes finish first, then the spring.
        _ = m.begin(); gen = m.release()
        check(m.writesFinished(generation: gen, at: 2.0) == .none && m.springFinished(at: 2.2) == .startFade, "commit: writes first, then the spring: fade")
        _ = m.fadeFinished()
        // Write timeout: 300ms after the spring ended, a slow app no longer holds the overlay.
        _ = m.begin(); gen = m.release()
        check(m.springFinished(at: 5.0) == .none && m.tick(at: 5.29) == .none && m.tick(at: 5.31) == .startFade, "commit: slow writes time out 300ms after the spring")
        check(m.writesFinished(generation: gen, at: 5.4) == .none, "commit: late writes change nothing")
        _ = m.fadeFinished()
        // Interrupted while settling: a new swipe continues, old writes are ignored, the next release starts over.
        _ = m.begin(); let g1 = m.release()
        check(m.begin() == .none && m.phase == .gesture, "commit: a swipe during the settle just continues")
        check(m.writesFinished(generation: g1, at: 9.0) == .none && m.springFinished(at: 9.0) == .none && m.phase == .gesture, "commit: stale writes and spring are ignored mid-gesture")
        let g2 = m.release()
        check(g2 != g1 && m.springFinished(at: 9.5) == .none && m.writesFinished(generation: g1, at: 9.6) == .none && m.writesFinished(generation: g2, at: 9.7) == .startFade,
              "commit: only the newest commit's writes count")
        // Interrupted while fading: the overlay comes back.
        check(m.begin() == .resumeFromFade && m.phase == .gesture, "commit: a swipe during the fade resumes the overlay")
        check(m.fadeFinished() == .none && m.overlayUp, "commit: the cancelled fade's completion does nothing")
        _ = m.release(); _ = m.springFinished(at: 12); _ = m.writesFinished(generation: m.generation, at: 12)
        check(m.fadeFinished() == .removeOverlay && !m.overlayUp, "commit: and the next release completes normally")

        // Snapshot ledger: freshness, cheap invalidation, size changes, trimming.
        var led = SnapshotLedger(); led.capacity = 3
        let sz = CGSize(width: 700, height: 900)
        check(led.use(1, size: sz, now: 0) == .none && led.needsCapture(1, size: sz, now: 0), "cache: unknown window needs a capture, has no image")
        led.stored(1, size: sz, scale: 2, now: 0)
        check(led.use(1, size: sz, scale: 2, now: 1) == .fresh && !led.needsCapture(1, size: sz, scale: 2, now: 1), "cache: just captured is fresh")
        check(led.use(1, size: sz, scale: 1, now: 1) == .fresh, "cache: a sharper image serves a lower resolution need")
        check(led.use(1, size: sz, scale: 2, now: SnapshotLedger.maxAge + 1) == .stale, "cache: old images are stale but still usable")
        led.stored(2, size: sz, scale: 1, now: 0)
        check(led.use(2, size: sz, scale: 2, now: 1) == .stale, "cache: a low-res image is stale when the window is now on screen")
        led.markDirty(1)
        check(led.use(1, size: sz, scale: 2, now: 1) == .stale && led.use(2, size: sz, scale: 1, now: 1) == .fresh, "cache: marking dirty touches only that window")
        check(led.use(1, size: CGSize(width: 705, height: 900), scale: 2, now: 1) == .stale, "cache: a slightly different size is shown stretched while refreshing")
        check(led.use(1, size: CGSize(width: 500, height: 900), scale: 2, now: 1) == .none, "cache: a very different size gets a placeholder instead")
        led.stored(1, size: sz, scale: 2, now: 2)
        check(led.use(1, size: sz, scale: 2, now: 2.5) == .fresh, "cache: a new capture clears dirty")
        led.markAllDirty()
        check(led.use(1, size: sz, scale: 2, now: 3) == .stale && led.use(2, size: sz, scale: 1, now: 3) == .stale, "cache: mark all dirty")
        led.stored(3, size: sz, now: 4); led.stored(4, size: sz, now: 5); led.touch(1, now: 6)
        let dropped = led.trim(alive: [1, 2, 3, 4])
        check(dropped == [2] && led.count == 3 && led.ids == [1, 3, 4], "cache: over capacity drops the least recently used")
        check(led.trim(alive: [1, 4]) == [3] && led.ids == [1, 4], "cache: windows that are gone are dropped")
        led.removeAll()
        check(led.count == 0 && led.use(1, size: sz, now: 7) == .none, "cache: removeAll drops everything (pause)")

        // Which windows take part.
        let disp = CGRect(x: 0, y: 0, width: 1000, height: 800)
        check(SwipeRange.inSnapshotRange(lx: -1400, w: 500, display: disp) && !SwipeRange.inSnapshotRange(lx: -2100, w: 500, display: disp), "range: snapshots reach 1.5 viewports to the left")
        check(SwipeRange.inSnapshotRange(lx: 2400, w: 500, display: disp) && !SwipeRange.inSnapshotRange(lx: 2500, w: 500, display: disp), "range: ...and to the right")
        check(SwipeRange.inDirectRange(lx: 1400, w: 500, display: disp) && !SwipeRange.inDirectRange(lx: 1600, w: 500, display: disp), "range: direct mode moves one column past the edge")
        check(CommitMachine.writeTimeout == 0.3 && CommitMachine.fadeDuration == 0.12, "commit: 300ms write timeout, 120ms fade")

        // Prediction: no lead for the first sample, none without movement, capped in px and in time, same sign as the motion, reset clears it.
        var pr = SwipePredictor()
        check(pr.offset(dx: 5, at: 1.0, target: 1.016) == 0, "predict: first sample has no lead")
        let o1 = pr.offset(dx: 5, at: 1.0083, target: 1.0166)
        check(o1 > 0 && o1 <= SwipePredictor.maxOffset, "predict: steady motion leads in its own direction, within the cap")
        check(abs(pr.offset(dx: 100, at: 1.0166, target: 1.0333)) == SwipePredictor.maxOffset, "predict: a fast swipe is capped at maxOffset px")
        var neg = SwipePredictor(); _ = neg.offset(dx: -2, at: 2.0, target: 2.01)
        let on = neg.offset(dx: -2, at: 2.0083, target: 2.0183)
        check(on < 0 && on > -SwipePredictor.maxOffset, "predict: leftwards motion leads leftwards")
        let steady = abs(on)
        check(neg.offset(dx: 0, at: 2.0166, target: 2.0266) == 0 && abs(neg.offset(dx: -2, at: 2.025, target: 2.035)) < steady, "predict: standing still drops the velocity; moving again leads less than before (no overshoot after a stop)")
        var gap = SwipePredictor(); _ = gap.offset(dx: 3, at: 3.0, target: 3.01)
        check(gap.offset(dx: 3, at: 3.5, target: 3.51) == 0, "predict: no extrapolation across a stall")
        gap.reset()
        check(gap.offset(dx: 3, at: 4.0, target: 4.01) == 0, "predict: reset forgets the previous swipe")
        check(SwipePredictor.lead(now: 5, target: 5.0166) == SwipePredictor.maxLead && SwipePredictor.lead(now: 5, target: 4.9) == 0
              && abs(SwipePredictor.lead(now: 5, target: 5.004) - 0.004) < 1e-9 && SwipePredictor.lead(now: 5, target: nil) == 1.0 / 120,
              "predict: look-ahead is the time to display, clamped to [0, maxLead]; a timer tick assumes one 120 Hz frame")
        var fine = SwipePredictor(); _ = fine.offset(dx: 0.2, at: 6.0, target: 6.008)
        check(abs(fine.offset(dx: 0.2, at: 6.0083, target: 6.0166)) < 1, "predict: slow motion leads by a fraction of a pixel")

        // Display link: the swiped display wins, then the main one, then the first; none without displays.
        let d1 = DisplayLinkChoice.Candidate(uuid: "A", displayID: 1), d2 = DisplayLinkChoice.Candidate(uuid: "B", displayID: 2)
        check(DisplayLinkChoice.pick(target: "B", in: [d1, d2], main: 1) == d2, "link: the display being swiped, not the main one")
        check(DisplayLinkChoice.pick(target: "Z", in: [d1, d2], main: 2) == d2, "link: unknown display falls back to the main one")
        check(DisplayLinkChoice.pick(target: nil, in: [d1, d2], main: nil) == d1, "link: ...then the first")
        check(DisplayLinkChoice.pick(target: "A", in: [], main: 1) == nil, "link: no displays, no link")
    }
}
