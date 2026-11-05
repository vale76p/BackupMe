import Foundation

public enum RepositoryError: Error, Equatable {
    case destinationMissing(String)
    case locked(pid: Int32, host: String)
    case corruptObject(String)
}

/// Archive layout: <destination>/BackupMe/<computer>/{repo.json, objects/, snapshots/, lock}
public final class Repository {
    public let root: URL
    private let fm = FileManager.default
    private var knownObjects: Set<String>?
    private let computer: String

    private var objectsDir: URL { root.appending(path: "objects", directoryHint: .isDirectory) }
    private var snapshotsDir: URL { root.appending(path: "snapshots", directoryHint: .isDirectory) }
    private var lockURL: URL { root.appending(path: "lock") }

    public init(destination: URL, computerName: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw RepositoryError.destinationMissing(destination.path)
        }
        let safeName = computerName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        computer = safeName
        root = destination.appending(path: "BackupMe", directoryHint: .isDirectory)
            .appending(path: safeName, directoryHint: .isDirectory)
        try fm.createDirectory(at: objectsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let info = root.appending(path: "repo.json")
        if !fm.fileExists(atPath: info.path) {
            let json = #"{"format":1,"id":"\#(UUID().uuidString)","created":\#(Date().timeIntervalSince1970)}"#
            try atomicWrite(Data(json.utf8), to: info, sync: .file)
        }
    }

    public static func computers(in destination: URL) -> [String] {
        let base = destination.appending(path: "BackupMe", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: base.appending(path: "\($0)/repo.json").path) }.sorted()
    }

    // MARK: objects

    private func objectURL(_ hash: String) -> URL {
        objectsDir.appending(path: String(hash.prefix(2)), directoryHint: .isDirectory).appending(path: "\(hash).lzfse")
    }

    public func allObjectHashes() throws -> Set<String> {
        var result = Set<String>()
        for dir in try fm.contentsOfDirectory(atPath: objectsDir.path) {
            let files = (try? fm.contentsOfDirectory(atPath: objectsDir.appending(path: dir).path)) ?? []
            for f in files where f.hasSuffix(".lzfse") { result.insert(String(f.dropLast(6))) }
        }
        return result
    }

    public func hasObject(_ hash: String) -> Bool {
        if knownObjects == nil { knownObjects = (try? allObjectHashes()) ?? [] }
        return knownObjects!.contains(hash)
    }

    /// Returns the bytes written to the archive.
    public func putObject(_ data: Data, hash: String) throws -> Int64 {
        let compressed = data.isEmpty ? Data() : try (data as NSData).compressed(using: .lzfse) as Data
        let url = objectURL(hash)
        let fanout = url.deletingLastPathComponent()
        // no intermediate folders: if the destination vanished mid-run this fails instead of recreating it locally
        if !fm.fileExists(atPath: fanout.path) { try fm.createDirectory(at: fanout, withIntermediateDirectories: false) }
        try atomicWrite(compressed, to: url, sync: .file)
        knownObjects?.insert(hash)
        return Int64(compressed.count)
    }

    public func readObject(_ hash: String) throws -> Data {
        let raw = try Data(contentsOf: objectURL(hash))
        let data = raw.isEmpty ? Data() : (try? (raw as NSData).decompressed(using: .lzfse)) as Data?
        guard let data, sha256Hex(data) == hash else {
            // drop it so the next backup stores the file again instead of trusting a broken copy
            try? deleteObject(hash)
            throw RepositoryError.corruptObject(hash)
        }
        return data
    }

    public func deleteObject(_ hash: String) throws {
        try fm.removeItem(at: objectURL(hash))
        knownObjects?.remove(hash)
    }

    public func removeTemporaryFiles() throws {
        for dir in [snapshotsDir, objectsDir] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "tmp" { try fm.removeItem(at: url) }
        }
    }

    public func poolSize() throws -> Int64 {
        var total: Int64 = 0
        for dir in [objectsDir, snapshotsDir] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    // MARK: snapshots

    private func snapshotURL(_ id: String) -> URL { snapshotsDir.appending(path: "\(id).json.lzfse") }

    public func snapshotIDs() throws -> [String] {
        try fm.contentsOfDirectory(atPath: snapshotsDir.path)
            .filter { $0.hasSuffix(".json.lzfse") }
            .map { String($0.dropLast(11)) }
            .sorted()
    }

    public func writeSnapshot(_ s: Snapshot) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = .sortedKeys
        let json = try enc.encode(s)
        // full flush: the manifest makes the backup exist, so everything before it must be on disk
        try atomicWrite(try (json as NSData).compressed(using: .lzfse) as Data, to: snapshotURL(s.id), sync: .device)
    }

    public func readSnapshot(_ id: String) throws -> Snapshot {
        let raw = try Data(contentsOf: snapshotURL(id))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(Snapshot.self, from: try (raw as NSData).decompressed(using: .lzfse) as Data)
    }

    public func deleteSnapshot(_ id: String) throws { try fm.removeItem(at: snapshotURL(id)) }

    // MARK: lock

    private struct LockInfo: Codable { var pid: Int32; var host: String; var boot: Int? }

    static var bootTime: Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Int(tv.tv_sec)
    }

    /// True if `pid` is alive and runs the same executable as this process.
    private static func isLiveSibling(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return (String(cString: buf) as NSString).lastPathComponent == ProcessInfo.processInfo.processName
    }

    @discardableResult
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try acquireLock(retry: true)
        defer { try? fm.removeItem(at: lockURL) }
        return try body()
    }

    private func acquireLock(retry: Bool) throws {
        let fd = open(lockURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 {
            let data = try JSONEncoder().encode(LockInfo(pid: getpid(), host: computer, boot: Self.bootTime))
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            return
        }
        let held = (try? Data(contentsOf: lockURL)).flatMap { try? JSONDecoder().decode(LockInfo.self, from: $0) }
        let stale: Bool
        if let held {
            // after a reboot pids are reused, so a lock from an earlier boot is always stale
            stale = held.boot != Self.bootTime || !Self.isLiveSibling(held.pid)
        } else {
            // unreadable lock: a crash between create and write; a live writer finishes within milliseconds
            let mtime = (try? fm.attributesOfItem(atPath: lockURL.path)[.modificationDate] as? Date) ?? Date()
            stale = Date().timeIntervalSince(mtime) > 60
        }
        guard stale, retry else { throw RepositoryError.locked(pid: held?.pid ?? 0, host: held?.host ?? "?") }
        try? fm.removeItem(at: lockURL)
        try acquireLock(retry: false)
    }

    // MARK: helpers

    enum Sync { case file, device }

    /// Write to <name>.tmp, flush, then rename, so a crash never leaves a half-written file under its final name.
    /// `.device` uses F_FULLFSYNC, which also flushes the drive cache holding earlier writes.
    private func atomicWrite(_ data: Data, to url: URL, sync: Sync) throws {
        let tmp = url.appendingPathExtension("tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { failure = errno; return }
                offset += n
            }
        }
        // some filesystems (exFAT, network) reject F_FULLFSYNC: fall back to fsync
        if failure == 0, !(sync == .device && fcntl(fd, F_FULLFSYNC) == 0), fsync(fd) != 0 { failure = errno }
        close(fd)
        guard failure == 0, rename(tmp.path, url.path) == 0 else {
            let code = failure != 0 ? failure : errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
