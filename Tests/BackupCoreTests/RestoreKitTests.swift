import Foundation
import Testing
@testable import BackupCore

@Suite struct RestoreKitTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let fm = FileManager.default
    var kit: URL { dest.appending(path: "BackupMe") }

    /// `input` is what the user types; nil = no terminal at all (/dev/null).
    func sh(_ args: [String], input: String? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [kit.appending(path: "RIPRISTINO.command").path] + args
        let pipe = Pipe(), stdin = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try p.run()
        stdin.fileHandleForWriting.write(Data((input ?? "").utf8))
        try stdin.fileHandleForWriting.close()
        // a script stuck waiting for an answer becomes a failure instead of blocking the test run
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationReason == .exit, "RIPRISTINO.command bloccato oltre 20 s:\n\(out)")
        return (p.terminationStatus, out)
    }

    @Test func kitInstalledAndKeptCurrent() throws {
        _ = try Repository(destination: dest, computerName: "Mac")
        let script = kit.appending(path: "RIPRISTINO.command"), readme = kit.appending(path: "LEGGIMI.txt")
        #expect(fm.isExecutableFile(atPath: script.path))
        #expect(try String(contentsOf: readme, encoding: .utf8) == RestoreKit.readme)
        write("vecchio", to: readme)
        _ = try Repository(destination: dest, computerName: "Mac")
        #expect(try String(contentsOf: readme, encoding: .utf8) == RestoreKit.readme)
    }

    @Test func newerKitFromAnotherMacIsKept() throws {
        _ = try Repository(destination: dest, computerName: "Mac")
        let script = kit.appending(path: "RIPRISTINO.command")
        #expect(RestoreKit.installedVersion(try String(contentsOf: script, encoding: .utf8)) == RestoreKit.version)
        let newer = "#!/bin/sh\n// BackupMe-kit: \(RestoreKit.version + 1)\n"
        write(newer, to: script)
        _ = try Repository(destination: dest, computerName: "Mac")
        #expect(try String(contentsOf: script, encoding: .utf8) == newer)
        write("#!/bin/sh\n// kit senza versione\n", to: script) // the first kit: always replaced
        _ = try Repository(destination: dest, computerName: "Mac")
        #expect(try String(contentsOf: script, encoding: .utf8) == RestoreKit.script)
    }

    @Test func scriptRestoresBackupWithoutTheApp() throws {
        write(String(repeating: "testo comprimibile ", count: 200), to: src.appending(path: "testo.txt"))
        try fm.createDirectory(at: src.appending(path: "sub/annidata"), withIntermediateDirectories: true)
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: src.appending(path: "sub/casuale.bin"))
        write("", to: src.appending(path: "vuoto.txt"))
        write("caffè", to: src.appending(path: "sub/annidata/caffè e \\ \"spazi\".txt"))
        write("#!/bin/sh", to: src.appending(path: "run.sh"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appending(path: "run.sh").path)
        write("x", to: src.appending(path: "chiusa/dentro.txt"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: src.appending(path: "chiusa").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appending(path: "chiusa").path) }
        try fm.createSymbolicLink(atPath: src.appending(path: "link").path, withDestinationPath: "sub/annidata")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000.25)],
                             ofItemAtPath: src.appending(path: "sub").path)

        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src])
        let id = try #require(report.snapshotID)
        let s = try repo.readSnapshot(id)
        let kinds = Set(s.entries.compactMap(\.hash).compactMap { objectFile(repo, $0)?.pathExtension })
        #expect(kinds == ["lzfse", "raw"])

        let listing = try sh([])
        #expect(listing.status == 0 && listing.out.contains("Computer: Mac") && listing.out.contains(id))

        let out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", id, out.path, "--si"])
        #expect(r.status == 0, "\(r.out)")
        let restored = out.appending(path: "progetto")
        for e in s.entries {
            let url = e.path.isEmpty ? restored : restored.appending(path: e.path)
            let st = try #require(FileStat(path: url.path), "\(e.path)")
            #expect(st.kind == e.kind, "\(e.path)")
            switch e.kind {
            case .file:
                #expect(sha256Hex(try Data(contentsOf: url)) == e.hash, "\(e.path)")
                #expect(st.mode == e.mode && abs(st.mtime.timeIntervalSince(e.mtime)) < 1e-5, "\(e.path)")
            case .directory:
                #expect(st.mode == e.mode && abs(st.mtime.timeIntervalSince(e.mtime)) < 1e-5, "\(e.path)")
            case .symlink:
                #expect(try fm.destinationOfSymbolicLink(atPath: url.path) == e.linkTarget)
            }
        }
        // never overwrites: a second run goes beside the first
        let again = try sh(["--si", "Mac", id, out.path])
        #expect(again.status == 0 && again.out.contains("progetto 2"), "\(again.out)")
        #expect(fm.fileExists(atPath: out.appending(path: "progetto 2/testo.txt").path))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restored.appending(path: "chiusa").path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.appending(path: "progetto 2/chiusa").path)
    }

    @Test func scriptRestoresASingleFileSource() throws {
        let file = src.deletingLastPathComponent().appending(path: "nota.txt")
        write("solo questo", to: file)
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [file])
        let out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", try #require(report.snapshotID), out.path, "--si"])
        #expect(r.status == 0, "\(r.out)")
        #expect(try String(contentsOf: out.appending(path: "nota.txt"), encoding: .utf8) == "solo questo")
    }

    @Test func scriptRefusesPathsOutsideDestination() throws {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let data = Data("fuori".utf8)
        _ = try repo.putObject(data, hash: sha256Hex(data))
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ path: String, _ kind: EntryKind) -> Entry {
            Entry(source: "/x/progetto", path: path, kind: kind, hash: kind == .file ? sha256Hex(data) : nil,
                  size: 5, mtime: d, mode: 0o644, linkTarget: nil)
        }
        try repo.writeSnapshot(Snapshot(date: d, sources: ["/x/progetto"],
                                        entries: [entry("", .directory), entry("../fuori.txt", .file)], warnings: []))
        let out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", Snapshot.id(for: d), out.path, "--si"])
        #expect(r.status != 0 && r.out.contains("fuori.txt"))
        #expect(!fm.fileExists(atPath: out.path))
        #expect(!fm.fileExists(atPath: out.appending(path: "fuori.txt").path))
    }

    @Test func scriptNeverWritesThroughANameThatCollidesOnDisk() throws {
        // "sub" (a symlink out) and "Sub" are one name on APFS: Sub/evil.txt would land outside
        let repo = try Repository(destination: dest, computerName: "Mac")
        let data = Data("PWNED".utf8), outside = tmp(), d = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try repo.putObject(data, hash: sha256Hex(data))
        func entry(_ path: String, _ kind: EntryKind, link: String? = nil) -> Entry {
            Entry(source: "/x/progetto", path: path, kind: kind, hash: kind == .file ? sha256Hex(data) : nil,
                  size: 5, mtime: d, mode: kind == .directory ? 0o755 : 0o644, linkTarget: link)
        }
        for sub in ["Sub", "s\u{0075}\u{0301}b"] { // case, and a Unicode form of a different name
            try repo.writeSnapshot(Snapshot(date: d, sources: ["/x/progetto"], entries: [
                entry("", .directory), entry("sub", .symlink, link: outside.path),
                entry(sub, .directory), entry(sub + "/evil.txt", .file)], warnings: []))
            let out = tmp().appending(path: "ripristino")
            _ = try sh(["Mac", Snapshot.id(for: d), out.path, "--si"])
            #expect(!fm.fileExists(atPath: outside.appending(path: "evil.txt").path), "\(sub)")
            try repo.deleteSnapshot(Snapshot.id(for: d))
        }
    }

    /// A one-file backup of `src`; returns its id.
    func backup() throws -> String {
        write("ciao", to: src.appending(path: "ciao.txt"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [src])
        return try #require(report.snapshotID)
    }

    @Test func scriptPrintsItsVersion() throws {
        _ = try Repository(destination: dest, computerName: "Mac")
        let line = "RIPRISTINO.command versione \(RestoreKit.version)"
        let r = try sh(["--versione"])
        #expect(r.status == 0 && r.out == line + "\n", "\(r.out)")
        #expect(try sh([]).out.contains(line))
        #expect(RestoreKit.readme.contains("Kit di ripristino versione \(RestoreKit.version)"))
    }

    @Test func newerFormatIsRefused() throws {
        let id = try backup()
        let info = kit.appending(path: "Mac/repo.json")
        try Data(#"{"format":3,"id":"x"}"#.utf8).write(to: info)
        let r = try sh(["Mac", id, tmp().path, "--si"])
        #expect(r.status != 0 && r.out.contains("formato 3"), "\(r.out)")
        #expect(throws: RepositoryError.newerFormat(3)) { try Repository(destination: dest, computerName: "Mac") }
        #expect(try Repository(destination: dest, computerName: "Mac", create: false).archiveID == "x", "browsing still works")
    }

    @Test func scriptKeepsComposedNames() throws {
        // made with POSIX calls: Foundation would write the names decomposed already
        let name = "Caffè ü 日本", file = "è.txt"
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        #expect((src.path + "/" + name).withCString { mkdir($0, 0o755) } == 0)
        let fd = (src.path + "/" + name + "/" + file).withCString { open($0, O_CREAT | O_WRONLY, 0o644) }
        #expect(fd >= 0); close(fd)
        let out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", try backup(), out.path, "--si"])
        #expect(r.status == 0, "\(r.out)")
        #expect(rawNames(out.path + "/progetto").contains(Array(name.utf8)))
        #expect(rawNames(out.path + "/progetto/" + name) == [Array(file.utf8)])
    }

    @Test func scriptRefusesAlteredIndex() throws {
        let id = try backup()
        let url = kit.appending(path: "Mac/snapshots/\(id).json.lzfse")
        var text = String(decoding: try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data, as: UTF8.self)
        // still valid JSON with valid hashes: only the checksum can tell
        text = text.replacingOccurrences(of: "\"size\":", with: "\"size\":1")
        try ((Data(text.utf8) as NSData).compressed(using: .lzfse) as Data).write(to: url)
        let out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", id, out.path, "--si"])
        #expect(r.status != 0 && r.out.contains("danneggiato"), "\(r.out)")
        #expect(!fm.fileExists(atPath: out.path))
    }

    @Test func foldersDifferingOnlyInCaseBothRestored() throws {
        let a = tmp().appending(path: "App", directoryHint: .isDirectory), b = tmp().appending(path: "app", directoryHint: .isDirectory)
        write("uno", to: a.appending(path: "a.txt"))
        write("due", to: b.appending(path: "b.txt"))
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                                      excludes: ExcludeRules(patterns: [])).run(sources: [a, b])
        let out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", try #require(report.snapshotID), out.path, "--si"])
        #expect(r.status == 0, "\(r.out)")
        let names = try fm.contentsOfDirectory(atPath: out.path).sorted()
        #expect(names.count == 2, "\(names)")
    }

    @Test func scriptAsksTwiceBeforeRestoring() throws {
        let id = try backup(), out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", id, out.path], input: "s\nRIPRISTINA\n")
        #expect(r.status == 0, "\(r.out)")
        #expect(r.out.contains(src.path) && r.out.contains(out.appending(path: "progetto").path))
        #expect(r.out.hasPrefix("RIPRISTINO.command versione \(RestoreKit.version)"))
        #expect(r.out.contains("1 file") && r.out.contains("[s/N]") && r.out.contains("scrivi RIPRISTINA"))
        #expect(try String(contentsOf: out.appending(path: "progetto/ciao.txt"), encoding: .utf8) == "ciao")
    }

    @Test(arguments: ["s\nno\n", "\n", "n\nRIPRISTINA\n", "s\n"])
    func scriptCancelsWithoutBothConfirmations(_ answers: String) throws {
        let id = try backup(), out = tmp().appending(path: "ripristino")
        let r = try sh(["Mac", id, out.path], input: answers)
        #expect(r.status == 2 && r.out.contains("Ripristino annullato, non è stato scritto nulla."), "\(r.out)")
        #expect(!fm.fileExists(atPath: out.path))
    }

    @Test func scriptWithoutAnswersOrFlagWritesNothing() throws {
        let id = try backup(), out = tmp().appending(path: "ripristino")
        for input in [nil, ""] as [String?] {
            let r = try sh(["Mac", id, out.path], input: input)
            #expect(r.status == 2 && r.out.contains("--si"), "\(r.out)")
            #expect(!fm.fileExists(atPath: out.path))
        }
    }
}
