import AppKit
import ApplicationServices

/// Crash recovery by relaunch.
///
/// Ribbon cannot put windows back from inside a crash: AX calls are not async-signal-safe. Instead, a tiny `/bin/sh` watchdog
/// (public API only) waits for Ribbon's pid to vanish. If Ribbon left a clean-exit marker (Quit, SIGTERM, logout: anything
/// that runs `applicationWillTerminate`) the watchdog just ends. Otherwise Ribbon crashed or was killed: the watchdog starts it
/// again within about a second. The new instance inherits `originals.json` (the real pre-Ribbon frames, written atomically)
/// and `session.json`, so it picks the layout up where it was; windows that were parked off-screen come straight back.
/// A crash loop (3 relaunches within 2 minutes) stops relaunching and un-parks every window from `originals.json` instead.
enum Relaunch {
    static let flag = "--relaunched"

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ribbon")
    }
    private static var historyURL: URL { supportDir.appendingPathComponent("relaunches.json") }
    private static func marker(_ pid: pid_t) -> String { supportDir.appendingPathComponent("clean-exit.\(pid)").path }

    // MARK: pure decisions

    static let loopLimit = 3
    static let loopWindow = 120.0

    /// Records a relaunch at `now`; returns the pruned history and whether it is a crash loop.
    static func recordRelaunch(history: [Double], now: Double) -> (history: [Double], loop: Bool) {
        let kept = history.filter { now - $0 < loopWindow && $0 <= now } + [now]
        return (kept, kept.count >= loopLimit)
    }

    /// The watchdog's shell script. $1 = Ribbon's pid, $2 = its marker file, the rest = the relaunch command.
    static let script = """
    P="$1"; M="$2"; shift 2
    while kill -0 "$P" 2>/dev/null; do sleep 1; done
    if [ -e "$M" ]; then rm -f "$M"; exit 0; fi
    pgrep -x Ribbon >/dev/null && exit 0
    exec "$@"
    """

    /// What the watchdog runs to start Ribbon again. Test and QA runs carry RIBBON_* settings that `open` would drop, so
    /// those exec the binary directly with the inherited environment; a normal install goes through Launch Services.
    static func relaunchCommand(bundlePath: String, executable: String, env: [String: String]) -> [String] {
        if env.keys.contains(where: { $0.hasPrefix("RIBBON_") }) { return [executable, flag] }
        return ["/usr/bin/open", "-n", bundlePath, "--args", flag]
    }

    // MARK: lifecycle

    /// Called once at launch. nil = start normally; true = crash loop (windows were un-parked, do not start).
    @MainActor
    static func checkLaunch() -> Bool {
        guard CommandLine.arguments.contains(flag) else { return false }
        let old = (try? JSONDecoder().decode([Double].self, from: Data(contentsOf: historyURL))) ?? []
        let (history, loop) = recordRelaunch(history: old, now: Date().timeIntervalSince1970)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        guard loop else { return false }
        NSLog("ribbon: crash loop, un-parking windows and giving up")
        unparkFromFile()
        try? FileManager.default.removeItem(at: historyURL)
        return true
    }

    /// Starts the watchdog for this process. Failure only costs the automatic relaunch.
    static func startWatchdog() {
        guard let exe = Bundle.main.executablePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let cmd = relaunchCommand(bundlePath: Bundle.main.bundlePath, executable: exe, env: ProcessInfo.processInfo.environment)
        p.arguments = ["-c", script, "ribbon-watchdog", String(getpid()), marker(getpid())] + cmd
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Deliberate termination: tells the watchdog not to relaunch. Safe to call twice.
    static func markCleanExit() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker(getpid()), contents: Data())
    }

    /// Puts every window listed in originals.json back (the crashed run's real frames), without managing anything.
    @MainActor
    static func unparkFromFile() {
        guard let data = try? Data(contentsOf: Restore.defaultURL), let file = try? JSONDecoder().decode(OriginalsFile.self, from: data) else { return }
        let displays = Screens.all().map(\.frame)
        guard let first = displays.first else { return }
        let byPid = Dictionary(grouping: file.windows, by: \.pid)
        for (pid, saved) in byPid {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            for el in app.windows() {
                guard let id = el.windowID, let w = saved.first(where: { $0.id == id }) else { continue }
                el.setFrame(Restore.restoredFrame(w.frame, displays: displays, fallback: first))
            }
        }
        try? FileManager.default.removeItem(at: Restore.defaultURL)
    }
}
