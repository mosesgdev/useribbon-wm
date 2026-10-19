import AppKit
import CoreGraphics

/// Session event tap that keeps a Ribbon three-finger swipe from also reaching the app under the pointer: with the system's
/// three-finger gestures off, macOS delivers those fingers as horizontal scroll-wheel (and gesture) events, and apps like
/// Dia or Arc switch profile/space on them. The decisions live in `SwipeGate`; this only plumbs events through it.
/// Runs on its own thread so a busy main thread can never make the tap time out. Two-finger scrolling is passed untouched.
final class SwipeTap: @unchecked Sendable {
    static let shared = SwipeTap()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()

    /// NSEvent gesture-family types as CGEvent types: rotate, beginGesture, endGesture, gesture, magnify, swipe.
    private static let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31]

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard tap == nil, AXIsProcessTrusted() else { return }
        var mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        for t in Self.gestureTypes { mask |= CGEventMask(1) << t }
        let cb: CGEventTapCallBack = { _, type, event, _ in
            switch type.rawValue {
            case CGEventType.scrollWheel.rawValue:
                let phase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase))
                let momentum = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
                return SwipeGate.shared.swallowScroll(phase: phase, momentum: momentum, at: CACurrentMediaTime()) ? nil : Unmanaged.passUnretained(event)
            case CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue:
                if let t = SwipeTap.shared.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            default:
                return SwipeGate.shared.swallowGesture(at: CACurrentMediaTime()) ? nil : Unmanaged.passUnretained(event)
            }
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: cb, userInfo: nil) else {
            NSLog("ribbon: event tap unavailable (Accessibility?)"); return
        }
        tap = port
        let thread = Thread { [self] in
            let src = CFMachPortCreateRunLoopSource(nil, port, 0)
            let rl = CFRunLoopGetCurrent()
            lock.lock(); runLoop = rl; lock.unlock()
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        thread.name = "ribbon.swipe-tap"; thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; runLoop = nil
        SwipeGate.shared.reset()
    }
}

/// Whether macOS itself also reacts to three-finger horizontal swipes (Mission Control / Spaces would fire together with Ribbon).
/// Read-only; Ribbon never writes system defaults.
enum SystemSwipe {
    static let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    static func key(_ fingers: Int) -> String { fingers == 4 ? "TrackpadFourFingerHorizSwipeGesture" : "TrackpadThreeFingerHorizSwipeGesture" }

    /// 1 and 2 mean "on" (0 off). `read` is injectable for tests.
    static func conflicts(fingers: Int = 3, read: (String, String) -> Int? = { d, k in
        CFPreferencesAppSynchronize(d as CFString)
        return (CFPreferencesCopyAppValue(k as CFString, d as CFString) as? NSNumber)?.intValue
    }) -> Bool {
        domains.contains { [1, 2].contains(read($0, key(fingers)) ?? 0) }
    }

    static let noticeShownKey = "systemSwipeNoticeShown"
    static func message(_ fingers: Int) -> String {
        fingers == 4 ? "macOS also uses four-finger swipes. Turn that off in Trackpad settings so Ribbon and macOS stay out of each other's way."
                     : "macOS also uses three-finger swipes — switch it to four fingers so Ribbon and macOS stay out of each other's way."
    }
    static func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
