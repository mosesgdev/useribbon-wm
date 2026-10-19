import SwiftUI

/// The free edition's tab bar has no button of this kind: no bar in it is ever the last of a held group, so this never shows.
struct PinTabButton: View {
    let hovered: Bool
    let pressed: Bool
    let glass: Namespace.ID

    var body: some View { EmptyView() }
    static func tooltip(for bar: TabBar?) -> String { "" }
    static func action(for id: UInt32) -> TabAction? { nil }
}

/// What a tab's menu needs beyond the bar itself: nothing in the free edition.
struct TabMenuContext: Equatable {}

/// The free edition adds nothing to a tab's menu.
enum TabMenuFeature {
    static func entries(for bar: TabBar, context: TabMenuContext?) -> [TabMenuEntry] { [] }
}
