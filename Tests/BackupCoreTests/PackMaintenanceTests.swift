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
                condemned: Set<String> = [], adding: Bool = false) throws -> (repo: Repository, report: BackupReport) {
        // adding: `files` change or join those of the last backup
        if !adding { try? FileManager.default.removeItem(at: src) }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: src.appending(path: name)) }
        let repo = try open(packBelow: packBelow)
        repo.condemned = condemned
        let report = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src], now: date)
        return (repo, report)
    }

    func clean(_ repo: Repository, _ policy: RetentionPolicy, at now: Date, max: Int? = nil, cap: Int64? = nil,
               forceGC: Bool = false, gcDue: Bool = true, convert: Bool = false,
               confirmed: ((String) -> Bool)? = nil) throws -> PruneResult {
        var o = CleanupOptions()
        o.maxDeletions = max
        o.convert = convert
        o.confirmed = confirmed
        return try prune(repository: repo, policy: policy, capBytes: cap, now: now, refsCache: refs, forceGC: forceGC,
                         gcDue: gcDue, options: o)
    }

    func random(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, n) }
        return d
    }

    func named(_ files: [Data], _ prefix: String = "f") -> [String: Data] {
        Dictionary(uniqueKeysWithValues: files.enumerated().map { ("\(prefix)\($0.offset)", $0.element) })
    }

    /// A container of 1000-byte objects from a first backup, of which a second, a day later, uses the first `used`.
    func sharedContainer(_ n: Int, used: Int) throws -> (repo: Repository, files: [Data], report: BackupReport) {
        let files = (0..<n).map { _ in random(1000) }, p = Repository.packThreshold
        try backup(named(files), at: t0, packBelow: p)
        let (repo, report) = try backup(named(Array(files.prefix(used))), at: t0.addingTimeInterval(day), packBelow: p)
        try #require(try repo.packIDs().count == 1)
        return (repo, files, report)
    }

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

    /// Two containers with the same objects, the newer one holding the copies that count.
    func repackedTwice() throws -> (repo: Repository, ids: [String], files: [String: Data], newer: URL) {
        let files = named((0..<3).map { _ in random(1000) })
        let repo = try backup(files, at: t0, packBelow: Repository.packThreshold).repo
        try repo.repack(files.values.map(sha256Hex))
        let ids = try repo.packIDs()
        try #require(ids.count == 2)
        return (repo, ids, files, repo.root.appending(path: "packs/\(ids[1]).pack"))
    }

    @Test func oldContainerStaysWhileTheCopyThatCountsDoesNotVerify() throws {
        let (repo, ids, files, newer) = try repackedTwice()
        let (name, data) = try #require(files.first)
        let e = try #require(try repo.packEntries(ids[1]).first { $0.hash == sha256Hex(data) })
        let intact = try Data(contentsOf: newer)
        var bytes = intact
        bytes[e.offset] ^= 0xff
        try bytes.write(to: newer)
        let again = try open(packBelow: Repository.packThreshold)
        _ = try clean(again, keepAll, at: t0, forceGC: true)
        #expect(try again.packIDs() == ids)
        #expect(try open().readObject(sha256Hex(data)) == data, "\(name) reads from the old copy")
        try intact.write(to: newer)
        _ = try clean(try open(packBelow: Repository.packThreshold), keepAll, at: t0, gcDue: false)
        #expect(try open().packIDs() == [ids[1]])
    }

    @Test func oldContainerStaysWhileTheCopyThatCountsIsOutOfReach() throws {
        let (_, ids, _, newer) = try repackedTwice()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: newer.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: newer.path) }
        _ = try clean(try open(packBelow: Repository.packThreshold), keepAll, at: t0, forceGC: true)
        #expect(try open().packIDs() == ids)
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

    // MARK: compaction

    @Test func halfDeadContainerIsRewrittenThenRemoved() throws {
        let (repo, files, report) = try sharedContainer(4, used: 1)
        let old = try repo.packIDs()
        for _ in 0..<2 { _ = try clean(repo, keepNewestOnly, at: t0.addingTimeInterval(day)) }
        let again = try open()
        let ids = try again.packIDs()
        #expect(ids.count == 1 && ids != old)
        #expect(try again.readObject(sha256Hex(files[0])) == files[0])
        #expect(try again.allObjectHashes().isDisjoint(with: files.dropFirst().map(sha256Hex)))
        #expect(try restores(again, report.snapshotID, named([files[0]])))
    }

    @Test func eightSmallContainersAreMergedSevenAreNot() throws {
        var repo: Repository!, files: [String: Data] = [:], kept: [(id: String?, files: [String: Data])] = []
        func add(_ i: Int) throws {
            files["f\(i)"] = random(1000)
            let r = try backup(files, at: t0.addingTimeInterval(Double(i) * 3600), packBelow: Repository.packThreshold)
            repo = r.repo
            kept.append((r.report.snapshotID, files))
        }
        for i in 0..<7 { try add(i) }
        let seven = try repo.packIDs()
        try #require(seven.count == 7)
        let now = t0.addingTimeInterval(day)
        _ = try clean(repo, keepAll, at: now, forceGC: true)
        _ = try clean(repo, keepAll, at: now, gcDue: false)
        #expect(try repo.packIDs() == seven)
        try add(7)
        _ = try clean(repo, keepAll, at: now, gcDue: false)
        #expect(try repo.packIDs().count == 9) // the merged one, the old ones waiting for the next call
        _ = try clean(repo, keepAll, at: now, gcDue: false)
        #expect(try repo.packIDs().count == 1)
        for k in kept { #expect(try restores(try open(), k.id, k.files)) }
    }

    @Test func containerWithACorruptLiveObjectIsLeftAlone() throws {
        let (repo, files, _) = try sharedContainer(4, used: 1)
        let id = try #require(try repo.packIDs().first), h = sha256Hex(files[0])
        let e = try #require(try repo.packEntries(id).first { $0.hash == h })
        let url = repo.root.appending(path: "packs/\(id).pack")
        var data = try Data(contentsOf: url)
        data[e.offset] ^= 0xff
        try data.write(to: url)
        let again = try open(packBelow: Repository.packThreshold)
        for _ in 0..<2 { _ = try clean(again, keepNewestOnly, at: t0.addingTimeInterval(day)) }
        #expect(try again.packIDs() == [id])
        #expect(try again.allObjectHashes().contains(h))
    }

    @Test func interruptedCompactionHealsItself() throws {
        let files = (0..<4).map { _ in random(1000) }, p = Repository.packThreshold
        let first = try backup(named(files), at: t0, packBelow: p).report
        let (repo, second) = try backup(named(Array(files.prefix(2))), at: t0.addingTimeInterval(3600), packBelow: p)
        let old = try repo.packIDs()
        try repo.repack(files.map(sha256Hex)) // a compaction that stopped right after publishing
        for _ in 0..<2 { _ = try clean(repo, keepAll, at: t0.addingTimeInterval(3600), forceGC: true) }
        let again = try open()
        let ids = try again.packIDs()
        #expect(ids.count == 1 && !old.contains(ids[0]))
        #expect(try restores(again, first.snapshotID, named(files)))
        #expect(try restores(again, second.snapshotID, named(Array(files.prefix(2)))))
    }

    @Test func overTheCapEveryDeadByteIsReclaimed() throws {
        let (repo, files, report) = try sharedContainer(5, used: 4)
        let old = try repo.packIDs(), now = t0.addingTimeInterval(day)
        let roomy = try repo.poolSize() + 1_000_000
        for _ in 0..<2 { _ = try clean(repo, keepNewestOnly, at: now, cap: roomy) }
        #expect(try repo.packIDs() == old) // 80% live and it fits: left alone
        let cap = try repo.poolSize() - 500
        let over = try clean(repo, keepNewestOnly, at: now, cap: cap)
        #expect(over.deletedSnapshots.isEmpty)
        _ = try clean(repo, keepNewestOnly, at: now, cap: cap)
        let ids = try repo.packIDs()
        #expect(ids.count == 1 && ids != old)
        #expect(try restores(try open(), report.snapshotID, named(Array(files.prefix(4)))))
    }

    // MARK: conversion

    @Test func conversionMovesSmallFilesWithinTheBudget() throws {
        let big = random(5 << 20)
        var files = named((0..<30).map { _ in random(2000) })
        files["big"] = big
        let report = try backup(files, at: t0).report
        let repo = try open(packBelow: Repository.packThreshold)
        var left: Int?, calls = 0
        repeat {
            let r = try clean(repo, keepAll, at: t0, max: 5, convert: true)
            #expect(r.deletedFiles <= 5)
            #expect(try restores(try open(), report.snapshotID, files))
            #expect(objectFile(repo, sha256Hex(big)) != nil)
            left = r.smallFilesLeft
            calls += 1
        } while left != 0 && calls < 20
        #expect(left == 0)
        #expect(try repo.packIDs().count == 1)
    }

    @Test func conversionWritesOneContainerAtATime() throws {
        // nine files just under the threshold: eight fill a container, the ninth waits for the next one
        let files = named((0..<9).map { _ in random(Repository.packThreshold - (64 << 10)) })
        let report = try backup(files, at: t0).report
        let repo = try open(packBelow: Repository.packThreshold)
        var counts: [Int] = []
        for _ in 0..<3 {
            #expect(try clean(repo, keepAll, at: t0, convert: true, confirmed: { _ in false }).deletedFiles == 0)
            counts.append(try repo.packIDs().count)
        }
        #expect(counts == [1, 1, 1])
        #expect(files.values.allSatisfy { objectFile(repo, sha256Hex($0)) != nil })
        // once relied on, the copies leave and the next container follows
        #expect(try clean(repo, keepAll, at: t0, convert: true, confirmed: { _ in true }).deletedFiles == 8)
        #expect(try repo.packIDs().count == 2)
        #expect(try restores(try open(), report.snapshotID, files))
    }

    @Test func condemnedSmallFilesAreNotConverted() throws {
        let report = try backup(["a.txt": Data("a".utf8)], at: t0).report
        let h = try orphan(try open(), "orfano piccolo")
        let repo = try open(packBelow: Repository.packThreshold)
        for _ in 0..<3 { _ = try clean(repo, keepAll, at: t0, max: 0, convert: true) }
        let again = try open()
        #expect(try again.packIDs().count == 1) // a.txt went into one
        #expect(condemnedObjects(refsCache: refs).contains(h))
        #expect(again.packOf(h) == nil && objectFile(again, h) != nil)
        _ = try clean(repo, keepAll, at: t0, convert: true)
        #expect(try open().packOf(h) == nil && objectFile(again, h) == nil)
        #expect(try restores(try open(), report.snapshotID, ["a.txt": Data("a".utf8)]))
    }

    /// A file written to repair a damaged copy in a container is the good one: never deleted as a duplicate.
    @Test func repairedFileIsNotTakenForADuplicate() throws {
        let data = random(2000), h = sha256Hex(data)
        let report = try backup(["a.bin": data], at: t0, packBelow: Repository.packThreshold).report
        let repo = try open(packBelow: Repository.packThreshold)
        let id = try #require(try repo.packIDs().first)
        let url = repo.root.appending(path: "packs/\(id).pack")
        var bytes = try Data(contentsOf: url)
        bytes[try #require(try repo.packEntries(id).first).offset] ^= 0xff
        try bytes.write(to: url)
        let source = tmp().appending(path: "a.bin")
        try data.write(to: source)
        #expect(try repo.repairObject(h, from: source))
        for _ in 0..<2 { #expect(try clean(repo, keepAll, at: t0, convert: true).deletedFiles == 0) }
        #expect(objectFile(repo, h) != nil)
        #expect(try restores(try open(), report.snapshotID, ["a.bin": data]))
    }

    @Test func conversionNeverCostsABackup() throws {
        let other = PackMaintenanceTests(), data = (0..<6).map { _ in random(3000) }
        var deleted: [[String]] = [[], []], converted = false
        for (i, d) in data.enumerated() {
            let at = t0.addingTimeInterval(Double(i) * 3600)
            for (k, s) in [self, other].enumerated() {
                try s.backup(["f.bin": d], at: at)
                let repo = try s.open(packBelow: Repository.packThreshold)
                deleted[k] += try s.clean(repo, keepAll, at: at, cap: 10_000, convert: k == 0).deletedSnapshots
                if k == 0, try !repo.packIDs().isEmpty { converted = true }
            }
        }
        #expect(converted && !deleted[0].isEmpty)
        #expect(deleted[0] == deleted[1])
        #expect(try open().snapshotIDs() == other.open().snapshotIDs())
    }

    @Test func aFortnightOfHourlyBackupsStaysUnderFiftyAnHour() throws {
        var files = named((0..<40).map { _ in random(500) })
        var ledger = DeletionLedger(), calls: [(at: Date, files: Int)] = [], reachedZero = false, lastGC: Date?
        var o = CleanupOptions()
        o.convert = true
        for hour in 0..<(14 * 24) {
            let at = t0.addingTimeInterval(Double(hour) * 3600)
            var changed = hour == 0 ? files : [:]
            for i in 0..<6 where hour > 0 { changed["f\((hour * 6 + i) % 40)"] = random(500) }
            files.merge(changed) { $1 }
            // the first day without containers, as an archive made by an earlier version
            let (repo, report) = try backup(changed, at: at, packBelow: hour < 24 ? 0 : Repository.packThreshold,
                                            condemned: condemnedObjects(refsCache: refs), adding: hour > 0)
            // after the backup, then after each of 3 failed attempts 15 minutes apart
            for attempt in 0..<4 {
                let now = at.addingTimeInterval(Double(attempt) * 900)
                o.maxDeletions = ledger.allowance(limit: 50, now: now)
                // as the app: a day after the last collection
                let r = try prune(repository: repo, policy: RetentionPolicy(), capBytes: nil, now: now, refsCache: refs,
                                  gcDue: lastGC.map { now.timeIntervalSince($0) > day } ?? true, options: o)
                if r.collected { lastGC = now }
                ledger.record(r.deletedFiles, at: now)
                calls.append((now, r.deletedFiles))
                if r.smallFilesLeft == 0 { reachedZero = true }
            }
            #expect(try restores(repo, report.snapshotID, files))
        }
        for c in calls {
            let hour = calls.filter { $0.at <= c.at && c.at.timeIntervalSince($0.at) <= 3600 }.reduce(0) { $0 + $1.files }
            #expect(hour <= 50)
        }
        #expect(reachedZero)
        #expect(calls.reduce(0) { $0 + $1.files } > 0)
    }

    @Test func conversionEndFollowsTheRealPace() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(conversionEnd(startCount: 1000, startDate: t, left: 1000, now: t.addingTimeInterval(86400)) == nil)
        #expect(conversionEnd(startCount: 1000, startDate: t, left: 750, now: t.addingTimeInterval(86400)) == t.addingTimeInterval(4 * 86400))
    }
}
