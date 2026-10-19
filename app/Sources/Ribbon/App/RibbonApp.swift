import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: Controller?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // QA: RIBBON_APPEARANCE=dark|light pins the appearance (the VM cannot switch it: Apple Events are not authorised there).
        switch ProcessInfo.processInfo.environment["RIBBON_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        Edition.logMismatch()   // an app and a core of different editions run as free (no Plus feature is registered)
        if Relaunch.checkLaunch() { NSApp.terminate(nil); return }   // crash loop: windows un-parked, stay out of the way
        Relaunch.startWatchdog()
        controller = Controller()
        controller?.launch()
    }

    /// Quit, SIGTERM, logout: any orderly end. A crash or SIGKILL never gets here, which is how the watchdog tells them apart.
    func applicationWillTerminate(_ notification: Notification) { Relaunch.markCleanExit() }
}

@main
enum RibbonMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--bench-ax"), i + 1 < args.count, let pid = pid_t(args[i + 1]) { exit(AXBench.run(pid: pid)) }
        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--hotkey-selftest") { MainActor.assumeIsolated { exit(HotkeySelfTest.run()) } }
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
            MainActor.assumeIsolated { exit(Snapshot.run(dir: dir)) }
        }
        if let i = args.firstIndex(of: "--hud-snapshot") {
            let dir = i + 1 < args.count ? args[i + 1] : "hud-snapshots"
            MainActor.assumeIsolated { exit(HUDSnapshot.run(dir: dir)) }
        }
        if let i = args.firstIndex(of: "--render-icon") {
            let dir = i + 1 < args.count ? args[i + 1] : "icon"
            MainActor.assumeIsolated { exit(IconRenderer.run(dir: dir)) }
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
