import SwiftUI

// The free edition's strip has only the ribbon's tiles: nothing is drawn, captioned or offered for a column held outside the ribbon.

extension HUDCaption {
    static func heldCaption(_ map: RibbonMap, focusID: UInt32?, hoverID: UInt32?) -> (name: String, detail: String, preview: Bool)? { nil }
    static func heldAxLabel(app: String, focused: Bool, tabs: Int? = nil, row: Int? = nil, rows: Int? = nil) -> String { "" }
}

extension RibbonMapView {
    var pinGlyph: some View { EmptyView() }
    func pinTile(_ g: HUDStrip) -> some View { EmptyView() }
    func heldJoinAction(from i: Int) -> some View { EmptyView() }
    func heldLeaveAction() -> some View { EmptyView() }
}
