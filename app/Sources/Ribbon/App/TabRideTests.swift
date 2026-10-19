import Foundation
import CoreGraphics
import AppKit

/// Selftest for tab bars that ride with their tiles: which panel shows which bar, what a bar that only moves writes, the icon
/// cache, and where a bar goes while a swipe or a glide carries its column (run from `SelfTest`).
enum TabRideTests {
    static func run(_ check: (Bool, String) -> Void) {
        panels(check)
        feed(check)
        icons(check)
        rides(check)
    }

    /// A 600 px swipe to the left, frame by frame: at every frame each bar's panel starts where its tile does (clipped by the
    /// display or by the pin), never at the place it had before the swipe.
    private static func rides(_ check: (Bool, String) -> Void) {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let was = [bar([1, 2], column: 0, x: 12, w: 700, active: 1), bar([3, 4], column: 1, x: 724, w: 700, active: 3)]
        var followed = true, moved = true
        for dx in stride(from: 10.0, through: 640, by: 10) {
            let placed = was.map { $0.riding(at: $0.x - dx) }
            for (bar, rect) in TabBarPlacement.shown(placed, visible: visible, area: visible) {
                let tile = bar.x
                followed = followed && abs(rect.minX - max(tile, visible.minX)) < 1e-9 && abs(rect.maxX - min(tile + bar.w, visible.maxX)) < 1e-9
                moved = moved && abs(rect.minX - was.first { $0.column == bar.column }!.x) > 1e-9
            }
        }
        check(followed, "tab ride: during a swipe every bar's panel starts at its tile's x, clipped by the display")
        check(moved, "tab ride: no mid-swipe frame leaves a bar where it was before the swipe")
        let mid = TabBarPlacement.shown(was.map { $0.riding(at: $0.x - 300) }, visible: visible, area: visible)
        check(mid.count == 2 && mid[0].rect.minX == 0 && mid[0].rect.width == 412 && mid[1].rect.minX == 424, "tab ride: halfway, one bar is cut by the left edge and the next has moved in")
        check(TabBarPlacement.shown(was.map { $0.riding(at: $0.x - 700) }, visible: visible, area: visible).count == 1, "tab ride: a bar with less than a sliver left on screen has no panel")
        check(TabBarPlacement.shown([was[0].riding(at: nil)], visible: visible, area: visible).isEmpty, "tab ride: a bar whose tile is not on the overlay is out of sight")
        // Beside a left pin the ribbon's bars pass beneath it with their columns; the pin's own bar stays where it is.
        let pin = CGRect(x: 12, y: 38, width: 888, height: 862)
        let area = CGRect(x: pin.maxX, y: visible.minY, width: visible.maxX - pin.maxX, height: visible.height)
        var pinBar = bar([8, 9], column: 2, x: 12, w: 888, active: 8)
        pinBar.pinned = true
        let beside = TabBarPlacement.shown([pinBar.riding(at: 500)] + was.map { $0.riding(at: $0.x - 300) }, visible: visible, area: area)
        check(beside.first { $0.bar.isPinned }?.rect.minX == 12, "tab ride: the pinned bar does not ride")
        check(beside.filter { !$0.bar.isPinned }.allSatisfy { $0.rect.minX >= area.minX }, "tab ride: ribbon bars are cut at the pin, not drawn across it")
        check(beside.filter { !$0.bar.isPinned }.map(\.rect) == [CGRect(x: 900, y: 38, width: 224, height: 28)], "tab ride: the column under the pin has no bar, the next one is cut at the pin's edge")
        check(was[0].riding(at: 100).drawn == was[0].drawn && was[0].riding(at: nil).drawn == was[0].drawn, "tab ride: riding changes the place, never what the bar draws")
    }

    private static func tabs(_ ids: [UInt32]) -> [TabItem] { ids.map { TabItem(id: $0, app: "App \($0)", title: "Doc \($0)") } }
    private static func bar(_ ids: [UInt32], column: Int = 0, x: Double = 12, w: Double = 700, active: UInt32? = nil, focused: Bool = true, onScreen: Bool = true) -> TabBar {
        TabBar(column: column, x: x, y: 38, w: w, h: 28, onScreen: onScreen, active: active ?? ids[0], focused: focused, tabs: tabs(ids))
    }

    private static func panels(_ check: (Bool, String) -> Void) {
        check(TabSlots.assign(bars: [[1, 2], [3, 4]], held: [[1, 2], [3, 4]]) == [0, 1], "tab panels: each bar keeps the panel that showed its tabs")
        check(TabSlots.assign(bars: [[3, 4], [1, 2]], held: [[1, 2], [3, 4]]) == [1, 0], "tab panels: bars that swap places in the list do not swap panels")
        check(TabSlots.assign(bars: [[2, 1, 7]], held: [[9], [1, 2]]) == [1], "tab panels: a bar whose tabs were reordered or added to keeps its panel")
        check(TabSlots.assign(bars: [[5]], held: [[1, 2]]) == [0], "tab panels: a new bar takes the panel nobody needs")
        check(TabSlots.assign(bars: [[1, 2], [5], [6]], held: [[1, 2]]) == [0, 1, 2], "tab panels: more bars than panels make new ones")
        check(TabSlots.assign(bars: [], held: [[1]]).isEmpty && TabSlots.assign(bars: [[1]], held: []) == [0], "tab panels: nothing to show, nothing held")
        // A bar that left the display and comes back finds its panel again (it was only ordered out, its tabs are still held).
        check(TabSlots.assign(bars: [[3, 4]], held: [[1, 2], [3, 4]]) == [1], "tab panels: a bar that comes back gets its own panel again")
    }

    private static func feed(_ check: (Bool, String) -> Void) {
        // A bar sliding across the display for 22 frames: the first frame fills the model, none after it writes anything.
        var feed = TabBarFeed()
        let first = feed.take(bar([1, 2, 3, 4, 5]), width: 700, receded: false)
        check(first == [.content, .width, .receded], "tab feed: the first frame fills the model")
        var later = 0
        for f in 1...22 {
            let slid = bar([1, 2, 3, 4, 5], x: 12 + Double(f) * 40)
            if !feed.take(slid, width: 700, receded: false).isEmpty { later += 1 }
        }
        check(later == 0, "tab feed: 22 frames of a bar that only moves write nothing to the model")
        check(feed.take(bar([1, 2, 3, 4, 5], active: 3), width: 700, receded: false) == [.content], "tab feed: another active tab is a content write")
        check(feed.take(bar([1, 2, 3, 4, 5], active: 3, focused: false), width: 700, receded: false) == [.content], "tab feed: focus changes what the bar shows")
        check(feed.take(bar([1, 2, 3, 4, 5], active: 3, focused: false), width: 520, receded: false) == [.width], "tab feed: a bar clipped by the display edge writes its width only")
        check(feed.take(bar([1, 2, 3, 4, 5], active: 3, focused: false), width: 520, receded: true) == [.receded], "tab feed: stepping back with the dim writes the flag only")
        check(feed.take(bar([1, 2, 3, 4, 5], active: 3, focused: false, onScreen: false), width: 520, receded: true).isEmpty, "tab feed: leaving the display is not a content change")
        check(feed.held == [1, 2, 3, 4, 5], "tab feed: the model knows which tabs it shows")
        check(feed.take(bar([1, 2, 3, 4, 5]).with(titleOf: 2, "Renamed"), width: 700, receded: false).contains(.content), "tab feed: a renamed tab is a content write")
    }

    @MainActor private static func iconsBody(_ check: (Bool, String) -> Void) {
        var asked: [pid_t] = []
        var available = true
        let cache = AppIconCache(lookup: { pid in asked.append(pid); return available ? NSImage(size: NSSize(width: 16, height: 16)) : nil })
        // 22 frames of a 5-tab bar: the system is asked once per process, not 110 times.
        for _ in 0..<22 { for pid in [100, 100, 200, 300, 300] as [pid_t] { _ = cache.icon(pid: pid) } }
        check(cache.lookups == 3 && asked == [100, 200, 300], "icon cache: one system lookup per process however many frames ask")
        cache.forget(pid: 200)
        _ = cache.icon(pid: 200); _ = cache.icon(pid: 200)
        check(cache.lookups == 4, "icon cache: an app that launched or quit is looked up again")
        available = false
        check(cache.icon(pid: 400) == nil && cache.icon(pid: 400) == nil && cache.lookups == 6, "icon cache: an icon that was not there yet is asked for again")
        cache.removeAll()
        available = true
        _ = cache.icon(pid: 100)
        check(cache.lookups == 7, "icon cache: emptied, it asks again")
    }

    private static func icons(_ check: (Bool, String) -> Void) { MainActor.assumeIsolated { iconsBody(check) } }
}

private extension TabBar {
    func with(titleOf id: UInt32, _ title: String) -> TabBar {
        var b = self
        if let i = b.tabs.firstIndex(where: { $0.id == id }) { b.tabs[i].title = title }
        return b
    }
}
