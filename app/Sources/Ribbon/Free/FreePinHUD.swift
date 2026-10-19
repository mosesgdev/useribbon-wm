import SwiftUI

// The free edition's strip has only the ribbon's tiles: nothing is drawn, captioned, hit, dropped on or offered for a column held
// outside the ribbon. The types below have no values, so no tile, hit, landing or argument of one can exist.

/// A held column's tile: there is none.
enum HeldTile: Equatable {
    init?(map: RibbonMap, focusID: UInt32?) { return nil }
    var focused: Bool { switch self {} }
    var leads: Bool { switch self {} }
    var w: CGFloat { switch self {} }
    func blockW(hasTrack: Bool) -> CGFloat { switch self {} }
    func covers(_ x: CGFloat, _ g: HUDStrip) -> Bool { switch self {} }
    func hit(_ p: CGPoint) -> HUDHit? { switch self {} }
    func landing(from i: Int, dx: CGFloat, _ g: HUDStrip) -> HeldLanding? { switch self {} }
}

/// A window of a held column's tile: there is none.
enum HeldHit: Equatable {
    func window(in map: RibbonMap) -> MapWindow? { switch self {} }
    func grab(dx: CGFloat) -> HUDDrag { switch self {} }
    static func hit(row: Int) -> HUDHit? { nil }
    func drop(dx: CGFloat, _ g: HUDStrip) -> HUDDrop { switch self {} }
}

/// Where a drag lands on a held column's account: nowhere.
enum HeldLanding: Equatable {
    func slide(of i: Int, from: Int) -> Int { switch self {} }
    func commands(map: RibbonMap, focusID: UInt32?, drag d: HUDDrag) -> [HUDCommand] { switch self {} }
}

/// A command argument for a held column: there is none.
enum HeldArg: Equatable, Encodable {
    func encode(to encoder: Encoder) throws { switch self {} }
}

extension HUDCaption {
    static func heldFocus(_ map: RibbonMap, _ focusID: UInt32?) -> MapWindow? { nil }
    static func heldCaption(_ map: RibbonMap, focusID: UInt32?, hoverID: UInt32?) -> (name: String, detail: String, preview: Bool)? { nil }
    static func heldAxLabel(app: String, focused: Bool, tabs: Int? = nil, row: Int? = nil, rows: Int? = nil) -> String { "" }
}

extension RibbonMapView {
    func heldBlock(_ g: HUDStrip, leading: Bool) -> some View { EmptyView() }
    func heldJoinAction(from i: Int) -> some View { EmptyView() }
    func heldLeaveAction() -> some View { EmptyView() }
}
