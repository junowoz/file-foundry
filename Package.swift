// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FileFoundry",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DoppelCore", targets: ["DoppelCore"]),
        .executable(name: "FileFoundry", targets: ["FileFoundry"]),
        .executable(name: "FileFoundryUpdater", targets: ["FileFoundryUpdater"])
    ],
    targets: [
        .target(
            name: "DoppelCore",
            path: "Doppel"
        ),
        .executableTarget(
            name: "FileFoundry",
            dependencies: ["DoppelCore"],
            path: "DoppelApp",
            exclude: [
                "Resources"
            ]
        ),
        .executableTarget(
            name: "FileFoundryUpdater",
            dependencies: ["DoppelCore"],
            path: "DoppelUpdater"
        ),
        .testTarget(
            name: "DoppelTests",
            dependencies: ["DoppelCore"],
            path: "DoppelTests"
        ),
        .testTarget(
            name: "MediaSortTests",
            dependencies: ["FileFoundry"],
            path: "MediaSortTests"
        )
    ]
)
