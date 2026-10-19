// Compiled only into the free edition; the Plus build declares the same two types in a Plus-only file.

/// What this binary was compiled as.
enum BuiltEdition {
    static let name = "free"
}

/// The free edition registers no features.
enum PlusFeatureList {
    static var all: [any RibbonFeature] { [] }
}
