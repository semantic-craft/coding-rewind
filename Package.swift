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
        )
    ],
    targets: [
        .target(
            name: "CodingRewindCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodingRewindCoreTests",
            dependencies: ["CodingRewindCore"]
        )
    ]
)
