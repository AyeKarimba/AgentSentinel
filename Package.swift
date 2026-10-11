// swift-tools-version:5.9
import PackageDescription

// No external dependencies on purpose: the hook binary runs on every Claude Code event,
// so build reproducibility and cold-start time matter more than argument-parsing sugar.
let package = Package(
    name: "AgentSentinel",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TNavCore", targets: ["TNavCore"]),
        .executable(name: "tnav", targets: ["tnav"]),
        .executable(name: "AgentSentinelApp", targets: ["AgentSentinelApp"]),
    ],
    targets: [
        .target(name: "CNotify"),
        .target(name: "TNavCore", dependencies: ["CNotify"]),
        .executableTarget(name: "tnav", dependencies: ["TNavCore"]),
        .executableTarget(name: "AgentSentinelApp", dependencies: ["TNavCore"]),
        .testTarget(name: "TNavCoreTests", dependencies: ["TNavCore"]),
    ]
)
