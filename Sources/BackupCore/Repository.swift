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

    private var objectsDir: URL { root.appending(path: "objects", directoryHint: .isDirectory) }
    private var snapshotsDir: URL { root.appending(path: "snapshots", directoryHint: .isDirectory) }
    private var lockURL: URL { root.appending(path: "lock") }

    public init(destination: URL, computerName: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw RepositoryError.destinationMissing(destination.path)
        }
        let safeName = computerName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        root = destination.appending(path: "BackupMe", directoryHint: .isDirectory)
            .appending(path: safeName, directoryHint: .isDirectory)
        try fm.createDirectory(at: objectsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let info = root.appending(path: "repo.json")
        if !fm.fileExists(atPath: info.path) {
            let json = #"{"format":1,"id":"\#(UUID().uuidString)","created":\#(Date().timeIntervalSince1970)}"#
            try atomicWrite(Data(json.utf8), to: info)
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
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(compressed, to: url)
        knownObjects?.insert(hash)
        return Int64(compressed.count)
    }

    public func readObject(_ hash: String) throws -> Data {
        let raw = try Data(contentsOf: objectURL(hash))
        let data = raw.isEmpty ? Data() : try (raw as NSData).decompressed(using: .lzfse) as Data
        guard sha256Hex(data) == hash else { throw RepositoryError.corruptObject(hash) }
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
        try atomicWrite(try (json as NSData).compressed(using: .lzfse) as Data, to: snapshotURL(s.id))
    }

    public func readSnapshot(_ id: String) throws -> Snapshot {
        let raw = try Data(contentsOf: snapshotURL(id))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try dec.decode(Snapshot.self, from: try (raw as NSData).decompressed(using: .lzfse) as Data)
    }

    public func deleteSnapshot(_ id: String) throws { try fm.removeItem(at: snapshotURL(id)) }

    // MARK: lock

    private struct LockInfo: Codable { var pid: Int32; var host: String }

    static var hostName: String {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count)
        return String(cString: buf)
    }

    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try acquireLock(retry: true)
        defer { try? fm.removeItem(at: lockURL) }
        return try body()
    }

    private func acquireLock(retry: Bool) throws {
        let fd = open(lockURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd >= 0 {
            let data = try JSONEncoder().encode(LockInfo(pid: getpid(), host: Self.hostName))
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            return
        }
        let held = (try? JSONDecoder().decode(LockInfo.self, from: Data(contentsOf: lockURL)))
            ?? LockInfo(pid: 0, host: "?")
        let stale = held.host == Self.hostName && kill(held.pid, 0) != 0 && errno == ESRCH
        guard stale, retry else { throw RepositoryError.locked(pid: held.pid, host: held.host) }
        try? fm.removeItem(at: lockURL)
        try acquireLock(retry: false)
    }

    // MARK: helpers

    /// Write to <name>.tmp then rename, so a crash never leaves a half-written file under its final name.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
