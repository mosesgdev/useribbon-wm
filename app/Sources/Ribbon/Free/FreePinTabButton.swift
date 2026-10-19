import SwiftUI

/// The free edition's tab bar ends in no button of a feature's own: nothing is kept free for one and nothing shows.
struct HeldBarButton: View {
    @ObservedObject var model: TabBarModel
    let glass: Namespace.ID

    var body: some View { EmptyView() }
    static func trailing(for bar: TabBar?, width: CGFloat) -> CGFloat { 0 }
    static func tooltip(for bar: TabBar?) -> String { "" }
    static func action(for id: UInt32) -> TabAction? { nil }
}

/// What a tab's menu needs beyond the bar itself: nothing in the free edition.
struct TabMenuContext: Equatable {}

/// The free edition adds nothing to a tab's menu, and every group can be closed.
enum TabMenuFeature {
    static func entries(for bar: TabBar, context: TabMenuContext?) -> [TabMenuEntry] { [] }
    static func closesGroup(_ bar: TabBar) -> Bool { true }
    static func keepOutTitle(_ bar: TabBar) -> String? { nil }
}
