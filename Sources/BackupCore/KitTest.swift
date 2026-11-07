import Foundation

/// "Prova il kit di ripristino": RIPRISTINO.command run as on a Mac without BackupMe, on a real backup.
public struct KitTest: Equatable, Sendable {
    /// The version in the destination; nil when the script is missing or has no version line.
    public var installed: Int?
    public var snapshotID: String
    public var files = 0
    /// Empty when the script started, listed the archive, restored the backup and every entry matched its index.
    public var problems: [String] = []
    public var passed: Bool { problems.isEmpty }
}

/// The backup the test restores (the latest) and how much it writes: asked before restoring it.
public struct KitTestPlan: Equatable, Sendable {
    public var snapshotID: String
    public var files: Int
    public var bytes: Int64
}

public func kitTestPlan(repository: Repository) throws -> KitTestPlan? {
    guard let id = try repository.snapshotIDs().last else { return nil }
    let files = try repository.readSnapshot(id).entries.filter { $0.kind == .file }
    return KitTestPlan(snapshotID: id, files: files.count, bytes: files.reduce(0) { $0 + $1.size })
}

/// Runs the kit beside the archives: version, listing, then a restore of `snapshotID` into `work` (created, and
/// removed at the end) checked entry by entry against the index, independently of the script's own check.
/// Throws `BackupError.cancelled` when `isCancelled` turns true; problems of the kit itself are in the result.
public func testRestoreKit(repository: Repository, snapshotID: String, into work: URL,
                           isCancelled: @escaping () -> Bool = { false }) throws -> KitTest {
    let fm = FileManager.default
    let base = repository.root.deletingLastPathComponent(), computer = repository.root.lastPathComponent
    let script = base.appending(path: "RIPRISTINO.command")
    var r = KitTest(installed: nil, snapshotID: snapshotID)
    guard let text = try? String(contentsOf: script, encoding: .utf8) else {
        r.problems.append("RIPRISTINO.command non c'è nella destinazione: lo riscrive il prossimo backup")
        return r
    }
    r.installed = RestoreKit.installedVersion(text)
    if (r.installed ?? 0) < RestoreKit.version {
        r.problems.append("RIPRISTINO.command è alla versione \(r.installed.map(String.init) ?? "iniziale"), questa app scrive la \(RestoreKit.version): lo aggiorna il prossimo avvio o backup")
    }

    func run(_ arguments: [String]) throws -> (status: Int32, out: String) {
        let log = fm.temporaryDirectory.appending(path: "backupme-kit-\(UUID().uuidString).txt")
        guard fm.createFile(atPath: log.path, contents: nil) else { throw POSIXError(.EIO) }
        defer { try? fm.removeItem(at: log) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + arguments
        // a file, not a pipe: a long restore prints more than a pipe holds while nobody reads it
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        while p.isRunning {
            if isCancelled() { p.terminate(); p.waitUntilExit(); throw BackupError.cancelled }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (p.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }
    func tail(_ out: String) -> String { out.split(separator: "\n").suffix(4).joined(separator: " · ") }

    let version = try run(["--versione"])
    guard version.status == 0, version.out.contains("RIPRISTINO.command versione") else {
        r.problems.append("RIPRISTINO.command non parte: \(tail(version.out))")
        return r
    }
    let listing = try run([])
    if listing.status != 0 || !listing.out.contains("Computer: \(computer)") || !listing.out.contains(snapshotID) {
        r.problems.append("RIPRISTINO.command non elenca questo backup: \(tail(listing.out))")
    }

    let snapshot = try repository.readSnapshot(snapshotID)
    r.files = snapshot.entries.filter { $0.kind == .file }.count
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { removeRestored(work) }
    let restore = try run(["--si", computer, snapshotID, work.path])
    guard restore.status == 0 else {
        r.problems.append("Il ripristino con RIPRISTINO.command non è riuscito: \(tail(restore.out))")
        return r
    }
    // the script's naming in an empty folder: the last component of each saved folder, "nome 2" for a repeat
    var taken = Set<String>(), wrong: [String] = []
    for source in snapshot.sources {
        let entries = snapshot.entries.filter { $0.source == source }
        guard !entries.isEmpty else { continue }
        var name = source.split(separator: "/").last.map(String.init) ?? "Backup"
        if name == "." || name == ".." { name = "Backup" }
        var target = name, n = 2
        while taken.contains(target.decomposedStringWithCanonicalMapping.lowercased()) { target = "\(name) \(n)"; n += 1 }
        taken.insert(target.decomposedStringWithCanonicalMapping.lowercased())
        let root = work.appending(path: target)
        for e in entries {
            if isCancelled() { throw BackupError.cancelled }
            let url = e.path.isEmpty ? root : root.appending(path: e.path)
            let ok: Bool
            switch e.kind {
            case .directory: ok = FileStat(path: url.path)?.kind == .directory
            case .file: ok = FileStat(path: url.path)?.kind == .file && (try? streamHash(url)) == e.hash
            case .symlink: ok = (try? fm.destinationOfSymbolicLink(atPath: url.path)) == e.linkTarget
            }
            if !ok { wrong.append(e.path.isEmpty ? source : e.path) }
        }
    }
    if !wrong.isEmpty {
        let examples = wrong.prefix(3).joined(separator: ", ") + (wrong.count > 3 ? "…" : "")
        r.problems.append(wrong.count == 1 ? "1 elemento ripristinato non corrisponde al backup: \(examples)"
                                           : "\(wrong.count) elementi ripristinati non corrispondono al backup, per esempio \(examples)")
    }
    return r
}

/// The restored copy goes away whole: the kit gives folders their saved permissions (0555 and the like).
private func removeRestored(_ work: URL) {
    let fm = FileManager.default
    if let all = fm.enumerator(atPath: work.path) {
        chmod(work.path, 0o700)
        for case let rel as String in all where (try? fm.destinationOfSymbolicLink(atPath: work.appending(path: rel).path)) == nil {
            chmod(work.appending(path: rel).path, 0o700)
        }
    }
    try? fm.removeItem(at: work)
}
