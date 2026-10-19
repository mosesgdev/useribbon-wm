import Foundation
import CoreGraphics

/// Pure-logic self tests for dragging and resizing: the window-number cache, the per-frame coalescing, the indicator's shapes.
enum DragTests {
    static func run(_ check: (Bool, String) -> Void) {
        idCache(check)
        coalescing(check)
        fullScreen(check)
        shapes(check)
    }

    private static func idCache(_ check: (Bool, String) -> Void) {
        var c = WindowIDCache<String>()
        c.remember("a", 10); c.remember("b", 11)
        check(c["a"] == 10 && c["b"] == 11 && c["c"] == nil && c.count == 2, "id cache: an element answers with its window number")
        c.forget(10)
        check(c["a"] == nil && c["b"] == 11 && c.count == 1, "id cache: a closed window's element is forgotten, the others stay")
        c.forget(10); c.forget(99)
        check(c.count == 1, "id cache: forgetting an unknown window changes nothing")
        // A window that comes back with a new element (un-minimized): the old element no longer names it.
        c.remember("b2", 11)
        check(c["b2"] == 11 && c["b"] == nil && c.count == 1, "id cache: a new element for the same window replaces the old one")
        c.removeAll()
        check(c["b2"] == nil && c.count == 0, "id cache: stopping the tracker empties it")
    }

    private static func coalescing(_ check: (Bool, String) -> Void) {
        var k = FrameCoalescer<UInt32, Int>()
        check(k.note(1, 100), "frame coalescing: the first event of a burst is handled at once and starts the clock")
        check(k.clockRunning && k.tick().batch.isEmpty, "frame coalescing: a tick with nothing held hands back nothing")
        check(!k.note(1, 101) && !k.note(2, 200) && !k.note(1, 102) && !k.note(2, 201), "frame coalescing: later events wait for the frame")
        var t = k.tick()
        check(t.batch.map(\.key) == [1, 2] && t.batch.map(\.value) == [102, 201] && !t.stop, "frame coalescing: one event per window per frame, the newest, oldest window first")
        check(k.tick().batch.isEmpty, "frame coalescing: delivered events are not delivered twice")
        // A window that closes before the frame: nothing is delivered for it.
        _ = k.note(3, 300); _ = k.note(4, 400)
        k.discard(3)
        t = k.tick()
        check(t.batch.map(\.key) == [4], "frame coalescing: a closed window's held event is dropped")
        k.discard(9)
        // The clock stops after a quiet spell, and the next burst starts afresh with an immediate event.
        var stops = 0, ticks = 0
        while ticks < 20 { ticks += 1; if k.tick().stop { stops += 1; break } }
        check(stops == 1 && ticks == FrameCoalescer<UInt32, Int>.quietTicksBeforeStop && !k.clockRunning, "frame coalescing: the clock stops after \(FrameCoalescer<UInt32, Int>.quietTicksBeforeStop) quiet ticks")
        check(k.note(1, 500), "frame coalescing: after the clock stopped the next event is handled at once again")
        // A steady stream keeps the clock alive.
        var alive = true
        for i in 0..<30 { _ = k.note(1, i); if k.tick().stop { alive = false } }
        check(alive && k.clockRunning, "frame coalescing: events every frame never stop the clock")
        k.reset()
        check(!k.clockRunning && k.tick().batch.isEmpty, "frame coalescing: reset forgets everything")
    }

    private static func fullScreen(_ check: (Bool, String) -> Void) {
        let screens = [CGRect(x: 0, y: 0, width: 3840, height: 1200), CGRect(x: 3840, y: 0, width: 1440, height: 900)]
        check(WindowTracker.mayBeFullScreen(CGRect(x: 0, y: 0, width: 3840, height: 1200), displays: screens), "full screen: a window filling its display may be full screen")
        check(WindowTracker.mayBeFullScreen(CGRect(x: 3840, y: 0, width: 1440, height: 868), displays: screens), "full screen: a notch's few points do not hide it")
        check(!WindowTracker.mayBeFullScreen(CGRect(x: 12, y: 42, width: 1902, height: 1056), displays: [screens[0]]), "full screen: half a display wide is a plain window")
        check(!WindowTracker.mayBeFullScreen(CGRect(x: 0, y: 0, width: 600, height: 400), displays: screens), "full screen: a small window is never asked")
        check(!WindowTracker.mayBeFullScreen(CGRect(x: 0, y: 0, width: 3840, height: 1200), displays: []), "full screen: no displays, no full screen")
    }

    private static func shapes(_ check: (Bool, String) -> Void) {
        // The panel covers this AX rect; AX y grows downward, the panel's grows upward.
        let area = CGRect(x: 100, y: 25, width: 1300, height: 800)
        let l = DropIndicatorShapes.local(CGRect(x: 112, y: 37, width: 400, height: 776), in: area)
        check(l == CGRect(x: 12, y: 12, width: 400, height: 776), "indicator: a column at the top-left of the area sits at its bottom-left-origin place")
        check(DropIndicatorShapes.local(CGRect(x: 100, y: 25, width: 10, height: 10), in: area).maxY == 800, "indicator: the area's top edge is the panel's top")

        let bar = DropIndicatorShapes.make(for: .bar(CGRect(x: 424, y: 37, width: 8, height: 776)), in: area)
        check(bar.shapes.count == 1 && bar.label == nil && bar.shapes[0].fill == .bar, "indicator: a bar is one shape and has no label")
        check(bar.shapes[0].radius == bar.shapes[0].rect.width / 2, "indicator: the bar is a capsule")

        let col = CGRect(x: 424, y: 37, width: 400, height: 776)
        let stack = DropIndicatorShapes.make(for: .stack(col, tab: false), in: area)
        check(stack.shapes.count == 1 && stack.shapes[0].fill == .column && stack.shapes[0].radius == Theme.Radius.row, "indicator: a stack is one rounded column")
        check(stack.label == .init(text: "Stack here", room: stack.shapes[0].rect), "indicator: the stack label sits in the column")
        check(DropIndicatorShapes.make(for: .stack(col, tab: true), in: area).label?.text == "Add as a tab", "indicator: a tab drop says so")
        // A very narrow column never gets corners wider than itself.
        let thin = DropIndicatorShapes.make(for: .stack(CGRect(x: 0, y: 0, width: 16, height: 300), tab: false), in: area)
        check(thin.shapes[0].radius == 8, "indicator: corners stay inside a narrow column")

        // A column running past the display's right edge: the words sit in the part that shows.
        let edge = DropIndicatorShapes.make(for: .stack(CGRect(x: 1200, y: 37, width: 600, height: 776), tab: false), in: area)
        check(edge.label?.room.maxX == area.width && edge.label?.room.minX == 1100, "indicator: the label stays in the visible part of a column cut off by the display edge")

        let strip = CGRect(x: 424, y: 37, width: 400, height: TabLayout.barHeight).insetBy(dx: 0, dy: 1)
        let group = DropIndicatorShapes.make(for: .tabGroup(strip), in: area)
        check(group.shapes.map(\.fill) == [.tab, .newTab], "indicator: a tab group previews the existing tab and the new one")
        let slots = TabLayout.tabs(count: 2, width: strip.width)
        let local = DropIndicatorShapes.local(strip, in: area)
        check(group.shapes.map(\.rect.minX) == slots.map { local.minX + $0.x } && group.shapes.map(\.rect.width) == slots.map { $0.w }, "indicator: the capsules sit where the tab bar's tabs will")
        check(group.label?.room == group.shapes[1].rect && group.label?.text == "Make a tab group", "indicator: the label names the new tab")
        check(group.shapes.allSatisfy { $0.radius == $0.rect.height / 2 && $0.rect.height == local.height - 4 }, "indicator: tab capsules are as tall as a tab")
    }
}
