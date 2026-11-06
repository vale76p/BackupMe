import Foundation
import Testing
@testable import BackupCore

/// Regression tests for what the stress test on the installed app found.
@Suite struct StressFixTests {
    let dest = tmp()
    let base = tmp()
    var src: URL { base.appending(path: "progetto", directoryHint: .isDirectory) }
    let cacheURL = tmp().appending(path: "cache.json")
    let fm = FileManager.default
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func repo() throws -> Repository { try Repository(destination: dest, computerName: "Mac") }
    func engine(_ r: Repository) -> BackupEngine {
        BackupEngine(repository: r, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: []))
    }
    func manifest(_ id: String) -> URL { dest.appending(path: "BackupMe/Mac/snapshots/\(id).json.lzfse") }
    func json(_ id: String) throws -> Data { try (Data(contentsOf: manifest(id)) as NSData).decompressed(using: .lzfse) as Data }
    func save(_ json: Data, _ id: String) throws {
        try ((json as NSData).compressed(using: .lzfse) as Data).write(to: manifest(id))
    }

    @Test func alteredManifestIsDamaged() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let r = try repo()
        let id = try #require(try engine(r).run(sources: [src], now: t0).snapshotID)
        #expect(r.snapshotIsIntact(id))
        // what one flipped byte of the compressed file did: still JSON, with another hash in it
        var text = String(decoding: try json(id), as: UTF8.self)
        let hash = try #require(try r.readSnapshot(id).entries.first { $0.path == "a.txt" }?.hash)
        text = text.replacingOccurrences(of: hash, with: String(hash.reversed()))
        try save(Data(text.utf8), id)
        #expect(throws: RepositoryError.damagedSnapshot(id)) { try r.readSnapshot(id) }
        #expect(!r.snapshotIsIntact(id))
    }

    @Test func oldManifestWithBrokenHashIsDamaged() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let r = try repo()
        let id = try #require(try engine(r).run(sources: [src], now: t0).snapshotID)
        // a manifest from before the checksum: no "check" key
        var text = String(decoding: try json(id), as: UTF8.self)
        let end = try #require(text.range(of: "\",")).upperBound
        text = "{" + text[end...]
        try save(Data(text.utf8), id)
        #expect(r.snapshotIsIntact(id))
        let hash = try #require(try r.readSnapshot(id).entries.first { $0.path == "a.txt" }?.hash)
        try save(Data(text.replacingOccurrences(of: hash, with: "683ra0" + hash.dropFirst(6)).utf8), id)
        #expect(throws: RepositoryError.damagedSnapshot(id)) { try r.readSnapshot(id) }
    }

    @Test func unchangedBackupReplacesDamagedNewest() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let r = try repo()
        let first = try #require(try engine(r).run(sources: [src], now: t0).snapshotID)
        let raw = try Data(contentsOf: manifest(first))
        try raw.prefix(raw.count / 2).write(to: manifest(first))
        // nothing changed: without the check the damaged manifest would stay the newest backup
        let again = try engine(r).run(sources: [src], now: t0.addingTimeInterval(3600))
        let id = try #require(again.snapshotID)
        #expect(id != first)
        #expect(try r.readSnapshot(id).entries.contains { $0.path == "a.txt" })
        #expect(again.warnings.contains { $0.hasPrefix(BackupEngine.damagedPrefix) })
    }

    @Test func rewrittenRepoInfoIsTheSameArchive() throws {
        let refs = tmp()
        write("uno", to: src.appending(path: "a.txt"))
        let r = try repo()
        _ = try engine(r).run(sources: [src], now: t0)
        _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs)
        let info = dest.appending(path: "BackupMe/Mac/repo.json")
        for damage in [{ try fm.removeItem(at: info) }, { try Data("{ rotto".utf8).write(to: info) }] {
            try damage()
            let again = try repo()
            #expect(again.archiveID != nil)
            let p = try prune(repository: again, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs)
            #expect(!p.archiveReplaced && !p.vanished && !p.gcSkipped)
        }
        try Data("{ rotto".utf8).write(to: info)
        #expect(try repo().repairedInfo)
    }

    @Test func restoredNamesKeepTheirSavedForm() throws {
        // made with POSIX calls: Foundation would write the names decomposed already
        let name = "àccènti ü 日本" // composed (NFC)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        #expect((src.path + "/" + name).withCString { mkdir($0, 0o755) } == 0)
        let fd = (src.path + "/" + name + "/è.txt").withCString { open($0, O_CREAT | O_WRONLY, 0o644) }
        #expect(fd >= 0); close(fd)
        let r = try repo()
        let snap = try r.readSnapshot(try #require(try engine(r).run(sources: [src], now: t0).snapshotID))
        let out = tmp()
        let restored = try Restorer(repository: r).restore(snap, source: src.path, path: "", mode: .into(out))
        #expect(rawNames(restored.path) == [Array(name.utf8)])
        #expect(rawNames(restored.path + "/" + name) == [Array("è.txt".utf8)])
    }

    @Test func onlyDamagedBackupsAreDeleted() throws {
        let refs = tmp()
        write("uno", to: src.appending(path: "a.txt"))
        let r = try repo()
        let good = try #require(try engine(r).run(sources: [src], now: t0).snapshotID)
        write("due", to: src.appending(path: "a.txt"))
        let bad = try #require(try engine(r).run(sources: [src], now: t0.addingTimeInterval(3600)).snapshotID)
        _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: t0.addingTimeInterval(3600), refsCache: refs)
        let raw = try Data(contentsOf: manifest(bad))
        try raw.prefix(raw.count / 2).write(to: manifest(bad))
        #expect(try deleteDamagedSnapshots([good, bad], repository: r, refsCache: refs) == [bad])
        #expect(try r.snapshotIDs() == [good])
        // gone on purpose: cleanup must not take it for a backup that vanished
        let p = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: t0.addingTimeInterval(7200), refsCache: refs)
        #expect(!p.vanished && !p.gcSkipped)
    }

    @Test func foundationErrorsGiveTheirPosixCode() {
        #expect(BackupEngine.posixCode(CocoaError(.fileWriteOutOfSpace)) == ENOSPC)
        #expect(BackupEngine.posixCode(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                               userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])) == ENOSPC)
        #expect(BackupEngine.posixCode(POSIXError(.EACCES)) == EACCES)
        #expect(BackupEngine.posixCode(CocoaError(.fileReadCorruptFile)) == nil)
    }
}

/// Names in a folder as the bytes on disk: FileManager may hand them back in another Unicode form.
func rawNames(_ dir: String) -> [[UInt8]] {
    guard let d = opendir(dir) else { return [] }
    defer { closedir(d) }
    var all: [[UInt8]] = []
    while let e = readdir(d) {
        let n = withUnsafeBytes(of: e.pointee.d_name) { Array($0.prefix(Int(e.pointee.d_namlen))) }
        if n != Array(".".utf8), n != Array("..".utf8) { all.append(n) }
    }
    return all.sorted { $0.lexicographicallyPrecedes($1) }
}
