import AppKit
import CoreImage
import ScreenCaptureKit

/// Window images for the swipe overlay, from ScreenCaptureKit. In memory only: nothing is ever written to disk, and
/// everything is dropped when Ribbon pauses or stops. Main-thread API; captures run asynchronously and in parallel.
///
/// The ledger (pure, `SnapshotLedger`) decides what is fresh. A stale image is still shown rather than waiting, so the first
/// frame of a swipe never waits for a capture; a window with no image at all gets a placeholder tile.
@MainActor
final class SnapshotStore {
    /// Cached: CGPreflightScreenCaptureAccess costs several milliseconds per call, which would land inside the first frame of a
    /// swipe. `refreshPermission()` re-reads it off the main thread (at touch-down, long before the swipe qualifies).
    static var permitted: Bool {
        if let c = cachedPermitted { return c }
        let v = ScreenRecording.preflight(); cachedPermitted = v; return v
    }
    private static var cachedPermitted: Bool?
    static func refreshPermission() {
        DispatchQueue.global(qos: .utility).async {
            let v = ScreenRecording.preflight()
            DispatchQueue.main.async { MainActor.assumeIsolated { cachedPermitted = v } }
        }
    }

    private(set) var images: [UInt32: CGImage] = [:]
    /// A blurred, small twin of each image: what the overlay shows inside the pin's blur strip (made with the capture, off the main thread).
    private(set) var softened: [UInt32: CGImage] = [:]
    /// Where each window really was when it was captured (global, top-left origin): its picture is drawn at that size.
    private(set) var frames: [UInt32: CGRect] = [:]
    private var ledger = SnapshotLedger()
    private(set) var backdrop: CGImage?
    /// The backdrop frosted (small and blurred, like the twins): what a ribbon window dissolves into beside the pin.
    private(set) var softBackdrop: CGImage?
    private var backdropFor: UInt32?
    private var backdropDirty = true
    private var inFlight = Set<UInt32>()
    private var backdropInFlight = false
    /// An image arrived for a window (or the backdrop, id 0) while the overlay may be up.
    var onImage: ((UInt32, CGImage) -> Void)?
    var onBackdrop: ((CGImage) -> Void)?

    /// `maxAge`: how old an image of this window may get before it is captured again.
    struct Want { let id: UInt32; let size: CGSize; let scale: Double; var maxAge = SnapshotLedger.maxAge }

    /// True while something is moving on the overlay (a swipe or a keyboard move): captures that have not started yet are dropped,
    /// so nothing competes with the window server's frames. The caller asks again once things are quiet.
    var hold = false
    static let maxConcurrent = 3

    /// The full-display backdrop (the wallpaper where the managed windows stand) of this display, when the store holds a fresh
    /// one. Only one display's is kept, the focused one; nil while it is being replaced or after `markBackdropDirty()`.
    func backdrop(for displayID: UInt32) -> CGImage? { backdropFor == displayID && !backdropDirty ? backdrop : nil }
    /// The same backdrop frosted, on the same terms.
    func softBackdrop(for displayID: UInt32) -> CGImage? { backdropFor == displayID && !backdropDirty ? softBackdrop : nil }

    func image(_ id: UInt32, size: CGSize, now: Double = CACurrentMediaTime()) -> CGImage? {
        guard ledger.use(id, size: size, now: now) != .none else { return nil }
        ledger.touch(id, now: now)
        return images[id]
    }
    func use(_ id: UInt32, size: CGSize, now: Double = CACurrentMediaTime()) -> SnapshotLedger.Use { ledger.use(id, size: size, now: now) }
    /// Seconds since the window's picture was taken (nil: none).
    func age(of id: UInt32) -> Double? { ledger.age(id, now: CACurrentMediaTime()) }
    /// A picture a tile of this size may show, stale or not: false for a window never captured or one that changed size since.
    func hasPicture(_ id: UInt32, size: CGSize) -> Bool { images[id] != nil && ledger.use(id, size: size, now: CACurrentMediaTime()) != .none }

    // MARK: invalidation (cheap: flags only)

    func markDirty(_ id: UInt32) { ledger.markDirty(id) }
    func markAllDirty() { ledger.markAllDirty(); backdropDirty = true }
    func markBackdropDirty() { backdropDirty = true }
    func forget(_ id: UInt32) { ledger.forget(id); images[id] = nil; softened[id] = nil; frames[id] = nil }
    /// Ribbon paused or stopped, or Screen Recording was withdrawn: nothing stays in memory.
    func dropAll() { ledger.removeAll(); images = [:]; softened = [:]; frames = [:]; backdrop = nil; softBackdrop = nil; backdropFor = nil; backdropDirty = true }

    /// Keeps images only for windows that still exist (and within capacity).
    func trim(alive: Set<UInt32>) { for id in ledger.trim(alive: alive) { images[id] = nil; softened[id] = nil; frames[id] = nil } }

    // MARK: capture

    /// Captures what is missing or stale, a few at a time, in the order given. `force`: windows on screen are always captured again (a swipe is starting).
    /// `through`: windows captured even while something moves (`hold`): the two whose title bars change with the focus, so
    /// their pictures are new when the overlay fades out over the live windows.
    /// `managed` and `floaters` are left out of the backdrop: the overlay draws the first as sliding tiles and the second as tiles that stay put.
    func refresh(_ wants: [Want], force: Set<UInt32> = [], excludingBackdropOf displayID: UInt32? = nil, managed: Set<UInt32> = [], floaters: Set<UInt32> = [], through: Set<UInt32> = []) {
        guard Self.permitted, !hold || !through.isEmpty else { return }
        let todo = Self.due(wants, hold: hold, through: through, force: force, inFlight: inFlight, ledger: ledger, now: CACurrentMediaTime())
        let needBackdrop = !hold ? displayID.map { (backdropDirty || backdropFor != $0 || backdrop == nil) && !backdropInFlight } ?? false : false
        guard !todo.isEmpty || needBackdrop else { return }
        for w in todo { inFlight.insert(w.id) }
        if needBackdrop { backdropInFlight = true }
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                self?.finish(failed: todo.map(\.id), backdrop: needBackdrop); return
            }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if needBackdrop, let did = displayID, let display = content.displays.first(where: { $0.displayID == did }) {
                let gone = Self.backdropHides(content.windows.map { ($0.windowID, $0.windowLayer, $0.owningApplication?.processID) },
                                              managed: managed, floaters: floaters, ownPID: ownPID)
                let hide = content.windows.filter { gone.contains($0.windowID) }
                let cfg = SCStreamConfiguration()
                let s = Double(NSScreen.screens.first { Screens.displayID($0) == did }?.backingScaleFactor ?? 2)
                cfg.width = Int(Double(display.width) * s); cfg.height = Int(Double(display.height) * s)
                cfg.showsCursor = false
                let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: hide), configuration: cfg)
                let soft = await Task.detached(priority: .utility) { image.flatMap { Self.soften($0, radius: SwipeOverlay.veilBlur * s) } }.value
                self?.gotBackdrop(image, soft: soft, display: did)
            } else if needBackdrop { self?.gotBackdrop(nil, soft: nil, display: displayID ?? 0) }
            await withTaskGroup(of: (UInt32, CGSize, Double, CGRect, CGImage?, CGImage?).self) { group in
                // At most `maxConcurrent` captures at a time, in the order given (focused and on-screen windows first), so the
                // window server is never flooded; a capture that has not started when movement begins is dropped (`hold`).
                var queue = todo[...]
                var running = 0
                while true {
                    while running < Self.maxConcurrent, let w = queue.popFirst() {
                        guard self?.hold != true || through.contains(w.id), let scw = byID[w.id], scw.frame.width >= 1 else { self?.inFlight.remove(w.id); continue }
                        running += 1
                        group.addTask {
                            // The window as it really is: asked for the planned size, a window that refuses it (a minimum
                            // height) would come back fitted into it, shrunk.
                            let cfg = SCStreamConfiguration()
                            cfg.width = max(1, Int(scw.frame.width * w.scale)); cfg.height = max(1, Int(scw.frame.height * w.scale))
                            cfg.showsCursor = false
                            cfg.ignoreShadowsSingleWindow = true
                            let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg)
                            let ok = img.flatMap { Self.looksBlank($0) ? nil : $0 }              // checked off the main thread
                            return (w.id, w.size, w.scale, scw.frame, ok, ok.flatMap { Self.soften($0, radius: SwipeOverlay.edgeBlur * w.scale) })
                        }
                    }
                    guard running > 0, let (id, size, scale, frame, img, soft) = await group.next() else { break }
                    running -= 1
                    guard let self else { continue }
                    self.inFlight.remove(id)
                    guard let img else { continue }
                    self.images[id] = img; self.softened[id] = soft; self.frames[id] = frame
                    self.ledger.stored(id, size: size, scale: scale, now: CACurrentMediaTime())
                    self.onImage?(id, img)
                }
            }
            self?.finish(failed: [], backdrop: false)
        }
    }

    /// What a refresh captures now, in the order given: windows that are missing or stale (or forced), not already being captured.
    /// While something moves (`hold`) only the `through` windows.
    nonisolated static func due(_ wants: [Want], hold: Bool, through: Set<UInt32>, force: Set<UInt32>, inFlight: Set<UInt32>, ledger: SnapshotLedger, now: Double) -> [Want] {
        wants.filter { (!hold || through.contains($0.id)) && !inFlight.contains($0.id)
                       && (force.contains($0.id) || ledger.needsCapture($0.id, size: $0.size, scale: $0.scale, now: now, maxAge: $0.maxAge)) }
    }

    private func finish(failed: [UInt32], backdrop b: Bool) {
        for id in failed { inFlight.remove(id) }
        if b { backdropInFlight = false }
    }

    /// What the backdrop leaves out: the managed windows (drawn as tiles), the floating ones (drawn as tiles that stay put: baked in,
    /// one that moved or closed since would linger as a ghost, and one above a tile would vanish under it), Ribbon's own, and
    /// everything layered above the swipe overlay (the Dock, menu bar, banners), which stays live on top of it; a frozen copy beneath
    /// would show through their glass.
    nonisolated static func backdropHides(_ windows: [(id: UInt32, layer: Int, pid: pid_t?)], managed: Set<UInt32>, floaters: Set<UInt32> = [], ownPID: pid_t) -> Set<UInt32> {
        Set(windows.filter { managed.contains($0.id) || floaters.contains($0.id) || $0.pid == ownPID || $0.layer > SwipeOverlay.level }.map(\.id))
    }

    private func gotBackdrop(_ image: CGImage?, soft: CGImage?, display: UInt32) {
        backdropInFlight = false
        guard let image else { return }
        backdrop = image; softBackdrop = soft; backdropFor = display; backdropDirty = false
        onBackdrop?(image)
    }

    /// A small, blurred twin of a window image for the pin's blur strip: shrunk to an eighth (a good low-pass in itself), then a
    /// Gaussian of the remaining radius with its edges extended, so the twin covers the window exactly and the sharp tile
    /// beneath never peeks around it. Drawn stretched back up by the layer, which smooths it further.
    nonisolated static func soften(_ img: CGImage, radius: Double) -> CGImage? {
        let f = 8.0
        let w = max(4, Int((Double(img.width) / f).rounded())), h = max(4, Int((Double(img.height) / f).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let blurred = CIImage(cgImage: small).clampedToExtent().applyingGaussianBlur(sigma: radius / f).cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
    }
    private nonisolated static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// A capture that came back fully transparent or tiny is no use: keep the older image (or the placeholder) instead of a blank tile.
    nonisolated static func looksBlank(_ img: CGImage) -> Bool {
        guard img.width >= 2, img.height >= 2 else { return true }
        // Sample a 9x9 grid of pixels through a 9x9 bitmap redraw (cheap): all fully transparent means nothing was captured.
        let n = 9
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return false }
        return stride(from: 3, to: px.count, by: 4).allSatisfy { px[$0] == 0 }
    }
}

/// Screen Recording is optional: with it, swipes and keyboard moves slide window images (smooth); without it, the real windows
/// move (direct mode, the AX glide). Ribbon asks only when the user presses the button in Settings or in the optional last step
/// of the first-run flow, and once, on a card, after the first swipe or keyboard glide without it.
enum ScreenRecording {
    static var granted: Bool { preflight() }
    /// RIBBON_QA_NO_SCREEN acts as if the permission were missing, so QA can exercise direct mode and the smooth-swipe offer on a VM that has it.
    nonisolated static func preflight() -> Bool {
        ProcessInfo.processInfo.environment["RIBBON_QA_NO_SCREEN"] == nil && CGPreflightScreenCaptureAccess()
    }

    /// Registers Ribbon in the Screen Recording list (the system prompt appears once) and opens the right Privacy pane.
    static func turnOn() {
        if !granted { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    /// Start a fresh copy of Ribbon and quit this one (a clean exit, so the crash watchdog stays out of it): the new
    /// process is the one macOS hands the Screen Recording permission to.
    static func reopen() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    static let note = "Swiping and keyboard moves glide on previews of your windows. Previews stay in memory and are never saved. Reopen Ribbon after turning it on."
}
