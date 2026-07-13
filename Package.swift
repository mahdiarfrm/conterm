// swift-tools-version:6.0
import Foundation
import PackageDescription

// The test suite is local-only (gitignored); declare the target only when
// its sources exist so clones without it can still load the manifest.
let hasLocalTests = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Tests/ContermTests")

let package = Package(
    name: "Conterm",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Conterm",
            dependencies: ["GhosttyKit", "CatchNSException"],
            path: "Sources/Conterm",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOKit"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "CatchNSException",
            path: "Sources/CatchNSException"
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
    ] + (hasLocalTests ? [
        .testTarget(
            name: "ContermTests",
            dependencies: ["Conterm", "GhosttyKit"],
            path: "Tests/ContermTests"
        ),
    ] : [])
)
