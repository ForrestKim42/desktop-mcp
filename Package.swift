// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DesktopPilot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "desktop-pilot-mcp", targets: ["DesktopPilot"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DesktopPilot",
            dependencies: [],
            path: "Sources/DesktopPilot",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "DesktopPilotTests",
            dependencies: ["DesktopPilot"],
            path: "Tests/DesktopPilotTests"
        )
    ]
)
