import Foundation

public enum RestoreMode: Equatable, Sendable { case besideOriginal, replace, into(URL) }
public enum EntryStatus: Equatable, Sendable { case unchanged, modified, missing }
public enum RestoreError: Error, Equatable { case notFound(String), invalidEntry(String) }

public final class Restorer {
    private let repository: Repository
    private let trash: (URL) throws -> Void
    private let fm = FileManager.default

    public init(repository: Repository,
                trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.repository = repository; self.trash = trash
    }

    /// Restores `path` ("" = whole source) from `snapshot`. Never overwrites: `.replace` trashes the current copy first.
    /// Everything is rebuilt in a hidden sibling folder and moved into place at the end, so a failure leaves nothing behind.
    @discardableResult
    public func restore(_ snapshot: Snapshot, source: String, path: String, mode: RestoreMode, now: Date = Date()) throws -> URL {
        let tree = snapshot.entries.filter { $0.source == source }
            .sorted { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
        try Self.validate(tree)
        let entries = tree.filter { path.isEmpty || $0.path == path || $0.path.hasPrefix(path + "/") }
        guard !entries.isEmpty else { throw RestoreError.notFound(path) }

        // a source that is a symlink was backed up through the link: restore into the real folder
        let sourceRoot = URL(fileURLWithPath: source).resolvingSymlinksInPath()
        let original = path.isEmpty ? sourceRoot : sourceRoot.appending(path: path)
        let name = path.isEmpty ? URL(fileURLWithPath: source).lastPathComponent : original.lastPathComponent
        let target: URL
        switch mode {
        case .besideOriginal: target = original.deletingLastPathComponent().appending(path: Self.restoredName(name, date: snapshot.date))
        case .replace: target = original
        case .into(let dir): target = dir.appending(path: name)
        }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".backupme-restore-\(UUID().uuidString)")
        do {
            try build(entries, prefix: path, at: staging)
            if mode == .replace, (try? fm.attributesOfItem(atPath: target.path)) != nil { try trash(target) }
            return try place(staging, at: target, renameIfTaken: mode != .replace)
        } catch {
            try? makeWritable(staging)
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Rejects manifests that would write outside the restore folder: absolute paths, `.`/`..` components,
    /// duplicates, or entries whose parent is not a folder of the backup (e.g. a symlink pointing elsewhere).
    static func validate(_ sortedByDepth: [Entry]) throws {
        var dirs = Set<String>()
        var seen = Set<String>()
        for e in sortedByDepth {
            guard seen.insert(e.path).inserted else { throw RestoreError.invalidEntry(e.path) }
            if e.path.isEmpty {
                guard e.kind == .directory else { throw RestoreError.invalidEntry(e.path) }
                dirs.insert("")
                continue
            }
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !e.path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  dirs.contains((e.path as NSString).deletingLastPathComponent),
                  e.kind != .file || e.hash != nil else { throw RestoreError.invalidEntry(e.path) }
            if e.kind == .directory { dirs.insert(e.path) }
        }
    }

    private func build(_ entries: [Entry], prefix: String, at root: URL) throws {
        var dirs: [(URL, Entry)] = []
        for e in entries {
            let rel = prefix.isEmpty ? e.path : (e.path == prefix ? "" : String(e.path.dropFirst(prefix.count + 1)))
            let url = rel.isEmpty ? root : root.appending(path: rel)
            switch e.kind {
            case .directory:
                try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                dirs.append((url, e))
            case .file:
                try repository.restoreObject(e.hash ?? "", to: url)
                try fm.setAttributes([.posixPermissions: Int(e.mode)], ofItemAtPath: url.path)
                try setModificationDate(url, e.mtime)
            case .symlink:
                // symlink mode/mtime are not restored: macOS ignores link permissions in practice
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: e.linkTarget ?? "")
            }
        }
        // deepest first, so a read-only folder is locked only after its children are written
        for (url, e) in dirs.reversed() {
            try fm.setAttributes([.posixPermissions: Int(e.mode)], ofItemAtPath: url.path)
            try setModificationDate(url, e.mtime)
        }
    }

    /// Full nanosecond precision (FileManager keeps only microseconds, which made restored files look "modificato").
    private func setModificationDate(_ url: URL, _ date: Date) throws {
        let t = date.timeIntervalSince1970
        let sec = t.rounded(.down)
        let ts = timespec(tv_sec: Int(sec), tv_nsec: min(Int(((t - sec) * 1e9).rounded()), 999_999_999))
        var times = [ts, ts]
        guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Moves `staging` to `target` without ever replacing an existing item. With `renameIfTaken`,
    /// picks "name 2", "name 3"… atomically, so two restores at once can't collide.
    private func place(_ staging: URL, at target: URL, renameIfTaken: Bool) throws -> URL {
        let ext = target.pathExtension
        let stem = ext.isEmpty ? target.lastPathComponent : String(target.lastPathComponent.dropLast(ext.count + 1))
        for n in 1...100 {
            let name = n == 1 ? target.lastPathComponent : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            let candidate = target.deletingLastPathComponent().appending(path: name)
            if renamex_np(staging.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST, renameIfTaken else { break }
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EEXIST)
    }

    private func makeWritable(_ url: URL) throws {
        guard let e = fm.enumerator(atPath: url.path) else { return }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        for case let rel as String in e { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.appending(path: rel).path) }
    }

    /// One entry per distinct content, newest first. Unreadable manifests are skipped.
    public func versions(source: String, path: String) throws -> [(snapshotID: String, entry: Entry)] {
        var seen = Set<String>()
        var result: [(snapshotID: String, entry: Entry)] = []
        for id in try repository.snapshotIDs().reversed() {
            let found = autoreleasepool {
                (try? repository.readSnapshot(id))?.entries.first { $0.source == source && $0.path == path }
            }
            guard let e = found, let h = e.hash, seen.insert(h).inserted else { continue }
            result.append((id, e))
        }
        return result
    }

    public static func restoredName(_ name: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM HH.mm"
        let stamp = "(ripristinato \(f.string(from: date)))"
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name) \(stamp)" }
        return "\((name as NSString).deletingPathExtension) \(stamp).\(ext)"
    }

    /// Compares a backed-up entry with what is on disk now.
    public static func status(of entry: Entry) -> EntryStatus {
        guard let st = FileStat(path: entry.url.path) else { return .missing }
        guard st.kind == entry.kind else { return .modified }
        switch entry.kind {
        case .directory: return .unchanged
        case .file:
            // dates go through a Double in the manifest: compare within a microsecond
            return st.size == entry.size && abs(st.mtime.timeIntervalSince(entry.mtime)) < 1e-6 ? .unchanged : .modified
        case .symlink:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)) == entry.linkTarget ? .unchanged : .modified
        }
    }
}
