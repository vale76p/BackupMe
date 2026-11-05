import CryptoKit
import Foundation

public enum RepositoryError: Error, Equatable {
    case destinationMissing(String)
    case locked(pid: Int32, host: String)
    case corruptObject(String)
}

/// Archive layout: <destination>/BackupMe/<archive name>/{repo.json, objects/, snapshots/, lock}
/// Objects are stored as `<hash>.lzfse` (compressed) or `<hash>.raw` (incompressible or large files).
public final class Repository {
    public let root: URL
    private let fm = FileManager.default
    private var knownObjects: Set<String>?
    private let computer: String

    private var objectsDir: URL { root.appending(path: "objects", directoryHint: .isDirectory) }
    private var snapshotsDir: URL { root.appending(path: "snapshots", directoryHint: .isDirectory) }
    private var lockURL: URL { root.appending(path: "lock") }

    /// `create: false` opens an existing archive only (browsing must never write to the destination).
    public init(destination: URL, computerName: String, create: Bool = true) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw RepositoryError.destinationMissing(destination.path)
        }
        let safeName = computerName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        computer = safeName
        root = destination.appending(path: "BackupMe", directoryHint: .isDirectory)
            .appending(path: safeName, directoryHint: .isDirectory)
        let info = root.appending(path: "repo.json")
        guard create else {
            guard fm.fileExists(atPath: info.path) else { throw RepositoryError.destinationMissing(root.path) }
            return
        }
        try fm.createDirectory(at: objectsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: info.path) {
            let json = #"{"format":1,"id":"\#(UUID().uuidString)","created":\#(Date().timeIntervalSince1970)}"#
            try atomicWrite(Data(json.utf8), to: info, sync: .file)
        }
    }

    /// Picking the BackupMe folder, or an archive inside it, means the folder holding them:
    /// taken literally, a new archive would be nested inside the old one and its backups would vanish from view.
    public static func destination(for picked: URL) -> URL {
        var u = picked.standardizedFileURL
        if FileManager.default.fileExists(atPath: u.appending(path: "repo.json").path),
           u.deletingLastPathComponent().lastPathComponent == "BackupMe" {
            u = u.deletingLastPathComponent()
        }
        if u.lastPathComponent == "BackupMe", !computers(in: u.deletingLastPathComponent()).isEmpty {
            u = u.deletingLastPathComponent()
        }
        return u
    }

    public static func computers(in destination: URL) -> [String] {
        let base = destination.appending(path: "BackupMe", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: base.appending(path: "\($0)/repo.json").path) }.sorted()
    }

    // MARK: objects

    private static let extensions = ["lzfse", "raw"]
    /// Files at least this big are hashed and copied as a stream, never loaded in memory or compressed.
    public static let streamThreshold: Int64 = 32 << 20

    private func objectURL(_ hash: String, _ ext: String) -> URL {
        objectsDir.appending(path: String(hash.prefix(2)), directoryHint: .isDirectory).appending(path: "\(hash).\(ext)")
    }

    private func existingObjectURL(_ hash: String) -> URL? {
        Self.extensions.map { objectURL(hash, $0) }.first { fm.fileExists(atPath: $0.path) }
    }

    /// Every stored object with its size on disk, from one listing of the archive.
    public func objectSizes() throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for dir in try fm.contentsOfDirectory(atPath: objectsDir.path) {
            let d = objectsDir.appending(path: dir)
            for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where Self.extensions.contains((f as NSString).pathExtension) {
                let size = (try? fm.attributesOfItem(atPath: d.appending(path: f).path)[.size] as? Int64) ?? 0
                result[(f as NSString).deletingPathExtension] = size
            }
        }
        return result
    }

    public func allObjectHashes() throws -> Set<String> {
        var result = Set<String>()
        for dir in try fm.contentsOfDirectory(atPath: objectsDir.path) {
            for f in (try? fm.contentsOfDirectory(atPath: objectsDir.appending(path: dir).path)) ?? []
            where Self.extensions.contains((f as NSString).pathExtension) {
                result.insert((f as NSString).deletingPathExtension)
            }
        }
        return result
    }

    public func hasObject(_ hash: String) -> Bool {
        if knownObjects == nil { knownObjects = (try? allObjectHashes()) ?? [] }
        return knownObjects!.contains(hash)
    }

    private func prepareFanout(_ url: URL) throws {
        let fanout = url.deletingLastPathComponent()
        // no intermediate folders: if the destination vanished mid-run this fails instead of recreating it locally
        if !fm.fileExists(atPath: fanout.path) { try fm.createDirectory(at: fanout, withIntermediateDirectories: false) }
    }

    /// Stores in-memory content; kept raw when compression saves less than 5%. Returns the bytes written.
    public func putObject(_ data: Data, hash: String) throws -> Int64 {
        let compressed = data.isEmpty ? nil : try? (data as NSData).compressed(using: .lzfse) as Data
        let useCompressed = compressed.map { $0.count < data.count * 95 / 100 } ?? false
        let body = useCompressed ? compressed! : data
        let url = objectURL(hash, useCompressed ? "lzfse" : "raw")
        try prepareFanout(url)
        try atomicWrite(body, to: url, sync: .file)
        knownObjects?.insert(hash)
        return Int64(body.count)
    }

    /// Stores a large file by copying it (a clone on the same APFS volume), without loading it in memory.
    public func putObjectFile(from source: URL, hash: String) throws -> Int64 {
        let url = objectURL(hash, "raw")
        try prepareFanout(url)
        let tmp = url.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        let fd = open(tmp.path, O_RDONLY)
        if fd >= 0 { fsync(fd); close(fd) }
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        knownObjects?.insert(hash)
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Reads and verifies an object. A mismatch throws but never deletes: the copy may still be syncing,
    /// and OneDrive version history can only help while the file is still there.
    public func readObject(_ hash: String) throws -> Data {
        guard let url = existingObjectURL(hash) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: hash]) }
        let raw = try Data(contentsOf: url)
        let data = url.pathExtension == "raw" || raw.isEmpty ? raw : (try? (raw as NSData).decompressed(using: .lzfse)) as Data?
        guard let data, sha256Hex(data) == hash else { throw RepositoryError.corruptObject(hash) }
        return data
    }

    /// Writes an object's content to `destination` (which must not exist), verifying its hash.
    public func restoreObject(_ hash: String, to destination: URL) throws {
        guard let url = existingObjectURL(hash) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: hash]) }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if url.pathExtension == "raw", size >= Self.streamThreshold {
            try fm.copyItem(at: url, to: destination)
            guard (try? streamHash(destination)) == hash else {
                try? fm.removeItem(at: destination)
                throw RepositoryError.corruptObject(hash)
            }
            return
        }
        try readObject(hash).write(to: destination, options: .withoutOverwriting)
    }

    public func deleteObject(_ hash: String) throws {
        for ext in Self.extensions { try? fm.removeItem(at: objectURL(hash, ext)) }
        knownObjects?.remove(hash)
    }

    public func removeTemporaryFiles() throws {
        for dir in [snapshotsDir, objectsDir] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "tmp" { try fm.removeItem(at: url) }
        }
    }

    public func poolSize() throws -> Int64 {
        try objectSizes().values.reduce(0, +) + snapshotSizes().values.reduce(0, +)
    }

    // MARK: snapshots

    private func snapshotURL(_ id: String) -> URL { snapshotsDir.appending(path: "\(id).json.lzfse") }

    public func snapshotIDs() throws -> [String] {
        try fm.contentsOfDirectory(atPath: snapshotsDir.path)
            .filter { $0.hasSuffix(".json.lzfse") }
            .map { String($0.dropLast(11)) }
            .sorted()
    }

    public func snapshotSizes() throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for id in try snapshotIDs() {
            result[id] = (try? fm.attributesOfItem(atPath: snapshotURL(id).path)[.size] as? Int64) ?? 0
        }
        return result
    }

    public func snapshotExists(_ id: String) -> Bool { fm.fileExists(atPath: snapshotURL(id).path) }

    /// Never overwrites an existing manifest: cached references assume manifests are immutable.
    public func writeSnapshot(_ s: Snapshot) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = .sortedKeys
        let json = try enc.encode(s)
        // full flush: the manifest makes the backup exist, so everything before it must be on disk
        try atomicWrite(try (json as NSData).compressed(using: .lzfse) as Data, to: snapshotURL(s.id), sync: .device, exclusive: true)
    }

    public func readSnapshot(_ id: String) throws -> Snapshot {
        let raw = try Data(contentsOf: snapshotURL(id))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(Snapshot.self, from: try (raw as NSData).decompressed(using: .lzfse) as Data)
    }

    public func deleteSnapshot(_ id: String) throws { try fm.removeItem(at: snapshotURL(id)) }

    // MARK: lock

    /// Exclusive lock with flock(2): the kernel releases it when the process dies, so there are no stale locks.
    /// Each Mac writes only its own archive folder, so a machine-local lock is enough.
    @discardableResult
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) } // closing releases the lock; the file is kept so waiters never lock a deleted inode
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // shortcut: filesystems without flock (some exFAT/SMB) run unlocked; acceptable for a single-user app
            guard errno == ENOTSUP || errno == EOPNOTSUPP else { throw RepositoryError.locked(pid: 0, host: computer) }
        }
        return try body()
    }

    // MARK: helpers

    enum Sync { case file, device }

    /// Write to <name>.tmp, flush, then rename, so a crash never leaves a half-written file under its final name.
    /// `.device` uses F_FULLFSYNC, which also flushes the drive cache holding earlier writes.
    /// `exclusive` refuses to replace an existing file.
    private func atomicWrite(_ data: Data, to url: URL, sync: Sync, exclusive: Bool = false) throws {
        let tmp = url.appendingPathExtension("tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                // write(2) rejects counts above INT_MAX with EINVAL: write in 1 GB chunks
                let n = write(fd, buf.baseAddress! + offset, min(buf.count - offset, 1 << 30))
                if n < 0 { failure = errno; return }
                offset += n
            }
        }
        // some filesystems (exFAT, network) reject F_FULLFSYNC: fall back to fsync
        if failure == 0, !(sync == .device && fcntl(fd, F_FULLFSYNC) == 0), fsync(fd) != 0 { failure = errno }
        close(fd)
        let moved = failure == 0
            && (exclusive ? renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL)) : rename(tmp.path, url.path)) == 0
        guard moved else {
            let code = failure != 0 ? failure : errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// SHA-256 of a file read in 4 MB chunks, so large files never sit in memory.
func streamHash(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
