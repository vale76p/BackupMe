import Foundation
import Testing
@testable import BackupCore

/// Regression tests for the findings of the adversarial review of 0.6.2.
@Suite struct AdversarialReview062Tests {
    let dest = tmp()
    let base = tmp()
    var src: URL { base.appending(path: "progetto", directoryHint: .isDirectory) }
    let fm = FileManager.default
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func crafted(_ entries: [Entry], objects: [Data]) throws -> (Repository, Snapshot) {
        let r = try Repository(destination: dest, computerName: "Mac")
        for d in objects { _ = try r.putObject(d, hash: sha256Hex(d)) }
        let s = Snapshot(date: t0, sources: [src.path], entries: entries, warnings: [])
        try r.writeSnapshot(s)
        return (r, s)
    }

    func entry(_ path: String, _ kind: EntryKind, data: Data? = nil, hash: String? = nil, link: String? = nil) -> Entry {
        Entry(source: src.path, path: path, kind: kind, hash: hash ?? data.map(sha256Hex), size: Int64(data?.count ?? 0),
              mtime: t0, mode: kind == .directory ? 0o755 : 0o644, linkTarget: link)
    }

    // MARK: restore

    @Test func caseCollisionSymlinkDoesNotEscape() throws {
        let outside = tmp(), evil = Data("PWNED".utf8)
        let (r, s) = try crafted([entry("", .directory), entry("sub", .symlink, link: outside.path),
                                  entry("Sub", .directory), entry("Sub/evil.txt", .file, data: evil)], objects: [evil])
        _ = try? Restorer(repository: r, trash: { _ in }).restore(s, source: src.path, path: "", mode: .into(tmp()))
        #expect(!fm.fileExists(atPath: outside.appending(path: "evil.txt").path))
    }

    @Test func truncatedPreviewLeftoverIsExtractedAgain() throws {
        let good = Data(repeating: 7, count: 100_000)
        let e = entry("big.bin", .file, data: good)
        let (r, _) = try crafted([entry("", .directory), e], objects: [good])
        let previews = tmp()
        write("troncato", to: previews.appending(path: e.hash!).appending(path: e.name)) // older versions wrote in place
        #expect(try Data(contentsOf: try Restorer(repository: r).extract(e, into: previews)) == good)
    }

    @Test func manifestHashCannotPointOutsideTheArchive() throws {
        let victim = tmp()
        write("file locale", to: victim.appending(path: "nota.txt"))
        let previews = tmp()
        let hops = String(repeating: "../", count: previews.pathComponents.count)
        let (r, _) = try crafted([entry("", .directory)], objects: [])
        let e = entry("nota.txt", .file, hash: hops + String(victim.path.dropFirst()))
        #expect(throws: (any Error).self) { try Restorer(repository: r).extract(e, into: previews) }
        let e2 = entry("x.txt", .file, hash: hops + String(victim.appending(path: "nuova").path.dropFirst()))
        _ = try? Restorer(repository: r).extract(e2, into: previews)
        #expect(!fm.fileExists(atPath: victim.appending(path: "nuova").path))
        // and a restore refuses such a manifest outright
        try r.deleteSnapshot(Snapshot.id(for: t0))
        let (r2, s2) = try crafted([entry("", .directory), e], objects: [])
        #expect(throws: RestoreError.invalidEntry("nota.txt")) {
            try Restorer(repository: r2).restore(s2, source: src.path, path: "", mode: .into(tmp()))
        }
    }

    @Test(arguments: ["progetto/..", "/"]) func intoStaysInsideChosenFolder(_ srcPath: String) throws {
        let source = srcPath == "/" ? "/" : base.appending(path: srcPath).path
        let data = Data("ciao".utf8)
        let es = [Entry(source: source, path: "", kind: .directory, hash: nil, size: 0, mtime: t0, mode: 0o755, linkTarget: nil),
                  Entry(source: source, path: "a.txt", kind: .file, hash: sha256Hex(data), size: 4, mtime: t0, mode: 0o644, linkTarget: nil)]
        let r = try Repository(destination: dest, computerName: "Mac")
        _ = try r.putObject(data, hash: sha256Hex(data))
        let s = Snapshot(date: t0, sources: [source], entries: es, warnings: [])
        let chosen = tmp().appending(path: "scelta", directoryHint: .isDirectory)
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        let out = try Restorer(repository: r).restore(s, source: source, path: "", mode: .into(chosen))
        #expect(out.standardizedFileURL.path.hasPrefix(chosen.path + "/"))
    }

    // MARK: archive integrity

    var cacheURL: URL { base.appending(path: "cache.json") }
    func engine(_ r: Repository) -> BackupEngine {
        BackupEngine(repository: r, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: ExcludeRules.defaults))
    }

    @Test func manifestThatVanishesAndComesBackKeepsItsObjects() throws {
        let refs = tmp()
        let r = try Repository(destination: dest, computerName: "Mac")
        write("unico contenuto", to: src.appending(path: "a.txt"))
        let id = try #require(try engine(r).run(sources: [src], now: t0).snapshotID)
        _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs) // stays ".seen"
        let m = r.root.appending(path: "snapshots/\(id).json.lzfse"), hidden = tmp().appending(path: "m")
        try fm.moveItem(at: m, to: hidden) // a cloud re-sync hides it
        #expect(try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs).gcSkipped)
        try fm.moveItem(at: hidden, to: m)
        let r2 = try Repository(destination: dest, computerName: "Mac")
        _ = try prune(repository: r2, policy: RetentionPolicy(), capBytes: nil, now: t0, refsCache: refs, forceGC: true)
        #expect(r2.hasObject(sha256Hex(Data("unico contenuto".utf8))))
    }

    @Test func wrongClockDoesNotWipeHistoryAndTheNewBackupIsKept() throws {
        let refs = tmp()
        let r = try Repository(destination: dest, computerName: "Mac")
        for d in 0..<30 {
            write("v\(d)", to: src.appending(path: "a.txt"))
            let now = t0.addingTimeInterval(Double(d) * 86400)
            _ = try engine(r).run(sources: [src], now: now)
            _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: now, refsCache: refs)
        }
        let wrong = t0.addingTimeInterval(30 * 86400 + 2 * 365 * 86400)
        write("orologio sbagliato", to: src.appending(path: "a.txt"))
        _ = try engine(r).run(sources: [src], now: wrong)
        _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: nil, now: wrong, refsCache: refs)
        #expect(try r.snapshotIDs().count > 1)
        // clock fixed: the real new backup isn't the last id any more; the app pins it, so the cap can't take it
        let fixed = t0.addingTimeInterval(31 * 86400)
        write(String(repeating: "x", count: 4000), to: src.appending(path: "a.txt"))
        let real = try #require(try engine(r).run(sources: [src], now: fixed).snapshotID)
        _ = try prune(repository: r, policy: RetentionPolicy(), capBytes: 1, now: fixed, refsCache: refs, pinned: [real])
        #expect(r.snapshotExists(real))
    }

    @Test func unreadableSubfolderMakesThePartialBackupAnError() throws {
        let secret = src.appending(path: "clienti", directoryHint: .isDirectory)
        write("contratto", to: secret.appending(path: "contratto.txt"))
        write("x", to: src.appending(path: "a.txt"))
        let r = try Repository(destination: dest, computerName: "Mac")
        _ = try engine(r).run(sources: [src], now: t0)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }
        write("y", to: src.appending(path: "a.txt"))
        let report = try engine(r).run(sources: [src], now: t0.addingTimeInterval(2 * 86400))
        #expect(report.error?.contains("clienti") == true)
    }

    @Test func gitRepackDuringTheBackupIsReadAgain() throws {
        let git = src.appending(path: ".git", directoryHint: .isDirectory)
        write("ref: refs/heads/main\n", to: git.appending(path: "HEAD"))
        write("abc\n", to: git.appending(path: "refs/heads/main"))
        write("loose-object", to: git.appending(path: "objects/ab/cdef"))
        try fm.createDirectory(at: git.appending(path: "objects/pack"), withIntermediateDirectories: true)
        write("code", to: src.appending(path: "main.swift"))
        let r = try Repository(destination: dest, computerName: "Mac")
        var done = false
        let report = try engine(r).run(sources: [src], now: Date(), progress: { _ in
            guard !done else { return }
            done = true // `git maintenance` packs the loose object while the backup runs
            try? FileManager.default.removeItem(at: git.appending(path: "objects/ab/cdef"))
            write("packed", to: git.appending(path: "objects/pack/pack-1.pack"))
        })
        let paths = Set(try r.readSnapshot(report.snapshotID!).entries.map(\.path))
        #expect(paths.contains(".git/objects/pack/pack-1.pack"))
    }

    // MARK: scale

    @Test func interruptedBackupKeepsTheHashesItComputed() throws {
        for i in 0..<5 { write("contenuto \(i)", to: src.appending(path: "\(i).txt")) }
        let r = try Repository(destination: dest, computerName: "Mac")
        var ticks = 0
        _ = try? engine(r).run(sources: [src], now: t0, progress: { _ in ticks += 1 }, isCancelled: { ticks >= 3 })
        let cache = HashCache(url: cacheURL)
        let known = (0..<5).filter { i in
            let p = src.appending(path: "\(i).txt").path
            guard let st = FileStat(path: p) else { return false }
            return cache.lookup(path: p, inode: st.inode, size: st.size, mtime: st.mtime, ctime: st.ctime) != nil
        }
        #expect(!known.isEmpty) // without the save on failure the next attempt rereads every file
    }

    @Test func capWithManyManifestsKeepsWhatFits() throws {
        let refs = tmp()
        let r = try Repository(destination: dest, computerName: "Mac")
        for d in 0..<8 {
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try Data((0..<2000).map { _ in UInt8.random(in: 0...255) }).write(to: src.appending(path: "f\(d).bin"))
            _ = try engine(r).run(sources: [src], now: t0.addingTimeInterval(Double(d) * 86400))
        }
        let before = try r.snapshotIDs()
        let result = try prune(repository: r, policy: RetentionPolicy(), capBytes: 9000, now: t0.addingTimeInterval(8 * 86400),
                               refsCache: refs)
        #expect(!result.deletedSnapshots.isEmpty && result.deletedSnapshots.allSatisfy(before.contains))
        #expect(try r.snapshotIDs().last == before.last) // never the newest
        #expect(result.poolSize <= 9000 || result.overCap)
        // what GC left is exactly what the kept manifests use
        let used = try r.snapshotIDs().reduce(into: Set<String>()) { $0.formUnion(try r.readSnapshot($1).entries.compactMap(\.hash)) }
        #expect(try r.allObjectHashes() == used)
    }
}
