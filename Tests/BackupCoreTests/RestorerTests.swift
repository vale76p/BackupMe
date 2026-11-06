import Foundation
import Testing
@testable import BackupCore

@Suite struct RestorerTests {
    let dest = tmp()
    let base = tmp()
    var src: URL { base.appending(path: "progetto", directoryHint: .isDirectory) }
    let cacheURL = tmp().appending(path: "cache.json")
    let trashDir = tmp()
    let fm = FileManager.default

    func restorer(_ repo: Repository) -> Restorer {
        Restorer(repository: repo, trash: { url in
            try FileManager.default.moveItem(at: url, to: trashDir.appending(path: UUID().uuidString))
        })
    }

    func backup(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> (Repository, Snapshot) {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let r = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                                 excludes: ExcludeRules(patterns: [])).run(sources: [src], now: date)
        return (repo, try repo.readSnapshot(r.snapshotID!))
    }

    func mtime(_ path: String) -> Double {
        var st = stat(); lstat(path, &st)
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    @Test func restoredNameFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
        #expect(Restorer.restoredName("README.md", date: d) == "README (ripristinato 5 nov 10.00).md")
        #expect(Restorer.restoredName(".env", date: d) == ".env (ripristinato 5 nov 10.00)")
        #expect(Restorer.restoredName("app-web", date: d) == "app-web (ripristinato 5 nov 10.00)")
    }

    @Test func replaceRefusesFolderHoldingTheArchive() throws {
        write("a", to: src.appending(path: "a.txt"))
        let inside = src.appending(path: "Backup", directoryHint: .isDirectory)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        let repo = try Repository(destination: inside, computerName: "Mac")
        let r = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                                 excludes: ExcludeRules(patterns: [])).run(sources: [src])
        let snapshot = try repo.readSnapshot(r.snapshotID!)
        #expect(throws: RestoreError.containsArchive(src.resolvingSymlinksInPath().path)) {
            try restorer(repo).restore(snapshot, source: src.path, path: "", mode: .replace)
        }
        #expect(fm.fileExists(atPath: repo.root.appending(path: "repo.json").path))
        #expect(try fm.contentsOfDirectory(atPath: trashDir.path).isEmpty)
    }

    @Test func roundTripWholeSourceInto() throws {
        write("ciao", to: src.appending(path: "spazi e àccénti 🎉.txt"))
        write("", to: src.appending(path: "vuoto.txt"))
        try fm.createDirectory(at: src.appending(path: "cartella vuota"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: src.appending(path: "rotto").path, withDestinationPath: "nessuno")
        write("#!/bin/sh", to: src.appending(path: "run.sh"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appending(path: "run.sh").path)
        write("ro", to: src.appending(path: "sola-lettura/dentro.txt"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: src.appending(path: "sola-lettura").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appending(path: "sola-lettura").path) }

        let (repo, snap) = try backup()
        let out = tmp()
        let result = try restorer(repo).restore(snap, source: src.path, path: "", mode: .into(out))
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: result.appending(path: "sola-lettura").path) }
        #expect(result.lastPathComponent == "progetto")

        for e in snap.entries {
            let orig = e.path.isEmpty ? src.path : src.path + "/" + e.path
            let copy = e.path.isEmpty ? result.path : result.path + "/" + e.path
            let a = try fm.attributesOfItem(atPath: orig), b = try fm.attributesOfItem(atPath: copy)
            #expect(a[.type] as? FileAttributeType == b[.type] as? FileAttributeType, "\(e.path)")
            if e.kind == .symlink {
                #expect(try fm.destinationOfSymbolicLink(atPath: copy) == "nessuno")
                continue
            }
            #expect(a[.posixPermissions] as? Int == b[.posixPermissions] as? Int, "\(e.path)")
            #expect(abs(mtime(orig) - mtime(copy)) < 0.001, "\(e.path)")
            if e.kind == .file { #expect(fm.contentsEqual(atPath: orig, andPath: copy), "\(e.path)") }
        }
    }

    @Test func besideOriginalNeverOverwrites() throws {
        write("vecchio", to: src.appending(path: "a.txt"))
        let (repo, snap) = try backup()
        write("nuovo", to: src.appending(path: "a.txt"))
        let result = try restorer(repo).restore(snap, source: src.path, path: "a.txt", mode: .besideOriginal)
        #expect(try String(contentsOf: src.appending(path: "a.txt"), encoding: .utf8) == "nuovo")
        #expect(result.deletingLastPathComponent().path == src.path)
        #expect(result.lastPathComponent.hasPrefix("a (ripristinato "))
        #expect(try String(contentsOf: result, encoding: .utf8) == "vecchio")
    }

    @Test func replaceTrashesCurrent() throws {
        write("vecchio", to: src.appending(path: "a.txt"))
        let (repo, snap) = try backup()
        write("nuovo", to: src.appending(path: "a.txt"))
        write("extra", to: src.appending(path: "b.txt"))
        let result = try restorer(repo).restore(snap, source: src.path, path: "", mode: .replace)
        #expect(result.path == src.path)
        #expect(try String(contentsOf: src.appending(path: "a.txt"), encoding: .utf8) == "vecchio")
        #expect(!fm.fileExists(atPath: src.appending(path: "b.txt").path))
        let trashed = try fm.contentsOfDirectory(atPath: trashDir.path)
        #expect(trashed.count == 1)
        #expect(fm.fileExists(atPath: trashDir.appending(path: trashed[0]).appending(path: "b.txt").path))
    }

    @Test func replaceKeepsRestoredCopyWhenFolderReappears() throws {
        write("vecchio", to: src.appending(path: "a.txt"))
        let (repo, snap) = try backup()
        // an IDE recreating the folder right after it went to the Trash
        let r = Restorer(repository: repo, trash: { url in
            try FileManager.default.moveItem(at: url, to: trashDir.appending(path: UUID().uuidString))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        })
        var kept: String?
        do { _ = try r.restore(snap, source: src.path, path: "", mode: .replace) } catch RestoreError.keptBeside(let p) { kept = p }
        let copy = try #require(kept)
        #expect(try String(contentsOf: URL(fileURLWithPath: copy).appending(path: "a.txt"), encoding: .utf8) == "vecchio")
        #expect(try fm.contentsOfDirectory(atPath: trashDir.path).count == 1)
    }

    @Test func extractWritesOnlyATemporaryCopy() throws {
        write("contenuto", to: src.appending(path: "a.txt"))
        let (repo, snap) = try backup()
        let e = try #require(snap.entries.first { $0.path == "a.txt" })
        let base = tmp()
        let url = try restorer(repo).extract(e, into: base)
        #expect(url.path.hasPrefix(base.path) && url.lastPathComponent == "a.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "contenuto")
        #expect(try restorer(repo).extract(e, into: base) == url) // same version: extracted once
        #expect(try fm.contentsOfDirectory(atPath: src.path) == ["a.txt"])
    }

    @Test func replaceCheckCountsChangesAndNewerCommits() throws {
        write("uno", to: src.appending(path: "a.txt"))
        write("due", to: src.appending(path: "b.txt"))
        write("ref: refs/heads/main\n", to: src.appending(path: ".git/HEAD"))
        write("aaaa\n", to: src.appending(path: ".git/refs/heads/main"))
        write("x", to: src.appending(path: ".git/objects/aa/bb"))
        let (_, snap) = try backup()
        #expect(Restorer.replaceCheck(snap, source: src.path) == .init(changedFiles: 0, repositoryChanged: false))
        write("uno modificato", to: src.appending(path: "a.txt"))
        try fm.removeItem(at: src.appending(path: "b.txt")) // deleted today: the backup brings it back, nothing lost
        write("y", to: src.appending(path: ".git/objects/aa/bb"))
        #expect(Restorer.replaceCheck(snap, source: src.path) == .init(changedFiles: 1, repositoryChanged: false))
        write("bbbbbb\n", to: src.appending(path: ".git/refs/heads/main"))
        #expect(Restorer.replaceCheck(snap, source: src.path).repositoryChanged)
    }

    @Test func symlinkedSourceIsComparedThroughTheLink() throws {
        write("a", to: src.appending(path: "a.txt"))
        let link = base.appending(path: "collegamento")
        try fm.createSymbolicLink(at: link, withDestinationURL: src)
        let repo = try Repository(destination: dest, computerName: "Mac")
        let r = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: []))
            .run(sources: [link], now: Date(timeIntervalSince1970: 1_700_000_000))
        let root = try #require(try repo.readSnapshot(r.snapshotID!).entries.first { $0.path.isEmpty })
        #expect(Restorer.status(of: root) == .unchanged)
    }

    @Test func corruptObjectFailsRestore() throws {
        write("a", to: src.appending(path: "a.txt"))
        let (repo, snap) = try backup()
        let h = sha256Hex(Data("a".utf8))
        try Data("b".utf8).write(to: objectFile(repo, h)!)
        #expect(throws: RepositoryError.corruptObject(h)) {
            try restorer(repo).restore(snap, source: src.path, path: "a.txt", mode: .into(tmp()))
        }
    }

    @Test func versionsDistinctByHash() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        write("v1", to: src.appending(path: "a.txt"))
        _ = try backup(at: t)
        _ = try backup(at: t.addingTimeInterval(3600))
        write("v2", to: src.appending(path: "a.txt"))
        let (repo, _) = try backup(at: t.addingTimeInterval(7200))
        let v = try restorer(repo).versions(source: src.path, path: "a.txt")
        #expect(v.count == 2)
        #expect(v[0].entry.hash == sha256Hex(Data("v2".utf8)))
        #expect(v[1].snapshotID == Snapshot.id(for: t))
    }

    @Test func statusDetection() throws {
        write("a", to: src.appending(path: "a.txt"))
        write("b", to: src.appending(path: "b.txt"))
        write("c", to: src.appending(path: "c.txt"))
        let (_, snap) = try backup()
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: src.appending(path: "b.txt").path)
        write("bb", to: src.appending(path: "b.txt"))
        try fm.removeItem(at: src.appending(path: "c.txt"))
        let entry = { (p: String) in snap.entries.first { $0.path == p }! }
        #expect(Restorer.status(of: entry("a.txt")) == .unchanged)
        #expect(Restorer.status(of: entry("b.txt")) == .modified)
        #expect(Restorer.status(of: entry("c.txt")) == .missing)
    }
}
