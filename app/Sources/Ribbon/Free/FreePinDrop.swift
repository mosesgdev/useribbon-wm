import CoreGraphics

// The free edition has no column held outside the ribbon to drop a window on: the drop rule is the ribbon's alone.

/// A drop on a held column: there is none, so no such target exists.
enum HeldDrop: Equatable {
    var position: String { switch self {} }
    func moveArg(id: UInt32) -> [String: Any] { switch self {} }
}

/// A held column as the drop rule sees it: there is none.
enum HeldDropColumn {
    static func build(from plan: Plan, dragging id: UInt32) -> HeldDropColumn? { nil }
    func claim(_ p: CGPoint, usable: CGRect, gap: CGFloat, lo: inout CGFloat, hi: inout CGFloat) -> HeldDrop? { switch self {} }
    func isNoOp(_ t: DropTarget) -> Bool? { switch self {} }
    func mark(_ h: HeldDrop) -> DropRule.Mark? { switch self {} }
}
