// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexAway",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "RemoteDevCore", targets: ["RemoteDevCore"]),
        .library(name: "RemoteDevServices", targets: ["RemoteDevServices"]),
        .executable(name: "codex-away", targets: ["RemoteDevDaemon"]),
    ],
    targets: [
        .target(name: "RemoteDevCore"),
        .target(
            name: "RemoteDevServices",
            dependencies: ["RemoteDevCore"]
        ),
        .executableTarget(
            name: "RemoteDevDaemon",
            dependencies: ["RemoteDevCore", "RemoteDevServices"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "RemoteDevCoreTests",
            dependencies: ["RemoteDevCore"]
        ),
        .testTarget(
            name: "RemoteDevServicesTests",
            dependencies: ["RemoteDevServices"]
        ),
    ]
)
