// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeCounterBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ClaudeCounterCore", targets: ["ClaudeCounterCore"]),
        .executable(name: "ClaudeCounterBar", targets: ["ClaudeCounterBar"]),
    ],
    targets: [
        .target(
            name: "ClaudeCounterCore",
            path: "Sources/ClaudeCounterCore"
        ),
        .executableTarget(
            name: "ClaudeCounterBar",
            dependencies: ["ClaudeCounterCore"],
            path: "Sources/ClaudeCounterBar",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ClaudeCounterCoreTests",
            dependencies: ["ClaudeCounterCore"],
            path: "Tests/ClaudeCounterCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
