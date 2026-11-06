import Foundation
import Testing
@testable import BackupCore

@Suite struct SourcesAndExcludesTests {
    let base = tmp()
    let cacheURL = tmp().appending(path: "cache.json")
    let fm = FileManager.default

    func run(_ sources: [URL], dest: URL, rules: ExcludeRules = ExcludeRules(patterns: [])) throws -> (BackupReport, Snapshot, Repository) {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let r = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: rules).run(sources: sources)
        return (r, try repo.readSnapshot(try #require(r.snapshotID)), repo)
    }

    @Test func singleFilesAreSourcesAndRestore() throws {
        let a = base.appending(path: "note.txt"), b = base.appending(path: "altro/conti.csv")
        write("appunti", to: a)
        write("1;2", to: b)
        let (report, s, repo) = try run([a, b], dest: tmp())
        #expect(report.error == nil && report.fileCount == 2)
        #expect(s.entries.map(\.path) == ["", ""] && s.entries.allSatisfy { $0.kind == .file })
        let out = tmp()
        let restored = try Restorer(repository: repo).restore(s, source: a.path, path: "", mode: .into(out))
        #expect(restored == out.appending(path: "note.txt"))
        #expect(try String(contentsOf: restored, encoding: .utf8) == "appunti")
        let beside = try Restorer(repository: repo).restore(s, source: b.path, path: "", mode: .besideOriginal)
        #expect(beside.lastPathComponent.hasPrefix("conti (ripristinato") && beside.pathExtension == "csv")
    }

    @Test func unreadableFileSourceIsAnError() throws {
        let a = base.appending(path: "chiuso.txt"), ok = base.appending(path: "ok.txt")
        write("x", to: a)
        write("y", to: ok)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: a.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path) }
        let (report, _, _) = try run([a, ok], dest: tmp())
        #expect(report.error?.contains("chiuso.txt") == true)
    }

    /// The whole profile with the destination inside its Library: the archive never ends up in its own backup.
    @Test func sourceHoldingTheDestinationSkipsIt() throws {
        write("codice", to: base.appending(path: "progetto/main.swift"))
        write("loose", to: base.appending(path: ".zshrc"))
        let dest = base.appending(path: "Library/CloudStorage/OneDrive/Backup", directoryHint: .isDirectory)
        write("altro", to: base.appending(path: "Library/Preferences/p.plist"))
        write("buttato", to: base.appending(path: ".Trash/vecchio.txt"))
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let auto = ExcludeRules.automatic(destination: dest.path, home: base.path).map(\.path)
        let (report, s, _) = try run([base], dest: dest, rules: ExcludeRules(patterns: [], paths: auto))
        let paths = Set(s.entries.map(\.path))
        #expect(report.error == nil)
        #expect(paths.contains("progetto/main.swift") && paths.contains(".zshrc"), "files of the profile are saved too")
        #expect(!paths.contains { $0.hasPrefix("Library") || $0.hasPrefix(".Trash") })
        #expect(report.excluded?.contains(base.lastPathComponent + "/Library") == true)
    }

    @Test func archiveFolderSkippedEvenWithoutRules() throws {
        write("codice", to: base.appending(path: "main.swift"))
        let dest = base.appending(path: "backup", directoryHint: .isDirectory)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let (_, s, _) = try run([base], dest: dest)
        #expect(s.entries.contains { $0.path == "main.swift" })
        #expect(!s.entries.contains { $0.path.hasPrefix("backup/BackupMe") })
    }

    @Test func excludedPathLeavesOutOnlyThatFolder() throws {
        write("v", to: base.appending(path: "a/video/film.mov"))
        write("v", to: base.appending(path: "b/video/clip.mov"))
        let rules = ExcludeRules(patterns: [], paths: [base.appending(path: "a/video").path])
        let (_, s, _) = try run([base], dest: tmp(), rules: rules)
        let paths = Set(s.entries.map(\.path))
        #expect(!paths.contains("a/video") && paths.contains("b/video/clip.mov"))
        // the saved item itself is never left out by its own path
        let (_, own, _) = try run([base.appending(path: "a/video")], dest: tmp(), rules: rules)
        #expect(own.entries.contains { $0.path == "film.mov" })
    }

    @Test func patternsThatWouldEmptyTheBackupAreRefused() {
        let existing = ["node_modules"]
        for bad in ["", " ", "*", "/", "*/", "node_modules", "?*"] {
            #expect(ExcludeRules.problem(with: bad, in: existing) != nil, "\(bad)")
        }
        for good in ["*.log", ".cache", "apps/*/dist", "/build", "coverage/"] {
            #expect(ExcludeRules.problem(with: good, in: existing) == nil, "\(good)")
        }
    }

    @Test func kindMatchesHowAPatternIsRead() {
        #expect(ExcludeRules.kind(of: "build") == .folders)
        #expect(ExcludeRules.kind(of: "build/") == .folders)
        #expect(ExcludeRules.kind(of: "*.log") == .foldersAndFiles)
        #expect(ExcludeRules.kind(of: ".DS_Store") == .foldersAndFiles)
        #expect(ExcludeRules.kind(of: "apps/*/dist") == .path)
        #expect(ExcludeRules.kind(of: "/build") == .rootPath)
        let r = ExcludeRules(patterns: ["build", "*.log"])
        #expect(r.matchingPattern(name: "x.log", isDirectory: false) == "*.log")
        #expect(r.matchingPattern(name: "build", isDirectory: false) == nil)
    }
}
