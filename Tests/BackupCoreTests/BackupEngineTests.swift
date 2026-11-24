import Foundation
import Testing
@testable import BackupCore

@Suite struct BackupEngineTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let cacheURL = tmp().appending(path: "cache.json")

    func engine() throws -> (BackupEngine, Repository) {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let e = BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                             excludes: ExcludeRules(patterns: ExcludeRules.defaults))
        return (e, repo)
    }

    func makeSource() {
        write("a", to: src.appending(path: "a.txt"))
        write("b", to: src.appending(path: "sub/b.txt"))
        write("ref: refs/heads/main", to: src.appending(path: ".git/HEAD"))
        write("x", to: src.appending(path: "node_modules/x.js"))
        try! FileManager.default.createSymbolicLink(atPath: src.appending(path: "link").path, withDestinationPath: "../a.txt")
    }

    @Test func excludesByName() {
        let r = ExcludeRules(patterns: ExcludeRules.defaults + ["*.log"])
        #expect(r.excludes(name: "node_modules", isDirectory: true))
        #expect(r.excludes(name: "x.log", isDirectory: false))
        #expect(!r.excludes(name: ".git", isDirectory: true))
    }

    @Test func backupCreatesSnapshotWithEntries() throws {
        makeSource()
        let (e, repo) = try engine()
        let report = try e.run(sources: [src])
        #expect(report.error == nil)
        let ids = try repo.snapshotIDs()
        #expect(ids.count == 1)
        #expect(report.snapshotID == ids.first)
        let s = try repo.readSnapshot(ids[0])
        let paths = Set(s.entries.map(\.path))
        #expect(paths == ["", "a.txt", "sub", "sub/b.txt", ".git", ".git/HEAD", "link"])
        let link = s.entries.first { $0.path == "link" }!
        #expect(link.kind == .symlink)
        #expect(link.linkTarget == "../a.txt")
        #expect(s.entries.first { $0.path == "a.txt" }!.hash == sha256Hex(Data("a".utf8)))
    }

    @Test func secondBackupWritesNoNewObjects() throws {
        makeSource()
        let (e, repo) = try engine()
        _ = try e.run(sources: [src], now: Date(timeIntervalSince1970: 1_000_000))
        let objects = try repo.allObjectHashes()
        let r2 = try e.run(sources: [src], now: Date(timeIntervalSince1970: 1_003_600))
        #expect(r2.newBytes == 0)
        #expect(try repo.allObjectHashes() == objects)
        #expect(try repo.snapshotIDs().count == 1)
    }

    @Test func identicalFilesStoredOnce() throws {
        write("uguale", to: src.appending(path: "a.txt"))
        write("uguale", to: src.appending(path: "copia.txt"))
        let (e, repo) = try engine()
        _ = try e.run(sources: [src])
        #expect(try repo.allObjectHashes().count == 1)
    }

    @Test func hashCacheHitsOnlyOnIdenticalStamp() throws {
        let url = tmp().appending(path: "c.json")
        let m = Date(timeIntervalSince1970: 1000), c = Date(timeIntervalSince1970: 2000)
        let cache = HashCache(url: url)
        cache.store(path: "/a", inode: 1, size: 3, mtime: m, ctime: c, hash: "h")
        try cache.save()
        let reloaded = HashCache(url: url)
        #expect(reloaded.lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: c) == "h")
        #expect(reloaded.lookup(path: "/a", inode: 1, size: 3, mtime: m, ctime: c.addingTimeInterval(1)) == nil)
    }

    @Test func unreadableFileIsWarning() throws {
        write("a", to: src.appending(path: "a.txt"))
        let secret = src.appending(path: "segreto.txt")
        write("s", to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }
        let (e, repo) = try engine()
        let r = try e.run(sources: [src])
        #expect(r.error == nil)
        #expect(r.warnings.contains { $0.contains("segreto.txt") })
        let s = try repo.readSnapshot(r.snapshotID!)
        #expect(s.entries.contains { $0.path == "a.txt" })
        #expect(!s.entries.contains { $0.path == "segreto.txt" })
    }

    @Test func validateRejectsOverlap() throws {
        let (_, repo) = try engine()
        // a source holding the archive is fine (the engine skips it); one inside it is not
        #expect(BackupEngine.validate(sources: [dest], repositoryRoot: repo.root) == nil)
        #expect(BackupEngine.validate(sources: [repo.root], repositoryRoot: repo.root) == .sourceOverlapsDestination(repo.root.path))
        #expect(BackupEngine.validate(sources: [repo.root.appending(path: "objects")], repositoryRoot: repo.root) != nil)
        #expect(BackupEngine.validate(sources: [src], repositoryRoot: repo.root) == nil)
    }

    @Test func cancelledLeavesNoSnapshot() throws {
        makeSource()
        let (e, repo) = try engine()
        #expect(throws: BackupError.cancelled) { try e.run(sources: [src], isCancelled: { true }) }
        #expect(try repo.snapshotIDs().isEmpty)
    }

    @Test func excludesByRelativePath() {
        let r = ExcludeRules(patterns: ["build/output", "apps/*/dist", "/top", "cache/"])
        #expect(r.excludes(name: "output", isDirectory: true, path: "build/output"))
        #expect(!r.excludes(name: "output", isDirectory: true, path: "x/build/output"))
        #expect(r.excludes(name: "dist", isDirectory: true, path: "apps/web/dist"))
        #expect(!r.excludes(name: "dist", isDirectory: true, path: "apps/web/src/dist"))
        #expect(!r.excludes(name: "dist", isDirectory: false, path: "apps/web/dist"))
        #expect(r.excludes(name: "top", isDirectory: true, path: "top"))
        #expect(!r.excludes(name: "top", isDirectory: true, path: "a/top"))
        #expect(r.excludes(name: "cache", isDirectory: true, path: "a/cache"))
    }

    @Test func cacheDirTagSkippedAndExcludedListed() throws {
        write("a", to: src.appending(path: "a.txt"))
        write("Signature: 8a477f597d28d172789f06886806bc55\n# cache", to: src.appending(path: "cache/CACHEDIR.TAG"))
        write("x", to: src.appending(path: "cache/x.bin"))
        write("not a tag", to: src.appending(path: "finto/CACHEDIR.TAG"))
        write("Signature: 8a477f597d28d172789f06886806bc55", to: src.appending(path: ".git/hooks/CACHEDIR.TAG"))
        write("x", to: src.appending(path: "node_modules/x.js"))
        write("x", to: src.appending(path: "x.log"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                                      excludes: ExcludeRules(patterns: ExcludeRules.defaults + ["*.log"])).run(sources: [src])
        #expect(report.excluded == ["progetto/cache", "progetto/node_modules"])
        let paths = Set(try repo.readSnapshot(report.snapshotID!).entries.map(\.path))
        #expect(paths.isSuperset(of: ["finto/CACHEDIR.TAG", ".git/hooks/CACHEDIR.TAG"]))
        #expect(paths.isDisjoint(with: ["cache", "node_modules", "x.log"]))
    }

    @Test func excludedListIsCapped() throws {
        for i in 0..<205 { try FileManager.default.createDirectory(at: src.appending(path: "p\(i)/build"), withIntermediateDirectories: true) }
        write("a", to: src.appending(path: "a.txt"))
        let (e, _) = try engine()
        #expect(try e.run(sources: [src]).excluded?.count == 200)
    }

    /// Not skipped silently, and not a warning only: the backup is partial, so retention keeps its last copies.
    @Test func savedFileTurningUnreadableMakesThePartialBackup() throws {
        let file = src.appending(path: "a.txt")
        write("prima", to: file)
        let repo = try Repository(destination: dest, computerName: "Mac")
        func run() throws -> BackupReport {
            try BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: []),
                             skipUnreadable: true).run(sources: [src])
        }
        _ = try run()
        write("dopo", to: file) // changed, so the cache can't answer for it
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let r = try run()
        #expect(r.skipped == nil && r.error?.contains("File già salvato che ora non si legge") == true)
    }

    @Test func filesOverSizeLimitAreExcluded() throws {
        write("piccolo", to: src.appending(path: "a.txt"))
        write(String(repeating: "x", count: 100), to: src.appending(path: "video/grande.mov"))
        write(String(repeating: "x", count: 100), to: src.appending(path: ".git/objects/pack/p.pack"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                                      excludes: ExcludeRules(patterns: [], maxFileSize: 50)).run(sources: [src])
        #expect(report.excluded == ["progetto/video/grande.mov"])
        let paths = Set(try repo.readSnapshot(report.snapshotID!).entries.map(\.path))
        #expect(paths.contains("a.txt") && paths.contains(".git/objects/pack/p.pack") && !paths.contains("video/grande.mov"))
    }

    @Test func unreadableFileIsSkippedNotWarned() throws {
        write("a", to: src.appending(path: "a.txt"))
        let locked = src.appending(path: ".taniu")
        write("segreto", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let repo = try Repository(destination: dest, computerName: "Mac")
        func run(skip: Bool) throws -> BackupReport {
            try BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: []),
                             skipUnreadable: skip).run(sources: [src])
        }
        let warned = try run(skip: false)
        #expect(warned.warnings.count == 1 && warned.skipped == nil)
        let skipped = try run(skip: true)
        #expect(skipped.warnings.isEmpty && skipped.error == nil && skipped.fileCount == 1)
        #expect(skipped.skipped == [locked.path])
    }

    @Test func oldReportWithoutExcludedDecodes() throws {
        let json = #"{"date":0,"duration":1,"fileCount":2,"newBytes":3,"warnings":[]}"#
        let r = try JSONDecoder().decode(BackupReport.self, from: Data(json.utf8))
        #expect(r.excluded == nil && r.fileCount == 2)
    }

    @Test func gitRefRewrittenDuringBackupIsReadAgain() throws {
        write("a", to: src.appending(path: "a.txt"))
        write("ref: refs/heads/main", to: src.appending(path: ".git/HEAD"))
        let ref = src.appending(path: ".git/refs/heads/main")
        write("vecchio", to: ref)
        let (e, repo) = try engine()
        var rewritten = false
        // the commit lands after the ref was read: the first pass holds the old ref
        let report = try e.run(sources: [src], progress: { if $0 == 1, !rewritten { rewritten = true; write("nuovo", to: ref) } })
        #expect(rewritten)
        #expect(!report.warnings.contains { $0.contains("git") })
        #expect(report.fileCount == 3)
        let s = try repo.readSnapshot(report.snapshotID!)
        #expect(s.entries.filter { $0.path == ".git/refs/heads/main" }.map(\.hash) == [sha256Hex(Data("nuovo".utf8))])
    }

    @Test func gitStillChangingIsWarned() throws {
        write("a", to: src.appending(path: "a.txt"))
        write("ref: refs/heads/main", to: src.appending(path: ".git/HEAD"))
        write("", to: src.appending(path: ".git/index.lock")) // git is in the middle of an operation
        let (e, repo) = try engine()
        let report = try e.run(sources: [src])
        #expect(report.warnings.contains("progetto: il repository git è cambiato durante il backup, ripeti il backup per averne una copia coerente"))
        #expect(report.fileCount == 3)
        #expect(try repo.readSnapshot(report.snapshotID!).entries.filter { $0.path == "a.txt" }.count == 1)
    }

    @Test func leftoverGitLockIsIgnored() throws {
        write("a", to: src.appending(path: "a.txt"))
        write("ref: refs/heads/main", to: src.appending(path: ".git/HEAD"))
        let lock = src.appending(path: ".git/index.lock")
        write("", to: lock) // left behind by a git that crashed an hour ago
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: lock.path)
        let (e, _) = try engine()
        let report = try e.run(sources: [src])
        #expect(!report.warnings.contains { $0.contains("repository git") })
    }
}
