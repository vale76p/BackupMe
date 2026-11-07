// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The tests are optional: a copy made only to build the app (e.g. for a managed Mac) can leave Tests/ out.
// Declared without its folder, the test target would claim every source file of the package.
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/BackupCoreTests")

let package = Package(
    name: "BackupMe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BackupCore"),
        .executableTarget(name: "BackupMe", dependencies: ["BackupCore"]),
        // run by scripts/build-app.sh --install: updates the restore kit beside the archives at once
        .executableTarget(name: "KitUpdater", dependencies: ["BackupCore"]),
    ] + (hasTests ? [.testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"], resources: [.copy("Fixtures")])] : [])
)
