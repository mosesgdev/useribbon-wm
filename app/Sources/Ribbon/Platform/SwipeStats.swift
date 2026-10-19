import Foundation
import QuartzCore

/// Swipe QA instrumentation, only alive when RIBBON_SWIPE_STATS is set (its value, if not "1", is the output path).
/// The writer reports every AX position write; `finish` prints a summary. Thread-safe.
final class SwipeStats: @unchecked Sendable {
    static let shared: SwipeStats? = {
        guard let v = ProcessInfo.processInfo.environment["RIBBON_SWIPE_STATS"], !v.isEmpty else { return nil }
        return SwipeStats(path: v == "1" ? "/tmp/swipe-stats.txt" : v)
    }()

    private struct Write { let frame: Int; let id: UInt32; let x: Double; let posted: Double; let start: Double; let end: Double }
    private let path: String
    private let lock = NSLock()
    private var writes: [Write] = []
    private var ticks: [Double] = []
    private var skipped = 0
    private var frameNo = 0
    private var label = ""
    private var cutoff = Double.infinity
    // Snapshot mode: when the overlay's layers were repositioned (one entry per display frame that moved them).
    private var overlayTicks: [Double] = []
    private var touchAt: Double?, contactAt: Double?, firstMoveAt: Double?, mode = "direct"
    private var commits: [(windows: Int, ms: Double)] = []
    private var cacheHits = 0, cacheMisses = 0
    // Acceptance data (see `finish`): display-link ticks, finger-vs-layer positions, commit timing, real window samples.
    private var linkTicks: [(t: Double, target: Double?)] = []
    private var jitter: [(t: Double, layer: Double, want: Double)] = []
    private var releaseAt: Double?, writesDoneAt: Double?, hiddenAt: Double?
    private var finalErr: Double?
    private var samples: [(t: Double, x: [UInt32: Double])] = []
    private var sampling = false
    private var marks: [(name: String, t: Double)] = []
    private var coreCalls: [Double] = []
    private var hudCalls: [Double] = []

    // Keyboard moves through the overlay: one record per move (or chain of moves), see `navBegin`.
    private var navLabel: String?, navT0 = 0.0
    private var navMarks: [(name: String, t: Double)] = []
    private var navTicks: [(t: Double, x: Double)] = []
    private var navCosts: [Double] = []
    private var navX0: Double?

    init(path: String) { self.path = path }

    /// `fingersUp`: time the fingers lift; smoothness is judged on the finger-down part, the glide is reported separately.
    func reset(_ label: String, fingersUp: Double = .infinity, touchDown: Double? = nil) { lock.lock(); writes = []; ticks = []; skipped = 0; frameNo = 0; self.label = label; cutoff = fingersUp
        touchAt = touchDown; linkTicks = []; jitter = []; releaseAt = nil; writesDoneAt = nil; hiddenAt = nil; finalErr = nil; samples = []; overlayTicks = []; contactAt = nil; firstMoveAt = nil; commits = []; cacheHits = 0; cacheMisses = 0; marks = []; coreCalls = []; hudCalls = []; lock.unlock() }

    /// The contacts qualified as a swipe (device time) ...
    func gestureBegan(contactTime t: Double, mode m: String) { lock.lock(); if contactAt == nil { contactAt = t }; mode = m; lock.unlock() }
    /// ... and this is the first time anything on screen followed them (overlay layer moved / first AX write finished).
    func firstMove(_ t: Double = CACurrentMediaTime()) { lock.lock(); if firstMoveAt == nil { firstMoveAt = t }; lock.unlock() }
    /// Gesture-start profiling: a named stamp (first occurrence per swipe wins), reported relative to the qualifying contact frame.
    func mark(_ name: String, _ t: Double = CACurrentMediaTime()) { lock.lock(); if contactAt != nil, !marks.contains(where: { $0.name == name }) { marks.append((name, t)) }; lock.unlock() }
    /// Duration (ms) of one core round trip (JSON encode + core + decode) during the swipe.
    func coreCall(ms: Double) { lock.lock(); coreCalls.append(ms); lock.unlock() }
    /// Main-thread time (ms) of one in-gesture HUD/strip update.
    func hudCall(ms: Double) { lock.lock(); hudCalls.append(ms); lock.unlock() }
    func overlayFrame(_ t: Double = CACurrentMediaTime()) { lock.lock(); overlayTicks.append(t); lock.unlock() }
    func commit(windows: Int, ms: Double) { lock.lock(); commits.append((windows, ms)); lock.unlock() }
    /// One display-link (or fallback timer) tick; `target` is the link's targetTimestamp (nil for the timer).
    func linkTick(_ t: Double, target: Double?) { lock.lock(); linkTicks.append((t, target)); lock.unlock() }
    /// Per overlay frame: where the reference layer is vs where the fingers say it should be (px, AX x).
    func position(layer: Double, want: Double, at t: Double = CACurrentMediaTime()) { lock.lock(); jitter.append((t, layer, want)); lock.unlock() }
    func released(_ t: Double = CACurrentMediaTime()) { lock.lock(); releaseAt = t; lock.unlock() }
    func writesDone(_ t: Double = CACurrentMediaTime()) { lock.lock(); writesDoneAt = t; lock.unlock() }
    func overlayHidden(_ t: Double = CACurrentMediaTime()) { lock.lock(); hiddenAt = t; lock.unlock() }
    /// Largest |AX frame - plan target| (px) over the windows after the commit.
    func finalError(maxPx: Double) { lock.lock(); finalErr = max(finalErr ?? 0, maxPx); lock.unlock() }

    /// Samples real window x positions (CGWindowList, what the window server shows) at ~display rate until `finish`.
    func startSampling(ids: [UInt32], hz: Double = 120) {
        lock.lock(); samples = []; sampling = true; lock.unlock()
        let q = DispatchQueue(label: "ribbon.stats.sample", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now(), repeating: 1 / hz, leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { timer.cancel(); return }
            self.lock.lock(); let on = self.sampling; self.lock.unlock()
            guard on else { timer.cancel(); return }
            let t = CACurrentMediaTime()
            guard let arr = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
            let want = Set(ids)
            var x: [UInt32: Double] = [:]
            for d in arr {
                if let n = d[kCGWindowNumber as String] as? UInt32, want.contains(n), let b = d[kCGWindowBounds as String] as? [String: Any], let v = b["X"] as? Double { x[n] = v }
            }
            self.lock.lock(); self.samples.append((t, x)); self.lock.unlock()
        }
        timer.resume()
    }
    func snapshotUse(hit: Bool) { lock.lock(); if hit { cacheHits += 1 } else { cacheMisses += 1 }; lock.unlock() }

    /// A new batch of targets reached the writer. Returns the frame number to pass to `write`.
    func tick(_ t: Double = CACurrentMediaTime()) -> Int { lock.lock(); defer { lock.unlock() }; frameNo += 1; ticks.append(t); return frameNo }
    /// A window's write was held back because its app was still busy with the previous one.
    func skip() { lock.lock(); skipped += 1; lock.unlock() }
    func write(frame: Int, id: UInt32, x: Double, posted: Double, start: Double, end: Double) {
        lock.lock(); writes.append(Write(frame: frame, id: id, x: x, posted: posted, start: start, end: end)); if firstMoveAt == nil { firstMoveAt = end }; lock.unlock()
    }

    /// A keyboard move starts (the plan reached `apply`). A move that arrives while the previous one is still on screen carries on
    /// the same record, with a `retarget` mark.
    func navBegin(_ label: String, at t: Double = CACurrentMediaTime()) {
        lock.lock()
        let fresh = navLabel == nil
        if fresh { navLabel = label; navT0 = t; navMarks = []; navTicks = []; navCosts = []; navX0 = nil }
        else { navMarks.append(("retarget", t)) }
        lock.unlock()
        // Where the main thread is between the key and the first frame: when the run loop next takes a block from the main queue, and
        // when it first runs out of work (the display link or the timer can only deliver after that).
        guard fresh else { return }
        DispatchQueue.main.async { [weak self] in self?.navMark("main_async") }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { [weak self] _, _ in self?.navMark("runloop_idle") }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    /// Where the leading tile stands before it moves: `first movement` is the first frame that differs from it.
    func navStart(x: Double?) { lock.lock(); if navX0 == nil { navX0 = x }; lock.unlock() }
    /// The move stayed with the AX path (`why`): printed so a QA run shows which commands the overlay did not take.
    func navFallback(_ why: String) { appendOut("== nav fallback: \(why)\n") }
    /// A named stamp of the current keyboard move (the first of each name wins, except `retarget`).
    func navMark(_ name: String, _ t: Double = CACurrentMediaTime()) {
        lock.lock(); if navLabel != nil, !navMarks.contains(where: { $0.name == name }) { navMarks.append((name, t)) }; lock.unlock()
    }
    /// One display frame of the move: the leading tile's x, and what the main thread spent on the frame (ms).
    func navTick(x: Double, cost ms: Double, at t: Double = CACurrentMediaTime()) {
        lock.lock(); if navLabel != nil { navTicks.append((t, x)); navCosts.append(ms) }; lock.unlock()
    }
    /// The overlay of the move is gone: print what it did (plan to first movement, frame pacing, steps, jumps).
    func navFinish(at end: Double = CACurrentMediaTime()) {
        lock.lock(); let lab = navLabel, t0 = navT0, mk = navMarks + [("hidden", end)], tk = navTicks, cost = navCosts, x0 = navX0 ?? navTicks.first?.x ?? 0; navLabel = nil; lock.unlock()
        guard let lab else { return }
        let ms = 1000.0
        let dts = zip(tk.dropFirst(), tk).map { ($0.t - $1.t) * ms }
        let steps = zip(tk.dropFirst(), tk).map { abs($0.x - $1.x) }
        let firstMove = tk.first { abs($0.x - x0) >= 1 }.map { ($0.t - t0) * ms }
        // How far the first frames jump: the first tick (the clock starts there, so it should still be at the start), and the first
        // frame that shows movement, as a fraction of the whole travel.
        let travel = abs((tk.last?.x ?? x0) - x0)
        let firstTick = tk.first.map { abs($0.x - x0) } ?? 0
        let firstStep = tk.first { abs($0.x - x0) >= 1 }.map { abs($0.x - x0) } ?? 0
        let fromMoving = mk.first { $0.name == "tiles_moving" }.map { ($0.t - t0) * ms }       // release to hidden: the glide and the fade
        let releaseToHidden = fromMoving.map { (end - t0) * ms - $0 }
        // A spring only slows down once it has passed its peak speed: a later step that grows by over 15% (and 2 px) is judder
        // (a retarget mid-glide legitimately does it once per command).
        let moving = steps.filter { $0 > 0.5 }
        let med = Self.pct(moving, 0.5)
        let peak = moving.firstIndex(of: moving.max() ?? 0) ?? 0
        let judder = zip(moving.dropFirst(peak + 1), moving.dropFirst(peak)).filter { $0 > $1 * 1.15 + 2 }.count
        let json: [String: Any] = [
            "nav": lab, "frames": tk.count, "first_move_ms": firstMove as Any,
            "first_tick_px": firstTick, "first_step_px": firstStep, "first_step_frac": travel > 0 ? firstStep / travel : 0, "travel_px": travel,
            "release_to_hidden_ms": releaseToHidden as Any,
            "marks_ms": Dictionary(mk.map { ($0.name, ($0.t - t0) * ms) }, uniquingKeysWith: { a, _ in a }),
            "interval_ms": ["mean": Self.mean(dts), "p95": Self.pct(dts, 0.95), "max": dts.max() ?? 0],
            "step_px": ["median": med, "max": moving.max() ?? 0], "judder": judder,
            "frame_cost_ms": ["mean": Self.mean(cost), "p95": Self.pct(cost, 0.95), "max": cost.max() ?? 0],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) { appendOut(line + "\n") }
        let f = { (v: Double) in String(format: "%.1f", v) }
        appendOut("== nav stats [\(lab)] first movement \(firstMove.map(f) ?? "n/a") ms after the plan, first frame \(f(firstTick)) px and first step \(f(firstStep)) of \(f(travel)) px; hidden \(releaseToHidden.map(f) ?? "n/a") ms after the tiles started; \(tk.count) frames, interval mean \(f(Self.mean(dts))) p95 \(f(Self.pct(dts, 0.95))) max \(f(dts.max() ?? 0)) ms; frame cost mean \(f(Self.mean(cost))) max \(f(cost.max() ?? 0)) ms\n")
    }

    private static func pct(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }
    private static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    private static func sd(_ a: [Double]) -> Double { let m = mean(a); return a.count < 2 ? 0 : (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot() }

    func finish() {
        lock.lock(); let w = writes, t = ticks, sk = skipped, lab = label, cut = cutoff
        let lt = linkTicks, jt = jitter, rel = releaseAt, wd = writesDoneAt, hid = hiddenAt, fe = finalErr, sm = samples
        sampling = false
        let mk = marks, cc = coreCalls, hc = hudCalls
        let ot = overlayTicks, c0 = contactAt, fm = firstMoveAt, md = mode, cm = commits, td0 = touchAt, ch = cacheHits, cmiss = cacheMisses; lock.unlock()
        guard !w.isEmpty || !ot.isEmpty || !lt.isEmpty else { return }
        let ms = 1000.0
        let lat = w.map { ($0.end - $0.start) * ms }
        let age = w.map { ($0.end - $0.posted) * ms }
        var spreads: [Double] = []
        for (_, g) in Dictionary(grouping: w, by: \.frame) where g.count > 1 {
            spreads.append((g.map(\.end).max()! - g.map(\.end).min()!) * ms)
        }
        let td = t.filter { $0 <= cut }
        let dts = zip(td.dropFirst(), td).map { ($0 - $1) * ms }
        // Visual smoothness: speed of the most-moving window between consecutive position changes, over the middle 60% of the swipe.
        let down = w.filter { $0.end <= cut }
        let byId = Dictionary(grouping: down, by: \.id)
        func distinctX(_ v: [Write]) -> Int { Set(v.map(\.x)).count }
        let refId = byId.keys.max { distinctX(byId[$0] ?? []) < distinctX(byId[$1] ?? []) }
        let ref = (refId.flatMap { byId[$0] } ?? []).sorted { $0.end < $1.end }
        let glide = w.filter { $0.end > cut }
        var changes: [(t: Double, x: Double)] = []
        for r in ref where changes.last.map({ $0.x != r.x }) ?? true { changes.append((r.end, r.x)) }
        var speeds: [Double] = [], gaps: [Double] = [], steps: [Double] = []
        if changes.count > 5 {
            let lo = changes.count / 5, hi = changes.count * 4 / 5
            for i in max(1, lo)..<hi {
                let dt = changes[i].t - changes[i - 1].t
                gaps.append(dt * ms); steps.append(abs(changes[i].x - changes[i - 1].x))
                if dt > 0 { speeds.append((changes[i].x - changes[i - 1].x) / dt) }
            }
        }
        let cv = Self.mean(speeds.map(abs)) > 0 ? Self.sd(speeds) / Self.mean(speeds.map(abs)) : 0
        let f = { (v: Double) in String(format: "%.1f", v) }
        let od = zip(ot.filter { $0 <= cut }.dropFirst(), ot.filter { $0 <= cut }).map { ($0 - $1) * ms }
        let oh = ot.filter { $0 <= cut }.count
        let latency = (c0 != nil && fm != nil) ? f((fm! - c0!) * ms) + " ms" : "n/a"
        let fromTouch = (td0 != nil && fm != nil) ? f((fm! - td0!) * ms) + " ms" : "n/a"
        func stats(_ a: [Double]) -> [String: Double] { ["n": Double(a.count), "mean": Self.mean(a), "p50": Self.pct(a, 0.5), "p95": Self.pct(a, 0.95), "max": a.max() ?? 0, "sd": Self.sd(a)] }
        // Display-link pacing during the fingers-down part: intervals, drops (> 1.5x nominal, first interval excluded), hitch time.
        let ldown = lt.filter { $0.t <= cut }
        let linkDts = zip(ldown.dropFirst(), ldown).map { ($0.t - $1.t) * ms }
        let linkSpan = (ldown.last?.t ?? 0) - (ldown.first?.t ?? 0)
        let fromLink = ldown.filter { $0.target != nil }
        let nominal: Double = {
            if fromLink.count > 3 { return Self.pct(zip(fromLink.dropFirst(), fromLink).map { ($0.t - $1.t) * ms }, 0.5) }
            return 1000.0 / 120
        }()
        let drops = linkDts.dropFirst().filter { $0 > 1.5 * nominal }
        let hitchMs = linkDts.dropFirst().filter { $0 > 1.5 * nominal }.map { $0 - nominal }.reduce(0, +)
        // Overlay frames (layers actually moved): jitter of the layer vs the finger-derived position.
        let dev = jt.filter { $0.t <= cut }.map { abs($0.layer - $0.want) }
        let jd = jt.filter { $0.t <= cut }
        var spd: [Double] = []
        for i in 1..<max(1, jd.count) where jd[i].t > jd[i - 1].t { spd.append((jd[i].layer - jd[i - 1].layer) / (jd[i].t - jd[i - 1].t)) }
        let mid = spd.isEmpty ? [] : Array(spd[(spd.count / 5)..<max(spd.count / 5 + 1, spd.count * 4 / 5)])
        let spdCV = Self.mean(mid.map(abs)) > 0 ? Self.sd(mid) / Self.mean(mid.map(abs)) : 0
        // Real windows as the window server shows them (direct mode: today's jitter; snapshot mode: must not move while fingers are down).
        var realMoves = 0, realCV = 0.0, realGapMax = 0.0, realGapMean = 0.0
        let sd0 = sm.filter { $0.t <= cut }
        if let ref = Set(sd0.flatMap { $0.x.keys }).max(by: { a, b in Set(sd0.compactMap { $0.x[a] }).count < Set(sd0.compactMap { $0.x[b] }).count }) {
            var chg: [(t: Double, x: Double)] = []
            for q in sd0 { if let x = q.x[ref], chg.last.map({ $0.x != x }) ?? true { chg.append((q.t, x)) } }
            realMoves = max(0, chg.count - 1)
            if chg.count > 5 {
                let gaps = zip(chg.dropFirst(), chg).map { ($0.t - $1.t) * ms }
                var sp: [Double] = []
                for i in 1..<chg.count { sp.append((chg[i].x - chg[i - 1].x) / (chg[i].t - chg[i - 1].t)) }
                let m = Array(sp[(sp.count / 5)..<max(sp.count / 5 + 1, sp.count * 4 / 5)])
                realCV = Self.mean(m.map(abs)) > 0 ? Self.sd(m) / Self.mean(m.map(abs)) : 0
                realGapMax = gaps.max() ?? 0; realGapMean = Self.mean(gaps)
            }
        }
        let latMs: Double? = (c0 != nil && fm != nil) ? (fm! - c0!) * ms : nil
        let json: [String: Any] = [
            "swipe": lab, "mode": md, "nominal_ms": nominal,
            "link": ["source": fromLink.isEmpty ? "timer" : "displaylink", "interval_ms": stats(linkDts), "dropped_after_first": drops.count,
                     "hitch_ms_per_s": linkSpan > 0 ? hitchMs / linkSpan : 0,
                     "hitch_at_frame": linkDts.enumerated().filter { $0.offset > 0 && $0.element > 1.5 * nominal }.map { $0.offset + 1 }],
            "overlay": ["frames": oh, "interval_ms": stats(od), "deviation_px": stats(dev), "speed_cv": spdCV],
            "latency_ms": latMs as Any, "latency_frames": latMs.map { $0 / nominal } as Any,
            "latency_from_touch_ms": (td0 != nil && fm != nil) ? (fm! - td0!) * ms : NSNull() as Any,
            "commit": ["release_to_writes_ms": (rel != nil && wd != nil) ? (wd! - rel!) * ms : NSNull() as Any,
                       "release_to_hidden_ms": (rel != nil && hid != nil) ? (hid! - rel!) * ms : NSNull() as Any,
                       "final_error_px": fe ?? NSNull() as Any, "windows": cm.map(\.windows).reduce(0, +)],
            "real_windows": ["samples": sd0.count, "windows_seen": Set(sd0.flatMap { $0.x.keys }).count, "moves_while_fingers_down": realMoves, "update_gap_ms_mean": realGapMean, "update_gap_ms_max": realGapMax, "speed_cv": realCV],
            "start_path_ms": Dictionary(uniqueKeysWithValues: mk.map { ($0.name, c0 != nil ? ($0.t - c0!) * ms : 0) }),
            "core_call_ms": stats(cc), "hud_call_ms": stats(hc),
            "snapshots": ["cached": ch, "placeholder": cmiss],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) { appendOut(line + "\n") }
        var out = """
        == swipe stats [\(lab)] mode=\(md) first-move latency \(latency) after the contacts qualified, \(fromTouch) after the first touch

        """
        if !ot.isEmpty {
            out += """
              overlay frames   \(oh) while fingers down; interval ms  mean \(f(Self.mean(od)))  sd \(f(Self.sd(od)))  p95 \(f(Self.pct(od, 0.95)))  max \(f(od.max() ?? 0))   (target steady 16.7 / 8.3)
              commit           \(cm.map { "\($0.windows) windows in \(f($0.ms)) ms" }.joined(separator: ", "))   snapshots: \(ch) cached, \(cmiss) placeholder

            """
        }
        if w.isEmpty { NSLog("%@", out); appendOut(out); return }
        out += """
        == direct writes: windows=\(Set(w.map(\.id)).count) frames=\(t.count) writes=\(w.count) held-back=\(sk)
          frame dt ms      mean \(f(Self.mean(dts)))  sd \(f(Self.sd(dts)))  max \(f(dts.max() ?? 0))
          write latency ms mean \(f(Self.mean(lat)))  p95 \(f(Self.pct(lat, 0.95)))  max \(f(lat.max() ?? 0))
          target->written  mean \(f(Self.mean(age)))  p95 \(f(Self.pct(age, 0.95)))  max \(f(age.max() ?? 0))   (ms from target to AX write done)
          window lag ms    mean \(f(Self.mean(spreads)))  max \(f(spreads.max() ?? 0))   (spread between windows of one frame)
          ref window       update gap ms mean \(f(Self.mean(gaps)))  sd \(f(Self.sd(gaps)))  max \(f(gaps.max() ?? 0))   step px mean \(f(Self.mean(steps)))  CV \(String(format: "%.2f", Self.mean(steps) > 0 ? Self.sd(steps) / Self.mean(steps) : 0))  speed CV \(String(format: "%.2f", cv))  (lower = smoother, fingers down only)
          glide after release: \(Set(glide.map(\.frame)).count) frames, \(f(((glide.map(\.end).max() ?? cut) - cut) * ms)) ms

        """
        NSLog("%@", out)
        appendOut(out)
    }

    private func appendOut(_ out: String) {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(out.utf8)); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: Data(out.utf8)) }
    }
}
