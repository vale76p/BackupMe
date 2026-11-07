import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Measures one phase of a backup of many synthetic files, one phase per process (the footprint peak never goes
/// down). Off by default; run it in release, at most 100k files:
///   BACKUPME_PERF=setup|first|unchanged|changed BACKUPME_PERF_DIR=/path BACKUPME_PERF_N=100000 \
///   swift test -c release -Xswiftc -enable-testing --filter PerformanceRC1Tests/measure
@Suite struct PerformanceRC1Tests {
    static let env = ProcessInfo.processInfo.environment
    let fm = FileManager.default
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var keepAll: RetentionPolicy { var p = RetentionPolicy(); p.days = 1000; return p }

    func manifestURL(_ r: Repository, _ id: String) -> URL { r.root.appending(path: "snapshots/\(id).json.lzfse") }

    /// writeSnapshot as it was up to 1.0-rc1: the Snapshot encoded whole, then sealed. The reference for the format.
    func legacyManifest(_ s: Snapshot) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = .sortedKeys
        let body = try enc.encode(s).dropFirst()
        let sealed = Data(#"{"check":""#.utf8) + Data(sha256Hex(Data(body)).utf8) + Data("\",".utf8) + body
        return try (sealed as NSData).compressed(using: .lzfse) as Data
    }

    func snapshot(_ entries: [Entry], warnings: [String] = []) -> Snapshot {
        Snapshot(date: t0.addingTimeInterval(0.5), sources: ["/Users/mario/Documenti", "/Users/mario/a \"b\"\\c/ü"],
                 entries: entries, warnings: warnings)
    }

    // MARK: format

    /// The manifest written entry by entry is the same file, byte for byte, as the one encoded whole: readers
    /// (RIPRISTINO.command, 0.9.x, other Macs) see no difference.
    @Test func streamedManifestIsByteIdentical() throws {
        let h = sha256Hex(Data("x".utf8))
        let odd = ["", "Caffè", "Caffe\u{0300}", "a/b/c.txt", "virgolette \"e\" \\barre\\", "riga\nnuova\ttab\u{1}",
                   "emoji 👩‍💻", "/assoluto", "entries\":[]", "\"entries\":[],\"id\":\"x\""]
        var entries: [Entry] = []
        for (i, p) in odd.enumerated() {
            entries.append(Entry(source: "/Users/mario/Documenti", path: p, kind: .file, hash: h, size: Int64(i) << 40,
                                 mtime: t0.addingTimeInterval(Double(i) * 0.123456789), mode: 0o644, linkTarget: nil))
        }
        entries.append(Entry(source: "/s", path: "dir", kind: .directory, hash: nil, size: 0, mtime: t0, mode: 0o755, linkTarget: nil))
        entries.append(Entry(source: "/s", path: "link", kind: .symlink, hash: nil, size: 3, mtime: Date(timeIntervalSince1970: -1.5),
                             mode: 0o777, linkTarget: "../dir \"x\""))
        let repo = try Repository(destination: dest, computerName: "Mac")
        for (n, s) in [snapshot(entries, warnings: ["avviso \"1\"", "… e altri 3 avvisi"]), snapshot([]),
                       Snapshot(date: t0.addingTimeInterval(9), sources: [], entries: Array(entries.prefix(1)), warnings: [])].enumerated() {
            var s = s
            s.id = Snapshot.id(for: t0.addingTimeInterval(Double(n) * 10))
            try repo.writeSnapshot(s)
            #expect(try Data(contentsOf: manifestURL(repo, s.id)) == legacyManifest(s), "manifest \(n)")
            let back = try repo.readSnapshot(s.id)
            // dates go through seconds since 1970, as they always did: compared to the millisecond
            #expect(back.entries.map(\.path) == s.entries.map(\.path) && back.entries.map(\.hash) == s.entries.map(\.hash))
            #expect(zip(back.entries, s.entries).allSatisfy { abs($0.mtime.timeIntervalSince($1.mtime)) < 0.001 && $0.linkTarget == $1.linkTarget })
            #expect(back.warnings == s.warnings && back.sources == s.sources)
            #expect(repo.snapshotIsIntact(s.id))
        }
    }

    /// The same for a real backup, compared with the manifest the old code would write for its entries.
    @Test func backupManifestMatchesTheOldEncoder() throws {
        for i in 0..<300 { write("file \(i)", to: src.appending(path: "d\(i % 7)/f \(i).txt")) }
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src], now: t0)
        let id = try #require(report.snapshotID)
        #expect(try Data(contentsOf: manifestURL(repo, id)) == legacyManifest(repo.readSnapshot(id)))
    }

    // MARK: intact check

    @Test func streamedIntactCheckFindsDamage() throws {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let h = sha256Hex(Data("x".utf8))
        let entries = (0..<2000).map { Entry(source: "/s", path: "f\($0)", kind: .file, hash: h, size: 1, mtime: t0, mode: 0o644, linkTarget: nil) }
        let s = snapshot(entries)
        try repo.writeSnapshot(s)
        let url = manifestURL(repo, s.id)
        let good = try Data(contentsOf: url)
        #expect(repo.snapshotIsIntact(s.id))
        var flipped = good
        flipped[flipped.count / 2] ^= 0x10
        try flipped.write(to: url)
        #expect(!repo.snapshotIsIntact(s.id))
        try good.prefix(good.count / 2).write(to: url)
        #expect(!repo.snapshotIsIntact(s.id))
        try Data("garbage".utf8).write(to: url)
        #expect(!repo.snapshotIsIntact(s.id))
        // before 0.9.2: no checksum, decoded whole; a hash that isn't one is damage
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = .sortedKeys
        try ((try enc.encode(s)) as NSData).compressed(using: .lzfse).write(to: url)
        #expect(repo.snapshotIsIntact(s.id))
        var bad = s
        bad.entries[0].hash = "zz"
        try ((try enc.encode(bad)) as NSData).compressed(using: .lzfse).write(to: url)
        #expect(!repo.snapshotIsIntact(s.id))
    }

    // MARK: hash cache

    @Test func hashCacheRoundTripAndDropsUnseen() throws {
        let url = tmp().appending(path: "c.json")
        let m = Date(timeIntervalSince1970: 1000.123456), c = Date(timeIntervalSince1970: 2000.5)
        let cache = HashCache(url: url)
        cache.store(path: "/a/Caffè", inode: 7, size: 3, mtime: m, ctime: c, hash: sha256Hex(Data("a".utf8)))
        cache.store(path: "/b", inode: 8, size: 4, mtime: m, ctime: c, hash: sha256Hex(Data("b".utf8)))
        cache.lastManifest = ("digest", "2023-11-14T22-13-20Z")
        try cache.save()
        let again = HashCache(url: url)
        #expect(again.lastManifest?.digest == "digest" && again.lastManifest?.id == "2023-11-14T22-13-20Z")
        #expect(again.lookup(path: "/a/Caffè", inode: 7, size: 3, mtime: m, ctime: c) == sha256Hex(Data("a".utf8)))
        #expect(again.path(for: sha256Hex(Data("b".utf8))) == "/b")
        try again.save() // "/b" was not looked up in this run: forgotten
        let third = HashCache(url: url)
        #expect(third.knows("/a/Caffè") && !third.knows("/b"))
    }

    /// The mtime alone tells an evicted cloud file (ctime ignored) whose content changed: no hit with another one.
    @Test func hashCacheMissesOnOtherMtime() throws {
        let cache = HashCache(url: tmp().appending(path: "c.json"))
        let m = Date(timeIntervalSince1970: 1000), c = Date(timeIntervalSince1970: 2000), h = sha256Hex(Data("a".utf8))
        cache.store(path: "/a", inode: 1, size: 3, mtime: m, ctime: c, hash: h)
        #expect(cache.lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: nil) == h)
        #expect(cache.lookup(path: "/a", inode: 1, size: 3, mtime: m.addingTimeInterval(1), ctime: nil) == nil)
        #expect(cache.lookup(path: "/a", inode: 1, size: 3, mtime: m.addingTimeInterval(1), ctime: c) == nil)
    }

    /// The JSON cache of earlier versions keeps its hashes (no file read again after the update) and is written
    /// again in the new format; one without ctime still matches an evicted cloud file.
    @Test func legacyJSONCacheIsReadAndConverted() throws {
        let url = tmp().appending(path: "c.json")
        let m = Date(timeIntervalSince1970: 1000), c = Date(timeIntervalSince1970: 2000), h = sha256Hex(Data("a".utf8))
        struct Item: Codable { var inode: UInt64; var size: Int64; var mtime: Date; var ctime: Date?; var hash: String }
        struct Stored: Codable { var items: [String: Item]; var manifestDigest: String?; var manifestID: String? }
        try JSONEncoder().encode(Stored(items: ["/a": Item(inode: 1, size: 3, mtime: m, ctime: c, hash: h),
                                                "/old": Item(inode: 2, size: 3, mtime: m, ctime: nil, hash: h)],
                                        manifestDigest: "d", manifestID: "id")).write(to: url)
        let cache = HashCache(url: url)
        #expect(cache.lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: c) == h)
        #expect(cache.lookup(path: "/old", inode: 2, size: 3, mtime: m, ctime: nil) == h)
        #expect(cache.lastManifest?.digest == "d")
        try cache.save()
        #expect(try Data(contentsOf: url).starts(with: Data("BMHC2\n".utf8)))
        #expect(HashCache(url: url).lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: c) == h)
    }

    /// A cache that doesn't verify starts empty, without error: the files are read again, never given a wrong hash.
    @Test func damagedCacheStartsEmpty() throws {
        let url = tmp().appending(path: "c.json")
        let m = Date(timeIntervalSince1970: 1000), h = sha256Hex(Data("a".utf8))
        let cache = HashCache(url: url)
        cache.store(path: "/a", inode: 1, size: 3, mtime: m, ctime: m, hash: h)
        cache.lastManifest = ("d", "id")
        try cache.save()
        var data = try Data(contentsOf: url)
        data[data.count - 3] ^= 0xff
        try data.write(to: url)
        let damaged = HashCache(url: url)
        #expect(damaged.lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: m) == nil && damaged.lastManifest == nil)
        try data.prefix(20).write(to: url)
        #expect(!HashCache(url: url).knows("/a"))
        try Data("{non json".utf8).write(to: url)
        #expect(!HashCache(url: url).knows("/a"))
    }

    // MARK: cleanup

    func backup(_ repo: Repository, _ files: [String: String], at date: Date) throws -> BackupReport {
        try? fm.removeItem(at: src)
        for (name, text) in files { write(text, to: src.appending(path: name)) }
        return try BackupEngine(repository: repo, cache: HashCache(url: dest.appending(path: "c.json")),
                                excludes: ExcludeRules(patterns: [])).run(sources: [src], now: date)
    }

    /// Under the cap with everything stored, references are not read (a manifest that can't be read doesn't stop
    /// it) and nothing is deleted; the pool size is what is stored.
    @Test func capThatFitsReadsNoReferences() throws {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let first = try backup(repo, ["a.txt": "uno"], at: t0)
        _ = try backup(repo, ["a.txt": "due"], at: t0.addingTimeInterval(3600))
        try Data("garbage".utf8).write(to: manifestURL(repo, try #require(first.snapshotID)))
        let r = try prune(repository: repo, policy: keepAll, capBytes: 1 << 40, now: t0.addingTimeInterval(3600),
                          refsCache: tmp(), gcDue: false)
        #expect(r.deletedSnapshots.isEmpty && !r.overCap && !r.collected)
        #expect(r.poolSize == (try repo.poolSize()))
    }

    /// Over the cap only because of unreferenced objects: references are counted, no backup is deleted, and
    /// the space is freed now (a cap doesn't wait for the daily collection).
    @Test func capOverOnlyByOrphansCollectsThemNow() throws {
        let repo = try Repository(destination: dest, computerName: "Mac")
        _ = try backup(repo, ["a.txt": String(repeating: "a", count: 1000)], at: t0)
        _ = try backup(repo, ["b.txt": String(repeating: "b", count: 1000)], at: t0.addingTimeInterval(86400 * 2))
        let orphan = Data((0..<5000).map { _ in UInt8.random(in: 0...255) })
        _ = try repo.putObject(orphan, hash: sha256Hex(orphan))
        let referenced = try repo.poolSize() - 5000
        // retention drops the first backup: collection is not due, but the cap needs the space
        var keepNewest = RetentionPolicy(); keepNewest.days = 0; keepNewest.weeks = 0; keepNewest.months = 0
        let r = try prune(repository: repo, policy: keepNewest, capBytes: referenced, now: t0.addingTimeInterval(86400 * 2),
                          refsCache: tmp(), gcDue: false)
        #expect(r.deletedSnapshots.count == 1 && r.collected && !repo.hasObject(sha256Hex(orphan)))
        let used = try repo.snapshotIDs().reduce(into: Set<String>()) { $0.formUnion(try repo.readSnapshot($1).entries.compactMap(\.hash)) }
        #expect(try repo.allObjectHashes() == used)
    }

    /// Orphans left by a deletion while the archive fitted push it over the cap later, with nothing deleted by
    /// retention in that run: they are collected now, the archive doesn't stay over the cap unnoticed.
    @Test func orphansOverCapWithoutDeletion() throws {
        func rnd(_ n: Int) -> String { String((0..<n).map { _ in "0123456789abcdefghijklmnopqrstuvwxyz".randomElement()! }) }
        let repo = try Repository(destination: dest, computerName: "Mac")
        let b = rnd(20000)
        _ = try backup(repo, ["a.txt": rnd(20000)], at: t0)
        _ = try backup(repo, ["b.txt": b], at: t0.addingTimeInterval(86400 * 2))
        var keepNewest = RetentionPolicy(); keepNewest.days = 0; keepNewest.weeks = 0; keepNewest.months = 0
        let first = try prune(repository: repo, policy: keepNewest, capBytes: 1 << 40, now: t0.addingTimeInterval(86400 * 2),
                              refsCache: tmp(), gcDue: false)
        #expect(first.deletedSnapshots.count == 1 && !first.collected) // fits: the orphan waits for the daily collection
        _ = try backup(repo, ["b.txt": b, "c.txt": rnd(20000)], at: t0.addingTimeInterval(86400 * 2 + 3600))
        let cap = try repo.poolSize() - 5000 // what the two backups use fits, with the orphan it doesn't
        let second = try prune(repository: repo, policy: keepAll, capBytes: cap, now: t0.addingTimeInterval(86400 * 2 + 3600),
                               refsCache: tmp(), gcDue: false)
        #expect(second.deletedSnapshots.isEmpty && second.collected && !second.overCap)
        #expect(try repo.poolSize() <= cap)
    }

    /// Object sizes from the bulk listing are the files' sizes.
    @Test func bulkObjectSizesMatchTheFiles() throws {
        let repo = try Repository(destination: dest, computerName: "Mac")
        _ = try backup(repo, ["a.txt": String(repeating: "a", count: 5000), "b.bin": "b"], at: t0)
        let sizes = try repo.objectSizes()
        #expect(sizes.count == 2)
        for (h, size) in sizes {
            let url = try #require(objectFile(repo, h))
            #expect(size == (try fm.attributesOfItem(atPath: url.path)[.size] as? Int64))
        }
    }

    /// The text references of earlier versions are still used (and rewritten in binary); a binary one that doesn't
    /// verify is read from the manifest again: in neither case is an object a kept backup uses deleted.
    @Test func referencesCacheOldTextAndDamagedBinary() throws {
        let refs = tmp()
        let repo = try Repository(destination: dest, computerName: "Mac")
        let a = try #require(try backup(repo, ["a.txt": "uno"], at: t0).snapshotID)
        let b = try #require(try backup(repo, ["b.txt": "due"], at: t0.addingTimeInterval(86400)).snapshotID)
        _ = try backup(repo, ["c.txt": "tre"], at: t0.addingTimeInterval(2 * 86400))
        _ = try prune(repository: repo, policy: keepAll, capBytes: nil, now: t0, refsCache: refs, forceGC: true)
        // a: as 0.9.x cached it, its manifest made unreadable so only the cache can answer
        try sha256Hex(Data("uno".utf8)).write(to: refs.appending(path: a), atomically: true, encoding: .utf8)
        try Data("garbage".utf8).write(to: manifestURL(repo, a))
        // b: the binary cache damaged, its manifest fine
        var binary = try Data(contentsOf: refs.appending(path: b))
        #expect(binary.starts(with: Data("BMREFS1\n".utf8)))
        binary[binary.count - 1] ^= 0xff
        try binary.write(to: refs.appending(path: b))
        let r = try prune(repository: repo, policy: keepAll, capBytes: nil, now: t0, refsCache: refs, forceGC: true)
        #expect(r.collected && r.deletedObjects == 0)
        for text in ["uno", "due", "tre"] { #expect(repo.hasObject(sha256Hex(Data(text.utf8))), "\(text)") }
        #expect(try Data(contentsOf: refs.appending(path: a)).starts(with: Data("BMREFS1\n".utf8)))
    }

    // MARK: warnings (B16)

    /// 250 warnings: report and manifest both list 200 and "… e altri 50 avvisi", not "altri 1 avvisi".
    @Test func warningsAreBoundedOnce() throws {
        for i in 0..<250 { write("x", to: src.appending(path: "f\(i).txt")) }
        write("ok", to: src.appending(path: "ok.txt"))
        let locked = (0..<250).map { src.appending(path: "f\($0).txt").path }
        for p in locked { try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: p) }
        defer { for p in locked { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: p) } }
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src])
        let manifest = try repo.readSnapshot(try #require(report.snapshotID)).warnings
        #expect(report.warnings.count == 201 && report.warnings.last == "… e altri 50 avvisi")
        #expect(manifest.count == 201 && manifest.last == "… e altri 50 avvisi")
        #expect(BackupEngine.bounded(Array(repeating: "x", count: 201), "avvisi", "avviso").last == "… e un altro avviso")
    }

    static func footprintPeakMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }

    @Test(.enabled(if: env["BACKUPME_PERF"] != nil)) func measure() throws {
        let phase = Self.env["BACKUPME_PERF"]!
        let base = URL(fileURLWithPath: try #require(Self.env["BACKUPME_PERF_DIR"]))
        let n = Int(Self.env["BACKUPME_PERF_N"] ?? "100000")!
        let src = base.appending(path: "Documenti", directoryHint: .isDirectory), dest = base.appending(path: "dest")
        let fm = FileManager.default
        if phase == "setup" {
            try? fm.removeItem(at: base)
            for i in 0..<n {
                let dir = src.appending(path: "progetto-\(i / 10_000)/cartella con nome lungo \(i / 100)")
                if i % 100 == 0 { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                try Data("contenuto del file numero \(i)\n".utf8).write(to: dir.appending(path: "documento-\(i).txt"))
            }
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            return
        }
        if phase == "changed" {
            try Data("cambiato \(Date())".utf8).write(to: src.appending(path: "progetto-0/cartella con nome lungo 0/documento-0.txt"))
        }
        let start = Date()
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: base.appending(path: "hashcache.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src])
        let backup = Date().timeIntervalSince(start)
        let peakBackup = Self.footprintPeakMB()
        let t = Date()
        // BACKUPME_PERF_CAP: a cap below what is stored, to time the full count of references
        let cap = Self.env["BACKUPME_PERF_CAP"].flatMap { Int64($0) } ?? 1 << 40
        let pruned = try prune(repository: repo, policy: keepAll, capBytes: cap, now: Date(),
                               refsCache: base.appending(path: "refs"), gcDue: false)
        let pruneTime = Date().timeIntervalSince(t)
        print(String(format: "PERF phase=%@ n=%d files=%d new=%lld backup=%.2fs peakBackup=%.0fMB prune=%.2fs peak=%.0fMB pool=%lld",
                     phase, n, report.fileCount, report.newBytes, backup, peakBackup, pruneTime, Self.footprintPeakMB(), pruned.poolSize))
    }
}
