import AppKit

// The free edition's stand-ins for what the Plus edition's Controller does for a pinned column: there is none, so none of it does anything.

/// What the Controller keeps for a Plus feature: nothing.
@MainActor
final class PinState {}

extension Controller {
    func wirePin() {}
    func hidePinChrome() {}
    func curtainInvalidate() {}
    func curtainWallpaperChanged() -> Bool { false }
    func restVeils(animated: Bool) {}
    func curtainTeardown() {}
    func isPinRaiseEcho(_ id: UInt32, arrived: Date) -> Bool { false }
    func pinEdge(on uuid: String) -> PinEdge? { nil }
    func overlayEdge(_ plan: Plan, shownPin: CGRect?, bar: CGRect?, display disp: CGRect) -> PinEdge? { nil }
    func heldBarTarget(of id: UInt32) -> (width: Double, tag: String)? { nil }
    func heldFocusedWindow() -> UInt32? { nil }
    func heldContextRows(of id: UInt32) -> [BarItem]? { nil }
    func ribbonWindowFeatureRows(of id: UInt32) -> [BarItem] { [] }
    func heldPlaces(_ map: RibbonMap) -> [UInt32: String] { [:] }
    func pinTabAction(_ a: TabAction) -> Bool { false }
    func featureCommand(_ name: String, _ arg: Int?) -> Bool { false }
    func ribbonArea(_ uuid: String, _ visible: CGRect) -> CGRect { visible }
    func menuContext(for id: UInt32) -> TabMenuContext? { nil }
    func notePin(_ plan: Plan, _ st: DisplayState) {}
    func raisePinned(force: Bool = false) {}
    func raisePinnedAfterFocus(gliding: Bool = false) {}
    func refreshCurtain(animated: Bool = true) {}
    func followVeil(_ now: Double) {}
    func curtainQA() -> [[String: Any]] { [] }
}
