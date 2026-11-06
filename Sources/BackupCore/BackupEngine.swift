import Foundation

public struct BackupReport: Codable, Sendable {
    public var snapshotID: String?
    public var date: Date
    public var duration: TimeInterval
    public var fileCount: Int
    public var newBytes: Int64
    public var warnings: [String]
    public var error: String?
    /// Folders skipped by the excludes or a CACHEDIR.TAG, as "<source folder name>/<path>"; at most 200.
    public var excluded: [String]?

    public init(snapshotID: String?, date: Date, duration: TimeInterval, fileCount: Int,
                newBytes: Int64, warnings: [String], error: String?, excluded: [String]? = nil) {
        self.snapshotID = snapshotID; self.date = date; self.duration = duration; self.fileCount = fileCount
        self.newBytes = newBytes; self.warnings = warnings; self.error = error; self.excluded = excluded
    }
}

public enum BackupError: Error, Equatable {
    case sourceOverlapsDestination(String)
    case cancelled
}

struct FileStat {
    var kind: EntryKind
    var inode: UInt64
    var size: Int64
    var mtime: Date
    var ctime: Date
    var mode: UInt16

    init?(path: String, followSymlink: Bool = false) {
        var st = stat()
        guard (followSymlink ? stat(path, &st) : lstat(path, &st)) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        case S_IFREG: kind = .file
        default: return nil // sockets, fifos, devices are skipped
        }
        inode = UInt64(st.st_ino)
        size = Int64(st.st_size)
        mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        ctime = Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec) + TimeInterval(st.st_ctimespec.tv_nsec) / 1e9)
        mode = UInt16(st.st_mode & 0o7777)
    }

    func unchanged(since o: FileStat) -> Bool { size == o.size && mtime == o.mtime && ctime == o.ctime }
}

public final class BackupEngine {
    private let repository: Repository
    private let cache: HashCache
    private let excludes: ExcludeRules

    public init(repository: Repository, cache: HashCache, excludes: ExcludeRules) {
        self.repository = repository; self.cache = cache; self.excludes = excludes
    }

    /// Returns an error if a source is, contains, or is inside the archive.
    public static func validate(sources: [URL], repositoryRoot: URL) -> BackupError? {
        let root = repositoryRoot.resolvingSymlinksInPath().path
        for s in sources {
            let p = s.resolvingSymlinksInPath().path
            if p == root || root.hasPrefix(p + "/") || p.hasPrefix(root + "/") {
                return .sourceOverlapsDestination(s.path)
            }
        }
        return nil
    }

    /// Backs up every source. A source that is missing or can't be listed (e.g. folder permission revoked)
    /// does not stop the others, but sets `error`: the backup is partial and must not count as a success.
    public func run(sources: [URL], now: Date = Date(), progress: (Double) -> Void = { _ in },
                    isCancelled: () -> Bool = { false }) throws -> BackupReport {
        if let err = Self.validate(sources: sources, repositoryRoot: repository.root) { throw err }
        let start = Date()
        return try repository.withLock {
            var sourceErrors: [String] = []
            var scans: [Scan] = []
            for s in sources {
                var scan = Scan(source: s.path)
                if let err = scanSource(&scan) { sourceErrors.append(err) } else { scans.append(scan) }
            }

            let total = scans.reduce(0) { $0 + $1.found.count }
            var done = 0
            var warnings: [String] = []
            var excluded: [String] = []
            var entries: [Entry] = []
            var newBytes: Int64 = 0
            var fileCount = 0
            for var scan in scans {
                var pass = try store(scan, isCancelled: isCancelled) { done += 1; progress(Double(done) / Double(total)) }
                newBytes += pass.newBytes
                // a commit during the pass may have stored refs pointing to objects read before it: read it again
                if gitChanged(scan, since: start) {
                    let again = Date()
                    var rescan = Scan(source: scan.source)
                    var consistent = false
                    if scanSource(&rescan) == nil {
                        scan = rescan
                        pass = try store(scan, isCancelled: isCancelled) {}
                        newBytes += pass.newBytes
                        consistent = !gitChanged(scan, since: again)
                    }
                    if !consistent {
                        pass.warnings.append("\((scan.source as NSString).lastPathComponent): il repository git è cambiato "
                                             + "durante il backup, ripeti il backup per averne una copia coerente")
                    }
                }
                entries += pass.entries; fileCount += pass.fileCount
                warnings += scan.warnings + pass.warnings
                excluded += scan.excluded
            }
            if isCancelled() { throw BackupError.cancelled }
            let error = sourceErrors.isEmpty ? nil : sourceErrors.joined(separator: "\n")
            func report(_ id: String?) -> BackupReport {
                BackupReport(snapshotID: id, date: now, duration: Date().timeIntervalSince(start), fileCount: fileCount,
                             newBytes: newBytes, warnings: warnings, error: id == nil ? (error ?? "Nessun file da salvare") : error,
                             excluded: Array(excluded.prefix(Self.excludedLimit)))
            }
            guard !entries.isEmpty else { return report(nil) }

            // identical to the last manifest: don't upload another copy of it
            let digest = Self.digest(sources: sources.map(\.path), entries: entries)
            if let last = cache.lastManifest, last.digest == digest, repository.snapshotExists(last.id) {
                try? cache.save()
                return report(last.id)
            }
            var date = now
            while repository.snapshotExists(Snapshot.id(for: date)) { date += 1 } // one manifest per second, never overwritten
            let snapshot = Snapshot(date: date, sources: sources.map(\.path), entries: entries, warnings: warnings)
            try repository.writeSnapshot(snapshot) // written last: a backup without manifest does not exist
            cache.lastManifest = (digest, snapshot.id)
            try? cache.save()
            return report(snapshot.id)
        }
    }

    static let excludedLimit = 200

    private struct Scan {
        var source: String
        var found: [(path: String, stat: FileStat)] = []
        var warnings: [String] = []
        var excluded: [String] = []
    }

    private func store(_ scan: Scan, isCancelled: () -> Bool, tick: () -> Void) throws
        -> (entries: [Entry], warnings: [String], fileCount: Int, newBytes: Int64) {
        var r: (entries: [Entry], warnings: [String], fileCount: Int, newBytes: Int64) = ([], [], 0, 0)
        for item in scan.found {
            if isCancelled() { throw BackupError.cancelled }
            let full = item.path.isEmpty ? scan.source : scan.source + "/" + item.path
            var st = item.stat
            var hash: String?
            var linkTarget: String?
            switch st.kind {
            case .directory: break
            case .symlink:
                linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: full)
            case .file:
                guard let s = try storeFile(full, stat: st, warnings: &r.warnings) else { tick(); continue }
                hash = s.hash; st = s.stat; r.newBytes += s.written; r.fileCount += 1
            }
            r.entries.append(Entry(source: scan.source, path: item.path, kind: st.kind, hash: hash, size: st.size,
                                   mtime: st.mtime, mode: st.mode, linkTarget: linkTarget))
            tick()
        }
        return r
    }

    /// True if a repository of the source has a git operation in progress (a lock file), or refs changed since `date`.
    /// A lock older than 10 minutes is a leftover of a crashed git, not an operation: it would warn at every backup.
    private func gitChanged(_ scan: Scan, since date: Date) -> Bool {
        let fm = FileManager.default
        func live(_ lock: String) -> Bool { FileStat(path: lock).map { $0.mtime > date.addingTimeInterval(-600) } ?? false }
        for item in scan.found where item.stat.kind == .directory && (item.path == ".git" || item.path.hasSuffix("/.git")) {
            let git = scan.source + "/" + item.path
            let top = (try? fm.contentsOfDirectory(atPath: git)) ?? []
            if top.contains(where: { $0.hasSuffix(".lock") && live(git + "/" + $0) }) { return true }
            var paths = [git + "/HEAD", git + "/packed-refs", git + "/refs"]
            paths += (fm.enumerator(atPath: git + "/refs")?.allObjects as? [String] ?? []).map { git + "/refs/" + $0 }
            for p in paths {
                if p.hasSuffix(".lock") { if live(p) { return true } else { continue } }
                if let st = FileStat(path: p), st.ctime > date { return true }
            }
        }
        return false
    }

    private static func digest(sources: [String], entries: [Entry]) -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = .sortedKeys
        return sha256Hex((try? enc.encode([AnyEncodable(sources), AnyEncodable(entries)])) ?? Data())
    }

    /// Returns an error message if the source itself is missing or unreadable.
    private func scanSource(_ scan: inout Scan) -> String? {
        let source = scan.source
        // the source folder itself may be a symlink to the real folder
        guard let st = FileStat(path: source, followSymlink: true), st.kind == .directory else {
            return "Cartella non trovata: \(source)"
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: source)
        } catch {
            return "Cartella non leggibile: \(source) (\(error.localizedDescription))"
        }
        walk(rel: "", stat: st, into: &scan)
        return nil
    }

    private func walk(rel: String, stat st: FileStat, insideGit: Bool = false, into scan: inout Scan) {
        let full = rel.isEmpty ? scan.source : scan.source + "/" + rel
        scan.found.append((rel, st))
        guard st.kind == .directory else { return }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: full) } catch {
            scan.warnings.append("\(full): \(error.localizedDescription)")
            return
        }
        for name in names.sorted() {
            guard let child = FileStat(path: full + "/" + name) else { continue }
            let path = rel.isEmpty ? name : rel + "/" + name
            let isDir = child.kind == .directory
            // excludes never apply inside .git: a branch named "build" is a file under .git/refs/heads
            if !insideGit, excludes.excludes(name: name, isDirectory: isDir, path: path)
                || (isDir && isCacheDirectory(full + "/" + name)) {
                if isDir, scan.excluded.count < Self.excludedLimit {
                    scan.excluded.append((scan.source as NSString).lastPathComponent + "/" + path)
                }
                continue
            }
            walk(rel: path, stat: child, insideGit: insideGit || name == ".git", into: &scan)
        }
    }

    /// Hashes and stores one file. Returns nil (with a warning) if the source is unreadable or changing while read;
    /// throws if the archive can't be written (disk full, destination gone), which fails the whole backup.
    /// Files above `Repository.streamThreshold` are hashed and copied as streams, never held in memory.
    private func storeFile(_ path: String, stat initial: FileStat, warnings: inout [String]) throws
        -> (hash: String, stat: FileStat, written: Int64)? {
        if let h = cache.lookup(path: path, inode: initial.inode, size: initial.size, mtime: initial.mtime, ctime: initial.ctime),
           repository.hasObject(h) {
            return (h, initial, 0)
        }
        let url = URL(fileURLWithPath: path)
        var st = initial
        for attempt in 0..<2 {
            let big = st.size >= Repository.streamThreshold
            var data = Data()
            let hash: String
            do {
                if big { hash = try streamHash(url) } else {
                    // read, not mapped: compression re-reads the bytes later, and a file rewritten in place
                    // meanwhile would be stored under a hash that doesn't match it
                    data = try Data(contentsOf: url)
                    hash = sha256Hex(data)
                }
            } catch {
                warnings.append("\(path): \(error.localizedDescription)")
                return nil
            }
            var stable = FileStat(path: path).map { $0.unchanged(since: st) } ?? false
            var written: Int64 = 0
            if stable, !repository.hasObject(hash) {
                if big {
                    // nil: the file changed between hashing and copying, and nothing was stored
                    if let w = try repository.putObjectFile(from: url, hash: hash) { written = w } else { stable = false }
                } else {
                    written = try repository.putObject(data, hash: hash)
                }
            }
            guard stable else {
                if attempt == 0, let again = FileStat(path: path) { st = again; continue }
                warnings.append("\(path): modificato durante la lettura, saltato")
                return nil
            }
            cache.store(path: path, inode: st.inode, size: st.size, mtime: st.mtime, ctime: st.ctime, hash: hash)
            return (hash, st, written)
        }
        return nil
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
