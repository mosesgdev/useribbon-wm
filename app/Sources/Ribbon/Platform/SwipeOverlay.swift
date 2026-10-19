import AppKit
import QuartzCore
import SwiftUI

/// The window that carries a swipe: a borderless, click-through, non-activating panel over one display, just above normal
/// windows (below the menu bar, Dock and notifications), holding one CALayer per window with that window's image, over a
/// backdrop (the display without the managed windows). While the fingers move, only layer positions change (Core Animation,
/// implicit animations off): no AX write, no window server round trip per frame. After release the layers glide to their
/// final spots on a short critically damped spring, then the layers cross-fade away (Core Animation, off the main thread) to
/// reveal the real windows beneath.
///
/// Keyboard commands that only slide windows sideways take the same road: the layers are staged at the old layout (only the tiles
/// the move can show; kept from the last move when they still match, and a run of quick moves adds the few that come into
/// reach), the real windows are written once under them, the tiles spring to the new layout, and the focus ring travels with its
/// tile.
///
/// A column held outside the ribbon (Plus) dresses the overlay through `OverlayEdge`: ribbon tiles pass beneath
/// its tile, blurred and dissolved into the backdrop as they near it, and nothing of the ribbon draws on its side (the clip). The
/// free edition's `OverlayEdge` does nothing, and the layers here are the backdrop, the floating windows and the ribbon's tiles.
///
/// Coordinates: tiles are placed in AX space (top-left origin) relative to the display's AX frame; the tile layers are flipped.
@MainActor
final class SwipeOverlay {
    struct TileSpec: Equatable { let id: UInt32; let rect: CGRect; let pid: pid_t; var held = false }
    /// A window the ribbon does not move (see `OverlayFloaters`): `rect` is its frame in AX space; `above`: drawn over the whole ribbon,
    /// else beneath the tiles.
    struct FloaterSpec: Equatable { let id: UInt32; let rect: CGRect; let pid: pid_t; let above: Bool }
    struct FloaterTile { let spec: FloaterSpec; let image: CGImage? }
    nonisolated static let springOmega = 32.0          // critically damped: settles in about a quarter of a second
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    /// `size` and `planY` are the planned rect (the motion and the staging check use them); `y` and `look` are where the layer
    /// is drawn, the window's real height and size when it refuses the planned one.
    private struct Tile { let layer: CALayer; let size: CGSize; let planY: CGFloat; var y: CGFloat; var look: CGSize; var x: Double; var placeholder: Bool; var held = false }

    private var panel: Panel?
    /// `container`, back to front: the backdrop, the floating windows beneath the ribbon, the ribbon tiles (inside `ribbonClip`), what a
    /// held column adds (the blur strip, the dissolve, its tiles; see `OverlayEdge`), the floating windows over the ribbon.
    private let container = CALayer()
    private let backdropLayer = CALayer()
    private let underLayer = CALayer()
    private let overLayer = CALayer()
    private let ribbonClip = CALayer()
    /// What a held column adds: the blur strip, the dissolve and the layer for its tiles (nothing in the free edition).
    private let dressing = OverlayEdge()
    /// Blur radius (points) of a softened twin of a tile (the blur, and the dim's Blur).
    nonisolated static let edgeBlur = 18.0
    /// Blur radius (points) of the frosted backdrop (the dissolve beside a held column, and the dim's Blur).
    nonisolated static let veilBlur = 24.0
    private var tiles: [UInt32: Tile] = [:]
    private var glide = TileGlide()
    private var fadeToken = 0
    private(set) var displayAX = CGRect.zero
    var isUp: Bool { shown }
    var isSettling: Bool { glide.isGliding }
    /// Some staged tile still shows a placeholder (no image yet), or some floating window has no picture.
    var hasPlaceholders: Bool { tiles.values.contains { $0.placeholder } || floaters.values.contains { !$0.hasImage } }
    /// This tile is staged and shows a real picture.
    func hasPicture(_ id: UInt32) -> Bool { tiles[id].map { !$0.placeholder } ?? false }
    /// The focus ring drawn with the tiles (nil = none): which tile it frames and how far it still is from it.
    private let ringLayer = CALayer()
    private var ringID: UInt32?
    private var ringCarry = RingCarry()
    private var ringMargin = 0.0
    private var warmToken = 0, keptToken = 0
    /// Dim or blur of the other windows, drawn with the tiles (see `setDim`).
    private struct DimTile { let tint: CALayer; let frost: CALayer? }
    private var dimTiles: [UInt32: DimTile] = [:]
    private let dimBackdrop = CAShapeLayer()                   // black over the backdrop, the focus window and its tab bar cut out
    private let frostBackdrop = CALayer()                      // Blur: the frosted backdrop (clipped to the usable area) under the tint
    private let frostPicture = CALayer()                       // ... its blurred picture, in display coordinates
    private(set) var dimStyle = OverlayStyle.off
    private var dimAlpha = 0.0, dimArea = CGRect.zero          // the tint's opacity and the area it covers (display coordinates)
    private var dimFocus: UInt32?                              // the tile that stays clear
    private var dimBar: CGRect?                                // its column's tab bar, relative to the tile
    private var dimCarry = RingCarry()                         // the cutout gliding from the old focus to the new one
    private var dimBase = CGSize.zero                          // the focus tile's size the bar was measured against
    private(set) var debugDimHole: CGRect?
    /// False in the self test: the layers are built and moved, the panel never goes on screen.
    var presents = true
    /// Layers kept for the next keyboard move are dropped after this long without one (their textures cost memory).
    static let keepFor = 20.0

    // MARK: show / hide

    private var panelScreen: NSScreen?
    private var panelMenuBar: CGFloat = 0
    /// The panel's window level: what is layered above it (the Dock, menus, banners) stays live over the overlay.
    nonisolated static let level = 2

    /// Creates the (invisible) panel ahead of the first swipe, so showing it later costs one ordering call, not a window build.
    func prewarm(on screen: NSScreen) {
        let menuBar = Self.menuBar(of: screen)
        if panel != nil, panelScreen === screen, panel?.frame == screen.frame, panelMenuBar == menuBar { return }
        teardown()
        let p = Panel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Self.level)            // above normal (0), below floating (3), the Dock and menus
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let view = NSView(frame: bounds)
        view.wantsLayer = true
        p.contentView = view
        // Everything stops at the menu bar: the backdrop holds the menu titles of the app that was frontmost when it was
        // captured, and the live menu bar (transparent) would draw its own over them. Children keep display coordinates.
        container.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - menuBar)
        container.bounds = CGRect(x: 0, y: menuBar, width: bounds.width, height: bounds.height - menuBar)
        container.isGeometryFlipped = true
        container.masksToBounds = true
        backdropLayer.frame = bounds
        backdropLayer.contentsGravity = .resize
        ribbonClip.masksToBounds = true
        dressing.install(bounds: bounds)
        underLayer.frame = bounds
        overLayer.frame = bounds
        container.sublayers = [backdropLayer, underLayer, ribbonClip] + dressing.layers + [overLayer]
        view.layer?.addSublayer(container)
        p.alphaValue = 0
        panel = p; panelScreen = screen; panelMenuBar = menuBar
    }

    /// The menu bar's height on `screen` (0 while it hides): what the visible frame leaves out at the top.
    private static func menuBar(of screen: NSScreen) -> CGFloat { max(0, screen.frame.maxY - screen.visibleFrame.maxY) }

    /// Renders the backdrop once, practically invisible, so the first real swipe does not pay for the first texture upload.
    func warm(backdrop: CGImage, soft: CGImage?, on screen: NSScreen) {
        if !shown, stagedSignature != nil, panel != nil { setBackdrop(backdrop, soft: soft); return }       // staged or kept layers: the newer backdrop is enough
        guard !shown, stagedSignature == nil else { return }
        prewarm(on: screen)
        guard let p = panel else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clearTiles()
        showBackdrop(backdrop, soft: soft)
        CATransaction.commit()
        p.alphaValue = 0.01
        if presents { p.orderFrontRegardless() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { if let self, !self.shown, self.stagedSignature == nil { self.hide() } }
        }
    }

    private(set) var stagedSignature: String?
    /// The pin edge the staged layers were built for.
    var stagedEdge: PinEdge? { dressing.edge }

    /// Builds the layers for the next swipe while the panel is still invisible (fingers resting on the pad), so that
    /// `reveal()` at the first movement is just an opacity flip. `signature` identifies what the layers show.
    /// `edge`: where the ribbon meets a held column (Plus) on this display, in display coordinates (top-left origin), if any.
    func stage(on screen: NSScreen, displayAX: CGRect, backdrop: CGImage?, softBackdrop: CGImage?, tiles specs: [TileSpec], edge: PinEdge?, signature: String,
               image: (UInt32, CGSize) -> CGImage?, realFrame: (UInt32) -> CGRect?, softened: (UInt32) -> CGImage?, icon: (pid_t) -> NSImage?) {
        prewarm(on: screen)
        guard let p = panel, !shown else { return }
        fadeToken += 1
        self.displayAX = displayAX
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clearTiles()
        backdropLayer.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        dressing.setBackground(backdropLayer.backgroundColor)
        showBackdrop(backdrop, soft: softBackdrop)
        dressing.layOut(edge, ribbonClip: ribbonClip, bounds: backdropLayer.frame)            // the whole display, like the backdrop the dissolve shows
        let scale = screen.backingScaleFactor
        // Left to right; held tiles go above what the edge adds, so ribbon tiles slide beneath them as the real windows do.
        for s in specs.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            addTile(s, scale: scale, image: image, realFrame: realFrame, softened: softened, icon: icon)
        }
        dressing.reset()
        updateEdge(now: CACurrentMediaTime())
        container.removeAllAnimations(); container.opacity = 1
        CATransaction.commit()
        warmComposite(p)
        stagedSignature = signature
        keptToken += 1
    }

    /// One tile's layer, at the spec's rect (inside the transaction of the caller). A held column's shadow and the blur strip's
    /// softened twin come with it.
    private func addTile(_ s: TileSpec, scale: CGFloat, image: (UInt32, CGSize) -> CGImage?, realFrame: (UInt32) -> CGRect?, softened: (UInt32) -> CGImage?, icon: (pid_t) -> NSImage?) {
        let l = CALayer()
        l.anchorPoint = .zero
        l.contentsScale = scale
        l.contentsGravity = .resize
        let x = s.rect.minX - displayAX.minX, y = s.rect.minY - displayAX.minY
        let img = image(s.id, s.rect.size)
        let look = img == nil ? s.rect : Self.look(plan: s.rect, real: realFrame(s.id))
        l.bounds = CGRect(origin: .zero, size: look.size)
        l.position = CGPoint(x: x, y: look.minY - displayAX.minY)
        if let img { l.contents = img } else { Self.makePlaceholder(l, icon: icon(s.pid)) }
        Self.shade(l, image: img)
        dressing.place(l, held: s.held, in: ribbonClip)
        tiles[s.id] = Tile(layer: l, size: s.rect.size, planY: y, y: look.minY - displayAX.minY, look: look.size, x: x, placeholder: img == nil, held: s.held)
        if !s.held, img != nil, let soft = softened(s.id) { setEdgeTile(s.id, soft) }
    }

    /// Brings staged layers (kept, or gliding right now) in line with the next keyboard move without touching the rest: `add` tiles
    /// get their layers at their old rects, `drop`ped ones lose theirs (their window closed), and the `snap` ones, out of sight
    /// before and after the move, are put at their final places. Nothing is rebuilt, so a glide in progress runs on.
    func extend(add specs: [TileSpec], drop: Set<UInt32>, snap: [UInt32: Double], image: (UInt32, CGSize) -> CGImage?, realFrame: (UInt32) -> CGRect?,
                softened: (UInt32) -> CGImage?, icon: (pid_t) -> NSImage?) {
        guard let p = panel, stagedSignature != nil, !(specs.isEmpty && drop.isEmpty && snap.isEmpty) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for id in drop {
            guard let t = tiles.removeValue(forKey: id) else { continue }
            t.layer.removeFromSuperlayer()
            dressing.removeTwin(id)
            glide.drop(id)
            if ringID == id { ringID = nil; ringLayer.removeFromSuperlayer() }
        }
        let scale = p.screen?.backingScaleFactor ?? panelScreen?.backingScaleFactor ?? 2
        for s in specs.sorted(by: { $0.rect.minX < $1.rect.minX }) where tiles[s.id] == nil {
            addTile(s, scale: scale, image: image, realFrame: realFrame, softened: softened, icon: icon)
        }
        for (id, ax) in snap {
            guard var t = tiles[id], !t.held else { continue }
            t.x = ax - displayAX.minX
            t.layer.position = CGPoint(x: t.x, y: t.y)
            dressing.moveTwin(id, to: t.layer.position)
            tiles[id] = t
            glide.drop(id)
        }
        CATransaction.commit()
    }

    /// Invisible, but composited once (1% opaque for an instant), so the textures are uploaded before the first visible frame
    /// instead of during it.
    private func warmComposite(_ p: Panel) {
        warmToken += 1
        let token = warmToken
        p.alphaValue = 0.01
        if presents { p.orderFrontRegardless() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { if let self, self.warmToken == token, !self.shown { self.panel?.alphaValue = 0 } }
        }
    }

    /// The tiles the staged layers show, at their current places (display-relative origin moved back to AX space).
    var stagedRects: [UInt32: CGRect] { tiles.mapValues { CGRect(x: $0.x + displayAX.minX, y: $0.planY + displayAX.minY, width: $0.size.width, height: $0.size.height) } }

    private func clearTiles() {
        ribbonClip.sublayers = nil
        dressing.clearTiles()
        ringID = nil
        removeDim()
        tiles = [:]; glide.cancel()
    }

    /// Follows the window leading the band: the blur rises while it travels beneath a held column and falls as it comes out.
    private func updateEdge(now: Double) {
        dressing.update(now: now, tiles: tiles.values.filter { !$0.held }.map { (x: CGFloat($0.x), w: $0.size.width) })
    }

    /// Makes the staged layers visible. The floating windows are looked at again first unless that was done within `floatersMaxAge`
    /// seconds (a swipe has done it when the fingers came to rest).
    func reveal(floatersMaxAge: Double = 0.25) {
        guard let p = panel, stagedSignature != nil else { return }
        refreshFloaters(newerThan: floatersMaxAge, warm: false)
        fadeToken += 1; warmToken += 1; keptToken += 1
        p.alphaValue = 1
        if presents { p.orderFrontRegardless() }
        shown = true
    }

    private var shown = false
    /// The overlay is off screen (the panel stays around, invisible, for the next swipe).
    func hide() {
        fadeToken += 1; warmToken += 1; keptToken += 1
        shown = false; stagedSignature = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clearTiles()
        clearFloaters()
        container.removeAllAnimations(); container.opacity = 1
        showBackdrop(nil, soft: nil)
        CATransaction.commit()
        dressing.hide()
    }

    /// The overlay is off screen but its layers stay, at the layout they ended in (`signature`), for the next keyboard move: the
    /// next one then only has to reveal them. They go after `keepFor` seconds without one.
    func keep(signature: String) {
        guard let p = panel, shown else { return }
        fadeToken += 1; warmToken += 1; keptToken += 1
        let token = keptToken
        shown = false
        p.alphaValue = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.removeAllAnimations(); container.opacity = 1
        for (id, target) in glide.targets { if var t = tiles[id] { t.x = target; t.layer.position = CGPoint(x: t.x, y: t.y); dressing.moveTwin(id, to: t.layer.position); tiles[id] = t } }
        glide.cancel()
        ringLayer.removeFromSuperlayer(); ringID = nil
        CATransaction.commit()
        stagedSignature = signature
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepFor) { [weak self] in
            MainActor.assumeIsolated { if let self, self.keptToken == token, !self.shown { self.hide() } }
        }
    }

    /// Drops the panel and everything it holds (pause, display change).
    func teardown() {
        hide()
        panel?.close(); panel = nil; panelScreen = nil
        container.removeFromSuperlayer()
    }

    // MARK: content

    func setBackdrop(_ img: CGImage, soft: CGImage?) {
        guard panel != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        showBackdrop(img, soft: soft)
        CATransaction.commit()
    }

    /// The backdrop, and the dissolve that shows it again, frosted (sharp when there is no frosted copy), over the ribbon beside a held column.
    private func showBackdrop(_ img: CGImage?, soft: CGImage?) {
        backdropLayer.contents = img
        dressing.setDissolve(soft ?? img)
    }

    /// The softened twin of a ribbon tile (inside the blur strip, drawn where the tile is).
    private func setEdgeTile(_ id: UInt32, _ img: CGImage) {
        guard let t = tiles[id], !t.held else { return }
        dressing.setTwin(id, img, look: t.look, at: CGPoint(x: t.x, y: t.y))
    }

    /// An image arrived for a tile. While the overlay is up only a placeholder takes it (swapping a texture mid-motion would hitch);
    /// while it waits out of sight, staged or kept, a stale picture is replaced too, so the next reveal shows the window as it is.
    /// `swap`: the caller knows the tile holds still (a glide has landed, the fade is next), so it takes the new picture even
    /// while the overlay is up: the window's title bar then matches the live one before the fade shows it.
    func setImage(_ id: UInt32, _ img: CGImage, softened: CGImage?, real: CGRect?, swap: Bool = false) {
        if floaters[id] != nil {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            setFloaterImage(id, img)
            CATransaction.commit()
            return
        }
        guard var t = tiles[id], t.placeholder || !shown || swap else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if t.placeholder { t.layer.sublayers = nil; t.layer.backgroundColor = nil; t.layer.borderWidth = 0; t.layer.cornerRadius = 0; t.placeholder = false }
        let look = Self.look(plan: CGRect(x: 0, y: t.planY, width: t.size.width, height: t.size.height), real: real.map { $0.offsetBy(dx: -displayAX.minX, dy: -displayAX.minY) })
        t.y = look.minY; t.look = look.size
        t.layer.bounds = CGRect(origin: .zero, size: t.look)
        t.layer.position = CGPoint(x: t.x, y: t.y)
        dressing.fitTwin(id, bounds: t.layer.bounds, at: t.layer.position)
        tiles[id] = t
        t.layer.contents = img
        if t.layer.shadowPath != nil { Self.fitShadow(t.layer, image: img) }
        if let softened { setEdgeTile(id, softened) }
        if dimStyle.isOn { dressDim(id, softened: softened) }
        CATransaction.commit()
        if !shown, stagedSignature != nil, let p = panel { warmComposite(p) }     // a swapped texture is uploaded now, not in the first visible frame
    }

    /// Where a window's picture is drawn: at its planned x, but at the size and height the window really has when it differs
    /// from the plan (an app that refuses a size, like a minimum height). Fitted into the planned rect it would look shrunk.
    nonisolated static func look(plan: CGRect, real: CGRect?) -> CGRect {
        guard let r = real, r.width >= 1, r.height >= 1,
              abs(r.width - plan.width) > 2 || abs(r.height - plan.height) > 2 || abs(r.minY - plan.minY) > 2 else { return plan }
        return CGRect(x: plan.minX, y: r.minY, width: r.width, height: r.height)
    }

    /// The soft, even shadow of a tile. Real windows have shadows, and the snapshots are taken without them (and the backdrop leaves
    /// the windows out with theirs), so without this every shadow would vanish the instant the overlay appears and return as it
    /// fades. It also lifts a held tile above what passes beneath it.
    static func shade(_ l: CALayer, image: CGImage?) {
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.32; l.shadowRadius = 16; l.shadowOffset = .zero
        fitShadow(l, image: image)
    }

    /// The shadow of a floating window's tile: any tile's once it has its picture. Before that the layer is empty, and a shadow on
    /// its path alone would be a dark box where the window is (the more such windows, the darker), so it has none.
    static func shadeFloater(_ l: CALayer, image: CGImage?) {
        if image != nil { shade(l, image: image) } else { l.shadowOpacity = 0; l.shadowPath = nil }
    }

    /// The shadow's path, rounded like the window itself: a shadow fills its whole path, so a corner rounder than the path
    /// would show the shadow's dark inside through the window's transparent curve.
    private static func fitShadow(_ l: CALayer, image: CGImage?) {
        let size = l.bounds.size
        let measured = image.flatMap { img in size.width > 0 ? cornerRadius(of: img, scale: CGFloat(img.width) / size.width) : nil }
        let r = min((measured ?? 16) + 1.5, min(size.width, size.height) / 2)
        l.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// A window snapshot's corner radius in points, read along the diagonal of its transparent top-left corner (where a circle
    /// of radius r is r·(1 − 1/√2) in from each edge). Nil when the corner tells nothing (a transparent image).
    nonisolated static func cornerRadius(of img: CGImage, scale: CGFloat) -> CGFloat? {
        let n = min(img.width, img.height, max(1, Int((40 * scale).rounded(.up))))
        guard scale > 0, n > 1, let crop = img.cropping(to: CGRect(x: 0, y: 0, width: n, height: n)) else { return nil }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn, let d = (0..<n).first(where: { px[($0 * n + $0) * 4 + 3] >= 128 }) else { return nil }
        return (CGFloat(d) + 0.5) / (1 - 1 / 2.squareRoot()) / scale
    }

    private static func makePlaceholder(_ l: CALayer, icon: NSImage?) {
        l.backgroundColor = NSColor(white: 0.22, alpha: 0.92).cgColor
        l.cornerRadius = 12; l.cornerCurve = .continuous; l.borderWidth = 1; l.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        guard let icon else { return }
        let side = min(96, min(l.bounds.width, l.bounds.height) * 0.4)
        let il = CALayer()
        il.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        il.position = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
        il.contents = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
        il.contentsGravity = .resizeAspect
        il.opacity = 0.9
        l.addSublayer(il)
    }

    // MARK: floating windows and stacking

    /// What the ribbon does not move on this display, with each window's picture: set by the controller, asked at `reveal()` (and
    /// when the fingers come to rest), so the overlay shows the windows as they are now, including ones that came, went or moved
    /// since the layers were staged or last used.
    var floaterSource: (() -> [FloaterTile])?
    private struct Floater { let layer: CALayer; var hasImage: Bool }
    private var floaters: [UInt32: Floater] = [:]
    private var floaterSpecs: [FloaterSpec] = []
    private var floatersAt: Double?

    /// Draws the floating windows as tiles that stay where they are while the ribbon slides, beneath or over it as in the real stack.
    /// Unless `maxAge` says it was done recently, asks the source. The same windows in the same places keep their layers.
    func refreshFloaters(newerThan maxAge: Double = 0, warm: Bool = true) {
        guard panel != nil, let source = floaterSource else { return }
        let now = CACurrentMediaTime()
        if let t = floatersAt, now - t < maxAge { return }
        floatersAt = now
        let next = source()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if next.map(\.spec) != floaterSpecs {
            underLayer.sublayers = nil; overLayer.sublayers = nil; floaters = [:]
            let scale = panelScreen?.backingScaleFactor ?? 2
            for f in next.reversed() {                               // the frontmost last
                let l = CALayer()
                l.anchorPoint = .zero
                l.contentsScale = scale
                l.contentsGravity = .resize
                l.bounds = CGRect(origin: .zero, size: f.spec.rect.size)
                l.position = CGPoint(x: f.spec.rect.minX - displayAX.minX, y: f.spec.rect.minY - displayAX.minY)
                Self.shadeFloater(l, image: nil)
                (f.spec.above ? overLayer : underLayer).addSublayer(l)
                floaters[f.spec.id] = Floater(layer: l, hasImage: false)
            }
            floaterSpecs = next.map(\.spec)
        }
        for f in next { if let img = f.image { setFloaterImage(f.spec.id, img) } }
        CATransaction.commit()
        if warm, !shown, stagedSignature != nil, let p = panel { warmComposite(p) }       // textures are uploaded now, not in the first visible frame
    }

    /// A picture for a floating window: taken while the layers wait out of sight, or when the window has none yet (swapping a
    /// texture mid-motion would hitch).
    private func setFloaterImage(_ id: UInt32, _ img: CGImage) {
        guard var f = floaters[id], !f.hasImage || !shown else { return }
        f.layer.contents = img
        f.hasImage = true
        Self.shadeFloater(f.layer, image: img)
        floaters[id] = f
    }

    private func clearFloaters() {
        underLayer.sublayers = nil; overLayer.sublayers = nil
        floaters = [:]; floaterSpecs = []; floatersAt = nil
    }

    /// The focused window is the frontmost of the ribbon's windows: its tile is drawn above its neighbours, as the real one would
    /// be while two windows pass each other (a column swap). Nil = none.
    func raise(_ id: UInt32?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        Self.raise(id, from: raised, in: tiles.filter { !$1.held }.mapValues(\.layer))
        CATransaction.commit()
        raised = id
    }
    private var raised: UInt32?

    static func raise(_ id: UInt32?, from old: UInt32?, in layers: [UInt32: CALayer]) {
        if let old, old != id { layers[old]?.zPosition = 0 }
        if let id { layers[id]?.zPosition = 1 }
    }

    // MARK: motion

    /// Absolute AX x of tiles (the core's logical positions). Tiles not named stay where they are, and so do held ones: a
    /// held column holds still while everything slides beneath it (a visual lead or a release velocity must never nudge it).
    func move(_ xs: [UInt32: Double]) {
        glide.cancel()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, ax) in xs {
            guard var t = tiles[id], !t.held else { continue }
            t.x = ax - displayAX.minX
            t.layer.position = CGPoint(x: t.x, y: t.y)
            dressing.moveTwin(id, to: t.layer.position)
            tiles[id] = t
        }
        let now = CACurrentMediaTime()
        updateEdge(now: now)
        placeRing(now: now)                                       // the ring travels with its tile
        placeDim(now: now)                                        // and so does the clear cutout
        CATransaction.commit()
    }

    /// Where a tile is on the display now (AX x).
    func currentX(_ id: UInt32) -> Double? { tiles[id].map { $0.x + displayAX.minX } }

    /// Glide to `finals` (AX x) from wherever the tiles are, carrying the release velocity (px/s, + = right) toward the finals. A tile
    /// that is still gliding keeps its own speed instead (a new keyboard move bends the motion, it does not restart it). `lazyClock`:
    /// a glide from rest starts at the first frame `step` is given, not at `now` (a keyboard move: the display link may be late to
    /// wake); a release, with the link already running, starts at `now`, so the motion carries on without a gap.
    func settle(to finals: [UInt32: Double], velocity: Double, now: Double, lazyClock: Bool = true) {
        var targets: [UInt32: Double] = [:], rendered: [UInt32: Double] = [:]
        for (id, ax) in finals {
            guard let t = tiles[id], !t.held else { continue }
            targets[id] = ax - displayAX.minX; rendered[id] = t.x
        }
        glide.retarget(to: targets, from: rendered, velocity: velocity, at: now, lazyClock: lazyClock)
    }

    /// Advances the glide to the frame due on screen at `now` (`interval`: the display's refresh period); true once the tiles have
    /// landed (also when nothing was gliding): close enough that the layers may start to fade. The last pixels carry on under the
    /// fade until they have settled.
    func step(at now: Double, interval: Double = 1.0 / 60) -> Bool {
        guard glide.isGliding else {
            let ringCarrying = ringID != nil && ringCarry.offset != .zero, dimCarrying = dimStyle.isOn && dimCarry.offset != .zero
            if ringCarrying || dimCarrying {
                // Focus moved but no tile glides: the ring (and the dim's cutout) still travel, and the overlay waits for them.
                if ringCarrying, ringCarry.start == nil { ringCarry.start = now }
                if dimCarrying, dimCarry.start == nil { dimCarry.start = now }
                let carrying = now - max(ringCarrying ? ringCarry.start ?? now : 0, dimCarrying ? dimCarry.start ?? now : 0) < RingCarry.settleTime
                if !carrying { ringCarry.offset = .zero; dimCarry.offset = .zero }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                placeRing(now: now)
                placeDim(now: now)
                CATransaction.commit()
                return !carrying
            }
            return true
        }
        let frame = glide.step(at: now, interval: interval)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, x) in frame.x {
            guard var tile = tiles[id] else { continue }
            tile.x = x
            tile.layer.position = CGPoint(x: tile.x, y: tile.y)
            dressing.moveTwin(id, to: tile.layer.position)
            tiles[id] = tile
        }
        if frame.done { ringCarry.offset = .zero; dimCarry.offset = .zero }
        else {
            if ringCarry.start == nil { ringCarry.start = glide.origin ?? now }
            if dimCarry.start == nil { dimCarry.start = glide.origin ?? now }
        }
        placeRing(now: now)
        placeDim(now: now)
        updateEdge(now: now)
        CATransaction.commit()
        return frame.landed
    }

    // MARK: focus ring

    /// Where a tile is now, in display coordinates.
    private func rect(of t: Tile) -> CGRect { CGRect(x: t.x, y: t.y, width: t.look.width, height: t.look.height) }

    /// The focus ring is drawn with the tiles.
    var hasRing: Bool { ringID != nil }
    /// Where the ring layer is now, in display coordinates (QA and tests).
    var debugRingFrame: CGRect? { ringID == nil ? nil : CGRect(origin: ringLayer.position, size: ringLayer.bounds.size) }
    /// How far the ring reaches beyond the tile it frames.
    var debugRingMargin: Double { ringMargin }

    /// The focus ring travels with the tiles: it frames tile `id` (nil = no ring). A ring that is already up, or the one the real
    /// window had on `from`, glides from where it is to the new tile; otherwise it simply appears there. `animated: false` (Reduce
    /// Motion): it is there at once.
    func ring(from: UInt32?, to id: UInt32?, now: Double, animated: Bool = true) {
        guard let id, let tile = tiles[id] else { removeRing(); return }
        let base = rect(of: tile)
        // A ring that is up goes on from where it was last drawn (the last frame), and its new glide runs on the tiles' clock.
        let start: CGRect? = animated ? (ringID != nil ? ringRect(now: glide.lastFrame ?? now) : from.flatMap { tiles[$0] }.map(rect(of:))) : nil
        ringCarry = start.map { RingCarry.from($0, to: base, at: glide.retargetTime(now)) } ?? RingCarry()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if ringLayer.contents == nil || ringID == nil { dressRing() }
        ringID = id
        // Under its window like the real ring; below every ribbon tile, so a ring on its way never draws across the others.
        if tile.held { tile.layer.superlayer?.insertSublayer(ringLayer, below: tile.layer) } else { ribbonClip.insertSublayer(ringLayer, at: 0) }
        placeRing(now: now)
        CATransaction.commit()
    }

    func removeRing() {
        guard ringID != nil else { return }
        ringID = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ringLayer.removeFromSuperlayer()
        CATransaction.commit()
    }

    private func ringRect(now: Double) -> CGRect? {
        guard let id = ringID, let t = tiles[id] else { return nil }
        return ringCarry.rect(on: rect(of: t), at: now)
    }

    private func placeRing(now: Double) {
        guard let r = ringRect(now: now) else { return }
        let m = ringMargin
        ringLayer.bounds = CGRect(x: 0, y: 0, width: r.width + 2 * m, height: r.height + 2 * m)
        ringLayer.position = CGPoint(x: r.minX - m, y: r.minY - m)
    }

    /// The ring's picture: a small nine-patch of the real ring's art (stretched between its corners), built once per setting.
    private func dressRing() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let scale = panel?.screen?.backingScaleFactor ?? 2
        let art = RingArt.make(width: contrast ? 8 : 5, strong: contrast, scale: scale)
        ringLayer.contents = art?.image
        ringLayer.contentsCenter = art?.center ?? CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ringLayer.contentsScale = scale
        ringLayer.anchorPoint = .zero
        ringMargin = art?.margin ?? 0
    }

    /// Stops a glide where it is (a new swipe took over).
    func freeze() { glide.cancel() }

    /// A glide that cannot go on (the next plan is more than a slide) ends at once: every tile takes the place it was heading
    /// for, ready for the fade that reveals the windows written there.
    func land() {
        guard glide.isGliding || ringCarry.offset != .zero || dimCarry.offset != .zero else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, x) in glide.land() {
            guard var t = tiles[id] else { continue }
            t.x = x
            t.layer.position = CGPoint(x: t.x, y: t.y)
            dressing.moveTwin(id, to: t.layer.position)
            tiles[id] = t
        }
        ringCarry.offset = .zero; dimCarry.offset = .zero
        placeRing(now: CACurrentMediaTime())
        placeDim(now: CACurrentMediaTime())
        updateEdge(now: CACurrentMediaTime())
        CATransaction.commit()
    }

    // MARK: dim and blur

    /// "Other windows: Dim / Blur" while the overlay covers the display: the overlay would otherwise light every window up for
    /// the whole swipe, because it sits above the real dim panel. As that panel does, everything but the focus window is darkened
    /// (Blur: frosted under a light tint), the focus window and its tab bar are cut out, and nothing here costs a frame: each
    /// ribbon tile carries its own tint, so the tint moves with its tile, and only the backdrop's cutout is placed per frame.
    /// `area`: the display's usable area (AX); `bar`: the focus column's tab bar relative to its tile, if it has one. A held
    /// tile is darkened like the others unless it holds the focus: with the focus in the ribbon the real dim panel sits above it.
    func setDim(_ style: OverlayStyle, area: CGRect, focus: UInt32?, bar: CGRect?, softened: (UInt32) -> CGImage?, softBackdrop: CGImage?) {
        removeDim()
        guard style.isOn, panel != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dimStyle = style
        switch style {
        case .dim(let a): dimAlpha = Double(a)
        case .blur(let tint): dimAlpha = Double(tint)
        case .off: break
        }
        dimArea = area.offsetBy(dx: -displayAX.minX, dy: -displayAX.minY)
        dimFocus = focus; dimBar = bar; dimCarry = RingCarry()
        dimBase = focus.flatMap { tiles[$0] }?.look ?? .zero
        if case .blur = style {
            // The blurred picture of the whole display, clipped to the area the real panel covers (the Dock stays as it is), with
            // the haze of the material over it.
            frostBackdrop.masksToBounds = true
            frostBackdrop.frame = dimArea
            frostPicture.contentsGravity = .resize
            frostPicture.magnificationFilter = .linear
            frostPicture.frame = backdropLayer.frame.offsetBy(dx: -dimArea.minX, dy: -dimArea.minY)
            frostPicture.contents = softBackdrop
            frostPicture.sublayers = nil
            let haze = CALayer()
            haze.frame = frostPicture.bounds
            haze.backgroundColor = Self.hazeColor
            haze.opacity = Self.hazeOpacity
            frostPicture.addSublayer(haze)
            frostBackdrop.sublayers = [frostPicture]
            container.insertSublayer(frostBackdrop, above: backdropLayer)
        }
        dimBackdrop.fillColor = NSColor.black.cgColor
        dimBackdrop.fillRule = .evenOdd
        dimBackdrop.frame = dimArea
        dimBackdrop.opacity = Float(dimAlpha)
        container.insertSublayer(dimBackdrop, above: frostBackdrop.superlayer != nil ? frostBackdrop : backdropLayer)
        for id in tiles.keys { dressDim(id, softened: softened(id)) }
        placeDim(now: CACurrentMediaTime())
        CATransaction.commit()
    }

    /// What the real blur material adds to a blurred picture: it lifts it towards white (towards dark in the dark appearance), so a
    /// frosted twin alone would look darker and more saturated than the blur the overlay fades onto.
    private static var hazeColor: CGColor {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(white: dark ? 0.1 : 1, alpha: 1).cgColor
    }
    private static let hazeOpacity: Float = 0.45

    /// The tile layers' own tint (and frosted twin): a black card rounded like the window it covers.
    private func dressDim(_ id: UInt32, softened: CGImage?) {
        guard let t = tiles[id] else { return }
        if let old = dimTiles[id] { old.tint.removeFromSuperlayer(); old.frost?.removeFromSuperlayer() }
        let clear = id == dimFocus
        let radius: CGFloat
        if let c = t.layer.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID, t.layer.bounds.width > 0 {
            let img = c as! CGImage
            radius = min(Self.cornerRadius(of: img, scale: CGFloat(img.width) / t.layer.bounds.width) ?? 12, min(t.layer.bounds.width, t.layer.bounds.height) / 2)
        } else {
            radius = t.layer.cornerRadius                           // a placeholder: its own rounded card
        }
        var frost: CALayer?
        if case .blur = dimStyle, !t.placeholder, let soft = softened {
            let f = CALayer()
            f.anchorPoint = .zero
            f.bounds = t.layer.bounds
            f.contentsGravity = .resize
            f.magnificationFilter = .linear                         // the twin is small: smooth upscaling is the blur's last step
            f.contents = soft
            f.opacity = clear ? 0 : 1
            let haze = CALayer()
            haze.frame = f.bounds
            haze.backgroundColor = Self.hazeColor
            haze.opacity = Self.hazeOpacity
            haze.cornerRadius = radius; haze.cornerCurve = .continuous
            f.addSublayer(haze)
            t.layer.addSublayer(f)
            frost = f
        }
        let tint = CALayer()
        tint.anchorPoint = .zero
        tint.bounds = t.layer.bounds
        tint.backgroundColor = NSColor.black.cgColor
        tint.cornerCurve = .continuous
        tint.cornerRadius = radius
        tint.opacity = clear ? 0 : Float(dimAlpha)
        t.layer.addSublayer(tint)
        dimTiles[id] = DimTile(tint: tint, frost: frost)
    }

    /// Focus passes to tile `id` (nil = none): the cutout glides there from where it is while the old focus tile darkens and the
    /// new one clears. `bar`: the new focus column's tab bar, relative to its tile.
    func setDimFocus(_ id: UInt32?, bar: CGRect?, now: Double, animated: Bool = true) {
        guard dimStyle.isOn, id != dimFocus else { dimBar = bar ?? dimBar; return }
        let from = dimWindow(now: glide.lastFrame ?? now)       // like the ring: on from where it was last drawn
        let old = dimFocus
        dimFocus = id; dimBar = bar
        dimBase = id.flatMap { tiles[$0] }?.look ?? .zero
        let base = id.flatMap { tiles[$0] }.map(rect(of:))
        dimCarry = animated ? (from.flatMap { f in base.map { RingCarry.from(f, to: $0, at: glide.retargetTime(now)) } } ?? RingCarry()) : RingCarry()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let old, let d = dimTiles[old] { fade(d, toClear: false, animated: animated) }
        if let id, let d = dimTiles[id] { fade(d, toClear: true, animated: animated) }
        placeDim(now: now)
        CATransaction.commit()
    }

    /// Takes the tint of one tile to its clear or its dimmed state over 0.2 s (Core Animation runs it, not the main thread).
    private func fade(_ d: DimTile, toClear clear: Bool, animated: Bool) {
        func go(_ layer: CALayer, to: Float) {
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = to
            guard animated, from != to else { layer.removeAnimation(forKey: "dim"); return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from; a.toValue = to; a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
            layer.add(a, forKey: "dim")
        }
        go(d.tint, to: clear ? 0 : Float(dimAlpha))
        if let f = d.frost { go(f, to: clear ? 0 : 1) }
    }

    /// Where the clear window is now (display coordinates): its tile, plus what is left of the glide from the old focus.
    private func dimWindow(now: Double) -> CGRect? {
        guard let id = dimFocus, let t = tiles[id] else { return nil }
        return dimCarry.rect(on: rect(of: t), at: now)
    }

    /// The backdrop's tint with the focus window and its tab bar cut out, where they are now.
    private func placeDim(now: Double) {
        guard dimStyle.isOn else { return }
        let win = dimWindow(now: now)
        let bar = win.flatMap { w in dimBar.map { CGRect(x: w.minX + $0.minX, y: w.minY + $0.minY, width: w.width + ($0.width - dimBase.width), height: $0.height) } }
        let holes = DimGeometry.holes(area: dimArea, focused: win, tabBar: bar)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: dimArea.size))
        for h in holes { path.addRoundedRect(in: h.rect, cornerWidth: h.radius, cornerHeight: h.radius) }
        dimBackdrop.path = path
        debugDimHole = holes.first?.rect
    }

    /// The overlay carries a dim.
    var hasDim: Bool { dimStyle.isOn }

    /// The tint is on its tile: its opacity (QA and tests).
    func debugDimOpacity(_ id: UInt32) -> Float? { dimTiles[id]?.tint.opacity }

    func removeDim() {
        for d in dimTiles.values { d.tint.removeFromSuperlayer(); d.frost?.removeFromSuperlayer() }
        dimTiles = [:]
        dimBackdrop.removeFromSuperlayer(); frostBackdrop.removeFromSuperlayer()
        dimBackdrop.path = nil; frostPicture.contents = nil; frostPicture.sublayers = nil; frostBackdrop.sublayers = nil
        dimStyle = .off; dimFocus = nil; dimBar = nil; debugDimHole = nil
    }

    // MARK: fade

    /// Fades the layers out with Core Animation (the render server runs it: the main thread only starts it). The panel stays at
    /// full alpha until `hide()`/`keep()`; `completion` runs once the layers are clear, unless a newer fade or `resume()` took over.
    func fadeOut(duration: Double, completion: @escaping () -> Void) {
        guard panel != nil else { completion(); return }
        fadeToken += 1
        let token = fadeToken
        let from = container.presentation()?.opacity ?? container.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if let self, self.fadeToken == token { completion() } }
        }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = 0; a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.setDisableActions(true)                   // the explicit animation alone: an implicit one (0.25 s) would outlast it
        container.opacity = 0
        container.add(a, forKey: "fade")
        CATransaction.commit()
    }

    /// A new swipe or move began while fading: the layers come back from where the fade had got to (no pop).
    func resume() {
        guard panel != nil else { return }
        fadeToken += 1
        let from = container.presentation()?.opacity ?? 0
        CATransaction.begin()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = 1; a.duration = 0.06
        CATransaction.setDisableActions(true)
        container.opacity = 1
        container.add(a, forKey: "fade")
        CATransaction.commit()
    }
}

/// The focus ring's art for the overlay: the same stroke and glow as `FocusRing`, drawn once on a small window-shaped frame
/// and stretched between its corners (a nine-patch), so a ring of any size is one texture.
enum RingArt {
    struct Art { let image: CGImage; let center: CGRect; let margin: Double }
    @MainActor private static var cache: [String: Art] = [:]

    @MainActor static func make(width w: Double, strong: Bool, scale: Double) -> Art? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(w)\(strong)\(scale)\(dark)"
        if let a = cache[key] { return a }
        let tuck = 2.0, glow = strong ? 0.0 : 10.0
        let m = w + glow
        let r = Double(FocusRing.windowRadius)
        let inner = 2 * r + 24                                   // the window the art frames: big enough to leave a stretchable middle
        let side = inner + 2 * m
        let px = Int((side * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        var accent = CGColor(gray: 0.5, alpha: 1)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { accent = Theme.accentNS.cgColor }
        let centre = CGRect(x: m, y: m, width: inner, height: inner).insetBy(dx: -(w - tuck) / 2, dy: -(w - tuck) / 2)
        let path = RoundedRectangle(cornerRadius: r + (w - tuck) / 2, style: .continuous).path(in: centre).cgPath
        if !strong { ctx.setShadow(offset: .zero, blur: 8, color: accent.copy(alpha: 0.5)) }
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(w + tuck)
        ctx.addPath(path)
        ctx.strokePath()
        guard let image = ctx.makeImage() else { return nil }
        let edge = (m + r + 8) / side                              // corners (and their glow) stay as drawn; the middle stretches
        let art = Art(image: image, center: CGRect(x: edge, y: edge, width: 1 - 2 * edge, height: 1 - 2 * edge), margin: m)
        cache[key] = art
        return art
    }
}
