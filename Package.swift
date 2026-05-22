// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Conterm",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Conterm",
            dependencies: ["GhosttyKit"],
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
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
    ]
)
