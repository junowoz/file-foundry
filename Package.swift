// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FileFoundry",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FileFoundryCore", targets: ["FileFoundryCore"]),
        .executable(name: "FileFoundry", targets: ["FileFoundry"]),
        .executable(name: "FileFoundryUpdater", targets: ["FileFoundryUpdater"])
    ],
    targets: [
        .target(
            name: "FileFoundryCore",
            path: "FileFoundryCore"
        ),
        .target(
            name: "CVirtualDisplay",
            path: "CVirtualDisplay",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "FileFoundry",
            dependencies: ["FileFoundryCore", "CVirtualDisplay"],
            path: "FileFoundryApp",
            exclude: [
                "Resources"
            ]
        ),
        .executableTarget(
            name: "FileFoundryUpdater",
            dependencies: ["FileFoundryCore"],
            path: "FileFoundryUpdater"
        ),
        .testTarget(
            name: "FileFoundryCoreTests",
            dependencies: ["FileFoundryCore"],
            path: "FileFoundryCoreTests"
        ),
        .testTarget(
            name: "MediaOrganizerTests",
            dependencies: ["FileFoundry"],
            path: "MediaOrganizerTests"
        )
    ]
)
