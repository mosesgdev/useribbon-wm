import SwiftUI

/// The free edition draws no sketch of a Plus feature in the toast pill.
enum PlusDiagram: Equatable {
    static func make(toast t: String, map: RibbonMap) -> PlusDiagram? { nil }
}

/// The free edition has no toast wording of its own either: every toast reads through the generic split.
enum PlusToast {
    static func text(_ t: String, key: (String) -> String?) -> (String, String?)? { nil }
    static func diagram(_ t: String, map: RibbonMap) -> PlusDiagram? { nil }
}

struct PlusDiagramView: View {
    let diagram: PlusDiagram
    let ink: Color

    var body: some View { EmptyView() }
}
