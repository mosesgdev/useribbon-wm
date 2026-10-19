import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// Self tests for Focus mode (style state machine, cutouts with tab bars) and the direct width hotkeys.
enum FocusTests {
    static func run(_ check: (Bool, String) -> Void) {
        style(check)
        session(check)
        geometry(check)
        widthHotkeys(check)
        engine(check)
        ring(check)
        tabGroups(check)
    }

    private static func style(_ check: (Bool, String) -> Void) {
        func s(_ m: OtherWindows, _ f: FocusSession = .follow, _ level: DimLevel = .subtle, rt: Bool = false) -> OverlayStyle {
            OverlayStyle.resolve(setting: m, session: f, level: level, reduceTransparency: rt)
        }
        check(s(.normal) == .off, "focus: Normal shows nothing")
        check(s(.dim) == .dim(DimLevel.subtle.alpha) && s(.dim, .follow, .medium) == .dim(DimLevel.medium.alpha), "focus: Dim keeps its two strengths")
        check(s(.blur) == .blur(tint: OverlayStyle.blurTint), "focus: Blur blurs with a light tint")
        check(s(.normal, .on) == .blur(tint: OverlayStyle.blurTint) && s(.dim, .on) == .blur(tint: OverlayStyle.blurTint), "focus: Focus mode blurs whatever Settings says")
        check(s(.blur, .off) == .off && s(.dim, .off) == .off, "focus: Focus mode off hides the overlay even when Settings says Blur or Dim")
        check(s(.blur, rt: true) == .dim(OverlayStyle.strongDim) && s(.normal, .on, rt: true) == .dim(OverlayStyle.strongDim),
              "focus: Reduce Transparency turns blur into a stronger dim")
        check(OverlayStyle.strongDim > DimLevel.medium.alpha, "focus: the fallback dim is stronger than Medium")
        check(s(.dim, rt: true) == .dim(DimLevel.subtle.alpha) && s(.normal, rt: true) == .off, "focus: Reduce Transparency leaves Dim and Normal alone")
        check(!OverlayStyle.off.isOn && OverlayStyle.dim(0.2).isOn && OverlayStyle.blur(tint: 0.1).isOn, "focus: isOn")
        check(OtherWindows.resolve(stored: nil, legacyDim: true) == .dim && OtherWindows.resolve(stored: nil, legacyDim: false) == .normal
              && OtherWindows.resolve(stored: "blur", legacyDim: true) == .blur && OtherWindows.resolve(stored: "junk", legacyDim: false) == .normal,
              "focus: the old Dim switch migrates; the new key wins; junk is Normal")
    }

    private static func session(_ check: (Bool, String) -> Void) {
        for setting in OtherWindows.allCases {
            // Two presses always come back, and one press always changes whether anything is hiding the other windows.
            var f = FocusSession.follow
            let before = OverlayStyle.resolve(setting: setting, session: f, level: .subtle, reduceTransparency: false)
            f = f.toggled(setting: setting)
            let after = OverlayStyle.resolve(setting: setting, session: f, level: .subtle, reduceTransparency: false)
            check(before != after, "focus: one press changes the overlay (Settings \(setting.rawValue))")
            f = f.toggled(setting: setting)
            f = f.toggled(setting: setting)
            f = f.toggled(setting: setting)
            check(OverlayStyle.resolve(setting: setting, session: f, level: .subtle, reduceTransparency: false) == before,
                  "focus: four presses are back where they started (Settings \(setting.rawValue))")
        }
        check(FocusSession.follow.toggled(setting: .normal) == .on && FocusSession.on.toggled(setting: .normal) == .follow, "focus: from Normal, on then back to Settings")
        check(FocusSession.follow.toggled(setting: .blur) == .off && FocusSession.off.toggled(setting: .blur) == .on, "focus: with Settings on Blur the key switches it off, then on")
        check(FocusSession.on.mode(setting: .normal) == .blur && FocusSession.off.mode(setting: .blur) == .normal && FocusSession.follow.mode(setting: .dim) == .dim,
              "focus: session mode over Settings")
    }

    private static let area = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private static func geometry(_ check: (Bool, String) -> Void) {
        let win = CGRect(x: 100, y: 100, width: 600, height: 500)
        let h = DimGeometry.holes(area: area, focused: win, tabBar: nil)
        check(h.count == 1 && h[0].rect == win.offsetBy(dx: 0, dy: -25) && h[0].radius == 12, "cutout: one hole for the focused window, in the layer's coordinates")
        check(DimGeometry.holes(area: area, focused: nil, tabBar: nil).isEmpty, "cutout: nothing focused, no hole")
        check(DimGeometry.holes(area: area, focused: CGRect(x: 2000, y: 100, width: 300, height: 300), tabBar: nil).isEmpty, "cutout: window on another display, no hole here")
        // Tabbed column: the bar sits 30pt above the window, flush (gap 0) or with a small gap; its hole reaches the window.
        let bar = CGRect(x: 100, y: 70, width: 600, height: 28)
        let t = DimGeometry.holes(area: area, focused: win, tabBar: bar)
        check(t.count == 2, "cutout: a tab bar adds a second hole")
        check(t[1].rect == CGRect(x: 100, y: 45, width: 600, height: 30), "cutout: the bar's hole reaches down to the window's top edge (no seam)")
        check(t[1].radius == 14, "cutout: the bar hole is rounded like a capsule, capped")
        let flush = DimGeometry.holes(area: area, focused: win, tabBar: CGRect(x: 100, y: 72, width: 600, height: 28))
        check(flush[1].rect.maxY == win.minY - 25 && flush[1].rect.height == 28, "cutout: a flush bar is left as it is")
        let far = DimGeometry.holes(area: area, focused: win, tabBar: CGRect(x: 100, y: 20, width: 600, height: 28))
        check(far[1].rect.height <= 28 + 0.01, "cutout: a bar further than the seam is not stretched to the window")
        let beside = DimGeometry.holes(area: area, focused: win, tabBar: CGRect(x: 800, y: 70, width: 300, height: 28))
        check(beside[1].rect.height == 28, "cutout: a bar that is not above the window is not stretched")
        let clipped = DimGeometry.holes(area: area, focused: win, tabBar: CGRect(x: 100, y: 0, width: 600, height: 28))
        check(clipped.count == 1 || clipped[1].rect.minY >= 0, "cutout: a bar above the usable area is clipped to it")
        check(DimGeometry.holes(area: area, focused: win, tabBar: CGRect(x: 5000, y: 70, width: 300, height: 28)).count == 1, "cutout: a bar on another display is ignored")
        check(DimGeometry.holes(area: area, focused: win, tabBar: nil).first?.rect == DimGeometry.cutout(area: area, focused: win), "cutout: matches the old single cutout")
    }

    private static func widthHotkeys(_ check: (Bool, String) -> Void) {
        let byId = Dictionary(Hotkeys.table.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        check((1...6).allSatisfy { byId["width_step#\($0)"]?.key == digits[$0 - 1] && byId["width_step#\($0)"]?.widthKey == true }, "width keys: steps 1…6 on digits 1…6")
        check((1...6).allSatisfy { byId["width_step#\($0)"]?.isRecordable == true } && byId["switch_desktop#1"]?.isRecordable == false, "width keys: recordable; desktops still a group")
        check(byId["toggle_focus"]?.key == kVK_ANSI_B && byId["toggle_focus"]?.isRecordable == true, "focus: Focus mode is on B and recordable (F is Full width)")
        MainActor.assumeIsolated {
            let suite = "ribbon.focustest.\(getpid())"
            let d = UserDefaults(suiteName: suite)!
            defer { d.removePersistentDomain(forName: suite) }
            let st = ShortcutStore(defaults: d, layout: [:], translate: { _ in nil }, systemKeys: { [] })
            let three = byId["width_step#3"]!, desk = byId["switch_desktop#3"]!, send = byId["move_to_desktop#3"]!
            check(st.effective(three) == KeyBinding(keyCode: kVK_ANSI_3, modifiers: controlKey | optionKey | cmdKey) && st.keys(for: three) == ["⌃", "⌥", "⌘", "3"], "width keys: ⌃⌥⌘3 by default")
            check(st.effective(three) != st.effective(desk) && st.effective(three) != st.effective(send), "width keys: distinct from the desktop keys")
            check(st.effective(byId["toggle_focus"]!) == KeyBinding(keyCode: kVK_ANSI_B, modifiers: controlKey | optionKey) && st.keys(for: byId["toggle_focus"]!) == ["⌃", "⌥", "B"], "focus: ⌃⌥B by default")
            d.set(ModifierChoice.ctrlCmd.rawValue, forKey: "modifier"); st.reload()
            check(st.effective(three)?.modifiers == controlKey | optionKey | cmdKey, "width keys: ⌃⌥⌘ under ⌃⌘ too")
            d.set(ModifierChoice.hyper.rawValue, forKey: "modifier"); st.reload()
            check(st.effective(three) == nil && (1...6).allSatisfy { st.effective(byId["width_step#\($0)"]!) == nil }, "width keys: no default under Hyper (every digit combination is taken); command bar and recording still work")
            // Recordable: a combo saved for one step replaces its default.
            let rec = KeyBinding(keyCode: kVK_ANSI_W, modifiers: controlKey | optionKey)
            st.set("width_step#3", rec)
            check(st.effective(three) == rec && st.isCustom(three), "width keys: a recorded combo is stored (also under Hyper)")
        }
        // Titles follow the active width list.
        check(WidthPresets.rich.map(WidthPresets.title) == ["Width 25\u{00A0}%", "Width 33\u{00A0}%", "Width 50\u{00A0}%", "Width 66\u{00A0}%", "Width 75\u{00A0}%", "Width 100\u{00A0}%"], "width keys: titles name the steps (rich)")
        check(WidthPresets.simple.map(WidthPresets.title) == ["Width 33\u{00A0}%", "Width 50\u{00A0}%", "Width 66\u{00A0}%", "Width 100\u{00A0}%"], "width keys: titles name the steps (simple)")
        let titles = MainActor.assumeIsolated { BarModel.specTitles }
        check(titles.contains("Focus mode"), "command bar: Focus mode exists")
    }

    private static func engine(_ check: (Bool, String) -> Void) {
        let e = Engine()
        _ = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1440, height: 875)))
        _ = e.handle(.windowAdded(ManagedWindow(id: 1, pid: 1, app: "A", title: "t", frame: CGRect(x: 0, y: 0, width: 400, height: 300), floating: false)))
        var plan = e.handle(.setWidth(0.667))
        check(plan.error == nil && plan.toast == "Width 66\u{00A0}%" && plan.toast == WidthPresets.title(0.667) && abs(plan.map.columns[0].widthFrac - 0.667) < 0.001, "engine: set_width through the real core, toast and map")
        plan = e.handle(.command("undo"))
        check(plan.toast == "Undid: width", "engine: set_width is one undo step")
        plan = e.handle(rawJSON: "{\"type\":\"command\",\"name\":\"set_width\",\"arg\":2}")
        check(plan.error != nil, "engine: set_width rejects a fraction above 1")
    }

    private static func ring(_ check: (Bool, String) -> Void) {
        var r = RingVisibility()
        check(r.phase == .idle && r.visible, "ring: idle shows")
        r.dragStarted()
        check(r.phase == .dragging && !r.visible, "ring: dragging hides ring and cutout")
        r.dragStarted()
        check(!r.visible, "ring: still hidden on further drag events")
        r.dragEnded()
        check(r.phase == .landed && r.visible, "ring: landed shows again at the final frame")
        r.settled()
        check(r.phase == .idle && r.visible, "ring: settled is idle")
        r.dragEnded(); r.settled()
        check(r.phase == .idle, "ring: end/settle without a drag change nothing")
        r.dragStarted(); r.reset()
        check(r.visible && r.phase == .idle, "ring: reset (pause) shows")
        fades(check)
    }

    /// The fades of the ring, the dim and the curtain on a fake clock: a refresh never cuts a fade-in short, a burst of focus
    /// switches never dips, a fade-out can turn back.
    private static func fades(_ check: (Bool, String) -> Void) {
        // A fade-in is read off the clock; a second show() 33 ms in (the direct-mode settle refreshes at 30 Hz) finds it still going.
        var ring = RingFade()
        ring.appear(at: 10)
        check(ring.isFadingIn(at: 10.033) && ring.isFadingIn(at: 10.1) && !ring.isFadingIn(at: 10.16), "fade: the first appearance holds the guard for its 0.15 s")
        check(ring.fade.alpha(at: 10) == 0 && abs(ring.fade.alpha(at: 10.075) - 0.5) < 1e-9 && ring.fade.alpha(at: 11) == 1, "fade: the opacity rises from nothing to full over the fade")
        // Five focus switches 90 ms apart (a held arrow key): the first fades in from nothing, none after it dips below the floor.
        var burst = RingFade()
        burst.appear(at: 0)
        var starts: [Double] = [], lowestAfterFirst = 1.0
        for i in 0..<5 {
            let t = 1.0 + Double(i) * 0.09
            starts.append(burst.switched(at: t))
            if i > 0 { lowestAfterFirst = min(lowestAfterFirst, (0...9).map { burst.fade.alpha(at: t + Double($0) * 0.009) }.min()!) }
        }
        check(starts[0] == 0, "fade: a lone switch fades the new ring in from nothing")
        check(starts.dropFirst().allSatisfy { $0 >= RingFade.floor } && lowestAfterFirst >= RingFade.floor, "fade: five switches 90 ms apart never let the ring fall below the floor")
        check(starts[4] > starts[1] && starts[4] > 0.8, "fade: a burst keeps the opacity high instead of restarting")
        var apart = RingFade()
        apart.appear(at: 0)
        _ = apart.switched(at: 1)
        check(apart.switched(at: 2) == 0, "fade: a switch long after the last one fades in from nothing again")
        // Switches that only move the ring (no fade of their own) still keep a burst together.
        var held = RingFade()
        held.appear(at: 0)
        check(held.switched(at: 1.0) == 0, "fade: a lone switch dips")
        held.noteSwitch(at: 1.09); held.noteSwitch(at: 1.18)
        check(held.switched(at: 1.27) >= RingFade.floor, "fade: switches that only move the ring still count for a burst, the next fade carries on")
        var quick = RingFade()
        quick.appear(at: 5)
        check(quick.switched(at: 5.06) >= RingFade.floor, "fade: a switch while the ring is still appearing carries on from there, at least the floor")
        // A panel fade (dim, curtain): a fade-out turns back from where it has got to.
        var panel = PanelFade()
        panel.begin(from: 1, to: 0, duration: 0.15, at: 0)
        check(panel.isRunning(at: 0.05) && !panel.isFadingIn(at: 0.05), "fade: a fade-out is running, not a fade-in")
        let back = panel.alpha(at: 0.06)
        panel.begin(from: back, to: 1, duration: 0.15, at: 0.06)
        check(abs(back - 0.6) < 1e-9 && panel.alpha(at: 0.06) == back && panel.isFadingIn(at: 0.1) && panel.alpha(at: 0.3) == 1, "fade: a fade-out that turns back starts from its current opacity")
        panel.stop(at: 0)
        check(!panel.isRunning(at: 100) && panel.alpha(at: 100) == 0, "fade: a stopped fade stays where it was set")
    }

    // Three 400pt columns at y 37; column 1 is a stack of two. Pointer rows: 37..77 is the title band.
    private static func tabGroups(_ check: (Bool, String) -> Void) {
        func col(_ i: Int, x: CGFloat, tabbed: Bool = false, rows: [CGRect] = []) -> DropColumn {
            DropColumn(index: i, frame: CGRect(x: x, y: 37, width: 400, height: 776), rows: rows, tabbed: tabbed, windows: [UInt32(i + 1)])
        }
        let usable = CGRect(x: 0, y: 25, width: 1300, height: 800)
        let cols = [col(0, x: 12), col(1, x: 424), col(2, x: 836, tabbed: true)]
        func t(_ x: CGFloat, _ y: CGFloat, source: (column: Int, alone: Bool, row: Int)? = nil) -> DropTarget? {
            DropRule.target(pointer: CGPoint(x: x, y: y), columns: cols, usable: usable, gap: 12, source: source)
        }
        check(t(600, 50) == .tabs(column: 1) && t(600, 76) == .tabs(column: 1), "drop: on a window's title bar area -> tab group")
        check(t(600, 78) == .before(column: 1) || t(600, 78) == .after(column: 1), "drop: just below the title band is a side drop again")
        check(t(500, 50, source: (0, true, 0)) == .tabs(column: 1), "drop: another window dragged onto the title bar makes tabs")
        check(t(500, 50, source: (1, true, 0)) == nil, "drop: onto its own title bar does nothing")
        check(t(500, 50, source: (1, false, 0)) == nil, "drop: a stack window onto its own column's title bar does nothing")
        check(t(900, 50) == .into(column: 2, row: 1), "drop: a tabbed column's bar still adds a tab")
        check(DropTarget.tabs(column: 4).position == "tabs" && DropTarget.tabs(column: 4).column == 4, "drop: tabs target position and column")
        if case .tabGroup(let r)? = DropRule.mark(for: .tabs(column: 1), columns: cols, usable: usable, gap: 12) {
            check(r.minX == 424 && r.width == 400 && r.minY == 38 && r.height == TabLayout.barHeight - 2, "mark: a tab-bar-shaped preview at the top of the column")
        } else { check(false, "mark: tabs draws a tab group preview") }
        // Through the real core: dropping a window by position "tabs" is one undo step and names the group.
        let e = Engine()
        _ = e.handle(.display(id: 1, frame: CGRect(x: 0, y: 25, width: 1440, height: 875)))
        for i in 1...3 { _ = e.handle(.windowAdded(ManagedWindow(id: UInt32(i), pid: 1, app: ["Safari", "Notes", "Mail"][i - 1], title: "w", frame: CGRect(x: 0, y: 0, width: 400, height: 300), floating: false))) }
        var plan = e.handle(rawJSON: "{\"type\":\"command\",\"name\":\"move_window_to\",\"arg\":{\"id\":3,\"column\":1,\"position\":\"tabs\"}}")
        check(plan.error == nil && plan.map.columns[0].tabbed && plan.map.columns[0].windows.map(\.id) == [1, 3] && plan.toast == "Tab group: Safari + Mail", "engine: drop on a title bar makes a tab group and says so")
        plan = e.handle(.command("undo"))
        check(plan.map.columns.count == 3 && !plan.map.columns[0].tabbed, "engine: the drop is one undo step")
        _ = e.handle(.windowFocused(2))
        plan = e.handle(.command("toggle_tabs"))
        check(plan.map.columns.count == 2 && plan.map.columns[0].tabbed && plan.toast == "Tab group: Safari + Notes", "engine: toggle_tabs on a lone window tabs it with its neighbour")
    }
}
