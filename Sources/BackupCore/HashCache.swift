import CryptoKit
import Foundation

/// Remembers the hash of files already read, so unchanged files are never re-read.
/// The key includes ctime, which tools like `touch -r` or `cp -p` cannot set back.
/// Only paths seen in the last run are kept, and the file is rewritten only when something changed.
///
/// Stored as LZFSE-compressed binary records under a checksum: the JSON of a million files was 338 MB rewritten at
/// every backup with changes, and decoding or encoding it built a tree of every item (GBs). A file that doesn't
/// verify, or the JSON written before 1.0, is read as before or else starts empty: files are hashed again, nothing is lost.
public final class HashCache {
    private struct Item { var inode: UInt64; var size: Int64; var mtime: Date; var ctime: Date?; var hash: String; var seen = false }
    private struct LegacyItem: Codable { var inode: UInt64; var size: Int64; var mtime: Date; var ctime: Date?; var hash: String }
    private struct Legacy: Codable { var items: [String: LegacyItem]; var manifestDigest: String?; var manifestID: String? }
    private static let magic = Data("BMHC2\n".utf8)
    private let url: URL
    // seen is a flag of the item, not a set of paths: that set held a second copy of every path (100+ MB at 1M files)
    private var items: [String: Item]
    private var changed = false
    /// Digest of the last manifest written, to skip writing an identical one.
    public var lastManifest: (digest: String, id: String)? { didSet { changed = true } }

    public init(url: URL) {
        self.url = url
        items = [:]
        // a pool: the file and its decompressed copy (tens of MB) would otherwise stay until the backup ends
        changed = autoreleasepool {
            guard let data = try? Data(contentsOf: url) else { return false }
            if data.starts(with: Self.magic) {
                if !load(data) { items = [:]; lastManifest = nil }
            } else if let stored = try? JSONDecoder().decode(Legacy.self, from: data) {
                for (path, i) in stored.items {
                    items[path] = Item(inode: i.inode, size: i.size, mtime: i.mtime, ctime: i.ctime, hash: i.hash)
                }
                if let d = stored.manifestDigest, let id = stored.manifestID { lastManifest = (d, id) }
                return true // written again in the binary format at the next save
            }
            return false
        }
    }

    /// `ctime: nil` ignores it: only for a file the cloud client evicted, which changes ctime and nothing else.
    public func lookup(path: String, inode: UInt64, size: Int64, mtime: Date, ctime: Date?) -> String? {
        guard let index = items.index(forKey: path) else { return nil }
        items.values[index].seen = true
        let i = items.values[index]
        guard i.inode == inode, i.size == size, i.mtime == mtime, ctime == nil || i.ctime == ctime else { return nil }
        return i.hash
    }

    public func store(path: String, inode: UInt64, size: Int64, mtime: Date, ctime: Date, hash: String) {
        items[path] = Item(inode: inode, size: size, mtime: mtime, ctime: ctime, hash: hash, seen: true)
        changed = true
    }

    /// True if this file was read in an earlier run: it is in the backups.
    public func knows(_ path: String) -> Bool { items[path] != nil }

    /// A file last seen with this content, if any (it may have changed since: check before trusting it).
    public func path(for hash: String) -> String? { items.first { $0.value.hash == hash }?.key }

    /// `dropUnseen: false` after an interrupted run: the paths it didn't reach are still valid, and forgetting them
    /// would mean reading and hashing every file again at the next attempt.
    public func save(dropUnseen: Bool = true) throws {
        let unseen = dropUnseen ? items.filter { !$0.value.seen }.map(\.key) : []
        for k in unseen { items[k] = nil }
        guard changed || !unseen.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // shortcut: rewritten whole when anything changed (~66 MB with a million files); keep it in the app and save
        // it once a day if that is still too much for the SSD
        try autoreleasepool { try write() } // its buffers (tens of MB) freed now, not when the run ends
        changed = false
    }

    private func write() throws {
        var payload = Data()
        // sized exactly: doubling a buffer of a million items copies it and can leave twice its size behind
        payload.reserveCapacity(items.reduce(200) { $0 + 44 + $1.key.utf8.count + $1.value.hash.utf8.count })
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { payload.append(contentsOf: $0) } }
        func put(_ s: String) { put(UInt32(s.utf8.count).littleEndian); payload.append(contentsOf: s.utf8) }
        put(lastManifest?.digest ?? ""); put(lastManifest?.id ?? ""); put(UInt32(items.count).littleEndian)
        for (path, i) in items {
            put(path)
            put(i.inode.littleEndian); put(i.size.littleEndian)
            put(i.mtime.timeIntervalSinceReferenceDate.bitPattern.littleEndian)
            put((i.ctime?.timeIntervalSinceReferenceDate ?? .nan).bitPattern.littleEndian)
            put(i.hash)
        }
        let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
        try (Self.magic + Data(SHA256.hash(data: payload)) + compressed).write(to: url, options: .atomic)
    }

    /// False when the file doesn't verify or parse: the caller starts empty.
    private func load(_ data: Data) -> Bool {
        let body = data.dropFirst(Self.magic.count)
        guard body.count > 32, let payload = try? (Data(body.dropFirst(32)) as NSData).decompressed(using: .lzfse) as Data,
              Data(SHA256.hash(data: payload)) == body.prefix(32) else { return false }
        return payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var at = 0
            func take<T: FixedWidthInteger>(_: T.Type) -> T? {
                guard at + MemoryLayout<T>.size <= raw.count else { return nil }
                defer { at += MemoryLayout<T>.size }
                return T(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: T.self))
            }
            func string() -> String? {
                guard let n = take(UInt32.self).map(Int.init), at + n <= raw.count else { return nil }
                defer { at += n }
                return String(decoding: raw[at ..< at + n], as: UTF8.self)
            }
            guard let digest = string(), let id = string() else { return false }
            guard let count = take(UInt32.self) else { return false }
            items.reserveCapacity(min(Int(count), raw.count / 40)) // growing a dictionary of a million items leaves its old tables behind
            if !digest.isEmpty, !id.isEmpty { lastManifest = (digest, id) }
            while at < raw.count {
                guard let path = string(), let inode = take(UInt64.self), let size = take(Int64.self),
                      let mtime = take(UInt64.self), let ctime = take(UInt64.self), let hash = string() else { return false }
                let c = Double(bitPattern: ctime)
                items[path] = Item(inode: inode, size: size, mtime: Date(timeIntervalSinceReferenceDate: Double(bitPattern: mtime)),
                                   ctime: c.isNaN ? nil : Date(timeIntervalSinceReferenceDate: c), hash: hash)
            }
            return true
        }
    }
}
