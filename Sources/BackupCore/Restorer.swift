import Foundation

public enum RestoreMode: Equatable, Sendable { case besideOriginal, replace, into(URL) }
public enum EntryStatus: Equatable, Sendable { case unchanged, modified, missing }
public enum RestoreError: Error, Equatable { case notFound(String) }

public final class Restorer {
    private let repository: Repository
    private let trash: (URL) throws -> Void
    private let fm = FileManager.default

    public init(repository: Repository,
                trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.repository = repository; self.trash = trash
    }

    /// Restores `path` ("" = whole source) from `snapshot`. Never overwrites: `.replace` trashes the current copy first.
    /// Everything is rebuilt in a hidden sibling folder and moved into place at the end, so a failure leaves nothing half-written.
    @discardableResult
    public func restore(_ snapshot: Snapshot, source: String, path: String, mode: RestoreMode, now: Date = Date()) throws -> URL {
        let entries = snapshot.entries
            .filter { $0.source == source && (path.isEmpty || $0.path == path || $0.path.hasPrefix(path + "/")) }
            .sorted { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }
        guard !entries.isEmpty else { throw RestoreError.notFound(path) }

        let original = path.isEmpty ? URL(fileURLWithPath: source) : URL(fileURLWithPath: source).appending(path: path)
        let name = original.lastPathComponent
        let target: URL
        switch mode {
        case .besideOriginal:
            target = unique(original.deletingLastPathComponent().appending(path: Self.restoredName(name, date: snapshot.date)))
        case .replace:
            target = original
        case .into(let dir):
            target = unique(dir.appending(path: name))
        }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".backupme-restore-\(UUID().uuidString)")
        do {
            try build(entries, prefix: path, at: staging)
        } catch {
            try? makeWritable(staging)
            try? fm.removeItem(at: staging)
            throw error
        }
        if mode == .replace, (try? fm.attributesOfItem(atPath: target.path)) != nil { try trash(target) }
        try fm.moveItem(at: staging, to: target)
        return target
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
                try repository.readObject(e.hash ?? "").write(to: url)
                try fm.setAttributes([.posixPermissions: Int(e.mode), .modificationDate: e.mtime], ofItemAtPath: url.path)
            case .symlink:
                // symlink mode/mtime are not restored: macOS ignores link permissions in practice
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: e.linkTarget ?? "")
            }
        }
        // deepest first, so a read-only folder is locked only after its children are written
        for (url, e) in dirs.reversed() {
            try fm.setAttributes([.posixPermissions: Int(e.mode), .modificationDate: e.mtime], ofItemAtPath: url.path)
        }
    }

    private func makeWritable(_ url: URL) throws {
        guard let e = fm.enumerator(atPath: url.path) else { return }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        for case let rel as String in e { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.appending(path: rel).path) }
    }

    private func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while (try? fm.attributesOfItem(atPath: candidate.path)) != nil {
            let ext = url.pathExtension
            let stem = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
            candidate = url.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// One entry per distinct content, newest first.
    public func versions(source: String, path: String) throws -> [(snapshotID: String, entry: Entry)] {
        var seen = Set<String>()
        var result: [(snapshotID: String, entry: Entry)] = []
        for id in try repository.snapshotIDs().reversed() {
            guard let e = try repository.readSnapshot(id).entries.first(where: { $0.source == source && $0.path == path }),
                  let h = e.hash, seen.insert(h).inserted else { continue }
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
        case .file: return st.size == entry.size && st.mtime == entry.mtime ? .unchanged : .modified
        case .symlink:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)) == entry.linkTarget ? .unchanged : .modified
        }
    }
}
