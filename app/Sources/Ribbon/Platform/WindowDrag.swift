import AppKit

/// Dragging a managed window by its title bar to reorder the ribbon.
///
/// A drag is a managed window that moves *while the left mouse button is down* (`NSEvent.pressedMouseButtons`), keeps its
/// planned size (a resize from a left/top edge also moves the origin) and was not just moved by Ribbon itself. From the first
/// such AX "moved" event until the button comes up:
/// - the controller writes nothing to that window (Ribbon never fights the mouse),
/// - the drop target under the pointer is previewed with the glass indicator,
/// and on release the window is moved (`move_window_to`), or snapped back to its slot when nothing was targeted or it barely moved.
///
/// The pinned column is a drop target too (its title-bar zone makes a tab, its body takes the window in), and a window dragged
/// out of the pin onto a ribbon target leaves it.
///
/// The class owns only the state machine and the clock (one tick per display refresh, on the display being dragged on);
/// geometry lives in `DropRule` (pure), everything about windows and engines is injected, so the controller stays the one place
/// that talks to the core. Nothing on the first move waits for the app or the core: the press already asked the controller to
/// read the plan (`warm`), and the window's frame comes from the window server.
@MainActor
final class WindowDragger {
    struct Layout {
        var columns: [DropColumn]
        var usable: CGRect
        var gap: CGFloat
        var source: (column: Int, alone: Bool, row: Int)?
        /// Set instead of `source` when the dragged window is one of the pin's (it has no ribbon column).
        var pinSource: (alone: Bool, row: Int)? = nil
        /// The display (UUID) the ribbon is on: the frame clock follows it.
        var display: String? = nil
    }
    enum Outcome: Equatable {
        case tiny                    // a click or a nudge: nothing to do
        case snapBack                // released over nothing (or where it already was): put it back
        case drop(DropTarget)
    }

    /// The window being dragged, if any.
    private(set) var active: UInt32?
    private var startPointer = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var layout: Layout?
    private let pacer = FramePacer()
    private let indicator = DropIndicator()
    private var pressMonitor: Any?

    /// May a drag start for this window right now? (Ribbon is not writing this window, it is tiled and on screen.)
    var canStart: (UInt32) -> Bool = { _ in false }
    /// Live frame (the window server's), planned frame, and the column geometry of the window's ribbon.
    var liveFrame: (UInt32) -> CGRect? = { _ in nil }
    var plannedFrame: (UInt32) -> CGRect? = { _ in nil }
    var layoutFor: (UInt32) -> Layout? = { _ in nil }
    var pointer: () -> CGPoint = { Screens.mouseAX() }
    var buttonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    var onEnd: (UInt32, Outcome) -> Void = { _, _ in }
    /// The left button went down at this point (AX coordinates), before anything moved: a window's title bar may be about to be
    /// dragged. The controller reads the ribbon's plan now, in the quiet between press and first move.
    var warm: (CGPoint) -> Void = { _ in }

    init() {
        pacer.onTick = { [weak self] _ in self?.tick() }
        pressMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.warm(self.pointer()) } }
        }
    }

    /// An AX "moved" event for a managed window. Returns true when the drag machinery has taken it (the caller then skips
    /// the old debounced settle).
    func windowMoved(_ id: UInt32) -> Bool {
        if let a = active { return a == id }
        guard buttonDown(), canStart(id), let live = liveFrame(id), let planned = plannedFrame(id) else { return false }
        // Same size as planned: a drag. A different size is a resize from an edge: not ours.
        guard abs(live.width - planned.width) <= 3, abs(live.height - planned.height) <= 3 else { return false }
        guard let l = layoutFor(id) else { return false }
        active = id
        layout = l
        startPointer = pointer()
        startOrigin = planned.origin
        indicator.begin(over: l.usable)
        pacer.start(uuid: l.display ?? "") { l.display.flatMap { Screens.screen(uuid: $0) } }
        tick()
        return true
    }

    /// The layout changed under the drag (a plan arrived): rebuild lazily.
    func invalidate() { if let id = active { layout = layoutFor(id) } }

    func cancel() {
        pacer.stop()
        active = nil; layout = nil
        indicator.end()
    }

    private func target() -> DropTarget? {
        guard let l = layout else { return nil }
        return DropRule.target(pointer: pointer(), columns: l.columns, usable: l.usable, gap: l.gap, source: l.source, pinSource: l.pinSource)
    }

    private func tick() {
        guard let id = active else { return }
        guard buttonDown() else { finish(id); return }
        guard let l = layout else { return }
        indicator.show(target().flatMap { DropRule.mark(for: $0, columns: l.columns, usable: l.usable, gap: l.gap) }, over: l.usable)
    }

    private func finish(_ id: UInt32) {
        let t = target()
        let now = pointer()
        let pointerTiny = DropRule.isTinyMove(from: startPointer, to: now)
        let windowTiny = liveFrame(id).map { DropRule.isTinyMove(from: startOrigin, to: $0.origin) } ?? true
        cancel()
        let outcome: Outcome = pointerTiny && windowTiny ? .tiny : t.map(Outcome.drop) ?? .snapBack
        onEnd(id, outcome)
    }

    /// QA: end the drag as if the button had come up (when the host cannot press a real button).
    func qaFinish() { if let id = active { finish(id) } }
}

extension FrameApplier {
    /// Is Ribbon writing this window just now (a write or a glide step within the last quarter second, the span in which the
    /// window's own move notifications are still the echo of our writes)? Other windows being written do not count: a drag
    /// right after a key press only waits for its own window. (An empty frame never matches the "same size as written" arm.)
    func isWriting(_ id: UInt32) -> Bool { isEcho(id: id, frame: .zero) }
}
