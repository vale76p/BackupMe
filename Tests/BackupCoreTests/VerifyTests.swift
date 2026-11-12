import Foundation
import Testing
@testable import BackupCore

@Suite struct VerifyTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let cacheURL = tmp().appending(path: "cache.json")

    func backup() throws -> Repository {
        let repo = try Repository(destination: dest, computerName: "Mac")
        _ = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: [])).run(sources: [src])
        return repo
    }

    func damage(_ url: URL) throws {
        let h = try FileHandle(forUpdating: url)
        try h.write(contentsOf: Data([0xFF, 0x00, 0xFF]))
        try h.close()
    }

    @Test func fullCheckFindsMissingAndUnreadable() throws {
        write("uno", to: src.appending(path: "a.txt"))
        write("due", to: src.appending(path: "b.txt"))
        let repo = try backup()
        let cache = HashCache(url: cacheURL)
        let ok = try checkArchive(repository: repo, cache: cache)
        #expect(ok.isHealthy && ok.snapshots == 1 && ok.objects.checked == 2)
        try repo.deleteObject(sha256Hex(Data("uno".utf8)))
        let id = try repo.snapshotIDs()[0]
        try Data("rotto".utf8).write(to: repo.root.appending(path: "snapshots/\(id).json.lzfse"))
        let bad = try checkArchive(repository: repo, cache: cache)
        // with its only manifest unreadable, no object is known to be needed
        #expect(!bad.isHealthy && bad.unreadableSnapshots == [id] && bad.objects.checked == 0)
    }

    @Test func fullCheckCountsMissingObjects() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let repo = try backup()
        try repo.deleteObject(sha256Hex(Data("uno".utf8)))
        let r = try checkArchive(repository: repo, cache: HashCache(url: cacheURL))
        #expect(r.missingObjects == 1 && r.unreadableSnapshots.isEmpty && !r.isHealthy)
    }

    @Test func corruptObjectRepairedFromSource() throws {
        let text = Data(String(repeating: "contenuto ", count: 100).utf8)
        write(String(decoding: text, as: UTF8.self), to: src.appending(path: "a.txt"))
        write("altro", to: src.appending(path: "b.txt"))
        let repo = try backup()
        let h = sha256Hex(text)
        try damage(objectFile(repo, h)!)
        let r = try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: .max)
        #expect(r.checked == 2 && r.repaired == [h] && r.corrupt.isEmpty && r.bytes > 0)
        #expect(try repo.readObject(h) == text)
    }

    @Test func corruptObjectWithoutGoodSourceIsKept() throws {
        write("originale", to: src.appending(path: "a.txt"))
        let repo = try backup()
        let h = sha256Hex(Data("originale".utf8))
        let object = objectFile(repo, h)!
        try damage(object)
        write("cambiato", to: src.appending(path: "a.txt"))
        let r = try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: .max)
        #expect(r.corrupt == [h] && r.repaired.isEmpty)
        #expect(FileManager.default.fileExists(atPath: object.path))
    }

    @Test func budgetLimitsTheSample() throws {
        for i in 0..<3 { write("file \(i)", to: src.appending(path: "\(i).txt")) }
        // each object is 6 bytes: a 6-byte budget reads one; a 1-byte one reads none rather than overshooting
        let repo = try backup()
        let r = try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: 6)
        #expect(r.checked == 1 && r.corrupt.isEmpty)
        #expect(try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: 1).checked == 0)
    }

    @Test func largeRawObjectVerifiedAsStreamAndRepaired() throws {
        let big = Data(repeating: 7, count: Int(Repository.streamThreshold))
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try big.write(to: src.appending(path: "grande.bin"))
        let repo = try backup()
        let h = sha256Hex(big)
        let object = objectFile(repo, h)!
        #expect(object.pathExtension == "raw")
        try damage(object)
        let r = try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: .max)
        #expect(r.repaired == [h] && r.bytes == Repository.streamThreshold)
        #expect(try streamHash(object) == h)
    }

    func packedBackup() throws -> (Repository, HashCache) {
        let repo = try Repository(destination: dest, computerName: "Mac", packBelow: Repository.packThreshold)
        let cache = HashCache(url: cacheURL)
        _ = try BackupEngine(repository: repo, cache: cache, excludes: ExcludeRules(patterns: [])).run(sources: [src])
        return (repo, cache)
    }

    func packFile(_ repo: Repository, _ ext: String = "pack") throws -> URL {
        repo.root.appending(path: "packs/\(try repo.packIDs()[0]).\(ext)")
    }

    @Test(arguments: [true, false]) func checkFindsAndRepairsACorruptObjectInAContainer(sourceKept: Bool) throws {
        write("contenuto piccolo", to: src.appending(path: "a.txt"))
        let (repo, cache) = try packedBackup()
        let h = sha256Hex(Data("contenuto piccolo".utf8))
        let entry = try #require(try repo.packEntries(repo.packIDs()[0]).first { $0.hash == h })
        var bytes = try Data(contentsOf: packFile(repo))
        bytes[entry.offset] ^= 0xff
        try bytes.write(to: packFile(repo))
        if !sourceKept { try FileManager.default.removeItem(at: src.appending(path: "a.txt")) }
        let r = try checkArchive(repository: repo, cache: cache)
        #expect(r.objects.repaired == (sourceKept ? [h] : []) && r.objects.corrupt == (sourceKept ? [] : [h]) && r.damagedPacks.isEmpty)
    }

    @Test func checkRebuildsAMissingIndex() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let (repo, cache) = try packedBackup()
        let idx = try packFile(repo, "idx")
        try FileManager.default.removeItem(at: idx)
        #expect(try checkArchive(repository: repo, cache: cache).isHealthy)
        #expect(FileManager.default.fileExists(atPath: idx.path))
    }

    @Test func truncatedContainerIsReported() throws {
        write("uno", to: src.appending(path: "a.txt"))
        write("due", to: src.appending(path: "b.txt"))
        let (repo, cache) = try packedBackup()
        let id = try repo.packIDs()[0], pack = try packFile(repo)
        try Data(contentsOf: pack).dropLast(2).write(to: pack)
        let r = try checkArchive(repository: repo, cache: cache)
        #expect(r.damagedPacks == [id] && !r.isHealthy)
    }

    @Test func unreadableContainerFailsTheCheckWithoutCallingItDamaged() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let (repo, cache) = try packedBackup()
        let pack = try packFile(repo), before = try Data(contentsOf: pack)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: pack.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pack.path) }
        #expect(throws: (any Error).self) { try checkArchive(repository: repo, cache: cache) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pack.path)
        #expect(try Data(contentsOf: pack) == before && FileManager.default.fileExists(atPath: try packFile(repo, "idx").path))
    }

    @Test func sampleToleratesADamagedContainer() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let (repo, cache) = try packedBackup()
        let pack = try packFile(repo)
        try Data(contentsOf: pack).dropLast(2).write(to: pack)
        try Data("xx".utf8).write(to: packFile(repo, "idx"))
        _ = try verifySample(repository: repo, cache: cache, budgetBytes: .max)
    }

    @Test func upgradeCheckReportsStraysInPacks() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let (repo, _) = try packedBackup()
        write("x", to: repo.root.appending(path: "packs/appunti.txt"))
        let r = try upgradeCheck(repository: repo)
        #expect(r.attention.contains { $0.contains("packs/appunti.txt") })
    }
}
