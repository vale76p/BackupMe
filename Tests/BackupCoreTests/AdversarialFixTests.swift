import Foundation
import Testing
@testable import BackupCore

/// Regression tests for the findings of the five adversarial reviews.
@Suite struct AdversarialFixTests {
    let dest = tmp()
    let base = tmp()
    var src: URL { base.appending(path: "progetto", directoryHint: .isDirectory) }
    let cacheURL = tmp().appending(path: "cache.json")
    let fm = FileManager.default
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func repo() throws -> Repository { try Repository(destination: dest, computerName: "Mac") }
    func engine(_ r: Repository, excludes: [String] = ExcludeRules.defaults) -> BackupEngine {
        BackupEngine(repository: r, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: excludes))
    }
    func restorer(_ r: Repository, trash: @escaping (URL) throws -> Void = { _ in }) -> Restorer {
        Restorer(repository: r, trash: trash)
    }

    // MARK: backup engine

    @Test func unreadableSourceIsPartialFailure() throws {
        let other = base.appending(path: "altro", directoryHint: .isDirectory)
        write("ok", to: src.appending(path: "a.txt"))
        write("x", to: other.appending(path: "b.txt"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: other.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path) }
        let r = try repo()
        let report = try engine(r).run(sources: [src, other], now: t0)
        #expect(report.error != nil)
        let s = try r.readSnapshot(report.snapshotID!)
        #expect(s.entries.contains { $0.path == "a.txt" })
    }

    @Test func missingSourceIsPartialFailure() throws {
        write("ok", to: src.appending(path: "a.txt"))
        let r = try repo()
        let report = try engine(r).run(sources: [src, base.appending(path: "sparita")], now: t0)
        #expect(report.error?.contains("sparita") == true)
        #expect(try r.readSnapshot(report.snapshotID!).entries.contains { $0.path == "a.txt" })
    }

    @Test func sameSecondBackupsDoNotOverwrite() throws {
        let refs = tmp()
        let r = try repo()
        write("uno", to: src.appending(path: "a.txt"))
        _ = try engine(r).run(sources: [src], now: t0)
        _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs)
        write("due", to: src.appending(path: "a.txt"))
        let second = try engine(r).run(sources: [src], now: t0)
        _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs)
        #expect(try r.snapshotIDs().count == 2)
        let s = try r.readSnapshot(second.snapshotID!)
        let h = try #require(s.entries.first { $0.path == "a.txt" }?.hash)
        #expect(try r.readObject(h) == Data("due".utf8))
    }

    @Test func noChangeBackupWritesNoManifest() throws {
        write("a", to: src.appending(path: "a.txt"))
        let r = try repo()
        let first = try engine(r).run(sources: [src], now: t0)
        let second = try engine(r).run(sources: [src], now: t0.addingTimeInterval(3600))
        #expect(second.error == nil)
        #expect(second.snapshotID == first.snapshotID)
        #expect(try r.snapshotIDs().count == 1)
    }

    @Test func sameSizeRewriteWithResetMtimeDetected() throws {
        let f = src.appending(path: "a.txt")
        write("AAAA", to: f)
        try fm.setAttributes([.modificationDate: t0], ofItemAtPath: f.path)
        let r = try repo()
        _ = try engine(r).run(sources: [src], now: t0)
        Thread.sleep(forTimeInterval: 1.1) // ctime has second granularity in practice
        write("BBBB", to: f)
        try fm.setAttributes([.modificationDate: t0], ofItemAtPath: f.path)
        let report = try engine(r).run(sources: [src], now: t0.addingTimeInterval(3600))
        let e = try #require(try r.readSnapshot(report.snapshotID!).entries.first { $0.path == "a.txt" })
        #expect(e.hash == sha256Hex(Data("BBBB".utf8)))
    }

    @Test func defaultExcludesSkipFoldersNotFiles() throws {
        write("#!/bin/sh", to: src.appending(path: "build"))
        write("x", to: src.appending(path: "sub/dist"))
        write("o", to: src.appending(path: "target/out.o"))
        write("l", to: src.appending(path: "app.log"))
        let r = try repo()
        let report = try engine(r, excludes: ExcludeRules.defaults + ["*.log"]).run(sources: [src], now: t0)
        let paths = Set(try r.readSnapshot(report.snapshotID!).entries.map(\.path))
        #expect(paths.contains("build"))
        #expect(paths.contains("sub/dist"))
        #expect(!paths.contains("target"))
        #expect(!paths.contains("app.log"))
    }

    @Test func incompressibleFileStoredRawAndRestored() throws {
        let big = Data((0..<(40 << 20)).map { _ in UInt8.random(in: 0...255) })
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try big.write(to: src.appending(path: "blob.bin"))
        let r = try repo()
        let report = try engine(r).run(sources: [src], now: t0)
        let h = sha256Hex(big)
        #expect(objectFile(r, h)?.pathExtension == "raw")
        let out = tmp()
        try restorer(r).restore(try r.readSnapshot(report.snapshotID!), source: src.path, path: "blob.bin", mode: .into(out))
        #expect(try Data(contentsOf: out.appending(path: "blob.bin")) == big)
    }

    // MARK: repository

    @Test func corruptObjectIsKept() throws {
        let r = try repo()
        let data = Data("originale".utf8), h = sha256Hex(data)
        _ = try r.putObject(data, hash: h)
        let file = try #require(objectFile(r, h))
        try Data("rotto".utf8).write(to: file)
        #expect(throws: RepositoryError.corruptObject(h)) { try r.readObject(h) }
        #expect(fm.fileExists(atPath: file.path))
    }

    @Test func openExistingDoesNotCreate() throws {
        #expect(throws: RepositoryError.self) { try Repository(destination: dest, computerName: "Mac", create: false) }
        #expect(!fm.fileExists(atPath: dest.appending(path: "BackupMe").path))
    }

    @Test func staleLockTakeoverIsExclusive() throws {
        let lock = try repo().root.appending(path: "lock")
        let dest = self.dest
        var peak = 0
        for _ in 0..<200 {
            try Data(#"{"pid":1,"host":"Mac","boot":1}"#.utf8).write(to: lock)
            let inside = Counter()
            let group = DispatchGroup()
            for _ in 0..<4 {
                DispatchQueue.global().async(group: group) {
                    let r = try! Repository(destination: dest, computerName: "Mac")
                    try? r.withLock { inside.enter(); usleep(2000); inside.leave() }
                }
            }
            group.wait()
            peak = max(peak, inside.peak)
            try? fm.removeItem(at: lock)
        }
        #expect(peak <= 1)
    }

    @Test func gcSkippedWhenSnapshotVanished() throws {
        let refs = tmp()
        let r = try repo()
        write("v1", to: src.appending(path: "a.txt"))
        let first = try engine(r).run(sources: [src], now: t0)
        write("v2", to: src.appending(path: "a.txt"))
        _ = try engine(r).run(sources: [src], now: t0.addingTimeInterval(86400))
        write("v3", to: src.appending(path: "a.txt"))
        _ = try engine(r).run(sources: [src], now: t0.addingTimeInterval(2 * 86400))
        var keepAll = RetentionPolicy(); keepAll.days = 1000
        _ = try prune(repository: r, policy: keepAll, capBytes: nil, now: t0, refsCache: refs)
        // OneDrive re-sync: the first manifest is temporarily not listed
        let m = r.root.appending(path: "snapshots/\(first.snapshotID!).json.lzfse")
        let hidden = tmp().appending(path: "m")
        try fm.moveItem(at: m, to: hidden)
        var keepNewest = RetentionPolicy(); keepNewest.days = 0; keepNewest.weeks = 0; keepNewest.months = 0
        let result = try prune(repository: r, policy: keepNewest, capBytes: nil, now: t0.addingTimeInterval(9 * 86400), refsCache: refs)
        #expect(result.gcSkipped && result.vanished)
        #expect(r.hasObject(sha256Hex(Data("v1".utf8))))
    }

    @Test func manifestLeavingTwiceDoesNotBlockCleanupForever() throws {
        let refs = tmp()
        let r = try repo()
        write("v1", to: src.appending(path: "a.txt"))
        let first = try engine(r).run(sources: [src], now: t0)
        write("v2", to: src.appending(path: "a.txt"))
        _ = try engine(r).run(sources: [src], now: t0.addingTimeInterval(60))
        var keepAll = RetentionPolicy(); keepAll.days = 1000
        // a cap makes cleanup cache every manifest's references
        _ = try prune(repository: r, policy: keepAll, capBytes: .max, now: t0, refsCache: refs)
        let m = r.root.appending(path: "snapshots/\(first.snapshotID!).json.lzfse")
        let hidden = tmp().appending(path: "m")
        func leave(_ at: Date) throws { try fm.moveItem(at: m, to: hidden); _ = try prune(repository: r, policy: keepAll, capBytes: nil, now: at, refsCache: refs) }
        func back(_ at: Date) throws { try fm.moveItem(at: hidden, to: m); _ = try prune(repository: r, policy: keepAll, capBytes: nil, now: at, refsCache: refs) }
        try leave(t0.addingTimeInterval(3600))
        try back(t0.addingTimeInterval(7200))
        try leave(t0.addingTimeInterval(3 * 3600))
        _ = try prune(repository: r, policy: keepAll, capBytes: nil, now: t0.addingTimeInterval(2 * 86400), refsCache: refs)
        let later = try prune(repository: r, policy: keepAll, capBytes: nil, now: t0.addingTimeInterval(4 * 86400), refsCache: refs)
        #expect(!later.gcSkipped && !later.vanished)
    }

    @Test func recreatedArchiveWaitsWithoutWarning() throws {
        let refs = tmp()
        write("v1", to: src.appending(path: "a.txt"))
        let old = try repo()
        _ = try engine(old).run(sources: [src], now: t0)
        _ = try prune(repository: old, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs)
        // the user deletes the archive folder; the next backup makes a new one, with a new id
        try fm.removeItem(at: dest.appending(path: "BackupMe"))
        write("v2", to: src.appending(path: "a.txt"))
        let new = try repo()
        #expect(new.archiveID != nil)
        _ = try BackupEngine(repository: new, cache: HashCache(url: tmp().appending(path: "c.json")),
                             excludes: ExcludeRules(patterns: [])).run(sources: [src], now: t0.addingTimeInterval(3600))
        let first = try prune(repository: new, policy: RetentionPolicy(), capBytes: nil, now: t0.addingTimeInterval(3600), refsCache: refs)
        // told once, in the run that notices it: the archive may also have been moved away by a cloud client
        #expect(first.gcSkipped && !first.vanished && first.archiveReplaced)
        let again = try prune(repository: new, policy: RetentionPolicy(), capBytes: nil, now: t0.addingTimeInterval(7200), refsCache: refs)
        #expect(again.gcSkipped && !again.vanished && !again.archiveReplaced)
        let later = try prune(repository: new, policy: RetentionPolicy(), capBytes: nil, now: t0.addingTimeInterval(4 * 86400), refsCache: refs)
        #expect(!later.gcSkipped && !later.vanished)
    }

    // MARK: retention & schedule

    @Test func dueWhenLastSuccessInFuture() {
        #expect(isBackupDue(lastSuccess: t0.addingTimeInterval(30 * 86400), intervalHours: 1, now: t0))
    }

    @Test func retentionDecodesMissingKeys() throws {
        let p = try JSONDecoder().decode(RetentionPolicy.self, from: Data(#"{"days":3}"#.utf8))
        #expect(p.days == 3 && p.weeks == 8 && p.months == 12)
    }

    // MARK: restore

    func crafted(_ entries: [Entry], objects: [Data]) throws -> (Repository, Snapshot) {
        let r = try repo()
        for d in objects { _ = try r.putObject(d, hash: sha256Hex(d)) }
        let s = Snapshot(date: t0, sources: [src.path], entries: entries, warnings: [])
        try r.writeSnapshot(s)
        return (r, s)
    }

    func entry(_ path: String, _ kind: EntryKind, data: Data? = nil, link: String? = nil) -> Entry {
        Entry(source: src.path, path: path, kind: kind, hash: data.map(sha256Hex), size: Int64(data?.count ?? 0),
              mtime: t0, mode: kind == .directory ? 0o755 : 0o644, linkTarget: link)
    }

    @Test func traversalDotDotRejected() throws {
        let victim = base.appending(path: "victim.txt")
        write("prezioso", to: victim)
        let evil = Data("PWNED".utf8)
        let (r, s) = try crafted([entry("", .directory), entry("../victim.txt", .file, data: evil)], objects: [evil])
        #expect(throws: RestoreError.self) { try restorer(r).restore(s, source: src.path, path: "", mode: .into(tmp())) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "prezioso")
    }

    @Test func traversalViaSymlinkRejected() throws {
        let victimDir = tmp()
        let evil = Data("PWNED".utf8)
        let (r, s) = try crafted([entry("", .directory), entry("lnk", .symlink, link: victimDir.path),
                                  entry("lnk/x.txt", .file, data: evil)], objects: [evil])
        #expect(throws: RestoreError.self) { try restorer(r).restore(s, source: src.path, path: "", mode: .into(tmp())) }
        #expect(!fm.fileExists(atPath: victimDir.appending(path: "x.txt").path))
    }

    @Test func replaceSymlinkedRootRestoresRealFolder() throws {
        let real = base.appending(path: "reale", directoryHint: .isDirectory)
        write("vecchio", to: real.appending(path: "a.txt"))
        try fm.createSymbolicLink(at: src, withDestinationURL: real)
        let r = try repo()
        let report = try engine(r).run(sources: [src], now: t0)
        write("nuovo", to: real.appending(path: "a.txt"))
        try restorer(r, trash: { try FileManager.default.moveItem(at: $0, to: tmp().appending(path: "t")) })
            .restore(try r.readSnapshot(report.snapshotID!), source: src.path, path: "", mode: .replace)
        #expect(try String(contentsOf: real.appending(path: "a.txt"), encoding: .utf8) == "vecchio")
        #expect((try? fm.destinationOfSymbolicLink(atPath: src.path)) != nil)
    }

    @Test func stagingCleanedWhenTrashFails() throws {
        write("a", to: src.appending(path: "a.txt"))
        let r = try repo()
        let report = try engine(r).run(sources: [src], now: t0)
        let s = try r.readSnapshot(report.snapshotID!)
        #expect(throws: (any Error).self) {
            try restorer(r, trash: { _ in throw CocoaError(.featureUnsupported) }).restore(s, source: src.path, path: "", mode: .replace)
        }
        let leftovers = try fm.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".backupme-restore") }
        #expect(leftovers.isEmpty)
        #expect(fm.fileExists(atPath: src.appending(path: "a.txt").path))
    }

    @Test func restoredFilesAreUnchanged() throws {
        for i in 0..<20 { write("f\(i)", to: src.appending(path: "f\(i).txt")) }
        let r = try repo()
        let report = try engine(r).run(sources: [src], now: t0)
        let s = try r.readSnapshot(report.snapshotID!)
        try restorer(r, trash: { try FileManager.default.moveItem(at: $0, to: tmp().appending(path: "t")) })
            .restore(s, source: src.path, path: "", mode: .replace)
        #expect(s.entries.filter { $0.kind == .file }.allSatisfy { Restorer.status(of: $0) == .unchanged })
    }

    @Test func versionsSkipUnreadableManifest() throws {
        let r = try repo()
        var ids: [String] = []
        for i in 0..<3 {
            write("v\(i)", to: src.appending(path: "a.txt"))
            ids.append(try engine(r).run(sources: [src], now: t0.addingTimeInterval(Double(i) * 3600)).snapshotID!)
        }
        try Data("garbage".utf8).write(to: r.root.appending(path: "snapshots/\(ids[1]).json.lzfse"))
        #expect(try restorer(r).versions(source: src.path, path: "a.txt").count == 2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var peak = 0
    func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
}
