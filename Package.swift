// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "CodingRewind",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "coding-rewind-sidecar", targets: ["ConversationSidecar"]),
        .library(
            name: "CodingRewindCore",
            targets: ["CodingRewindCore"]
        ),
        .executable(
            name: "coding-rewind-hook",
            targets: ["AntigravityBridge"]
        ),
        .executable(
            name: "CodingRewindApp",
            targets: ["CodingRewindApp"]
        )
    ],
    dependencies: [.package(path: "Vendor/KeyboardShortcuts")],
    targets: [
        .executableTarget(name: "ConversationSidecar", dependencies: ["CodingRewindCore"]),
        .target(
            name: "CodingRewindCore"
        ),
        .executableTarget(
            name: "AntigravityBridge",
            dependencies: ["CodingRewindCore"]
        ),
        .executableTarget(
            name: "CodingRewindApp",
            dependencies: ["CodingRewindCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
        ),
        .executableTarget(
            name: "ShortcutConflictFixture",
            path: "Tests/Support/ShortcutConflictFixture"
        ),
        .testTarget(
            name: "CodingRewindAppTests",
            dependencies: ["CodingRewindApp", "ShortcutConflictFixture", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
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
                "ConversationSidecar"
            ]
        )
    ]
)
