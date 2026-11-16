// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConnectionRig",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ConnectionRig", targets: ["ConnectionRig"]),
        .library(name: "RigProtocol", targets: ["RigProtocol"]),
        .executable(name: "rig-agent", targets: ["RigAgent"]),
        .executable(name: "RigCompanion", targets: ["RigCompanion"]),
    ],
    targets: [
        .target(name: "RigProtocol"),
        .target(
            name: "DownloadExample",
            path: "Examples/DownloadLab/Sources",
            exclude: ["App.swift"]
        ),
        .target(name: "ConnectionRig", dependencies: ["RigProtocol"]),
        .target(name: "RigAgentCore", dependencies: ["RigProtocol"]),
        .executableTarget(name: "RigAgent", dependencies: ["RigAgentCore"]),
        .executableTarget(name: "RigCompanion", dependencies: ["RigAgentCore", "ConnectionRig"]),
        .testTarget(name: "RigProtocolTests", dependencies: ["RigProtocol", "ConnectionRig"]),
        .testTarget(
            name: "RigAgentTests",
            dependencies: ["RigAgentCore", "ConnectionRig", "DownloadExample"]
        ),
    ]
)
