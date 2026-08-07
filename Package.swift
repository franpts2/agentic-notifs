// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgenticNotifs",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgenticNotifs", targets: ["AgenticNotifsApp"]),
        .executable(name: "agentic-notify", targets: ["AgenticNotifyCLI"])
    ],
    targets: [
        .target(name: "AgenticNotifsCore"),
        .executableTarget(
            name: "AgenticNotifsApp",
            dependencies: ["AgenticNotifsCore"]
        ),
        .executableTarget(
            name: "AgenticNotifyCLI",
            dependencies: ["AgenticNotifsCore"]
        )
    ]
)
