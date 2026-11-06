import Foundation

/// Remembers the hash of files already read, so unchanged files are never re-read.
/// The key includes ctime, which tools like `touch -r` or `cp -p` cannot set back.
/// Only paths seen in the last run are kept, and the file is rewritten only when something changed.
public final class HashCache {
    private struct Item: Codable { var inode: UInt64; var size: Int64; var mtime: Date; var ctime: Date?; var hash: String }
    private struct Stored: Codable { var items: [String: Item]; var manifestDigest: String?; var manifestID: String? }
    private let url: URL
    private var items: [String: Item]
    private var seen = Set<String>()
    private var changed = false
    /// Digest of the last manifest written, to skip writing an identical one.
    public var lastManifest: (digest: String, id: String)? { didSet { changed = true } }

    public init(url: URL) {
        self.url = url
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        items = stored?.items ?? [:]
        if let d = stored?.manifestDigest, let id = stored?.manifestID { lastManifest = (d, id) }
        changed = false
    }

    public func lookup(path: String, inode: UInt64, size: Int64, mtime: Date, ctime: Date) -> String? {
        seen.insert(path)
        guard let i = items[path], i.inode == inode, i.size == size, i.mtime == mtime, i.ctime == ctime else { return nil }
        return i.hash
    }

    public func store(path: String, inode: UInt64, size: Int64, mtime: Date, ctime: Date, hash: String) {
        seen.insert(path)
        items[path] = Item(inode: inode, size: size, mtime: mtime, ctime: ctime, hash: hash)
        changed = true
    }

    /// A file last seen with this content, if any (it may have changed since: check before trusting it).
    public func path(for hash: String) -> String? { items.first { $0.value.hash == hash }?.key }

    /// `dropUnseen: false` after an interrupted run: the paths it didn't reach are still valid, and forgetting them
    /// would mean reading and hashing every file again at the next attempt.
    public func save(dropUnseen: Bool = true) throws {
        let unseen = dropUnseen ? items.keys.filter { !seen.contains($0) } : []
        for k in unseen { items[k] = nil }
        guard changed || !unseen.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = Stored(items: items, manifestDigest: lastManifest?.digest, manifestID: lastManifest?.id)
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        changed = false
    }
}
