// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupMe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BackupCore"),
        .executableTarget(name: "BackupMe", dependencies: ["BackupCore"]),
        // run by scripts/build-app.sh --install: updates the restore kit beside the archives at once
        .executableTarget(name: "KitUpdater", dependencies: ["BackupCore"]),
        .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
    ]
)
