import Foundation

/// Remembers the hash of files already read, so unchanged files are never re-read.
public final class HashCache {
    private struct Item: Codable { var inode: UInt64; var size: Int64; var mtime: Date; var hash: String }
    private let url: URL
    private var items: [String: Item]

    public init(url: URL) {
        self.url = url
        items = (try? JSONDecoder().decode([String: Item].self, from: Data(contentsOf: url))) ?? [:]
    }

    public func lookup(path: String, inode: UInt64, size: Int64, mtime: Date) -> String? {
        guard let i = items[path], i.inode == inode, i.size == size, i.mtime == mtime else { return nil }
        return i.hash
    }

    public func store(path: String, inode: UInt64, size: Int64, mtime: Date, hash: String) {
        items[path] = Item(inode: inode, size: size, mtime: mtime, hash: hash)
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
    }
}
