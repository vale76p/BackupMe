import Foundation
import Testing
@testable import BackupCore

@Suite struct BackupEngineTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let cacheURL = tmp().appending(path: "cache.json")

    func engine() throws -> (BackupEngine, Repository) {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let e = BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                             excludes: ExcludeRules(patterns: ExcludeRules.defaults))
        return (e, repo)
    }

    func makeSource() {
        write("a", to: src.appending(path: "a.txt"))
        write("b", to: src.appending(path: "sub/b.txt"))
        write("ref: refs/heads/main", to: src.appending(path: ".git/HEAD"))
        write("x", to: src.appending(path: "node_modules/x.js"))
        try! FileManager.default.createSymbolicLink(atPath: src.appending(path: "link").path, withDestinationPath: "../a.txt")
    }

    @Test func excludesByName() {
        let r = ExcludeRules(patterns: ExcludeRules.defaults + ["*.log"])
        #expect(r.excludes(name: "node_modules", isDirectory: true))
        #expect(r.excludes(name: "x.log", isDirectory: false))
        #expect(!r.excludes(name: ".git", isDirectory: true))
    }

    @Test func backupCreatesSnapshotWithEntries() throws {
        makeSource()
        let (e, repo) = try engine()
        let report = try e.run(sources: [src])
        #expect(report.error == nil)
        let ids = try repo.snapshotIDs()
        #expect(ids.count == 1)
        #expect(report.snapshotID == ids.first)
        let s = try repo.readSnapshot(ids[0])
        let paths = Set(s.entries.map(\.path))
        #expect(paths == ["", "a.txt", "sub", "sub/b.txt", ".git", ".git/HEAD", "link"])
        let link = s.entries.first { $0.path == "link" }!
        #expect(link.kind == .symlink)
        #expect(link.linkTarget == "../a.txt")
        #expect(s.entries.first { $0.path == "a.txt" }!.hash == sha256Hex(Data("a".utf8)))
    }

    @Test func secondBackupWritesNoNewObjects() throws {
        makeSource()
        let (e, repo) = try engine()
        _ = try e.run(sources: [src], now: Date(timeIntervalSince1970: 1_000_000))
        let objects = try repo.allObjectHashes()
        let r2 = try e.run(sources: [src], now: Date(timeIntervalSince1970: 1_003_600))
        #expect(r2.newBytes == 0)
        #expect(try repo.allObjectHashes() == objects)
        #expect(try repo.snapshotIDs().count == 1)
    }

    @Test func identicalFilesStoredOnce() throws {
        write("uguale", to: src.appending(path: "a.txt"))
        write("uguale", to: src.appending(path: "copia.txt"))
        let (e, repo) = try engine()
        _ = try e.run(sources: [src])
        #expect(try repo.allObjectHashes().count == 1)
    }

    @Test func hashCacheHitsOnlyOnIdenticalStamp() throws {
        let url = tmp().appending(path: "c.json")
        let m = Date(timeIntervalSince1970: 1000), c = Date(timeIntervalSince1970: 2000)
        let cache = HashCache(url: url)
        cache.store(path: "/a", inode: 1, size: 3, mtime: m, ctime: c, hash: "h")
        try cache.save()
        let reloaded = HashCache(url: url)
        #expect(reloaded.lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: c) == "h")
        #expect(reloaded.lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: c.addingTimeInterval(1)) == nil)
    }

    @Test func unreadableFileIsWarning() throws {
        write("a", to: src.appending(path: "a.txt"))
        let secret = src.appending(path: "segreto.txt")
        write("s", to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
        let (e, repo) = try engine()
        let r = try e.run(sources: [src])
        #expect(r.error == nil)
        #expect(r.warnings.contains { $0.contains("segreto.txt") })
        let s = try repo.readSnapshot(r.snapshotID!)
        #expect(s.entries.contains { $0.path == "a.txt" })
        #expect(!s.entries.contains { $0.path == "segreto.txt" })
    }

    @Test func validateRejectsOverlap() throws {
        let (_, repo) = try engine()
        #expect(BackupEngine.validate(sources: [dest], repositoryRoot: repo.root) == .sourceOverlapsDestination(dest.path))
        #expect(BackupEngine.validate(sources: [repo.root.appending(path: "objects")], repositoryRoot: repo.root) != nil)
        #expect(BackupEngine.validate(sources: [src], repositoryRoot: repo.root) == nil)
    }

    @Test func cancelledLeavesNoSnapshot() throws {
        makeSource()
        let (e, repo) = try engine()
        #expect(throws: BackupError.cancelled) { try e.run(sources: [src], isCancelled: { true }) }
        #expect(try repo.snapshotIDs().isEmpty)
    }
}
