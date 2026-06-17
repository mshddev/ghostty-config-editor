// swift-tools-version: 6.0
import PackageDescription

// Ghostty Config Manager — a native macOS (SwiftUI) configuration tool for Ghostty.
//
// Structured as a SwiftPM package rather than a hand-rolled .xcodeproj so every
// logic layer has real `swift test` coverage and the package still opens natively
// in Xcode (`xed .`). KTD1's non-sandboxed / Hardened-Runtime / Developer-ID
// configuration and notarization are distribution-time concerns layered at the
// codesign/packaging step (a plain executable is non-sandboxed by default).
//
// Floor is macOS 14 (KTD9) to enable @Observable and NavigationSplitView.
let package = Package(
    name: "GhosttyConfigManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GhosttyConfigManager", targets: ["GhosttyConfigManager"]),
        .library(name: "GhosttyConfigKit", targets: ["GhosttyConfigKit"]),
    ],
    targets: [
        // All non-UI logic lives here so the test target can exercise it directly.
        .target(
            name: "GhosttyConfigKit",
            resources: [.process("Resources")]
        ),
        // Thin SwiftUI shell over GhosttyConfigKit.
        .executableTarget(
            name: "GhosttyConfigManager",
            dependencies: ["GhosttyConfigKit"]
        ),
        .testTarget(
            name: "GhosttyConfigKitTests",
            dependencies: ["GhosttyConfigKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
