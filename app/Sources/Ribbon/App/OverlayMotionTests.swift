import Foundation
import CoreGraphics

/// Selftest for how the overlay's tiles move: where the clock of a glide starts, a command mid-glide, when the tiles count as
/// landed (the fade may start) and a release that never kicks outward (run from `SelfTest`).
enum OverlayMotionTests {
    static func run(_ check: (Bool, String) -> Void) {
        let omega = SwipeOverlay.springOmega
        let frame = 1.0 / 60
        /// A glide of tile 1 from x0 to `to`, begun at `now` from rest.
        func glide(from x0: Double = 0, to: Double = 500, now: Double = 10, lazy: Bool = true) -> TileGlide {
            var g = TileGlide()
            g.retarget(to: [1: to], from: [1: x0], velocity: 0, at: now, lazyClock: lazy)
            return g
        }

        // The clock: a keyboard move starts it at the first frame, however late the display link wakes up, and no more than one frame
        // before it. The first frame covers what the key had time for, and at most the usual tenth of the way: not the half or more
        // that ran since the key. The glide is moving from that very frame.
        let tenth = CriticalSpring(from: 0, target: 500, velocity: 0, omega: omega).value(at: frame)
        for late in [0.005, 0.06, 0.125] {
            var g = glide()
            let first = g.step(at: 10 + late).x[1]!, second = g.step(at: 10 + late + frame).x[1]!
            let want = CriticalSpring(from: 0, target: 500, velocity: 0, omega: omega).value(at: min(late, frame))
            check(abs(first - want) < 1e-9 && first > 0 && first <= tenth + 1e-9 && second > first,
                  "overlay motion: a first frame \(Int(late * 1000)) ms after the key moves \(Int(first)) of 500 px (a tenth at most), and the next carries on")
        }
        check(tenth < 0.11 * 500, "overlay motion: a frame of a glide covers about a tenth of a 500 px move at 60 Hz")
        var g120 = glide()
        check(g120.step(at: 10.2, interval: 1.0 / 120).x[1]! < 0.04 * 500, "overlay motion: at 120 Hz the first frame of a late tick covers less than 4%")
        var early = glide(lazy: false)
        check(early.step(at: 10.06).x[1]! > 0.5 * 500, "overlay motion: a clock that starts at the key would have jumped over half the way by a first frame at 60 ms")

        // A command mid-glide continues from where the springs are at that moment (not from the last frame drawn): a new target equal
        // to the old one changes nothing, whenever between two frames it arrives.
        for key in [10.2005, 10.205, 10.2084] {
            var g = glide(now: 10)
            for i in 0...12 { _ = g.step(at: 10.0 + Double(i) * frame) }            // frames at 10.000 ... 10.200
            let reference = g
            g.retarget(to: [1: 500], from: [1: g.position(of: 1, at: 10.2)!], velocity: 0, at: key, lazyClock: true)
            var again = reference
            let next = 10.2 + frame
            let x = g.step(at: next).x[1]!, want = again.step(at: next).x[1]!
            check(abs(x - want) < 0.01, "overlay motion: a command at \(key) re-aiming at the same place changes nothing (off by \(abs(x - want)) px)")
        }
        do {
            var g = glide(now: 10)
            for i in 0...6 { _ = g.step(at: 10.0 + Double(i) * frame) }              // 10.100: well into the glide, fast
            let lastFrame = 10.0 + 6 * frame
            let key = lastFrame + 0.008                                              // 8 ms after the newest frame
            let before = g.position(of: 1, at: lastFrame)!
            let v = CriticalSpring(from: 0, target: 500, velocity: 0, omega: omega).velocity(at: 6 * frame)
            g.retarget(to: [1: 100], from: [1: before], velocity: 0, at: key, lazyClock: true)
            let at = g.retargetTime(key)!
            let start = g.step(at: at).x[1]!, expected = CriticalSpring(from: 0, target: 500, velocity: 0, omega: omega).value(at: at - 10)
            check(abs(start - expected) < 0.01, "overlay motion: a new target starts at the old spring's position at that moment, not at the last frame (off by \(abs(start - expected)) px; the gap is \(Int(v * 0.008)) px)")
            let after = g.step(at: at + 0.001).x[1]!
            check(after > start, "overlay motion: and keeps the speed it had toward the old target before turning back")
        }
        do {   // two commands before the first frame: the clock still waits, and the second starts where the first did
            var g = glide(to: 500)
            g.retarget(to: [1: 900], from: [1: 0], velocity: 0, at: 10.01, lazyClock: true)
            check(g.retargetTime(10.02) == nil, "overlay motion: a glide that has not drawn a frame yet keeps waiting for its first")
            let first = g.step(at: 10.1).x[1]!
            check(first > 0 && first < 0.11 * 900 && g.targets[1] == 900, "overlay motion: two keys before the first frame: the tile starts at its start, heading for the newer place")
        }

        // Landed: within 1.5 px and under 60 px/s counts, 3 px does not; the fade can start while the last pixels still move.
        let near = CriticalSpring(from: 1.4, target: 0, velocity: -40, omega: omega)
        let far = CriticalSpring(from: 3, target: 0, velocity: -40, omega: omega)
        let fast = CriticalSpring(from: 1.4, target: 0, velocity: 70, omega: omega)          // flung away at 70 px/s
        check(near.landed(at: 0) && !near.settled(at: 0), "overlay motion: 1.4 px away at 40 px/s has landed but has not settled")
        check(!far.landed(at: 0) && !fast.landed(at: 0), "overlay motion: 3 px away, or 1.4 px at 70 px/s, has not landed")
        let spring = CriticalSpring(from: 0, target: 494, velocity: 0, omega: omega)
        let times = stride(from: 0.0, through: 1.0, by: 0.001)
        let tLanded = times.first { spring.landed(at: $0) }!, tSettled = times.first { spring.settled(at: $0) }!
        check(tLanded < tSettled - 0.04 && tLanded < 0.27, "overlay motion: a 494 px move has landed at \(Int(tLanded * 1000)) ms, \(Int((tSettled - tLanded) * 1000)) ms before it settles")
        do {
            var g = glide(to: 494)
            var t = 10.0, landedAt: Double?, doneAt: Double?, xs: [Double] = []
            _ = g.step(at: t)
            while doneAt == nil, t < 12 {
                t += frame
                let f = g.step(at: t)
                xs.append(f.x[1]!)
                if f.landed, landedAt == nil { landedAt = t }
                if f.done { doneAt = t }
            }
            check(landedAt != nil && doneAt != nil && landedAt! < doneAt! && xs.last == 494, "overlay motion: the glide lands first and settles exactly on its target a few frames later")
            check(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && !g.isGliding, "overlay motion: it approaches monotonically and is over once settled")
        }

        // A release never kicks outward. The layers lead the core by up to 8 px (the finger prediction), moving at the finger speed.
        func distances(from x: Double, to target: Double, velocity v: Double) -> [Double] {
            var g = TileGlide()
            g.retarget(to: [1: target], from: [1: x], velocity: v, at: 5, lazyClock: false)
            return stride(from: 0.0, through: 0.6, by: 0.004).map { abs(g.position(of: 1, at: 5 + $0)! - target) }
        }
        for (v, name) in [(-1500.0, "fast"), (-300.0, "slow"), (-40.0, "gentle")] {
            // Tiles move left (v < 0); the core's final place is where the fingers stopped, 8 px behind the led layers.
            let d = distances(from: 100 - 8, to: 100, velocity: v)
            check(zip(d, d.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 } && d.max()! <= 8 + 1e-9, "overlay motion: a \(name) release 8 px past the core's place only comes back, never further out (\(String(format: "%.2f", d.max()!)) px at most)")
        }
        let kick = CriticalSpring(from: 92, target: 100, velocity: -1500, omega: omega)       // the plain spring: carried on out, then back
        check(stride(from: 0.0, through: 0.3, by: 0.004).map { 100 - kick.value(at: $0) }.max()! > 8 + 5, "overlay motion: a plain spring would have kicked the tile more than 5 px further out")
        let back = distances(from: 100, to: 100 + 220, velocity: -400)       // the plan settles back the way the fingers came
        check(zip(back, back.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 } && back.max()! <= 220 + 1e-9, "overlay motion: a release that settles back the way the fingers came does not coast out first")
        let ahead = distances(from: 100, to: 100 - 300, velocity: -1200)
        let still = distances(from: 100, to: 100 - 300, velocity: 0)
        check(ahead[1] < still[1] - 1 && zip(ahead, ahead.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 }, "overlay motion: a release toward its place keeps the finger speed (it is ahead of one from rest)")
        do {   // tiles on both sides of a snap: the ones the velocity carries toward their place keep it, the others start from rest
            var g = TileGlide()
            g.retarget(to: [1: 0, 2: 700], from: [1: 150, 2: 120], velocity: -900, at: 1, lazyClock: false)
            let moving = CriticalSpring(from: 150, target: 0, velocity: -900, omega: omega), resting = CriticalSpring(from: 120, target: 700, velocity: 0, omega: omega)
            check(abs(g.position(of: 1, at: 1.02)! - moving.value(at: 0.02)) < 1e-9 && abs(g.position(of: 2, at: 1.02)! - resting.value(at: 0.02)) < 1e-9,
                  "overlay motion: each tile of a release keeps the speed only toward its own place")
        }

        // The fallback timer does not run ahead of a link that ticks on this display: after a main-thread stall both are overdue, and a
        // timer tick (no screen time) followed within a frame by the link's would make the first frames of a glide jump.
        check(FramePacer.fallbackGrace(linkTicks: true) >= 0.08 && FramePacer.fallbackGrace(linkTicks: false) <= 0.03,
              "overlay motion: a link that ticks is given time to recover from a stall, a display without one is paced by the timer")

        // The focus ring's clock waits for the first frame too: until then it stays where it was.
        let base = CGRect(x: 1424, y: 42, width: 900, height: 1100), was = CGRect(x: 12, y: 42, width: 1400, height: 1100)
        let waiting = RingCarry.from(was, to: base, at: nil)
        check(waiting.rect(on: base, at: 10) == was && waiting.rect(on: base, at: 10.5) == was, "overlay motion: a ring that waits for its first frame stays where it was")
        var started = waiting
        started.start = 10.125 - frame             // the clock of the tiles' first frame, one frame before it
        let firstFrame = started.rect(on: base, at: 10.125).minX
        check(started.rect(on: base, at: 10.125 - frame) == was && firstFrame > was.minX && firstFrame < was.minX + 0.2 * (base.minX - was.minX),
              "overlay motion: and once started it covers a tenth of the way in the first frame, however late that was")
    }
}
