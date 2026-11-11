// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "CodingRewind",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CodingRewindCore",
            targets: ["CodingRewindCore"]
        ),
        .executable(
            name: "coding-rewind-hook",
            targets: ["AntigravityBridge"]
        ),
        .executable(
            name: "rewind-mcp",
            targets: ["RewindMCP"]
        ),
        .executable(
            name: "CodingRewindApp",
            targets: ["CodingRewindApp"]
        )
    ],
    targets: [
        .target(
            name: "CodingRewindCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AntigravityBridge",
            dependencies: ["CodingRewindCore"]
        ),
        .executableTarget(
            name: "RewindMCP",
            dependencies: ["CodingRewindCore"]
        ),
        .executableTarget(
            name: "CodingRewindApp",
            dependencies: ["CodingRewindCore"]
        ),
        .testTarget(
            name: "CodingRewindCoreTests",
            dependencies: ["CodingRewindCore"]
        ),
        .testTarget(
            name: "CodingRewindCLITests",
            dependencies: [
                "CodingRewindCore",
                "AntigravityBridge",
                "RewindMCP"
            ]
        )
    ]
)
