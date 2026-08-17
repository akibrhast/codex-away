// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexRemoteOnLock",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "RemoteDevCore", targets: ["RemoteDevCore"]),
        .executable(name: "codex-remote-on-lock", targets: ["RemoteDevDaemon"]),
    ],
    targets: [
        .target(name: "RemoteDevCore"),
        .executableTarget(
            name: "RemoteDevDaemon",
            dependencies: ["RemoteDevCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "RemoteDevCoreTests",
            dependencies: ["RemoteDevCore"]
        ),
    ]
)
