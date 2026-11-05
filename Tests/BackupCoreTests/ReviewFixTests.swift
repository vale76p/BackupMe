import Foundation
import Testing
@testable import BackupCore

/// Regression tests for the findings of the whole-branch review.
@Suite struct ReviewFixTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let cacheURL = tmp().appending(path: "cache.json")
    let fm = FileManager.default

    func engine(_ repo: Repository, excludes: [String] = ExcludeRules.defaults) -> BackupEngine {
        BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: excludes))
    }

    // C1: a write error on the archive must fail the backup, not become a warning.
    @Test func archiveWriteErrorFailsBackup() throws {
        write("a", to: src.appending(path: "a.txt"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        let objects = repo.root.appending(path: "objects")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: objects.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: objects.path) }
        #expect(throws: (any Error).self) { try engine(repo).run(sources: [src]) }
        #expect(try repo.snapshotIDs().isEmpty)
    }

    // I1: if the destination vanishes mid-run, it must not be recreated as a local folder.
    @Test func vanishedDestinationNotRecreated() throws {
        let d = dest.appending(path: "OneDrive", directoryHint: .isDirectory)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        let repo = try Repository(destination: d, computerName: "Mac")
        try fm.removeItem(at: d)
        let data = Data("x".utf8)
        #expect(throws: (any Error).self) { try repo.putObject(data, hash: sha256Hex(data)) }
        #expect(!fm.fileExists(atPath: d.path))
    }

    // I2: stale locks after reboot / from another process / garbled.
    @Test func lockFromOtherProcessIsStale() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        // pid 1 (launchd) is alive but is not us
        try Data(#"{"pid":1,"host":"x","boot":\#(Repository.bootTime)}"#.utf8).write(to: r.root.appending(path: "lock"))
        var ran = false
        try r.withLock { ran = true }
        #expect(ran)
    }

    @Test func lockFromPreviousBootIsStale() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        try Data(#"{"pid":\#(getpid()),"host":"x","boot":1}"#.utf8).write(to: r.root.appending(path: "lock"))
        var ran = false
        try r.withLock { ran = true }
        #expect(ran)
    }

    @Test func oldGarbledLockIsStale() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let lock = r.root.appending(path: "lock")
        try Data().write(to: lock)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: lock.path)
        var ran = false
        try r.withLock { ran = true }
        #expect(ran)
    }

    // I3: a corrupt object is dropped so the next backup stores the file again.
    @Test func corruptObjectIsDropped() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let data = Data("originale".utf8), h = sha256Hex(data)
        _ = try r.putObject(data, hash: h)
        try (Data("rotto".utf8) as NSData).compressed(using: .lzfse).write(to: r.root.appending(path: "objects/\(h.prefix(2))/\(h).lzfse"))
        #expect(throws: RepositoryError.corruptObject(h)) { try r.readObject(h) }
        #expect(!r.hasObject(h))
    }

    // I4: with a refs cache, prune does not re-read manifests it has already seen.
    @Test func pruneUsesRefsCache() throws {
        let refs = tmp()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let repo = try Repository(destination: dest, computerName: "Mac")
        for i in 0..<3 {
            write("v\(i)", to: src.appending(path: "a.txt"))
            _ = try engine(repo).run(sources: [src], now: t0.addingTimeInterval(Double(i) * 86400))
        }
        var keepAll = RetentionPolicy(); keepAll.days = 1000
        _ = try prune(repository: repo, policy: keepAll, capBytes: nil, now: t0, refsCache: refs)
        // garble a manifest that stays: a re-read would throw
        let ids = try repo.snapshotIDs()
        try Data("garbage".utf8).write(to: repo.root.appending(path: "snapshots/\(ids[2]).json.lzfse"))
        var keepNewest = RetentionPolicy(); keepNewest.days = 0; keepNewest.weeks = 0; keepNewest.months = 0
        let r = try prune(repository: repo, policy: keepNewest, capBytes: nil, now: t0.addingTimeInterval(10 * 86400), refsCache: refs)
        #expect(r.deletedSnapshots == [ids[0], ids[1]])
        #expect(try repo.allObjectHashes() == [sha256Hex(Data("v2".utf8))])
    }

    // M2 (re-graded): default excludes must not drop git internals such as a branch named "build".
    @Test func gitInternalsNeverExcluded() throws {
        write("sha", to: src.appending(path: ".git/refs/heads/build"))
        write("x", to: src.appending(path: "build/out.o"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try engine(repo).run(sources: [src])
        let paths = Set(try repo.readSnapshot(report.snapshotID!).entries.map(\.path))
        #expect(paths.contains(".git/refs/heads/build"))
        #expect(!paths.contains("build"))
    }

    // M12 (re-graded): a source folder that is a symlink is followed.
    @Test func symlinkedSourceIsFollowed() throws {
        let real = tmp().appending(path: "reale", directoryHint: .isDirectory)
        write("a", to: real.appending(path: "a.txt"))
        try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: src, withDestinationURL: real)
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try engine(repo).run(sources: [src])
        #expect(report.fileCount == 1)
    }
}
