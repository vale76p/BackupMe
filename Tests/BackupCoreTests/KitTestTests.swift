import Foundation
import Testing
@testable import BackupCore

@Suite struct KitTestTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let fm = FileManager.default
    var script: URL { dest.appending(path: "BackupMe/RIPRISTINO.command") }

    func backup() throws -> (Repository, String) {
        write(String(repeating: "testo comprimibile ", count: 200), to: src.appending(path: "testo.txt"))
        write("caffè", to: src.appending(path: "sub/caffè.txt"))
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: src.appending(path: "sub/casuale.bin"))
        write("x", to: src.appending(path: "chiusa/dentro.txt"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: src.appending(path: "chiusa").path)
        try fm.createSymbolicLink(atPath: src.appending(path: "link").path, withDestinationPath: "sub")
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src])
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appending(path: "chiusa").path)
        return (repo, try #require(report.snapshotID))
    }

    @Test func passesOnARealBackupAndLeavesNothingBehind() throws {
        let (repo, id) = try backup()
        let plan = try #require(try kitTestPlan(repository: repo))
        #expect(plan.snapshotID == id && plan.files == 4)
        let work = tmp().appending(path: "prova")
        let r = try testRestoreKit(repository: repo, snapshotID: id, into: work)
        #expect(r.passed, "\(r.problems)")
        #expect(r.installed == RestoreKit.version && r.files == 4)
        #expect(!fm.fileExists(atPath: work.path))
    }

    @Test func damagedObjectFails() throws {
        let (repo, id) = try backup()
        let hash = try #require(try repo.readSnapshot(id).entries.first { $0.path == "sub/casuale.bin" }?.hash)
        try Data(repeating: 0, count: 4096).write(to: try #require(objectFile(repo, hash)))
        let r = try testRestoreKit(repository: repo, snapshotID: id, into: tmp().appending(path: "prova"))
        #expect(!r.passed)
    }

    @Test func missingOrOlderScriptIsReported() throws {
        let (repo, id) = try backup()
        let text = try String(contentsOf: script, encoding: .utf8)
        try text.replacingOccurrences(of: "BackupMe-kit: \(RestoreKit.version)", with: "BackupMe-kit: \(RestoreKit.version - 1)")
            .write(to: script, atomically: true, encoding: .utf8)
        let older = try testRestoreKit(repository: repo, snapshotID: id, into: tmp().appending(path: "prova"))
        #expect(older.installed == RestoreKit.version - 1 && older.problems.count == 1, "\(older.problems)")
        try fm.removeItem(at: script)
        let missing = try testRestoreKit(repository: repo, snapshotID: id, into: tmp().appending(path: "prova"))
        #expect(missing.installed == nil && !missing.passed)
    }

    @Test func cancelStopsAndCleansUp() throws {
        let (repo, id) = try backup()
        let work = tmp().appending(path: "prova")
        #expect(throws: BackupError.cancelled) { try testRestoreKit(repository: repo, snapshotID: id, into: work) { true } }
        #expect(!fm.fileExists(atPath: work.path))
    }
}
