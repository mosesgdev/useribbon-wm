import Foundation
import CoreGraphics

/// Pure-logic checks for the stability pieces: quarantine/backoff, coalescing, drift decisions, crash-loop guard.
enum StabilityTests {
    static func run(_ check: (Bool, String) -> Void) {
        // Quarantine: three failures within 5 s.
        var q = Quarantine()
        check(q.failure(1, at: 0) == nil && q.failure(1, at: 1) == nil && !q.isQuarantined(1), "quarantine: two failures are not enough")
        check(q.failure(1, at: 2) == .quarantined && q.isQuarantined(1), "quarantine: third failure within 5 s marks the app unresponsive")
        check(q.retryAt(1) == 3, "quarantine: first retry 1 s after")
        check(!q.isQuarantined(2), "quarantine: other apps are unaffected")
        var slow = Quarantine()
        _ = slow.failure(1, at: 0); _ = slow.failure(1, at: 3); _ = slow.failure(1, at: 6)
        check(!slow.isQuarantined(1), "quarantine: failures spread over more than 5 s do not count")
        var reset = Quarantine()
        _ = reset.failure(1, at: 0); _ = reset.failure(1, at: 1); _ = reset.success(1)
        check(reset.failure(1, at: 2) == nil && !reset.isQuarantined(1), "quarantine: a success breaks the run of failures")
        // Backoff 1, 2, 4, 8, 16, 30, 30.
        check((0..<7).map { Quarantine.backoff(attempt: $0) } == [1, 2, 4, 8, 16, 30, 30], "backoff doubles from 1 s up to 30 s")
        check(q.failure(1, at: 3) == nil, "quarantine: a failed probe a second in says nothing")
        check(q.retryAt(1) == 5 && q.isQuarantined(1), "quarantine: a failed probe backs off to 2 s")
        _ = q.failure(1, at: 5)
        check(q.retryAt(1) == 9, "quarantine: then 4 s")
        check(q.success(1) == .recovered && !q.isQuarantined(1) && q.retryAt(1) == nil, "quarantine: a successful probe lifts it")
        check(q.success(1) == nil, "quarantine: success on a healthy app says nothing")
        // The toast waits for a real hang: a hiccup is never named, a hang that outlasts 10 s is, once.
        var hang = Quarantine()
        _ = hang.failure(1, at: 0); _ = hang.failure(1, at: 1)
        check(hang.failure(1, at: 2) == .quarantined, "hang: quarantined quietly")
        check(hang.failure(1, at: 3) == nil && hang.failure(1, at: 5) == nil && hang.failure(1, at: 9) == nil, "hang: probes within 10 s say nothing")
        check(hang.failure(1, at: 17) == .unresponsive && hang.isQuarantined(1), "hang: still hung 15 s in, the user hears about it")
        check(hang.failure(1, at: 47) == nil, "hang: announced once per hang")
        check(hang.success(1) == .recovered, "hang: it recovers")
        for t in [100.0, 101, 102] { _ = hang.failure(1, at: t) }
        check(hang.failure(1, at: 120) == nil, "hang: the same app is not announced again within the hour")
        _ = hang.success(1); for t in [4000.0, 4001, 4002] { _ = hang.failure(1, at: t) }
        check(hang.failure(1, at: 4015) == .unresponsive, "hang: announced again after an hour")
        var hiccup = Quarantine()
        for t in [0.0, 1, 2, 3, 5] { _ = hiccup.failure(1, at: t) }
        check(hiccup.success(1) == .recovered && hiccup.failure(1, at: 30) == nil, "hiccup: an app that answers within seconds is never named")
        var many = Quarantine()
        for p: pid_t in [5, 6] { for t in 0..<3 { _ = many.failure(p, at: Double(t)) } }
        many.reset()
        check(many.quarantined.isEmpty, "quarantine: reset (wake) clears everything")

        // Coalescing: latest frame per window wins, one lane per app, stale jobs are gone once taken.
        var jobs = CoalescedJobs<Int>()
        jobs.post(10, pid: 1, 1); jobs.post(10, pid: 1, 2); jobs.post(11, pid: 1, 3); jobs.post(20, pid: 2, 4)
        check(jobs.pending(10, pid: 1) == 2, "coalescing: a newer target replaces the queued one")
        check(Set(jobs.pids) == [1, 2], "coalescing: one lane per app")
        let lane = jobs.take(pid: 1)
        check(lane == [10: 2, 11: 3] && !jobs.hasPending(1) && jobs.hasPending(2), "coalescing: taking an app's lane leaves the others")
        jobs.post(20, pid: 2, 5); jobs.postIfAbsent(20, pid: 2, 6); jobs.postIfAbsent(21, pid: 2, 7)
        check(jobs.pending(20, pid: 2) == 5 && jobs.pending(21, pid: 2) == 7, "coalescing: a re-queued old job never overwrites a newer one")
        jobs.remove(20)
        check(jobs.pending(20, pid: 2) == nil && jobs.pending(21, pid: 2) == 7, "coalescing: a dragged window's queued job can be dropped")
        jobs.removeAll()
        check(jobs.isEmpty, "coalescing: cancel drops everything")

        // Drift: a position error must show up on two checks in a row.
        let plan: [UInt32: CGRect] = [1: CGRect(x: 100, y: 50, width: 600, height: 500), 2: CGRect(x: 1500, y: 50, width: 600, height: 500)]
        var live = plan; live[1] = CGRect(x: 100, y: 50, width: 640, height: 500); live[2] = CGRect(x: 900, y: 50, width: 600, height: 500)
        let first = Reconcile.drifted(planned: plan, live: live, previous: [])
        check(first.fix.isEmpty && first.suspects == [2], "drift: one off-plan reading is only a suspect; a size change alone is not position drift")
        let second = Reconcile.drifted(planned: plan, live: live, previous: first.suspects)
        check(second.fix == [2], "drift: the second reading corrects it")
        live[2] = plan[2]!.offsetBy(dx: 5, dy: -6)
        check(Reconcile.drifted(planned: plan, live: live, previous: [2]).fix.isEmpty, "drift: within tolerance is ignored")
        live[2] = nil
        check(Reconcile.drifted(planned: plan, live: live, previous: [2]).fix.isEmpty, "drift: a window that could not be read is skipped")
        check(Reconcile.sizeDrifted(planned: plan[1]!, live: CGRect(x: 100, y: 50, width: 640, height: 500)) && !Reconcile.sizeDrifted(planned: plan[1]!, live: plan[1]!.insetBy(dx: -0.5, dy: 0)),
              "drift: size beyond rounding is detected")
        check(Reconcile.mayCheck(started: true, paused: false, writing: false, scrolling: false, overlayUp: false, mouseDown: false), "periodic check runs when idle")
        check(!Reconcile.mayCheck(started: true, paused: false, writing: true, scrolling: false, overlayUp: false, mouseDown: false)
              && !Reconcile.mayCheck(started: true, paused: false, writing: false, scrolling: true, overlayUp: false, mouseDown: false)
              && !Reconcile.mayCheck(started: true, paused: false, writing: false, scrolling: false, overlayUp: true, mouseDown: false)
              && !Reconcile.mayCheck(started: true, paused: false, writing: false, scrolling: false, overlayUp: false, mouseDown: true)
              && !Reconcile.mayCheck(started: true, paused: true, writing: false, scrolling: false, overlayUp: false, mouseDown: false)
              && !Reconcile.mayCheck(started: false, paused: false, writing: false, scrolling: false, overlayUp: false, mouseDown: false),
              "periodic check never competes with a write, swipe, overlay, mouse drag, pause or start-up")

        let notice = HUDCaption.make(map: RibbonMap(columns: [], viewport: Viewport(start: 0, end: 1), focusedIndex: nil), focusID: nil, hoverID: nil,
                                     toast: "Slack isn't responding. Ribbon will leave it alone until it recovers.")
        check(notice.primary == "Slack isn't responding" && notice.secondary == "Ribbon will leave it alone until it recovers", "toast: headline plus detail")

        // Crash loop guard and relaunch command.
        var h: [Double] = []
        var loop = false
        for t in [0.0, 30, 60] { (h, loop) = Relaunch.recordRelaunch(history: h, now: t) }
        check(loop, "relaunch: 3 relaunches within 2 minutes is a crash loop")
        (h, loop) = Relaunch.recordRelaunch(history: [0, 30], now: 200)
        check(!loop && h == [200], "relaunch: old relaunches age out")
        check(Relaunch.relaunchCommand(bundlePath: "/A/Ribbon.app", executable: "/A/Ribbon.app/Contents/MacOS/Ribbon", env: ["RIBBON_CMD_FIFO": "x"])
              == ["/A/Ribbon.app/Contents/MacOS/Ribbon", "--relaunched"], "relaunch: QA runs exec the binary so their RIBBON_* settings survive")
        check(Relaunch.relaunchCommand(bundlePath: "/A/Ribbon.app", executable: "/x", env: ["HOME": "/h"]).first == "/usr/bin/open", "relaunch: a normal install goes through Launch Services")
    }
}
