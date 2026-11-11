import Foundation
import Testing
@testable import BackupCore

@Suite struct PrunerTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let cacheURL = tmp().appending(path: "cache.json")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let keepNewestOnly: RetentionPolicy = { var p = RetentionPolicy(); p.days = 0; p.weeks = 0; p.months = 0; return p }()
    let keepAll: RetentionPolicy = { var p = RetentionPolicy(); p.days = 1000; return p }()

    func backup(_ files: [String: Data], at date: Date) throws -> Repository {
        try? FileManager.default.removeItem(at: src)
        for (name, data) in files {
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try data.write(to: src.appending(path: name))
        }
        let repo = try Repository(destination: dest, computerName: "Mac")
        _ = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                             excludes: ExcludeRules(patterns: [])).run(sources: [src], now: date)
        return repo
    }

    func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

    @Test func deletesExpiredSnapshotsAndTheirObjects() throws {
        let shared = Data("condiviso".utf8), old = Data("vecchio".utf8), new = Data("nuovo".utf8)
        _ = try backup(["s.txt": shared, "v.txt": old], at: t0)
        let repo = try backup(["s.txt": shared, "n.txt": new], at: t0.addingTimeInterval(30 * 86400))
        let r = try prune(repository: repo, policy: keepNewestOnly, capBytes: nil, now: t0.addingTimeInterval(30 * 86400))
        #expect(r.deletedSnapshots == [Snapshot.id(for: t0)])
        #expect(try repo.allObjectHashes() == [sha256Hex(shared), sha256Hex(new)])
        #expect(r.deletedObjects == 1)
    }

    @Test func pinnedSnapshotSurvivesRetentionAndCap() throws {
        let complete = Snapshot.id(for: t0)
        _ = try backup(["a.txt": random(4000)], at: t0)
        _ = try backup(["b.txt": random(4000)], at: t0.addingTimeInterval(86400))
        let repo = try backup(["c.txt": random(4000)], at: t0.addingTimeInterval(2 * 86400))
        let now = t0.addingTimeInterval(2 * 86400)
        let r = try prune(repository: repo, policy: keepNewestOnly, capBytes: 1, now: now, pinned: [complete])
        #expect(try repo.snapshotIDs() == [complete, Snapshot.id(for: now)])
        #expect(r.deletedSnapshots == [Snapshot.id(for: t0.addingTimeInterval(86400))])
    }

    @Test func orphanObjectsFromInterruptedBackupRemoved() throws {
        let repo = try backup(["a.txt": Data("a".utf8)], at: t0)
        let orphan = Data("orfano".utf8)
        _ = try repo.putObject(orphan, hash: sha256Hex(orphan))
        let tmpFile = repo.root.appending(path: "objects/zz/x.lzfse.tmp")
        write("t", to: tmpFile)
        _ = try prune(repository: repo, policy: keepAll, capBytes: nil, now: t0, forceGC: true)
        #expect(!repo.hasObject(sha256Hex(orphan)))
        #expect(try repo.allObjectHashes() == [sha256Hex(Data("a".utf8))])
        #expect(!FileManager.default.fileExists(atPath: tmpFile.path))
    }

    /// What the app relies on since it stopped forcing collection after a failed backup: ordinary cleanup leaves
    /// the objects of a run without a manifest, the next backup uses them without copying, and the cap still wins.
    @Test func objectsOfFailedRunSurviveCleanupAndAreReused() throws {
        let repo = try backup(["a.txt": Data("a".utf8)], at: t0)
        let copied = random(4000)
        _ = try repo.putObject(copied, hash: sha256Hex(copied)) // a run that failed before writing its manifest
        let kept = try prune(repository: repo, policy: keepAll, capBytes: nil, now: t0)
        #expect(!kept.collected && kept.deletedObjects == 0 && repo.hasObject(sha256Hex(copied)))

        try copied.write(to: src.appending(path: "b.bin"))
        let next = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: []))
            .run(sources: [src], now: t0.addingTimeInterval(3600))
        #expect(next.newBytes == 0 && next.error == nil)

        let orphan = random(4000)
        _ = try repo.putObject(orphan, hash: sha256Hex(orphan))
        let over = try prune(repository: repo, policy: keepAll, capBytes: 6000, now: t0.addingTimeInterval(3600))
        #expect(over.collected && !repo.hasObject(sha256Hex(orphan)) && repo.hasObject(sha256Hex(copied)))
    }

    @Test func capDeletesOldestUntilUnder() throws {
        var repo: Repository!
        for i in 0..<3 { repo = try backup(["f\(i).bin": random(1_000_000)], at: t0.addingTimeInterval(Double(i) * 3600)) }
        let cap: Int64 = 2_500_000
        let r = try prune(repository: repo, policy: keepAll, capBytes: cap, now: t0.addingTimeInterval(7200))
        #expect(r.deletedSnapshots == [Snapshot.id(for: t0)])
        #expect(try repo.snapshotIDs().count == 2)
        #expect(r.poolSize <= cap)
        #expect(!r.overCap)
    }

    @Test func capNeverDeletesNewest() throws {
        var repo: Repository!
        for i in 0..<2 { repo = try backup(["f\(i).bin": random(1000)], at: t0.addingTimeInterval(Double(i) * 3600)) }
        let r = try prune(repository: repo, policy: keepAll, capBytes: 1, now: t0.addingTimeInterval(3600))
        #expect(try repo.snapshotIDs() == [Snapshot.id(for: t0.addingTimeInterval(3600))])
        #expect(r.overCap)
    }

    @Test func missingObjectsCounted() throws {
        let gone = Data("sparito".utf8)
        let repo = try backup(["a.txt": Data("a".utf8), "b.txt": gone], at: t0)
        try FileManager.default.removeItem(at: objectFile(repo, sha256Hex(gone))!)
        #expect(try prune(repository: repo, policy: keepAll, capBytes: nil, now: t0).missingObjects == 0) // no cleanup ran
        #expect(try prune(repository: repo, policy: keepAll, capBytes: nil, now: t0, forceGC: true).missingObjects == 1)
    }
}
