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
