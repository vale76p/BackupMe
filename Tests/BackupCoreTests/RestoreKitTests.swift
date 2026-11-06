import Foundation
import Testing
@testable import BackupCore

@Suite struct RestoreKitTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let fm = FileManager.default
    var kit: URL { dest.appending(path: "BackupMe") }

    func sh(_ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [kit.appending(path: "RIPRISTINO.command").path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
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
        let r = try sh(["Mac", id, out.path])
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
        #expect(try sh(["Mac", id, out.path]).status == 0)
        #expect(fm.fileExists(atPath: out.appending(path: "progetto 2/testo.txt").path))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restored.appending(path: "chiusa").path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.appending(path: "progetto 2/chiusa").path)
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
        let r = try sh(["Mac", Snapshot.id(for: d), out.path])
        #expect(r.status != 0 && r.out.contains("fuori.txt"))
        #expect(!fm.fileExists(atPath: out.path))
        #expect(!fm.fileExists(atPath: out.appending(path: "fuori.txt").path))
    }
}
