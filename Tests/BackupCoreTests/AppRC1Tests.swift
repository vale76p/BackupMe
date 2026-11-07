import Foundation
import Testing
@testable import BackupCore

/// Fixes of the rc1 round in the app's area: exclusions read once (#44), replaceCheck inside a nested .git (#45),
/// versions listed as backups are read (#18).
@Suite struct AppRC1Tests {
    /// `matchingPattern` as it was before the patterns were read once in init: the decisions must not change.
    static func legacyMatch(_ patterns: [String], name: String, isDirectory: Bool, path: String?) -> String? {
        patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.first { p in
            var p = p.hasSuffix("/") ? String(p.dropLast()) : p
            let byPath = p.contains("/")
            if byPath { p = p.hasPrefix("/") ? String(p.dropFirst()) : p }
            let last = (p as NSString).lastPathComponent
            guard isDirectory || last.hasPrefix(".") || last.contains(where: { "*?[".contains($0) }) else { return false }
            return byPath ? fnmatch(p, path ?? name, FNM_PATHNAME) == 0 : fnmatch(p, name, 0) == 0
        }
    }

    @Test func excludeDecisionsUnchanged() {
        let nfc = "Caf\u{e9}", nfd = "Cafe\u{301}"
        let patterns = ExcludeRules.defaults + [
            "*.log", "logs/", "/build", "apps/*/dist", ".git", nfc, "e\u{301}t\u{e9}", "[Tt]emp", "a\\*b", "?x",
            "dir//", "/", "  spaced  ", "*", "**/foo", "sub/", "/top/leaf", "Build", ".env*", "x/y/", "näme",
        ]
        let names = ExcludeRules.defaults + [
            nfc, nfd, nfc.lowercased(), nfd.uppercased(), "\u{e9}t\u{e9}", "e\u{301}te\u{301}", "build", "BUILD", "Build",
            ".git", ".gitignore", "a.log", "A.LOG", "logs", "temp", "Temp", "TEMP", "a*b", "a\\*b", "ax", "xx", "dir",
            "spaced", "  spaced  ", "foo", "dist", "sub", "top", "leaf", ".env", ".env.local", "y", "x", "na\u{308}me",
            "n\u{e4}me", "file.txt", "", " ",
        ]
        let parents = ["", "apps/web", "top", "sub", "a/b", "x", nfd, nfc, ".git", "apps/web/.git", "logs"]
        var checked = 0
        for set in [patterns, ExcludeRules.defaults, [], ["*"], ["/build", "apps/*/dist"], [nfc, nfd]] {
            let rules = ExcludeRules(patterns: set)
            for name in names {
                for parent in parents {
                    let path = parent.isEmpty ? name : parent + "/" + name
                    for isDir in [true, false] {
                        for p in [path, nil] as [String?] {
                            let expected = Self.legacyMatch(set, name: name, isDirectory: isDir, path: p)
                            #expect(rules.matchingPattern(name: name, isDirectory: isDir, path: p) == expected,
                                    "\(set.count) pattern, \(path) dir \(isDir)")
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked > 10_000)
        // composed and decomposed are different names, as for fnmatch and the disk
        let rules = ExcludeRules(patterns: [nfc])
        #expect(rules.excludes(name: nfc, isDirectory: true))
        #expect(!rules.excludes(name: nfd, isDirectory: true))
    }

    /// Inside a nested .git the backup applies no exclusion and no size limit: what replaceCheck counts as new
    /// must be exactly what the backup would have saved.
    @Test func replaceCheckNestedGitMatchesBackup() throws {
        let base = tmp(), src = base.appending(path: "progetto")
        write("a", to: src.appending(path: "a.txt"))
        write("x", to: src.appending(path: "build/out.o")) // excluded folder: neither saved nor new
        write(String(repeating: "x", count: 100), to: src.appending(path: "grande.bin")) // over the limit
        write("ref", to: src.appending(path: "sub/.git/refs/heads/build/feature")) // a branch "build/feature"
        write(String(repeating: "x", count: 100), to: src.appending(path: "sub/.git/objects/pack/p.pack"))
        write(".DS", to: src.appending(path: "sub/.git/.DS_Store"))
        write("z", to: src.appending(path: "sub/node_modules/z.js"))
        let rules = ExcludeRules(patterns: ExcludeRules.defaults, maxFileSize: 10)

        let repo = try Repository(destination: base, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: base.appending(path: "cache.json")),
                                      excludes: rules).run(sources: [src])
        let snapshot = try repo.readSnapshot(try #require(report.snapshotID))
        let savedFiles = snapshot.entries.filter { $0.kind == .file }.map(\.path).sorted()
        #expect(savedFiles == ["a.txt", "sub/.git/.DS_Store", "sub/.git/objects/pack/p.pack", "sub/.git/refs/heads/build/feature"])

        // nothing changed since the backup: nothing new
        #expect(Restorer.replaceCheck(snapshot, source: src.path, rules: rules).newFiles == 0)
        // against a backup that lacks them all, the files counted are the ones the backup saves
        let empty = Snapshot(date: snapshot.date, sources: snapshot.sources, entries: [], warnings: [])
        #expect(Restorer.replaceCheck(empty, source: src.path, rules: rules).newFiles == savedFiles.count)
    }

    @Test func versionsNewestFirstUnderViewedBackup() {
        func e(_ hash: String?) -> Entry {
            Entry(source: "/s", path: "f.txt", kind: .file, hash: hash, size: 1, mtime: Date(), mode: 0o644, linkTarget: nil)
        }
        let order = ["s5", "s4", "s3", "s2", "s1"] // newest first
        // read in any order: the backups already open first, then the others as they arrive
        let found = [("s3", e("B")), ("s1", e("A")), ("s5", e("C")), ("s4", e("B")), ("s2", e("A")), ("x", e("D")), ("s2", e(nil))]
            .map { (snapshotID: $0.0, entry: $0.1) }
        let plain = Restorer.versions(found, newestFirst: order)
        #expect(plain.map(\.snapshotID) == ["s5", "s4", "s2"])
        #expect(plain.map(\.entry.hash) == ["C", "B", "A"])
        // the content of the backup being viewed is listed under it, in the place of its newest copy
        let viewed = Restorer.versions(found, newestFirst: order, preferring: "s3")
        #expect(viewed.map(\.snapshotID) == ["s5", "s3", "s2"])
        // the viewed one read first, a newer copy arriving later keeps it
        let late = Restorer.versions([found[0], found[3]], newestFirst: order, preferring: "s3")
        #expect(late.map(\.snapshotID) == ["s3"])
        #expect(Restorer.versions([], newestFirst: order).isEmpty)
    }
}
