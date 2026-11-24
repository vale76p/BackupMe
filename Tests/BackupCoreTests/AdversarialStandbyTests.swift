import Foundation
import Testing
@testable import BackupCore

/// Adversarial review "standby": reads of the archive that fail for a moment after a sleep (a cloud file being
/// downloaded again, a volume reconnecting) must never be taken for damage, let alone delete a sound backup.
@Suite(.serialized) struct AdversarialStandbyTests {
    let dest = tmp()
    let src = tmp()
    let cacheURL = tmp().appending(path: "cache.json")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func engine(_ r: Repository) -> BackupEngine {
        BackupEngine(repository: r, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: []))
    }

    /// Three sound backups, an hour apart.
    func backups(packBelow: Int = 0) throws -> Repository {
        let r = try Repository(destination: dest, computerName: "Mac", packBelow: packBelow)
        for i in 0..<3 {
            write("contenuto \(i)", to: src.appending(path: "f\(i).txt"))
            _ = try engine(r).run(sources: [src], now: t0.addingTimeInterval(Double(i) * 3600))
        }
        return r
    }

    func manifests(_ r: Repository) throws -> [String] {
        try r.snapshotIDs().map { r.root.appending(path: "snapshots/\($0).json.lzfse").path }
    }

    /// Files whose reads fail now and then while their content never changes.
    final class Flapper: @unchecked Sendable {
        let paths: [String], mode: mode_t
        private let lock = NSLock()
        private var stop = false
        init(_ paths: [String], mode: mode_t) { self.paths = paths; self.mode = mode }
        func start() {
            Thread.detachNewThread { [self] in
                while !lock.withLock({ stop }) {
                    for p in paths { chmod(p, 0) }
                    usleep(UInt32.random(in: 0...60))
                    for p in paths { chmod(p, mode) }
                    usleep(UInt32.random(in: 0...60))
                }
            }
        }
        func end() { lock.withLock { stop = true }; usleep(10_000); for p in paths { chmod(p, mode) } }
    }

    @Test func controllaOraNeverCallsAFlappingManifestDamaged() throws {
        let r = try backups()
        let flap = Flapper(try manifests(r), mode: 0o644)
        flap.start()
        var damaged = 0
        for _ in 0..<200 {
            damaged += (try? checkArchive(repository: r, cache: HashCache(url: cacheURL)))?.unreadableSnapshots.count ?? 0
        }
        flap.end()
        #expect(damaged == 0)
        #expect(try checkArchive(repository: r, cache: HashCache(url: cacheURL)).isHealthy)
    }

    @Test func deletingDamagedBackupsNeverDeletesAFlappingSoundOne() throws {
        let r = try backups()
        let ids = try r.snapshotIDs()
        let flap = Flapper(try manifests(r), mode: 0o644)
        flap.start()
        var deleted: [String] = []
        for _ in 0..<300 { deleted += (try? deleteDamagedSnapshots(ids, repository: r, refsCache: nil)) ?? [] }
        flap.end()
        #expect(deleted.isEmpty)
        #expect(try r.snapshotIDs() == ids)
    }

    @Test func aManifestThatCantBeReadIsNotDamagedOneThatIsIs() throws {
        let r = try backups()
        let ids = try r.snapshotIDs(), paths = try manifests(r)
        chmod(paths[0], 0)
        defer { chmod(paths[0], 0o644) }
        #expect(r.snapshotDamaged(ids[0]) == nil)
        #expect(r.snapshotDamaged(ids[1]) == false)
        var bytes = try Data(contentsOf: URL(fileURLWithPath: paths[1]))
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: URL(fileURLWithPath: paths[1]))
        #expect(r.snapshotDamaged(ids[1]) == true)
        let c = try checkArchive(repository: r, cache: HashCache(url: cacheURL))
        #expect(c.unreadSnapshots == [ids[0]] && c.unreadableSnapshots == [ids[1]])
        // only the damaged one goes; the one not read stays
        #expect(try deleteDamagedSnapshots(ids, repository: r, refsCache: nil) == [ids[1]])
        #expect(r.snapshotExists(ids[0]))
    }

    /// The first backup after waking finds nothing changed and the newest manifest not readable yet: a new one is
    /// written, without the critical "Archivio danneggiato" that pushes to delete it.
    @Test func newestManifestNotReadableYetIsNoAlarm() throws {
        let r = try backups()
        let newest = try #require(try manifests(r).last)
        chmod(newest, 0)
        defer { chmod(newest, 0o644) }
        let report = try engine(r).run(sources: [src], now: t0.addingTimeInterval(4 * 3600))
        #expect(report.snapshotID != nil)
        #expect(!report.warnings.contains { $0.hasPrefix(BackupEngine.damagedPrefix) })
    }

    /// A fan-out folder of objects/ that can't be listed was taken for empty: "N file mancanti" for sound objects.
    @Test func objectFolderThatCantBeListedIsNotMissingObjects() throws {
        let r = try backups()
        let dirs = try FileManager.default.contentsOfDirectory(atPath: r.root.appending(path: "objects").path)
            .map { r.root.appending(path: "objects/\($0)").path }
        let flap = Flapper(dirs, mode: 0o755)
        flap.start()
        var falseAlarms = 0
        for _ in 0..<80 {
            if let c = try? checkArchive(repository: r, cache: HashCache(url: cacheURL)), c.missingObjects > 0 { falseAlarms += 1 }
        }
        flap.end()
        #expect(falseAlarms == 0)
        #expect(try checkArchive(repository: r, cache: HashCache(url: cacheURL)).isHealthy)
    }
}

/// Adversarial review "standby", sources: volumes that go away after a sleep, files already saved that can't be read
/// any more, timestamps kept to the second. A backup missing part of its files must be partial, so that retention
/// keeps the last complete one.
@Suite(.serialized) struct AdversarialStandbySourceTests {
    func engine(_ dest: URL, _ cache: URL) throws -> (BackupEngine, Repository) {
        let repo = try Repository(destination: dest, computerName: "Mac")
        return (BackupEngine(repository: repo, cache: HashCache(url: cache), excludes: ExcludeRules(patterns: [])), repo)
    }

    @discardableResult
    static func hdiutil(_ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    /// A small HFS+ image (times to the second, like an external "Mac OS Extended" disk) mounted in a test folder.
    static func withImage(_ body: (URL) throws -> Void) throws {
        let dir = tmp(), dmg = dir.appending(path: "src.dmg"), mnt = dir.appending(path: "mnt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        try #require(hdiutil("create", "-quiet", "-size", "40m", "-fs", "HFS+", "-volname", "BMSim", dmg.path) == 0)
        try #require(hdiutil("attach", "-quiet", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint", mnt.path, dmg.path) == 0)
        defer { hdiutil("detach", "-quiet", "-force", mnt.path); try? FileManager.default.removeItem(at: dir) }
        try body(mnt)
    }

    func hash(_ r: Repository, _ id: String?, _ path: String) throws -> String? {
        try r.readSnapshot(try #require(id)).entries.first { $0.path == path }?.hash
    }

    @Test func volumeGoneHalfwayMakesThePartialBackup() throws {
        try Self.withImage { mnt in
            for i in 0..<2000 { write(String(repeating: "x", count: 1500) + "\(i)", to: mnt.appending(path: "d\(i % 20)/f\(i).txt")) }
            let (e, _) = try engine(tmp(), tmp().appending(path: "cache"))
            var detached = false
            let report = try e.run(sources: [mnt]) { p in
                if p > 0.3, !detached { detached = true; Self.hdiutil("detach", "-quiet", "-force", mnt.path) }
            }
            #expect(detached && report.fileCount < 2000)
            #expect(report.error?.contains("Sorgente scollegata durante il backup") == true)
            #expect(cleanupDecision(thrown: nil, report: report, lastComplete: "older") == .prune(pinned: ["older", report.snapshotID!]))
        }
    }

    @Test func sameSecondRewriteIsNotCachedForGood() throws {
        try Self.withImage { mnt in
            let f = mnt.appending(path: "doc.txt")
            let v1 = Data("versione-1-AAAA".utf8), v2 = Data("versione-2-BBBB".utf8)
            let (e, repo) = try engine(tmp(), tmp().appending(path: "cache"))
            // right after a second boundary: write, back up and rewrite all fit in the same second
            while Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0.05 { usleep(5000) }
            try v1.write(to: f)
            _ = try e.run(sources: [mnt])
            try v2.write(to: f) // in place, same size, same second
            usleep(1_500_000)
            let r2 = try e.run(sources: [mnt], now: Date().addingTimeInterval(3600))
            #expect(try hash(repo, r2.snapshotID, "doc.txt") == sha256Hex(v2))
        }
    }

    /// chmod 000 stands in for EIO from a disk or a broken placeholder after wake.
    @Test func savedFileStayingUnreadableKeepsItsLastCopy() throws {
        let src = tmp().appending(path: "src", directoryHint: .isDirectory)
        write("importante", to: src.appending(path: "tesi.docx"))
        write("0", to: src.appending(path: "altro.txt"))
        let (e, repo) = try engine(tmp(), tmp().appending(path: "cache"))
        var policy = RetentionPolicy(); policy.days = 3; policy.weeks = 1; policy.months = 1
        let day0 = Date(timeIntervalSince1970: 1_780_000_000)
        var lastComplete = try e.run(sources: [src], now: day0).snapshotID
        chmod(src.appending(path: "tesi.docx").path, 0)
        defer { chmod(src.appending(path: "tesi.docx").path, 0o644) }
        for d in 1...45 {
            write("\(d)", to: src.appending(path: "altro.txt"))
            let now = day0.addingTimeInterval(Double(d) * 86400)
            let r = try e.run(sources: [src], now: now)
            #expect(r.error != nil)
            if r.error == nil { lastComplete = r.snapshotID }
            if case let .prune(pinned) = cleanupDecision(thrown: nil, report: r, lastComplete: lastComplete) {
                _ = try prune(repository: repo, policy: policy, capBytes: nil, now: now, pinned: pinned)
            }
        }
        #expect(try repo.snapshotIDs().contains { try repo.readSnapshot($0).entries.contains { $0.path == "tesi.docx" } })
    }

    /// A NAS not mounted yet at the first backup after wake: back at the next one, it must not be read again in full.
    @Test func sourceMissingForOneBackupKeepsItsHashes() throws {
        let nas = tmp().appending(path: "nas", directoryHint: .isDirectory), doc = tmp().appending(path: "doc", directoryHint: .isDirectory)
        write("a", to: nas.appending(path: "a.bin")); write("b", to: doc.appending(path: "b.txt"))
        let cacheURL = tmp().appending(path: "cache"), dest = tmp()
        _ = try engine(dest, cacheURL).0.run(sources: [nas, doc])
        let away = nas.deletingLastPathComponent().appending(path: "nas-via")
        try FileManager.default.moveItem(at: nas, to: away)
        // a new engine and cache per backup, as the app does
        let r2 = try engine(dest, cacheURL).0.run(sources: [nas, doc], now: Date().addingTimeInterval(3600))
        try FileManager.default.moveItem(at: away, to: nas)
        #expect(r2.error != nil)
        #expect(HashCache(url: cacheURL).knows(nas.appending(path: "a.bin").path))
    }
}
