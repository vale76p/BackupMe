import Foundation

public struct BackupReport: Codable, Sendable {
    public var snapshotID: String?
    public var date: Date
    public var duration: TimeInterval
    public var fileCount: Int
    public var newBytes: Int64
    public var warnings: [String]
    public var error: String?

    public init(snapshotID: String?, date: Date, duration: TimeInterval, fileCount: Int,
                newBytes: Int64, warnings: [String], error: String?) {
        self.snapshotID = snapshotID; self.date = date; self.duration = duration; self.fileCount = fileCount
        self.newBytes = newBytes; self.warnings = warnings; self.error = error
    }
}

public enum BackupError: Error, Equatable {
    case sourceMissing(String)
    case sourceOverlapsDestination(String)
    case cancelled
}

struct FileStat {
    var kind: EntryKind
    var inode: UInt64
    var size: Int64
    var mtime: Date
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
        mode = UInt16(st.st_mode & 0o7777)
    }
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

    public func run(sources: [URL], now: Date = Date(), progress: (Double) -> Void = { _ in },
                    isCancelled: () -> Bool = { false }) throws -> BackupReport {
        if let err = Self.validate(sources: sources, repositoryRoot: repository.root) { throw err }
        for s in sources {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: s.path, isDirectory: &isDir), isDir.boolValue else {
                throw BackupError.sourceMissing(s.path)
            }
        }
        let start = Date()
        return try repository.withLock {
            var warnings: [String] = []
            var found: [(source: String, path: String, stat: FileStat)] = []
            for s in sources { scan(source: s.path, rel: "", into: &found, warnings: &warnings) }

            var entries: [Entry] = []
            var newBytes: Int64 = 0
            var fileCount = 0
            for (i, item) in found.enumerated() {
                if isCancelled() { throw BackupError.cancelled }
                let full = item.path.isEmpty ? item.source : item.source + "/" + item.path
                var st = item.stat
                var hash: String?
                var linkTarget: String?
                switch st.kind {
                case .directory: break
                case .symlink:
                    linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: full)
                case .file:
                    guard let r = try storeFile(full, stat: st, warnings: &warnings) else { continue }
                    hash = r.hash; st = r.stat; newBytes += r.written; fileCount += 1
                }
                entries.append(Entry(source: item.source, path: item.path, kind: st.kind, hash: hash, size: st.size,
                                     mtime: st.mtime, mode: st.mode, linkTarget: linkTarget))
                progress(Double(i + 1) / Double(found.count))
            }
            if isCancelled() { throw BackupError.cancelled }
            let snapshot = Snapshot(date: now, sources: sources.map(\.path), entries: entries, warnings: warnings)
            try repository.writeSnapshot(snapshot) // written last: a backup without manifest does not exist
            try? cache.save()
            return BackupReport(snapshotID: snapshot.id, date: now, duration: Date().timeIntervalSince(start),
                                fileCount: fileCount, newBytes: newBytes, warnings: warnings, error: nil)
        }
    }

    private func scan(source: String, rel: String, insideGit: Bool = false,
                      into found: inout [(source: String, path: String, stat: FileStat)], warnings: inout [String]) {
        let full = rel.isEmpty ? source : source + "/" + rel
        // the source folder itself may be a symlink to the real folder
        guard let st = FileStat(path: full, followSymlink: rel.isEmpty) else { return }
        found.append((source, rel, st))
        guard st.kind == .directory else { return }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: full) } catch {
            warnings.append("\(full): \(error.localizedDescription)")
            return
        }
        // excludes never apply inside .git: a branch named "build" is a file under .git/refs/heads
        for name in names.sorted() where insideGit || !excludes.excludes(name: name) {
            scan(source: source, rel: rel.isEmpty ? name : rel + "/" + name, insideGit: insideGit || name == ".git",
                 into: &found, warnings: &warnings)
        }
    }

    /// Hashes and stores one file. Returns nil (with a warning) if the source is unreadable or changing while read;
    /// throws if the archive can't be written (disk full, destination gone), which fails the whole backup.
    private func storeFile(_ path: String, stat initial: FileStat, warnings: inout [String]) throws
        -> (hash: String, stat: FileStat, written: Int64)? {
        if let h = cache.lookup(path: path, inode: initial.inode, size: initial.size, mtime: initial.mtime),
           repository.hasObject(h) {
            return (h, initial, 0)
        }
        var st = initial
        for attempt in 0..<2 {
            let data: Data
            do {
                // shortcut: whole file mapped in memory; for multi-GB files switch to streamed chunks.
                data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            } catch {
                warnings.append("\(path): \(error.localizedDescription)")
                return nil
            }
            let hash = sha256Hex(data)
            guard let after = FileStat(path: path), after.size == st.size, after.mtime == st.mtime else {
                if attempt == 0, let again = FileStat(path: path) { st = again; continue }
                warnings.append("\(path): modificato durante la lettura, saltato")
                return nil
            }
            let written = repository.hasObject(hash) ? 0 : try repository.putObject(data, hash: hash)
            cache.store(path: path, inode: st.inode, size: st.size, mtime: st.mtime, hash: hash)
            return (hash, st, written)
        }
        return nil
    }
}
