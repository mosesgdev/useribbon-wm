import Foundation
import CoreGraphics

/// Selftest for keyboard moves on the overlay: when a plan is a rigid slide, what the layers need, the ring's glide, a new target
/// mid-glide, and the snapshot order (run from `SelfTest`).
enum OverlayNavTests {
    private typealias Spec = SwipeOverlay.TileSpec

    static func run(_ check: (Bool, String) -> Void) {
        let disp = CGRect(x: 0, y: 0, width: 3840, height: 1200)
        func tile(_ id: UInt32, _ x: Double, w: Double = 1400, y: Double = 42, h: Double = 1100, pinned: Bool = false) -> Spec {
            Spec(id: id, rect: CGRect(x: x, y: y, width: w, height: h), pid: pid_t(100 + id), held: pinned)
        }
        func layout(_ xs: [Double], desk: Int = 1) -> NavLayout {
            NavLayout(desktop: desk, specs: xs.enumerated().map { tile(UInt32($0.offset + 1), $0.element) }, edge: nil)
        }
        let a = layout([12, 1424, 2836, 4248]), b = layout([-1400, 12, 1424, 2836])

        // A plain slide: windows 1...4 shift one column. The layers start at the old places and end at the new ones.
        let s = NavLayout.slide(from: a, to: b, changed: [1, 2, 3, 4], display: disp)
        check(s != nil, "overlay nav: a focus move that only shifts columns is a slide")
        check(s?.staging.first { $0.id == 2 }?.rect.minX == 1424 && s?.finals[2] == 12, "overlay nav: tiles stage at the old layout and end at the new one")
        check(s?.staging.count == 4 && Set(s?.finals.keys.map { $0 } ?? []) == [1, 2, 3, 4], "overlay nav: every window in reach is staged, before or after the move")

        // Everything that is more than a slide takes the AX path.
        check(NavLayout.slide(from: a, to: layout([12, 1424, 2836, 4248], desk: 2), changed: [1], display: disp) == nil, "overlay nav: another desktop is no slide")
        check(NavLayout.slide(from: a, to: layout([-1400, 12, 1424]), changed: [1, 2, 3], display: disp) == nil, "overlay nav: a window that left is no slide")
        var wider = b; wider.specs[1] = tile(2, 12, w: 1500)
        check(NavLayout.slide(from: a, to: wider, changed: [1, 2, 3, 4], display: disp) == nil, "overlay nav: a size change is no slide")
        var lower = b; lower.specs[2] = tile(3, 1424, y: 80)
        check(NavLayout.slide(from: a, to: lower, changed: [1, 2, 3, 4], display: disp) == nil, "overlay nav: a move in y is no slide")
        check(NavLayout.slide(from: a, to: b, changed: [1, 2, 3, 7], display: disp) == nil, "overlay nav: a changed window that is no tile (a floating one) is no slide")
        var tabbed = a, tabbedTo = b
        tabbed.hidden = [7]; tabbedTo.hidden = [7]
        check(NavLayout.slide(from: tabbed, to: tabbedTo, changed: [1, 2, 3, 4, 7], display: disp) != nil, "overlay nav: the hidden tabs of a column move along with it, no tiles of their own")
        check(NavLayout.slide(from: a, to: layout([12, 1424, 2836, 4248]), changed: [1], display: disp) == nil, "overlay nav: nothing moved, nothing to show")
        let farA = layout([12, 1424, 9000, 10412]), farB = layout([12, 1424, 9500, 10412])
        check(NavLayout.slide(from: farA, to: farB, changed: [3], display: disp) == nil, "overlay nav: moves that are nowhere near the display are no slide")


        // Staged layers that already show the old layout are reused (a missing one is added, a closed window's is dropped); one
        // that sits elsewhere than its tile means the layers are built again.
        let have = Dictionary(uniqueKeysWithValues: a.specs.map { ($0.id, $0.rect) })
        check(NavLayout.layersAgree(have, with: a), "overlay nav: layers staged at the old layout are reused")
        var moved = have; moved[2] = CGRect(x: 1000, y: 42, width: 1400, height: 1100)
        check(!NavLayout.layersAgree(moved, with: a), "overlay nav: layers that sit elsewhere are staged again")
        var resized = have; resized[3] = CGRect(x: 2836, y: 42, width: 1300, height: 1100)
        check(!NavLayout.layersAgree(resized, with: a), "overlay nav: a layer of another size is staged again")
        check(NavLayout.layersAgree([1: have[1]!], with: a) && NavLayout.layersAgree(have.merging([99: CGRect(x: 0, y: 0, width: 10, height: 10)]) { a, _ in a }, with: a),
              "overlay nav: layers beyond the tiles the move shows, or of a closed window, do not call for staging again")
        check(!NavLayout.layersAgree([99: CGRect(x: 0, y: 0, width: 10, height: 10)], with: a) && NavLayout.layersAgree([:], with: a),
              "overlay nav: layers of another display (no window of this layout) are staged again, never carried over")

        navStaging(check)
        navGate(check)
        freshPictures(check)

        // The spring: velocity is its derivative, and a new target mid-glide continues at the speed the tile had.
        let sp = CriticalSpring(from: 0, target: 900, velocity: 0, omega: SwipeOverlay.springOmega)
        let t = 0.05, h = 1e-5
        let numeric = (sp.value(at: t + h) - sp.value(at: t - h)) / (2 * h)
        check(abs(sp.velocity(at: t) - numeric) < 0.5 && sp.velocity(at: 0) == 0, "overlay nav: spring velocity matches its slope")
        let mid = CriticalSpring(from: sp.value(at: t), target: -300, velocity: sp.velocity(at: t), omega: SwipeOverlay.springOmega)
        check(mid.velocity(at: 0) > 0 && mid.velocity(at: 0) <= sp.velocity(at: t) + 1e-6, "overlay nav: a new target mid-glide keeps the tile's speed (it never snaps back at once)")
        check(abs(mid.value(at: 0) - sp.value(at: t)) < 1e-9, "overlay nav: a new target mid-glide starts where the tile is")

        // The ring: starts where it was, ends on its tile, and keeps following the tile while it glides.
        let from = CGRect(x: 12, y: 42, width: 1400, height: 1100), base = CGRect(x: 1424, y: 42, width: 900, height: 1100)
        let carry = RingCarry.from(from, to: base, at: 10)
        check(carry.rect(on: base, at: 10) == from, "overlay nav: the ring starts exactly where the old one was")
        check(abs(carry.rect(on: base, at: 10.6).minX - base.minX) < 0.01 && abs(carry.rect(on: base, at: 10.6).width - base.width) < 0.01, "overlay nav: the ring lands on its tile")
        let moving = base.offsetBy(dx: -500, dy: 0)
        check(abs(carry.rect(on: moving, at: 10.6).minX - moving.minX) < 0.01, "overlay nav: the ring keeps following its tile while it travels")
        let xs = stride(from: 0.0, through: 0.5, by: 0.01).map { carry.rect(on: base, at: 10 + $0).minX }
        check(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && RingCarry.progress(0.5) > 0.99 && RingCarry.progress(-1) == 0, "overlay nav: the ring glides one way, without overshoot")

        // Which windows are captured first, and how soon an on-screen image counts as old.
        check(SnapshotOrder.sorted([(1, false), (2, true), (3, false), (4, true)], focus: 3) == [3, 2, 4, 1], "snapshots: the focused window first, then the ones on screen, then the rest in order")
        var led = SnapshotLedger()
        led.stored(1, size: CGSize(width: 800, height: 600), scale: 2, now: 100)
        let sz = CGSize(width: 800, height: 600)
        check(!led.needsCapture(1, size: sz, scale: 2, now: 103), "snapshots: a few seconds old is still fresh by the general rule")
        check(led.needsCapture(1, size: sz, scale: 2, now: 103, maxAge: 2), "snapshots: windows on screen are captured again after 2 seconds of quiet")
    }

    /// Which keyboard moves may use the overlay, and when the Screen Recording card is offered.
    private static func navGate(_ check: (Bool, String) -> Void) {
        // The swipe setting is no part of it.
        check(NavGate().open, "overlay nav: a plain glide with Screen Recording uses the overlay, with or without the swipe setting")
        check(!NavGate(permitted: false).open && !NavGate(undimmed: false).open && !NavGate(motion: false).open && !NavGate(glides: false).open
              && !NavGate(idle: false).open && !NavGate(plain: false).open && !NavGate(focusedDisplay: false).open && !NavGate(enabled: false).open && !NavGate(started: false).open,
              "overlay nav: no Screen Recording, a dim, Reduce Motion, a jump, a swipe or drag, a hand move, another display or QA's switch send the move down the AX road")
        check(NavGate.offersPermission(glided: true, permitted: false, enabled: true) && !NavGate.offersPermission(glided: false, permitted: false, enabled: true)
              && !NavGate.offersPermission(glided: true, permitted: true, enabled: true) && !NavGate.offersPermission(glided: true, permitted: false, enabled: false),
              "overlay nav: the first keyboard glide on the AX road without Screen Recording offers the permission")
    }

    /// The pictures the overlay shows match the live windows: the focus pair is captured through the hold and swapped in at the
    /// landing, the sweep is armed by the soonest request, the focused window follows the user.
    private static func freshPictures(_ check: (Bool, String) -> Void) {
        typealias Want = SnapshotStore.Want
        let sz = CGSize(width: 800, height: 600)
        var led = SnapshotLedger()
        for id: UInt32 in 1...4 { led.stored(id, size: sz, scale: 2, now: 100) }
        let wants = (1...4).map { Want(id: UInt32($0), size: sz, scale: 2, maxAge: 6) }
        led.markDirty(2); led.markDirty(3)
        let moving = SnapshotStore.due(wants, hold: true, through: [2, 3], force: [], inFlight: [], ledger: led, now: 101).map(\.id)
        check(moving == [2, 3], "fresh pictures: while the overlay holds the captures, the two windows whose focus changed are still captured")
        check(SnapshotStore.due(wants, hold: true, through: [], force: [], inFlight: [], ledger: led, now: 101).isEmpty, "fresh pictures: ... and nothing else is")
        check(SnapshotStore.due(wants, hold: false, through: [], force: [], inFlight: [3], ledger: led, now: 101).map(\.id) == [2], "fresh pictures: without the hold the stale ones are captured, not the ones already on their way")
        check(SnapshotStore.due(wants, hold: true, through: [1], force: [1], inFlight: [], ledger: led, now: 101).map(\.id) == [1], "fresh pictures: a forced window is captured even when its picture is fresh")

        check(PictureSwap.verdict(overlayUp: true, focusPair: true, hasPicture: true, moving: true) == .wait
              && PictureSwap.verdict(overlayUp: true, focusPair: true, hasPicture: true, moving: false) == .swap
              && PictureSwap.verdict(overlayUp: true, focusPair: true, hasPicture: false, moving: true) == .swap,
              "fresh pictures: the focus pair's new picture waits for the glide to land, then swaps in before the fade (a placeholder takes it at once)")
        check(PictureSwap.verdict(overlayUp: true, focusPair: false, hasPicture: true, moving: false) == .normal
              && PictureSwap.verdict(overlayUp: false, focusPair: true, hasPicture: true, moving: false) == .normal,
              "fresh pictures: any other tile, or a tile while the overlay is down, follows the overlay's own rule")

        // The sweep: the soonest request wins, the quiet check stays with the sweep.
        var clock = SweepClock()
        check(clock.arm(after: 1.0, at: 10) && !clock.arm(after: 1.0, at: 10.1) && clock.arm(after: 0.3, at: 10.4) && !clock.arm(after: 1.0, at: 10.5),
              "fresh pictures: a sweep after 0.3 s (a landing) is not pushed back by the 1 s one every plan asks for, nor the other way round")
        clock.fired()
        check(clock.arm(after: 1.0, at: 11), "fresh pictures: after a sweep fired the next request arms again")

        // The focused window follows the user while they work.
        check(LiveRefresh.takes(idle: 0.5, age: 2) && !LiveRefresh.takes(idle: 0.5, age: 0.3) && !LiveRefresh.takes(idle: 3, age: 20) && LiveRefresh.takes(idle: 1, age: nil),
              "fresh pictures: the focused window's picture is taken again about every ¾ s while the user is active, not when they are idle or it is fresh")
        check(LiveRefresh.keepsWatching(idle: 9) && !LiveRefresh.keepsWatching(idle: 11), "fresh pictures: the follower stops after ten idle seconds")
    }

    /// Which tiles a keyboard move puts on the layers, what a run of quick moves adds to them, and which pictures a move needs.
    private static func navStaging(_ check: (Bool, String) -> Void) {
        let disp = CGRect(x: 0, y: 0, width: 1512, height: 1000)
        func tile(_ id: UInt32, _ x: Double) -> Spec { Spec(id: id, rect: CGRect(x: x, y: 42, width: 756, height: 900), pid: pid_t(100 + id)) }
        /// Fourteen half-width columns, the ribbon scrolled by `scroll`.
        func ribbon(_ scroll: Double, count: Int = 14) -> NavLayout {
            NavLayout(desktop: 1, specs: (0..<count).map { tile(UInt32($0 + 1), 12 + Double($0) * 768 - scroll) })
        }
        func ids(_ s: [Spec]) -> Set<UInt32> { Set(s.map(\.id)) }

        // Only what can be seen is staged: on the display before, after or on the way, plus a column of margin.
        let one = NavLayout.slide(from: ribbon(0), to: ribbon(768), changed: Array(1...14), display: disp)
        check(one != nil && ids(one!.staging) == [1, 2, 3, 4], "overlay nav: a move on a long ribbon stages the tiles it can show, not the whole ribbon")
        check(one?.seen == [1, 2, 3], "overlay nav: the tiles on the display before or after are the ones that must have a picture")
        check(one?.add.count == one?.staging.count, "overlay nav: with no layers every staged tile is added")

        // A far jump: a tile that starts and ends beyond reach still crosses the display on the way, so it is staged (no hole).
        let jump = NavLayout.slide(from: ribbon(0), to: ribbon(7000), changed: Array(1...14), display: disp)
        check(jump?.staging.contains { $0.id == 6 } == true && jump?.seen.contains(6) == true,
              "overlay nav: a tile that starts and ends out of reach but crosses the display on a far jump is staged")
        check(jump?.seen == Set(1...12) && jump.map { ids($0.staging).isSuperset(of: $0.seen) } == true, "overlay nav: every tile that crosses the display on a far jump is seen")

        // A run of eight quick presses on a fourteen-column ribbon: staged once, then only the few tiles that come into reach are
        // added to the layers, nothing is built again, and everything the move shows is on the layers.
        var layers: [UInt32: CGRect] = [:]
        var stagings = 0, worstAdd = 0, covered = true, widest = 0
        for press in 0..<8 {
            let old = ribbon(Double(press) * 768), new = ribbon(Double(press + 1) * 768)
            let restage = layers.isEmpty
            guard let m = NavLayout.slide(from: old, to: new, changed: Array(1...14), display: disp, layers: restage ? [:] : layers) else { covered = false; break }
            if restage { stagings += 1; layers = Dictionary(uniqueKeysWithValues: m.staging.map { ($0.id, $0.rect) }) }
            else {
                worstAdd = max(worstAdd, m.add.count)
                for t in m.add { layers[t.id] = t.rect }
                for (id, x) in m.snap { if let r = layers[id] { layers[id] = CGRect(x: x, y: r.minY, width: r.width, height: r.height) } }
                for id in m.drop { layers[id] = nil }
            }
            covered = covered && ids(m.staging).isSuperset(of: m.seen) && m.seen.allSatisfy { layers[$0] != nil }
            // The glide gets 60% of the way before the next press.
            for (id, x) in m.finals { if let r = layers[id] { layers[id] = r.offsetBy(dx: (x - r.minX) * 0.6, dy: 0) } }
            widest = max(widest, layers.count)
        }
        check(covered && stagings == 1, "overlay nav: a run of quick moves stages once and every tile it shows is on the layers")
        check(worstAdd <= 2 && widest <= 8, "overlay nav: ... then adds at most the tiles that come into reach (\(worstAdd) per move) and keeps the layers few (\(widest))")

        // A window closed since the layers were staged: its layer is dropped at the next move, so it never shows as a ghost.
        let kept = Dictionary(uniqueKeysWithValues: ribbon(0).specs.map { ($0.id, $0.rect) })
        let ghost = NavLayout.slide(from: ribbon(0, count: 13), to: ribbon(768, count: 13), changed: Array(1...13), display: disp, layers: kept)
        check(ghost?.drop.contains(14) == true, "overlay nav: the layer of a window that closed is dropped at the next move")
        check(NavLayout.slide(from: ribbon(0), to: ribbon(0, count: 13), changed: [14], display: disp) == nil, "overlay nav: a window that closed is no slide")

        // A tile without a picture never slides: a seen one sends the move down the AX road, a margin one just stays out.
        let all = one!
        check(all.pictured { _ in true } == all, "overlay nav: with a picture for every tile the move is whole")
        check(all.pictured { $0 != 2 } == nil, "overlay nav: a tile on the display without a picture is no overlay move (no gray placeholder)")
        let margin = all.pictured { $0 != 4 }
        check(margin.map { !ids($0.staging).contains(4) && $0.finals[4] == nil && $0.snap[4] != nil && !$0.add.contains { $0.id == 4 } } == true,
              "overlay nav: a margin tile without a picture stays out of the move")

        // Pictures: every tile of the ribbon up to the ledger's capacity, the nearest first, so a far jump finds them.
        let tiles = ribbon(0).specs.map { (id: $0.id, lx: Double($0.rect.minX), w: Double($0.rect.width), onScreen: $0.rect.minX < disp.maxX) }
        let picks = SnapshotReach.wanted(tiles, display: disp, limit: SnapshotLedger.defaultCapacity)
        check(picks.count == 14 && picks.first?.id == 1 && picks.last?.id == 14, "snapshots: every window of a ribbon within the ledger's capacity is wanted, nearest first")
        check(SnapshotReach.wanted(tiles, display: disp, limit: 6).map(\.id) == [1, 2, 3, 4, 5, 6], "snapshots: a longer ribbon is cut to the nearest windows")
        check(SnapshotReach.wanted(tiles, display: disp, limit: 14).contains { $0.id == 14 && $0.maxAge == SnapshotReach.farAge }
              && picks.first?.maxAge == 2 && picks.first { $0.id == 5 }?.maxAge == SnapshotLedger.maxAge, "snapshots: pictures of windows on the display age fastest, far ones slowest")
        let behind = ribbon(8 * 768).specs.map { (id: $0.id, lx: Double($0.rect.minX), w: Double($0.rect.width), onScreen: $0.rect.maxX > 0 && $0.rect.minX < disp.maxX) }
        check(SnapshotReach.wanted(behind, display: disp, limit: 5).map(\.id) == [8, 9, 10, 11, 7], "snapshots: tiles to the left of the display count by their distance too")
    }
}
