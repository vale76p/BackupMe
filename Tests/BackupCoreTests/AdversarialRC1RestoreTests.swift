import Foundation
import Testing
@testable import BackupCore

/// Regression tests for the restore findings of the adversarial review of 1.0.0-rc1.
@Suite struct AdversarialRC1RestoreTests {
    let dest = tmp()
    let base = tmp()
    var src: URL { base.appending(path: "progetto", directoryHint: .isDirectory) }
    let cacheURL = tmp().appending(path: "cache.json")
    let fm = FileManager.default
    var kit: URL { dest.appending(path: "BackupMe") }

    func backup(_ sources: [URL], excludes: [String] = []) throws -> (Repository, Snapshot) {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let r = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL),
                                 excludes: ExcludeRules(patterns: excludes)).run(sources: sources)
        return (repo, try repo.readSnapshot(try #require(r.snapshotID)))
    }

    func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    func kitRestore(_ id: String, to out: URL) throws -> (status: Int32, out: String) {
        try run("/bin/sh", [kit.appending(path: "RIPRISTINO.command").path, "--si", "Mac", id, out.path])
    }

    /// A small disk image of filesystem `fs`, mounted until `body` returns.
    func withVolume(_ fs: String, _ body: (URL) throws -> Void) throws {
        let dir = tmp(), mount = dir.appending(path: "vol"), image = dir.appending(path: "vol.dmg")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try #require(try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "40m", "-fs", fs, "-volname", "T", image.path]).status == 0)
        try #require(try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]).status == 0)
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        try body(mount)
    }

    func entry(_ source: String, _ path: String, _ kind: EntryKind, data: Data = Data()) -> Entry {
        Entry(source: source, path: path, kind: kind, hash: kind == .file ? sha256Hex(data) : nil, size: Int64(data.count),
              mtime: Date(timeIntervalSince1970: 1_700_000_000), mode: kind == .directory ? 0o755 : 0o644, linkTarget: nil)
    }

    /// M2: exFAT and FAT32 reject RENAME_EXCL. The app restores there anyway, never replaces, and leaves no staging folder.
    @Test(arguments: ["ExFAT", "MS-DOS"]) func appRestoresOntoFATVolumes(fs: String) throws {
        write("uno", to: src.appending(path: "a.txt"))
        write("due", to: src.appending(path: "sub/b.txt"))
        let (repo, snap) = try backup([src])
        try withVolume(fs) { mount in
            let restorer = Restorer(repository: repo, trash: { _ in })
            let first = try restorer.restore(snap, source: src.path, path: "", mode: .into(mount))
            #expect(try String(contentsOf: first.appending(path: "sub/b.txt"), encoding: .utf8) == "due")
            let second = try restorer.restore(snap, source: src.path, path: "", mode: .into(mount))
            #expect(second.lastPathComponent == "progetto 2")
            #expect(try String(contentsOf: first.appending(path: "a.txt"), encoding: .utf8) == "uno")
            let names = try fm.contentsOfDirectory(atPath: mount.path)
            #expect(!names.contains { $0.hasPrefix(".backupme-restore-") }, "\(names)")
        }
    }

    /// M3: names differing only by case in one saved folder don't stop the kit: the other folders are restored,
    /// the collision is named, and the exit status says something is missing.
    @Test func kitRestoresOtherSourcesBesideACaseCollision() throws {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let one = Data("all:\n".utf8), two = Data("ok".utf8)
        for d in [one, two] { _ = try repo.putObject(d, hash: sha256Hex(d)) }
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.writeSnapshot(Snapshot(date: d, sources: ["/x/linux", "/x/altro"], entries: [
            entry("/x/linux", "", .directory), entry("/x/linux", "Makefile", .file, data: one),
            entry("/x/linux", "makefile", .file, data: one),
            entry("/x/altro", "", .directory), entry("/x/altro", "ok.txt", .file, data: two)], warnings: []))
        let out = tmp().appending(path: "ripristino")
        let r = try kitRestore(Snapshot.id(for: d), to: out)
        #expect(r.status != 0 && r.out.contains("makefile"), "\(r.out)")
        #expect(r.out.contains("solo per maiuscole"), "\(r.out)")
        #expect(try String(contentsOf: out.appending(path: "altro/ok.txt"), encoding: .utf8) == "ok")
        #expect(try String(contentsOf: out.appending(path: "linux/Makefile"), encoding: .utf8) == "all:\n")

        // an invalid saved folder is skipped alone, never written
        try repo.deleteSnapshot(Snapshot.id(for: d))
        try repo.writeSnapshot(Snapshot(date: d, sources: ["/x/linux", "/x/altro"], entries: [
            entry("/x/linux", "", .directory), entry("/x/linux", "../fuori.txt", .file, data: one),
            entry("/x/altro", "", .directory), entry("/x/altro", "ok.txt", .file, data: two)], warnings: []))
        let out2 = tmp().appending(path: "ripristino")
        let r2 = try kitRestore(Snapshot.id(for: d), to: out2)
        #expect(r2.status != 0 && r2.out.contains("fuori.txt"), "\(r2.out)")
        #expect(fm.fileExists(atPath: out2.appending(path: "altro/ok.txt").path))
        #expect(!fm.fileExists(atPath: out2.appending(path: "linux").path))
        #expect(!fm.fileExists(atPath: out2.appending(path: "fuori.txt").path))
    }

    /// M4: a saved folder that couldn't be read is in the manifest's warnings; the kit names it and exits with an error.
    @Test func partialBackupIsMarkedInManifestAndKit() throws {
        write("ok", to: src.appending(path: "a.txt"))
        let missing = base.appending(path: "Documenti", directoryHint: .isDirectory)
        let (_, snap) = try backup([src, missing])
        #expect(snap.warnings.contains { $0.contains(missing.path) || $0.contains("Documenti") }, "\(snap.warnings)")
        let out = tmp().appending(path: "ripristino")
        let r = try kitRestore(snap.id, to: out)
        #expect(r.status != 0, "\(r.out)")
        #expect(r.out.contains("NON è in questo backup: " + missing.path), "\(r.out)")
        #expect(r.out.contains("Avvisi del backup"), "\(r.out)")
        #expect(try String(contentsOf: out.appending(path: "progetto/a.txt"), encoding: .utf8) == "ok")
    }

    /// B10: on case-sensitive APFS a rename between two forms of one name does nothing: names, and folders created on
    /// the way to the original, keep the composed bytes saved in the backup (app and kit).
    @Test func composedNamesKeptOnCaseSensitiveAPFS() throws {
        let name = "Caffè", inner = "è dentro", file = "ü.txt"
        try withVolume("Case-sensitive APFS") { mount in
            // made with POSIX calls: Foundation would write the names decomposed already
            let root = mount.path + "/progetto"
            #expect(mkdir(root, 0o755) == 0 && mkdir(root + "/" + name, 0o755) == 0 && mkdir(root + "/" + name + "/" + inner, 0o755) == 0)
            let fd = open(root + "/" + name + "/" + inner + "/" + file, O_CREAT | O_WRONLY, 0o644)
            #expect(fd >= 0); close(fd)
            let (repo, snap) = try backup([URL(fileURLWithPath: root)])
            let restorer = Restorer(repository: repo, trash: { _ in })

            let into = mount.appending(path: "dentro")
            try fm.createDirectory(at: into, withIntermediateDirectories: true)
            try restorer.restore(snap, source: root, path: name, mode: .into(into))
            #expect(rawNames(into.path) == [Array(name.utf8)])
            #expect(rawNames(into.path + "/" + name) == [Array(inner.utf8)])
            #expect(rawNames(into.path + "/" + name + "/" + inner) == [Array(file.utf8)])

            // the folders on the way to the original are gone: created again with the saved names
            try fm.removeItem(atPath: root + "/" + name)
            try restorer.restore(snap, source: root, path: name + "/" + inner + "/" + file, mode: .besideOriginal)
            #expect(rawNames(root) == [Array(name.utf8)])
            #expect(rawNames(root + "/" + name) == [Array(inner.utf8)])

            let out = mount.appending(path: "kit")
            let r = try kitRestore(snap.id, to: out)
            #expect(r.status == 0, "\(r.out)")
            #expect(rawNames(out.path + "/progetto") == [Array(name.utf8)])
            #expect(rawNames(out.path + "/progetto/" + name) == [Array(inner.utf8)])
            #expect(rawNames(out.path + "/progetto/" + name + "/" + inner) == [Array(file.utf8)])
        }
    }

    /// B11: exFAT has no "important usage" capacity: the kit shows the plain free space, not 0 MB.
    @Test func kitShowsFreeSpaceOnExFAT() throws {
        write("ok", to: src.appending(path: "a.txt"))
        let (_, snap) = try backup([src])
        try withVolume("ExFAT") { mount in
            let r = try kitRestore(snap.id, to: mount.appending(path: "ripristino"))
            #expect(r.status == 0, "\(r.out)")
            #expect(!r.out.contains("destinazione: 0,0 MB") && !r.out.contains("sconosciuto"), "\(r.out)")
            #expect(!r.out.contains("non basta"), "\(r.out)")
        }
    }

    /// B12: files created after the backup go to the Trash with the folder: Sostituisci counts them.
    @Test func replaceCheckCountsFilesNewerThanTheBackup() throws {
        write("uno", to: src.appending(path: "a.txt"))
        let (_, snap) = try backup([src], excludes: ["node_modules"])
        let rules = ExcludeRules(patterns: ["node_modules"])
        #expect(Restorer.replaceCheck(snap, source: src.path, rules: rules).newFiles == 0)
        write("nuovo", to: src.appending(path: "nuovo.txt"))
        write("nuovo", to: src.appending(path: "cartella nuova/dentro.txt"))
        write("escluso", to: src.appending(path: "node_modules/x.js"))
        write("ref", to: src.appending(path: ".git/refs/heads/nuovo"))
        #expect(Restorer.replaceCheck(snap, source: src.path, rules: rules) == .init(changedFiles: 0, repositoryChanged: false, newFiles: 2))
    }
}
