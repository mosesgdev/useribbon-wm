// swift-tools-version: 6.0
import PackageDescription

// Build with `make` (or scripts/bootstrap.sh): the Makefile picks the edition and passes what depends on it. The core of that
// edition is found through `-Xlinker -L<core/target/EDITION/release>`, and the Plus edition is compiled with `-Xswiftc -DRIBBON_PLUS`.
// Each edition builds in its own scratch path (app/.build/EDITION), so neither ever links the other's core.
let package = Package(
    name: "Ribbon",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Pinned exactly: updates go through this, so a new Sparkle is a deliberate change.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .systemLibrary(name: "RibbonCoreFFI", path: "Sources/RibbonCoreFFI"),
        .executableTarget(
            name: "Ribbon",
            dependencies: ["RibbonCoreFFI", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is found in the bundle (Contents/Frameworks) or, for --selftest, beside the built binary.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@loader_path"])]
        ),
        // QA helper: opens N plain windows so Ribbon can be tested without touching real apps.
        .executableTarget(name: "RibbonDummy"),
    ],
    swiftLanguageModes: [.v5]
)
