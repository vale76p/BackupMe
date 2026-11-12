import Foundation
import Testing
@testable import BackupCore

@Suite struct PackMaintenanceTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let cacheURL = tmp().appending(path: "cache.json")
    let refs = tmp()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let day: TimeInterval = 86400
    let keepNewestOnly: RetentionPolicy = { var p = RetentionPolicy(); p.days = 0; p.weeks = 0; p.months = 0; return p }()
    let keepAll: RetentionPolicy = { var p = RetentionPolicy(); p.days = 1000; return p }()

    func open(packBelow: Int = 0) throws -> Repository { try Repository(destination: dest, computerName: "Mac", packBelow: packBelow) }

    @discardableResult
    func backup(_ files: [String: Data], at date: Date, packBelow: Int = 0,
                condemned: Set<String> = []) throws -> (repo: Repository, report: BackupReport) {
        try? FileManager.default.removeItem(at: src)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: src.appending(path: name)) }
        let repo = try open(packBelow: packBelow)
        repo.condemned = condemned
        let report = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src], now: date)
        return (repo, report)
    }

    func clean(_ repo: Repository, _ policy: RetentionPolicy, at now: Date, max: Int? = nil, cap: Int64? = nil,
               forceGC: Bool = false, gcDue: Bool = true, confirmed: ((String) -> Bool)? = nil) throws -> PruneResult {
        var o = CleanupOptions()
        o.maxDeletions = max
        o.confirmed = confirmed
        return try prune(repository: repo, policy: policy, capBytes: cap, now: now, refsCache: refs, forceGC: forceGC,
                         gcDue: gcDue, options: o)
    }

    func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

    func orphan(_ repo: Repository, _ text: String) throws -> String {
        let data = Data(text.utf8), h = sha256Hex(data)
        _ = try repo.putObject(data, hash: h)
        return h
    }

    /// The backup restores with exactly these files.
    func restores(_ repo: Repository, _ id: String?, _ files: [String: Data]) throws -> Bool {
        let snap = try repo.readSnapshot(try #require(id))
        let dir = try Restorer(repository: repo).restore(snap, source: src.path, path: "", mode: .into(tmp()))
        return try files.allSatisfy { try Data(contentsOf: dir.appending(path: $0.key)) == $0.value }
    }

    func manifest(_ repo: Repository, _ id: String) -> URL { repo.root.appending(path: "snapshots/\(id).json.lzfse") }

    @Test func budgetIsNeverExceededAndTheRestWaits() throws {
        var repo: Repository!
        var newest: [String: Data] = [:], newestID: String?
        for i in 0..<6 {
            newest = ["f\(i).txt": Data("file \(i)".utf8)]
            (repo, _) = try backup(newest, at: t0.addingTimeInterval(Double(i) * day))
            newestID = try repo.snapshotIDs().last
        }
        let now = t0.addingTimeInterval(5 * day)
        // 5 manifests and 5 objects leave: 3 per call, the rest at the next call
        var counts: [Int] = []
        for _ in 0..<5 { counts.append(try clean(repo, keepNewestOnly, at: now, max: 3).deletedFiles) }
        #expect(counts == [3, 3, 3, 1, 0])
        #expect(try repo.snapshotIDs() == [try #require(newestID)])
        #expect(try repo.allObjectHashes() == [sha256Hex(Data("file 5".utf8))])
        #expect(try restores(repo, newestID, newest))
    }

    @Test func hourlyRunsUseThePlanWithoutReadingOldManifests() throws {
        let repo = try backup(["a.txt": Data("a".utf8)], at: t0).repo
        try backup(["b.txt": Data("b".utf8)], at: t0.addingTimeInterval(3600))
        let orphans = try (0..<5).map { try orphan(repo, "orfano \($0)") }
        let first = try clean(repo, keepAll, at: t0.addingTimeInterval(3600), max: 2, forceGC: true)
        #expect(first.collected && first.deletedFiles == 2 && first.deletedObjects == 2)
        let oldest = try #require(try repo.snapshotIDs().first)
        try Data("garbage".utf8).write(to: manifest(repo, oldest))
        try FileManager.default.removeItem(at: refs.appending(path: oldest))
        let hourly = try clean(repo, keepAll, at: t0.addingTimeInterval(7200), max: 2, gcDue: false)
        #expect(!hourly.collected && hourly.deletedFiles == 2)
        #expect(orphans.filter { objectFile(repo, $0) != nil }.count == 1)
    }

    /// Each file of an object counts: one stored in both forms costs 2, and the form the budget leaves waits in the plan.
    @Test func bothFormsOfAnObjectCountAgainstTheBudget() throws {
        let repo = try backup(["a.txt": Data("a".utf8)], at: t0).repo
        let text = String(repeating: "si comprime bene ", count: 200), source = tmp().appending(path: "o.txt")
        write(text, to: source)
        let h = try orphan(repo, text)
        _ = try repo.putObjectFile(from: source, hash: h)
        let forms = ["lzfse", "raw"].map { repo.root.appending(path: "objects/\(h.prefix(2))/\(h).\($0)") }
        try #require(forms.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let first = try clean(repo, keepAll, at: t0, max: 1, forceGC: true)
        #expect(first.deletedFiles == 1 && first.deletedObjects == 0)
        #expect(forms.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
        #expect(condemnedObjects(refsCache: refs).contains(h))
        let second = try clean(repo, keepAll, at: t0, max: 1, gcDue: false)
        #expect(second.deletedFiles == 1 && second.deletedObjects == 1 && objectFile(repo, h) == nil)
        #expect(!condemnedObjects(refsCache: refs).contains(h))
    }

    @Test func noPlanNoObjectDeletion() throws {
        let repo = try backup(["a.txt": Data("a".utf8)], at: t0).repo
        let h = try orphan(repo, "orfano")
        let r = try clean(repo, keepAll, at: t0, gcDue: false)
        #expect(r.deletedFiles == 0 && objectFile(repo, h) != nil)
        #expect(!FileManager.default.fileExists(atPath: refs.appending(path: "cleanup").path))
    }

    @Test func objectReusedByANewBackupIsNotDeleted() throws {
        let x = Data("contenuto X".utf8)
        try backup(["x.txt": x], at: t0)
        let repo = try backup(["y.txt": Data("y".utf8)], at: t0.addingTimeInterval(day)).repo
        let collection = try clean(repo, keepNewestOnly, at: t0.addingTimeInterval(day), max: 1)
        #expect(collection.collected && collection.deletedFiles == 1 && objectFile(repo, sha256Hex(x)) != nil)
        #expect(condemnedObjects(refsCache: refs) == [sha256Hex(x)])
        let (again, report) = try backup(["z.txt": x], at: t0.addingTimeInterval(day + 3600))
        #expect(report.newBytes == 0) // X reused: the backup was not told it is condemned
        let r = try clean(again, keepNewestOnly, at: t0.addingTimeInterval(day + 3600), gcDue: false)
        #expect(r.deletedFiles == 0 && objectFile(again, sha256Hex(x)) != nil)
        #expect(try restores(again, report.snapshotID, ["z.txt": x]))
    }

    @Test func condemnedObjectIsStoredAgain() throws {
        let x = Data("contenuto X".utf8)
        try backup(["x.txt": x], at: t0)
        let repo = try backup(["y.txt": Data("y".utf8)], at: t0.addingTimeInterval(day)).repo
        _ = try clean(repo, keepNewestOnly, at: t0.addingTimeInterval(day), max: 1)
        let (again, report) = try backup(["z.txt": x], at: t0.addingTimeInterval(day + 3600),
                                         condemned: condemnedObjects(refsCache: refs))
        #expect(report.newBytes > 0)
        let r = try clean(again, keepNewestOnly, at: t0.addingTimeInterval(day + 3600), gcDue: false)
        #expect(r.deletedFiles == 0 && objectFile(again, sha256Hex(x)) != nil)
        #expect(try restores(again, report.snapshotID, ["z.txt": x]))
    }

    @Test func deadContainerCostsTwoAndWaitsForRoom() throws {
        let p = Repository.packThreshold
        try backup(["a.txt": Data("vecchio".utf8)], at: t0, packBelow: p)
        let (repo, report) = try backup(["b.txt": Data("nuovo".utf8)], at: t0.addingTimeInterval(day), packBelow: p)
        let ids = try repo.packIDs()
        try #require(ids.count == 2)
        let now = t0.addingTimeInterval(day)
        #expect(try clean(repo, keepNewestOnly, at: now, max: 1).deletedFiles == 1) // the expired manifest only
        #expect(try clean(repo, keepNewestOnly, at: now, max: 1, gcDue: false).deletedFiles == 0)
        #expect(try repo.packIDs() == ids)
        let r = try clean(repo, keepNewestOnly, at: now, max: 2, gcDue: false)
        #expect(r.deletedFiles == 2 && r.deletedObjects == 0)
        #expect(try repo.packIDs() == [ids[1]])
        #expect(!FileManager.default.fileExists(atPath: repo.root.appending(path: "packs/\(ids[0]).idx").path))
        #expect(try restores(repo, report.snapshotID, ["b.txt": Data("nuovo".utf8)]))
    }

    @Test func oldContainerWaitsForTheOneHoldingTheCopy() throws {
        let files = ["a.txt": Data("uno".utf8), "b.txt": Data("due".utf8)]
        let (repo, report) = try backup(files, at: t0, packBelow: Repository.packThreshold)
        let old = try #require(try repo.packIDs().first)
        try repo.repack(files.values.map(sha256Hex))
        let ids = try repo.packIDs()
        try #require(ids.count == 2)
        let loose = try orphan(try open(), "orfano singolo")
        let waiting = try clean(repo, keepAll, at: t0, forceGC: true, confirmed: { _ in false })
        #expect(waiting.deletedFiles == 1 && waiting.deletedObjects == 1 && objectFile(repo, loose) == nil)
        #expect(try repo.packIDs() == ids)
        let r = try clean(repo, keepAll, at: t0, gcDue: false, confirmed: { _ in true })
        #expect(r.deletedFiles == 2)
        #expect(try repo.packIDs() == [ids[1]] && ids[1] != old)
        // outside a cloud folder a container is relied on at once
        #expect(repo.packIsConfirmed(ids[1], now: t0))
        #expect(try restores(try open(), report.snapshotID, files))
    }

    @Test func vanishedBackupsStopObjectDeletions() throws {
        try backup(["a.txt": Data("a".utf8)], at: t0)
        try backup(["b.txt": Data("b".utf8)], at: t0.addingTimeInterval(day))
        let repo = try backup(["c.txt": Data("c".utf8)], at: t0.addingTimeInterval(2 * day)).repo
        let h = try orphan(repo, "orfano")
        _ = try clean(repo, keepAll, at: t0.addingTimeInterval(2 * day), max: 0, forceGC: true) // a plan condemning the orphan
        let ids = try repo.snapshotIDs()
        try FileManager.default.moveItem(at: manifest(repo, ids[1]), to: tmp().appending(path: "m"))
        let r = try clean(repo, keepNewestOnly, at: t0.addingTimeInterval(2 * day), forceGC: true)
        #expect(r.gcSkipped && r.deletedSnapshots == [ids[0]] && r.deletedFiles == 1 && r.deletedObjects == 0)
        #expect(objectFile(repo, h) != nil && objectFile(repo, sha256Hex(Data("a".utf8))) != nil)
    }

    @Test func unreadableNewManifestSkipsTheRun() throws {
        let repo = try backup(["a.txt": Data("a".utf8)], at: t0).repo
        let h = try orphan(repo, "orfano")
        _ = try clean(repo, keepAll, at: t0, max: 0, forceGC: true)
        let report = try backup(["b.txt": Data("b".utf8)], at: t0.addingTimeInterval(3600)).report
        try Data("garbage".utf8).write(to: manifest(repo, try #require(report.snapshotID)))
        let r = try clean(repo, keepAll, at: t0.addingTimeInterval(3600), gcDue: false)
        #expect(r.deletedFiles == 0 && objectFile(repo, h) != nil)
    }

    @Test func capStoppedByTheBudgetIsPending() throws {
        var repo: Repository!
        for i in 0..<3 { repo = try backup(["f\(i).bin": random(4000)], at: t0.addingTimeInterval(Double(i) * 3600)).repo }
        let now = t0.addingTimeInterval(7200)
        let limited = try clean(repo, keepAll, at: now, max: 1, cap: 1)
        #expect(limited.deletedSnapshots.count == 1 && limited.capPending && limited.overCap)
        let unlimited = try clean(repo, keepAll, at: now, cap: 1)
        #expect(unlimited.deletedSnapshots.count == 1 && !unlimited.capPending && unlimited.overCap)
        #expect(try repo.snapshotIDs().count == 1)
    }

    @Test func cleanupFileIsNotTakenForABackup() throws {
        let repo = try backup(["a.txt": Data("a".utf8)], at: t0).repo
        _ = try orphan(repo, "orfano")
        #expect(try clean(repo, keepAll, at: t0, forceGC: true).collected)
        #expect(FileManager.default.fileExists(atPath: refs.appending(path: "cleanup").path))
        let next = try clean(repo, keepAll, at: t0.addingTimeInterval(3600))
        #expect(!next.vanished && !next.gcSkipped)
    }

    /// Cut short, its index no longer reaches its end: what it held can't be judged, so it is never deleted.
    @Test func containerWithoutAWholeIndexIsNeverDeleted() throws {
        let p = Repository.packThreshold
        try backup(["a.txt": Data("vecchio".utf8)], at: t0, packBelow: p)
        let repo = try backup(["b.txt": Data("nuovo".utf8)], at: t0.addingTimeInterval(day), packBelow: p).repo
        let ids = try repo.packIDs()
        let pack = repo.root.appending(path: "packs/\(ids[0]).pack")
        try Data(contentsOf: pack).dropLast(1).write(to: pack)
        let again = try open(packBelow: p)
        _ = try clean(again, keepNewestOnly, at: t0.addingTimeInterval(day))
        let r = try clean(again, keepNewestOnly, at: t0.addingTimeInterval(day), forceGC: true)
        #expect(try r.deletedFiles == 0 && again.packIDs() == ids)
    }
}
