import CryptoKit
import Foundation
import Testing
@testable import BackupCore

/// Archives written by released versions, kept in Fixtures/ to pin format 1: each is the BackupMe folder (kit included)
/// after two backups of the same source made with that version's BackupEngine and cleanup (`prune`), plus that
/// version's local caches in `local/` (HashCache, references of the cleanup). `source/source-N.tar` is the source as
/// it was at backup N (names, dates, permissions, link). Generated with the tags v0.8.0, v0.9.4 and 057e5ac (1.0-rc1),
/// the source at /private/tmp/BackupMeFixture/src; the fixtures are only read: every test works on a copy.
@Suite struct FormatFixtureTests {
    static let versions = ["0.8.0", "0.9.4", "1.0-rc1"]
    static let ids = ["2026-01-01T10-00-00Z", "2026-01-02T10-00-00Z"]
    let fm = FileManager.default
    let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures", directoryHint: .isDirectory)

    static func archive(_ version: String) -> String { version == "1.0-rc1" ? "MacProva-1A2B3C4D-prova" : "MacProva-1A2B3C4D" }

    /// A copy of the fixture: the destination (holding BackupMe/) and the local caches.
    func copy(_ version: String) throws -> (dest: URL, local: URL) {
        let dir = tmp(), from = fixtures.appending(path: "archive-\(version)")
        try fm.createDirectory(at: dir.appending(path: "dest"), withIntermediateDirectories: true)
        try fm.copyItem(at: from.appending(path: "BackupMe"), to: dir.appending(path: "dest/BackupMe"))
        try fm.copyItem(at: from.appending(path: "local"), to: dir.appending(path: "local"))
        return (dir.appending(path: "dest"), dir.appending(path: "local"))
    }

    /// The source as it was at backup `n` (1 or 2), extracted with its names, dates and permissions. The tars are
    /// ustar (in its default pax format bsdtar stores composed names decomposed). The fixture's HashCache never
    /// matches the extracted files: its key holds inode and ctime, which no extraction can give back.
    func source(_ n: Int) throws -> URL {
        let dir = tmp()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/pax")
        p.arguments = ["-r", "-pp", "-f", fixtures.appending(path: "source/source-\(n).tar").path]
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        return dir
    }

    /// Same names (as bytes), kinds, contents, link targets, and for files and folders the same permissions and
    /// modification dates, at every level below `a` and `b`. `composedNames: false` compares names in one Unicode form
    /// only: the kit of 0.8.0 wrote composed names decomposed (the files are found by either name on APFS).
    func expectIdentical(_ a: String, _ b: String, _ context: String, composedNames: Bool = true) {
        let names = rawNames(b)
        let nfc = { (n: [[UInt8]]) in Set(n.map { String(decoding: $0, as: UTF8.self).precomposedStringWithCanonicalMapping }) }
        if composedNames {
            #expect(rawNames(a) == names, "\(context): nomi diversi in \(a)")
        } else {
            #expect(nfc(rawNames(a)) == nfc(names), "\(context): nomi diversi in \(a)")
        }
        for raw in names {
            let name = String(decoding: raw, as: UTF8.self), x = a + "/" + name, y = b + "/" + name
            guard let sx = FileStat(path: x), let sy = FileStat(path: y) else { Issue.record("\(context): manca \(y)"); continue }
            #expect(sx.kind == sy.kind, "\(context): \(name)")
            switch sx.kind {
            case .symlink:
                #expect((try? fm.destinationOfSymbolicLink(atPath: x)) == (try? fm.destinationOfSymbolicLink(atPath: y)), "\(context): \(name)")
            case .file, .directory:
                #expect(sx.mode == sy.mode && sx.mtime == sy.mtime, "\(context): \(name) \(sx.mode) \(sy.mode) \(sx.mtime) \(sy.mtime)")
                if sx.kind == .file {
                    #expect(fm.contents(atPath: x) == fm.contents(atPath: y), "\(context): contenuto di \(name)")
                } else {
                    expectIdentical(x, y, context, composedNames: composedNames)
                }
            }
        }
    }

    /// `RIPRISTINO.command` (or another kit in the same folder) run with --si: restores backup `id` into `out`.
    func runKit(_ script: URL, _ archive: String, _ id: String, into out: URL) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, "--si", archive, id, out.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }

    /// Top-level keys of a manifest and, per kind, the keys of its entries ("check" left out: older manifests lack it).
    func structure(_ json: Data) throws -> [String: Set<String>] {
        let top = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        var out = ["snapshot": Set(top.keys).subtracting(["check"])]
        for e in try #require(top["entries"] as? [[String: Any]]) { out[e["kind"] as! String, default: []].formUnion(e.keys) }
        return out
    }

    func manifestJSON(_ dest: URL, _ archive: String, _ id: String) throws -> Data {
        let url = dest.appending(path: "BackupMe/\(archive)/snapshots/\(id).json.lzfse")
        return try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
    }

    @Test(arguments: versions) func currentCodeReadsChecksAndRestoresEveryBackup(_ version: String) throws {
        let (dest, local) = try copy(version), name = Self.archive(version)
        let repo = try Repository(destination: dest, computerName: name, create: false)
        #expect(try repo.snapshotIDs() == Self.ids)
        let check = try checkArchive(repository: repo, cache: HashCache(url: local.appending(path: "hashcache.json")))
        #expect(check.isHealthy && check.snapshots == 2, "\(check)")
        for (n, id) in Self.ids.enumerated() {
            let s = try repo.readSnapshot(id)
            #expect(s.id == id && s.date == Snapshot.date(fromID: id) && s.warnings.isEmpty)
            #expect(s.sources.map { ($0 as NSString).lastPathComponent } == ["Documenti", "Nota singola.txt"])
            let out = tmp()
            for src in s.sources { try Restorer(repository: repo).restore(s, source: src, path: "", mode: .into(out)) }
            expectIdentical(out.path, try source(n + 1).path, "\(version) \(id)")
        }
    }

    @Test(arguments: versions) func currentKitRestoresTheNewestBackup(_ version: String) throws {
        let (dest, _) = try copy(version)
        #expect(Repository.updateRestoreKit(destination: dest) != .noArchive)
        let kit = dest.appending(path: "BackupMe/RIPRISTINO.command")
        #expect(try String(contentsOf: kit, encoding: .utf8) == RestoreKit.script)
        let out = tmp().appending(path: "ripristino")
        let r = try runKit(kit, Self.archive(version), Self.ids[1], into: out)
        #expect(r.status == 0, "\(r.out)")
        expectIdentical(out.path, try source(2).path, "\(version) kit attuale")
    }

    /// A backup by the current code on the old archive, with the old local caches: no object copied again, the
    /// cleanup deletes nothing, the manifest keeps the old layout, and the kit saved by that version restores it.
    @Test(arguments: versions) func newBackupOnOldArchive(_ version: String) throws {
        let (dest, local) = try copy(version), name = Self.archive(version)
        let base = dest.appending(path: "BackupMe")
        let originalKit = try Data(contentsOf: base.appending(path: "RIPRISTINO.command"))
        let objects = base.appending(path: "\(name)/objects")
        let before = try fm.subpathsOfDirectory(atPath: objects.path).sorted()

        let src = try source(2)
        let now = try #require(Snapshot.date(fromID: "2026-01-03T10-00-00Z"))
        let repo = try Repository(destination: dest, computerName: name)
        let report = try BackupEngine(repository: repo, cache: HashCache(url: local.appending(path: "hashcache.json")),
                                      excludes: ExcludeRules(patterns: []))
            .run(sources: [src.appending(path: "Documenti"), src.appending(path: "Nota singola.txt")], now: now)
        #expect(report.snapshotID == "2026-01-03T10-00-00Z" && report.error == nil && report.warnings.isEmpty, "\(report)")
        #expect(report.newBytes == 0 && report.fileCount == 9, "\(report)")
        let pruned = try prune(repository: repo, policy: RetentionPolicy(), capBytes: nil, now: now,
                               refsCache: local.appending(path: "refs", directoryHint: .isDirectory), forceGC: true)
        #expect(pruned.deletedSnapshots.isEmpty && pruned.deletedObjects == 0 && pruned.missingObjects == 0, "\(pruned)")
        #expect(try fm.subpathsOfDirectory(atPath: objects.path).sorted() == before)
        #expect(try checkArchive(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json"))).isHealthy)

        let new = try structure(manifestJSON(dest, name, "2026-01-03T10-00-00Z"))
        #expect(new == (try structure(manifestJSON(dest, name, Self.ids[1]))))

        // backwards: the kit of that version, beside the current one, restores the backup the current code wrote
        let old = base.appending(path: "RIPRISTINO-\(version).command")
        try originalKit.write(to: old)
        let out = tmp().appending(path: "ripristino")
        let r = try runKit(old, name, "2026-01-03T10-00-00Z", into: out)
        #expect(r.status == 0, "\(r.out)")
        expectIdentical(out.path, src.path, "\(version) kit originale", composedNames: version != "0.8.0")
    }

    /// The bytes of the 1.0-rc1 archive against docs/formato-archivio.md.
    @Test func rc1BytesMatchTheFormatDocument() throws {
        let (dest, _) = try copy("1.0-rc1"), name = Self.archive("1.0-rc1")
        let root = dest.appending(path: "BackupMe/\(name)")

        // repo.json after claim(owner:): keys sorted, no spaces
        let info = String(decoding: try Data(contentsOf: root.appending(path: "repo.json")), as: UTF8.self)
        #expect(info.wholeMatch(of: #/\{"created":\d+(\.\d+)?,"format":1,"id":"[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}","owner":501,"ownerName":"prova"\}/#) != nil, "\(info)")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = .sortedKeys
        let repo = try Repository(destination: dest, computerName: name, create: false)
        var used = Set<String>()
        for id in Self.ids {
            #expect(id.wholeMatch(of: #/\d{4}-\d\d-\d\dT\d\d-\d\d-\d\dZ/#) != nil)
            let json = try manifestJSON(dest, name, id)
            // {"check":"<sha256 of the rest>",<the encoded JSON without its "{">
            let prefix = Data(#"{"check":""#.utf8)
            #expect(json.prefix(10) == prefix && json[74] == UInt8(ascii: "\"") && json[75] == UInt8(ascii: ","))
            let check = String(decoding: json[10 ..< 74], as: UTF8.self)
            #expect(Repository.isHash(check) && sha256Hex(json[76...]) == check)
            let s = try repo.readSnapshot(id)
            #expect(Data("{".utf8) + json[76...] == (try enc.encode(s)), "chiavi ordinate, date in secondi, senza spazi")
            #expect(try structure(json) == [
                "snapshot": ["date", "entries", "id", "sources", "warnings"],
                "file": ["hash", "kind", "mode", "mtime", "path", "size", "source"],
                "directory": ["kind", "mode", "mtime", "path", "size", "source"],
                "symlink": ["kind", "linkTarget", "mode", "mtime", "path", "size", "source"],
            ])
            used.formUnion(s.entries.compactMap(\.hash))
        }

        // objects/<2 digits>/<sha256>.lzfse|.raw: lzfse when it saves more than 5%, raw otherwise
        var stored = Set<String>()
        for path in try fm.subpathsOfDirectory(atPath: root.appending(path: "objects").path) where path.contains(".") {
            let dir = (path as NSString).deletingLastPathComponent, file = (path as NSString).lastPathComponent
            let hash = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
            #expect(Repository.isHash(hash) && dir == String(hash.prefix(2)), "\(path)")
            let body = try Data(contentsOf: root.appending(path: "objects/\(path)"))
            let content = ext == "lzfse" ? try (body as NSData).decompressed(using: .lzfse) as Data : body
            #expect(sha256Hex(content) == hash, "\(path)")
            let packed = content.isEmpty ? nil : try (content as NSData).compressed(using: .lzfse) as Data
            let saves = packed.map { Double($0.count) < Double(content.count) * 0.95 } ?? false
            #expect(["lzfse", "raw"].contains(ext) && saves == (ext == "lzfse"), "\(path)")
            stored.insert(hash)
        }
        #expect(stored == used)
        #expect(try Data(contentsOf: root.appending(path: "lock")).isEmpty)
    }
}
