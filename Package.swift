// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupMe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BackupCore"),
        .executableTarget(name: "BackupMe", dependencies: ["BackupCore"]),
        .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
    ]
)
