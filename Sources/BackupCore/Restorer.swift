import Foundation

public enum RestoreMode: Equatable, Sendable { case besideOriginal, replace, into(URL) }
public enum EntryStatus: Equatable, Sendable { case unchanged, modified, missing }
public enum RestoreError: Error, Equatable {
    case notFound(String), invalidEntry(String)
    /// Replace moved the current item to the Trash but couldn't put the restored copy in its place:
    /// the copy was kept beside it, at this path.
    case keptBeside(String)
    /// Replace would move this folder to the Trash with the backup archive inside it.
    case containsArchive(String)
    /// A folder on the way to the original is a symbolic link today: writing there would land somewhere else.
    case linkInPath(String)
}

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
        // names from strings, not URLs: a URL holds them decomposed, and the restored item would get another name
        let last = ((path.isEmpty ? source : path) as NSString).lastPathComponent
        // a source "/" (or a tampered name) would otherwise land next to the chosen folder, not inside it
        let name = ["", "/", ".", ".."].contains(last) ? "Backup" : last
        let target: URL
        let targetName: String
        switch mode {
        case .besideOriginal:
            targetName = Self.restoredName(name, date: snapshot.date)
            target = original.deletingLastPathComponent().appending(path: targetName)
        case .replace:
            target = original
            targetName = path.isEmpty ? ((source as NSString).resolvingSymlinksInPath as NSString).lastPathComponent : last
        case .into(let dir):
            target = dir.appending(path: name)
            targetName = name
        }
        // the destination may sit inside a saved folder (it is skipped by the backup): trashing that folder would
        // take every backup with it, and the restored copy doesn't hold them
        if mode == .replace,
           repository.root.resolvingSymlinksInPath().path.hasPrefix(target.resolvingSymlinksInPath().path + "/") {
            throw RestoreError.containsArchive(target.path)
        }
        // beside or in place of the original: no folder on the way may have become a link since the backup
        var missing: [(URL, String)] = []
        if mode == .besideOriginal || mode == .replace {
            var dir = sourceRoot
            for part in path.split(separator: "/").dropLast() {
                dir = dir.appending(path: String(part))
                if (try? fm.destinationOfSymbolicLink(atPath: dir.path)) != nil { throw RestoreError.linkInPath(dir.path) }
                if (try? fm.attributesOfItem(atPath: dir.path)) == nil { missing.append((dir, String(part))) }
            }
        }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // folders on the way that are gone: created decomposed, like everything Foundation writes
        for (dir, part) in missing { Self.keepSavedName(dir, part) }
        let staging = parent.appending(path: ".backupme-restore-\(UUID().uuidString)")
        var trashed = false
        do {
            try build(entries, prefix: path, at: staging)
            if mode == .replace, (try? fm.attributesOfItem(atPath: target.path)) != nil { try trash(target); trashed = true }
            return try place(staging, in: parent, name: targetName, renameIfTaken: mode != .replace)
        } catch {
            // the current item is already in the Trash: the rebuilt copy is now the only one outside it, keep it
            if trashed, let kept = try? place(staging, in: parent, name: Self.restoredName(name, date: snapshot.date),
                                              renameIfTaken: true) {
                throw RestoreError.keptBeside(kept.path)
            }
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
                // a saved folder, or a single saved file
                guard e.kind == .directory || (e.kind == .file && e.hash.map(Repository.isHash) == true)
                else { throw RestoreError.invalidEntry(e.path) }
                dirs.insert("")
                continue
            }
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !e.path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  dirs.contains((e.path as NSString).deletingLastPathComponent),
                  e.kind != .file || e.hash.map(Repository.isHash) == true else { throw RestoreError.invalidEntry(e.path) }
            if e.kind == .directory { dirs.insert(e.path) }
        }
    }

    private func build(_ entries: [Entry], prefix: String, at root: URL) throws {
        var dirs: [(URL, Entry)] = []
        for e in entries {
            // a pool per item: decompressed copies would otherwise stay in memory until the whole restore ends
            try autoreleasepool {
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
                if !rel.isEmpty { Self.keepSavedName(url, (rel as NSString).lastPathComponent) }
            }
        }
        // deepest first, so a read-only folder is locked only after its children are written
        for (url, e) in dirs.reversed() {
            try fm.setAttributes([.posixPermissions: Int(e.mode)], ofItemAtPath: url.path)
            try setModificationDate(url, e.mtime)
        }
    }

    /// Foundation writes names decomposed ("u" + "¨"): the saved name was most likely composed ("ü"). The same
    /// name for the Finder, another one for git, rsync or a Linux server. rename(2) keeps the bytes it is given.
    /// Through a temporary name: on case-sensitive APFS a rename between two forms of one name does nothing.
    /// exFAT and FAT32 store every name decomposed whatever they are given: the item goes back to its first name.
    static func keepSavedName(_ url: URL, _ name: String) {
        let decomposed = name.decomposedStringWithCanonicalMapping
        guard !name.utf8.elementsEqual(decomposed.utf8) else { return }
        let dir = url.deletingLastPathComponent().path
        let step = dir + "/.backupme-name-\(UUID().uuidString)"
        guard rename(dir + "/" + decomposed, step) == 0 else { return }
        if renameExclusive(step, dir + "/" + name) != 0 { _ = rename(step, dir + "/" + decomposed) }
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
    private func place(_ staging: URL, in dir: URL, name target: String, renameIfTaken: Bool) throws -> URL {
        let ext = (target as NSString).pathExtension
        let stem = ext.isEmpty ? target : String(target.dropLast(ext.count + 1))
        for n in 1...100 {
            let name = n == 1 ? target : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            // a String path: rename(2) keeps the bytes of the name as given
            let candidate = dir.path + "/" + name
            if Self.renameExclusive(staging.path, candidate) == 0 { return URL(fileURLWithPath: candidate) }
            guard errno == EEXIST, renameIfTaken else { break }
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EEXIST)
    }

    /// rename(2) that fails with EEXIST instead of replacing `to`. exFAT and FAT32 reject RENAME_EXCL with ENOTSUP.
    static func renameExclusive(_ from: String, _ to: String) -> Int32 {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
        guard errno == ENOTSUP || errno == EOPNOTSUPP else { return -1 }
        // shortcut: an item created at `to` between the check and the rename would be replaced (an empty folder) or
        // make it fail; these filesystems offer nothing exclusive for folders, upgrade if one ever does
        var st = stat()
        if lstat(to, &st) == 0 { errno = EEXIST; return -1 }
        guard errno == ENOENT else { return -1 }
        return rename(from, to)
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

    /// A read-only copy of a backed-up file for previewing or comparing, in a temporary folder per content:
    /// nothing outside it is written, and each version is extracted once.
    public func extract(_ entry: Entry,
                        into base: URL = FileManager.default.temporaryDirectory.appending(path: "BackupMe-anteprime")) throws -> URL {
        guard entry.kind == .file, let hash = entry.hash, Repository.isHash(hash),
              !["", ".", ".."].contains(entry.name) else { throw RestoreError.invalidEntry(entry.path) }
        let dir = base.appending(path: hash, directoryHint: .isDirectory)
        let url = dir.appending(path: entry.name)
        // only a complete, verified copy gets the final name; one of the wrong size is a leftover of an older
        // version that wrote in place: extracted again
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
            if size == entry.size { return url }
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".estrazione-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try repository.restoreObject(hash, to: tmp)
        try? fm.setAttributes([.posixPermissions: 0o444, .modificationDate: entry.mtime], ofItemAtPath: tmp.path)
        if rename(tmp.path, url.path) != 0, !fm.fileExists(atPath: url.path) {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    public struct ReplaceCheck: Equatable, Sendable {
        /// Files whose current version differs from the backup: replacing sends today's version to the Trash.
        public var changedFiles: Int
        /// HEAD or refs differ from the backup: commits or branches newer than it would go to the Trash too.
        public var repositoryChanged: Bool
        /// Files created after the backup, which it lacks: they go to the Trash with the folder.
        public var newFiles = 0
    }

    /// What replacing `source` with `snapshot` would set aside beyond the backup. Reads file metadata only.
    /// `rules`: what the backup excludes, which the message already names as going to the Trash.
    public static func replaceCheck(_ snapshot: Snapshot, source: String,
                                    rules: ExcludeRules = ExcludeRules(patterns: [])) -> ReplaceCheck {
        var check = ReplaceCheck(changedFiles: 0, repositoryChanged: false)
        let saved = Set(snapshot.entries.lazy.filter { $0.source == source }.map(\.path))
        // a source that is a symlink was backed up through the link: walk the real folder
        let root = URL(fileURLWithPath: (source as NSString).resolvingSymlinksInPath)
        // skips what the backup skips (see BackupEngine.walk), or all of it would count as new
        // relative URLs: absolute ones may come back without /private, and wouldn't match the root
        if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: .producesRelativePathURLs) {
            for case let url as URL in walk {
                let path = url.relativePath, full = root.path + "/" + path
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                // inside a nested .git (sub/.git) the backup applies no rule and no size limit: neither does this
                let inGit = path.contains("/.git/")
                // .git internals: covered by the refs below. A folder only in the cloud: listing it would download it
                if path == ".git"
                    || (!inGit && (rules.excludes(name: url.lastPathComponent, isDirectory: isDir, path: path)
                                   || rules.paths.contains(full) || (isDir && isCacheDirectory(full))))
                    || (isDir && FileStat(path: full)?.dataless == true) {
                    if isDir { walk.skipDescendants() }
                    continue
                }
                guard !isDir, !saved.contains(path) else { continue }
                if !inGit, let max = rules.maxFileSize, let st = FileStat(path: full), st.size > max { continue }
                check.newFiles += 1
            }
        }
        for e in snapshot.entries where e.source == source && e.kind == .file {
            let isRef = e.path == ".git/HEAD" || e.path == ".git/packed-refs" || e.path.hasPrefix(".git/refs/")
            guard isRef || !e.path.hasPrefix(".git/") else { continue } // other git internals: covered by the refs
            let s = status(of: e)
            if isRef { if s != .unchanged { check.repositoryChanged = true } } else if s == .modified { check.changedFiles += 1 }
        }
        return check
    }

    /// How many lines a list bounded by the engine stands for: its last may be "… e altri N avvisi" or
    /// "… e un altro avviso", which is no warning itself but stands for the ones left out.
    public static func boundedCount(_ lines: [String]) -> Int {
        guard let last = lines.last else { return 0 }
        if last.hasPrefix("… e un altro ") { return lines.count }
        guard last.hasPrefix("… e altri "), let more = Int(last.dropFirst("… e altri ".count).prefix(while: \.isNumber))
        else { return lines.count }
        return lines.count - 1 + more
    }

    /// One version per distinct content of `found` (backups read so far, in any order), newest first by `newestFirst`.
    /// Each is listed under the newest backup holding it, or under `preferring` (the one being viewed) if that holds it.
    public static func versions(_ found: [(snapshotID: String, entry: Entry)], newestFirst: [String],
                                preferring: String? = nil) -> [(snapshotID: String, entry: Entry)] {
        let rank = Dictionary(newestFirst.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var best: [String: (rank: Int, version: (snapshotID: String, entry: Entry))] = [:]
        for v in found {
            guard let h = v.entry.hash, let r = rank[v.snapshotID] else { continue }
            guard var b = best[h] else { best[h] = (r, v); continue }
            if r < b.rank { b.rank = r; if b.version.snapshotID != preferring { b.version = v } }
            if v.snapshotID == preferring { b.version = v }
            best[h] = b
        }
        return best.values.sorted { $0.rank < $1.rank }.map(\.version)
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
        // a saved folder that is a symlink was backed up through the link: compare with the real folder
        guard let st = FileStat(path: entry.url.path, followSymlink: entry.path.isEmpty) else { return .missing }
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
