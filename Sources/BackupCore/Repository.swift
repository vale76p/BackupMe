import Darwin
import CryptoKit
import Foundation

public enum RepositoryError: Error, Equatable {
    case destinationMissing(String)
    case locked(pid: Int32, host: String)
    case corruptObject(String)
    /// The archive was written by a newer BackupMe, in a format this version doesn't know.
    case newerFormat(Int)
    /// A manifest whose checksum or hashes don't match: that backup can't be trusted, so it isn't read.
    case damagedSnapshot(String)
}

/// Archive layout: <destination>/BackupMe/<archive name>/{repo.json, objects/, snapshots/, lock}
/// Objects are stored as `<hash>.lzfse` (compressed) or `<hash>.raw` (incompressible or large files).
public final class Repository {
    /// The archive layout this version reads and writes (repo.json "format").
    public static let format = 1
    public let root: URL
    private let fm = FileManager.default
    private var knownObjects: Set<String>?
    private let computer: String
    private var destinationFD: Int32 = -1

    deinit { if destinationFD >= 0 { close(destinationFD) } }

    private var objectsDir: URL { root.appending(path: "objects", directoryHint: .isDirectory) }
    private var snapshotsDir: URL { root.appending(path: "snapshots", directoryHint: .isDirectory) }

    /// `create: false` opens an existing archive only (browsing must never write to the destination).
    /// repo.json was there but unreadable and has been written again (same layout, a new id).
    public private(set) var repairedInfo = false

    public init(destination: URL, computerName: String, create: Bool = true) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            throw RepositoryError.destinationMissing(destination.path)
        }
        let safeName = computerName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try Self.checkComponent(safeName)
        computer = safeName
        root = destination.appending(path: "BackupMe", directoryHint: .isDirectory)
            .appending(path: safeName, directoryHint: .isDirectory)
        // The user-selected destination may itself be an alias; archive components below it may not.
        destinationFD = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard destinationFD >= 0 else { throw Self.posixError() }
        let info = root.appending(path: "repo.json")
        if create, let found = newerFormat { throw RepositoryError.newerFormat(found) }
        guard create else {
            guard fm.fileExists(atPath: info.path) else { throw RepositoryError.destinationMissing(root.path) }
            return
        }
        let archive = try archiveDirectory(create: true)
        defer { close(archive) }
        for name in ["objects", "snapshots"] {
            let fd = try Self.childDirectory(name, in: archive, create: true)
            close(fd)
        }
        // read but not JSON with an id: damaged, written again. Not when the read fails (an offline cloud file):
        // that one is probably fine
        let damaged = (try? Data(contentsOf: info)).map { Self.id(in: $0) == nil } ?? false
        if damaged || !fm.fileExists(atPath: info.path) {
            repairedInfo = damaged
            let json = #"{"format":\#(Self.format),"id":"\#(UUID().uuidString)","created":\#(Date().timeIntervalSince1970)}"#
            try atomicWrite(Data(json.utf8), to: info, sync: .file)
        }
        // the BackupMe folder opened again without following links: a link swapped in since is never written through
        if let base = try? Self.childDirectory("BackupMe", in: destinationFD) { RestoreKit.install(in: base); close(base) }
    }

    /// The archive's identity, from repo.json: a different one means the archive was made again from nothing.
    public var archiveID: String? {
        (try? Data(contentsOf: root.appending(path: "repo.json"))).flatMap(Self.id(in:))
    }

    /// repo.json's format when it is newer than this version's. Browsing such an archive is allowed; writing to it
    /// or cleaning it up could damage what this version doesn't understand.
    private var newerFormat: Int? {
        guard let data = try? Data(contentsOf: root.appending(path: "repo.json")),
              let found = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? Int,
              found > Self.format else { return nil }
        return found
    }

    private static func id(in data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String
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

    public enum RestoreKitUpdate: Equatable, Sendable {
        case installed(from: Int?, to: Int), current(Int), newerKept(Int), noArchive
    }

    /// Brings the restore kit beside the archives up to date now, instead of at the next backup. Never creates
    /// the BackupMe folder, and never replaces a newer kit written by another Mac.
    public static func updateRestoreKit(destination: URL) -> RestoreKitUpdate {
        let dest = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dest >= 0 else { return .noArchive }
        defer { close(dest) }
        // a BackupMe that is a link is not followed out of the destination, as when backing up
        guard let base = try? childDirectory("BackupMe", in: dest) else { return .noArchive }
        defer { close(base) }
        let script = "RIPRISTINO.command"
        let old = RestoreKit.read(script, in: base).flatMap { String(data: $0, encoding: .utf8) }.flatMap(RestoreKit.installedVersion)
        if let old, old > RestoreKit.version { return .newerKept(old) }
        let before = RestoreKit.read(script, in: base)
        RestoreKit.install(in: base)
        return RestoreKit.read(script, in: base) == before ? .current(RestoreKit.version) : .installed(from: old, to: RestoreKit.version)
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
        // a hash from a tampered manifest ("../../x") must never become a path outside objects/
        guard Self.isHash(hash) else { return nil }
        return Self.extensions.map { objectURL(hash, $0) }.first { fm.fileExists(atPath: $0.path) }
    }

    /// A SHA-256 as the archive names objects: 64 lowercase hex digits.
    public static func isHash(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// Every stored object with its size on disk, from one listing of the archive.
    /// `sampleDirs`: only that many of the 256 fan-out folders, picked at random (a sample, without listing the
    /// whole archive).
    public func objectSizes(sampleDirs: Int? = nil) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        var dirs = try fm.contentsOfDirectory(atPath: objectsDir.path)
        if let n = sampleDirs { dirs = Array(dirs.shuffled().prefix(n)) }
        for dir in dirs {
            let d = objectsDir.appending(path: dir)
            for f in objectNames(in: dir) {
                let size = (try? fm.attributesOfItem(atPath: d.appending(path: f).path)[.size] as? Int64) ?? 0
                result[(f as NSString).deletingPathExtension] = size
            }
        }
        return result
    }

    public func allObjectHashes() throws -> Set<String> {
        var result = Set<String>()
        for dir in try fm.contentsOfDirectory(atPath: objectsDir.path) {
            for f in objectNames(in: dir) { result.insert((f as NSString).deletingPathExtension) }
        }
        return result
    }

    /// The objects in one fan-out folder: only `<hash>.<ext>` under its own prefix, never through a link. A link
    /// planted in objects/ would otherwise list files outside the archive as unreferenced objects, for cleanup.
    private func objectNames(in dir: String) -> [String] {
        let d = objectsDir.appending(path: dir)
        guard (try? fm.attributesOfItem(atPath: d.path)[.type] as? FileAttributeType) == .typeDirectory else { return [] }
        return ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter {
            let hash = ($0 as NSString).deletingPathExtension
            return Self.extensions.contains(($0 as NSString).pathExtension) && Self.isHash(hash) && hash.hasPrefix(dir)
        }
    }

    public func hasObject(_ hash: String) -> Bool {
        if knownObjects == nil { knownObjects = (try? allObjectHashes()) ?? [] }
        return knownObjects!.contains(hash)
    }

    private func prepareFanout(_ url: URL) throws {
        let archive = try archiveDirectory()
        defer { close(archive) }
        let objects = try Self.childDirectory("objects", in: archive)
        defer { close(objects) }
        let fanout = try Self.childDirectory(url.deletingLastPathComponent().lastPathComponent, in: objects, create: true)
        close(fanout)
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
    /// The copy is verified before it gets its final name; nil means it didn't match `hash` (the file changed
    /// after hashing) and nothing was stored. An existing object is never touched, so older backups stay safe.
    public func putObjectFile(from source: URL, hash: String) throws -> Int64? {
        let url = objectURL(hash, "raw")
        try prepareFanout(url)
        let sourceFD = open(source.path, O_RDONLY | O_CLOEXEC)
        guard sourceFD >= 0 else { throw Self.posixError() }
        defer { close(sourceFD) }
        var info = stat()
        guard fstat(sourceFD, &info) == 0 else { throw Self.posixError() }
        var size: Int64 = 0
        let stored = try publish(to: url, sync: .file, mode: info.st_mode & 0o777, cloning: sourceFD) { fd, cloned in
            // in chunks that each beat: a single copy call to a slow disk looked stuck. Data only: the flags of a file
            // locked in the Finder (uchg) would lock the temporary file
            if !cloned {
                var buffer = [UInt8](repeating: 0, count: 4 << 20)
                while true {
                    let n = read(sourceFD, &buffer, buffer.count)
                    if n < 0, errno == EINTR { continue }
                    guard n >= 0 else { throw Self.posixError() }
                    if n == 0 { break }
                    var offset = 0
                    while offset < n {
                        let w = buffer[offset ..< n].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                        if w < 0, errno == EINTR { continue }
                        guard w > 0 else { throw w == 0 ? POSIXError(.EIO) : Self.posixError() }
                        offset += w
                    }
                    Activity.beat()
                }
            }
            guard lseek(fd, 0, SEEK_SET) >= 0 else { throw Self.posixError() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard try streamHash(handle) == hash else { return false }
            guard fstat(fd, &info) == 0 else { throw Self.posixError() }
            size = Int64(info.st_size)
            return true
        }
        guard stored else { return nil }
        knownObjects?.insert(hash)
        return size
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

    /// True if the object's content matches its hash; large raw objects are hashed as a stream.
    func verifyObject(_ hash: String) throws -> Bool {
        guard let url = existingObjectURL(hash) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: hash]) }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if url.pathExtension == "raw", size >= Self.streamThreshold { return try streamHash(url) == hash }
        do { _ = try readObject(hash) } catch RepositoryError.corruptObject { return false }
        return true
    }

    /// Rewrites a corrupt object from a file with the same content, under the same name so it replaces the bad
    /// copy atomically. Nothing changes unless `source` hashes to `hash`. True if the object now verifies.
    func repairObject(_ hash: String, from source: URL) throws -> Bool {
        guard let url = existingObjectURL(hash) else { return false }
        if url.pathExtension == "raw" {
            guard try putObjectFile(from: source, hash: hash) != nil else { return false }
        } else {
            let data = try Data(contentsOf: source)
            guard sha256Hex(data) == hash else { return false }
            try atomicWrite(try (data as NSData).compressed(using: .lzfse) as Data, to: url, sync: .file)
        }
        return try verifyObject(hash)
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
        knownObjects?.remove(hash)
        // by descriptor, opened without following links: a fan-out folder swapped for a link deletes nothing outside
        guard Self.isHash(hash), let fanout = try? parentDirectory(of: objectURL(hash, "raw")) else { return }
        defer { close(fanout) }
        for ext in Self.extensions { unlinkat(fanout, "\(hash).\(ext)", 0) }
    }

    public func removeTemporaryFiles() throws {
        for dir in [snapshotsDir, objectsDir] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "tmp" {
                // a locked leftover (cloned from a file locked in the Finder) would fail every cleanup
                lchflags(url.path, 0)
                try fm.removeItem(at: url)
            }
        }
    }

    /// Free space on the destination's volume, nil when the volume doesn't say.
    public func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // exFAT, FAT32 and APFS mounted outside /Volumes say 0 for important usage: a big file would never fit
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// The largest file the destination's filesystem can hold: 4 GiB - 1 on FAT32.
    public private(set) lazy var maxFileSize: Int64 = {
        // bits of the size as a signed number: 33 on FAT32, 64 on exFAT
        let bits = pathconf(root.path, _PC_FILESIZEBITS)
        return bits > 1 && bits < 64 ? (Int64(1) << (bits - 1)) - 1 : .max
    }()

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
        // a checksum as the first key: one byte flipped in the compressed file can still decode, into other hashes
        // and names. Readers that don't know it (RIPRISTINO.command, older versions) skip an unknown key
        let body = json.dropFirst() // without "{"
        let sealed = Data(Self.checkPrefix.utf8) + Data(sha256Hex(Data(body)).utf8) + Data("\",".utf8) + body
        // full flush: the manifest makes the backup exist, so everything before it must be on disk
        try atomicWrite(try (sealed as NSData).compressed(using: .lzfse) as Data, to: snapshotURL(s.id), sync: .device, exclusive: true)
    }

    private static let checkPrefix = #"{"check":""#

    public func readSnapshot(_ id: String) throws -> Snapshot {
        let json = try sealedJSON(id)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let s = try dec.decode(Snapshot.self, from: json)
        // manifests from before the checksum: a hash that isn't one is the trace of a damaged file
        guard json.starts(with: Data(Self.checkPrefix.utf8)) || s.entries.allSatisfy({ $0.hash.map(Self.isHash) ?? true }) else {
            throw RepositoryError.damagedSnapshot(id)
        }
        return s
    }

    /// Whether a manifest can be read: its checksum, without decoding it, when it has one.
    public func snapshotIsIntact(_ id: String) -> Bool {
        autoreleasepool {
            guard let json = try? sealedJSON(id) else { return false }
            return json.starts(with: Data(Self.checkPrefix.utf8)) || (try? readSnapshot(id)) != nil
        }
    }

    /// The manifest's JSON, its checksum verified when it has one.
    private func sealedJSON(_ id: String) throws -> Data {
        let raw = try Data(contentsOf: snapshotURL(id))
        guard let json = try? (raw as NSData).decompressed(using: .lzfse) as Data else { throw RepositoryError.damagedSnapshot(id) }
        let prefix = Data(Self.checkPrefix.utf8)
        guard json.starts(with: prefix) else { return json }
        let start = json.startIndex + prefix.count
        guard json.count > prefix.count + 66, json[start + 64] == UInt8(ascii: "\""), json[start + 65] == UInt8(ascii: ","),
              String(decoding: json[start ..< start + 64], as: UTF8.self) == sha256Hex(Data(json[(start + 66)...])) else {
            throw RepositoryError.damagedSnapshot(id)
        }
        return json
    }

    public func deleteSnapshot(_ id: String) throws { try fm.removeItem(at: snapshotURL(id)) }

    // MARK: lock

    /// Exclusive lock with flock(2): the kernel releases it when the process dies, so there are no stale locks.
    /// Each Mac writes only its own archive folder, so a machine-local lock is enough.
    @discardableResult
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        // every write goes through here, also from an archive opened with `create: false` ("Controlla ora", "Elimina…")
        if let found = newerFormat { throw RepositoryError.newerFormat(found) }
        let archive = try archiveDirectory()
        defer { close(archive) }
        // close-on-exec: a process started meanwhile would otherwise inherit the descriptor and hold the lock.
        // No-follow: a link planted as the lock never creates a file outside the archive
        let fd = openat(archive, "lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) } // closing releases the lock; the file is kept so waiters never lock a deleted inode
        // only a plain file: a pipe or a device put in its place is refused
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        // a moment's wait: a process being spawned holds a copy of the descriptor until it execs
        var attempt = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            // shortcut: filesystems without flock (some exFAT/SMB) run unlocked; acceptable for a single-user app
            if errno == ENOTSUP || errno == EOPNOTSUPP { break }
            guard errno == EWOULDBLOCK, attempt < 100 else { throw RepositoryError.locked(pid: 0, host: computer) }
            attempt += 1
            usleep(10_000)
        }
        return try body()
    }

    // MARK: helpers

    enum Sync { case file, device }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func checkComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
    }

    static func childDirectory(_ name: String, in parent: Int32, create: Bool = false) throws -> Int32 {
        try checkComponent(name)
        if create, mkdirat(parent, name, 0o755) != 0, errno != EEXIST { throw posixError() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        return fd
    }

    private func archiveDirectory(create: Bool = false) throws -> Int32 {
        guard destinationFD >= 0 else { throw POSIXError(.EBADF) }
        let base = try Self.childDirectory("BackupMe", in: destinationFD, create: create)
        defer { close(base) }
        return try Self.childDirectory(computer, in: base, create: create)
    }

    private func parentDirectory(of url: URL) throws -> Int32 {
        let prefix = root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw POSIXError(.EINVAL) }
        let parts = String(url.path.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts { try Self.checkComponent(part) }
        var fd = try archiveDirectory()
        do {
            for part in parts.dropLast() {
                let next = try Self.childDirectory(part, in: fd)
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    /// Own a fresh inode beneath no-follow directory descriptors through flush and atomic publication.
    /// `.device` flushes the drive cache; `exclusive` preserves immutable manifests.
    /// `cloning`: the temporary file starts as an APFS clone of that descriptor's file when the volume allows it;
    /// `body` is told whether it did, and must fill the file itself when it didn't.
    @discardableResult
    private func publish(to url: URL, sync: Sync, exclusive: Bool = false, mode: mode_t = 0o644, cloning source: Int32? = nil,
                         body: (_ fd: Int32, _ cloned: Bool) throws -> Bool) throws -> Bool {
        let parent = try parentDirectory(of: url)
        defer { close(parent) }
        return try Self.publish(url.lastPathComponent, in: parent, sync: sync, exclusive: exclusive, mode: mode,
                                cloning: source, body: body)
    }

    /// `publish(to:)` for a file directly in `parent`, a folder already opened without following links.
    @discardableResult
    static func publish(_ name: String, in parent: Int32, sync: Sync, exclusive: Bool = false, mode: mode_t = 0o644,
                        cloning source: Int32? = nil, body: (_ fd: Int32, _ cloned: Bool) throws -> Bool) throws -> Bool {
        try checkComponent(name)
        let tmp = name + ".tmp"
        // a leftover of an interrupted run (its space comes back now) or a planted link: removed, never followed
        guard removeLeftover(tmp, in: parent) == 0 || errno == ENOENT else { throw Self.posixError() }
        // other volumes, or a clone that fails, get a plain copy
        let cloned = source.map { fclonefileat($0, parent, tmp, 0) == 0 } ?? false
        // a clone keeps its source's mode (git packs are read-only) and is only read back: never opened for writing
        let fd = cloned
            ? openat(parent, tmp, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            : openat(parent, tmp, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            let error = Self.posixError()
            if cloned { unlinkat(parent, tmp, 0) }
            throw error
        }
        var published = false
        defer { close(fd); if !published { unlinkat(parent, tmp, 0) } }
        // a clone is reopened by name: something swapped in meanwhile (a hard link to another file) is refused
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Self.posixError() }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { throw POSIXError(.EPERM) }
        // a clone keeps its source's flags: a file locked in the Finder (uchg) makes it unchangeable and unremovable
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        guard st.st_flags & locks == 0 || fchflags(fd, st.st_flags & ~locks) == 0 else { throw Self.posixError() }
        guard fchmod(fd, 0o600) == 0 else { throw Self.posixError() }
        guard try body(fd, cloned) else { return false }
        // Preserve published-file readability for portable/shared archives.
        guard fchmod(fd, mode) == 0 else { throw Self.posixError() }
        // Some filesystems reject F_FULLFSYNC: fall back to fsync.
        if !(sync == .device && fcntl(fd, F_FULLFSYNC) == 0), fsync(fd) != 0 { throw Self.posixError() }
        let moved = exclusive
            ? Self.renameExclusive(tmp, name, in: parent)
            : renameat(parent, tmp, parent, name)
        guard moved == 0 else { throw Self.posixError() }
        published = true
        return true
    }

    /// unlinkat that also removes a leftover locked by a clone of a locked file (before 0.9.5): unlocked first.
    private static func removeLeftover(_ name: String, in dir: Int32) -> Int32 {
        if unlinkat(dir, name, 0) == 0 { return 0 }
        guard errno == EPERM else { return -1 }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { errno = EPERM; return -1 }
        fchflags(fd, 0)
        close(fd)
        return unlinkat(dir, name, 0)
    }

    private func atomicWrite(_ data: Data, to url: URL, sync: Sync, exclusive: Bool = false) throws {
        let parent = try parentDirectory(of: url)
        defer { close(parent) }
        try Self.atomicWrite(data, named: url.lastPathComponent, in: parent, sync: sync, exclusive: exclusive)
    }

    static func atomicWrite(_ data: Data, named name: String, in parent: Int32, sync: Sync, exclusive: Bool = false,
                            mode: mode_t = 0o644) throws {
        try publish(name, in: parent, sync: sync, exclusive: exclusive, mode: mode) { fd, _ in
            try data.withUnsafeBytes { buf in
                var offset = 0
                while offset < buf.count {
                    // write(2) rejects counts above INT_MAX with EINVAL: write in 1 GB chunks
                    let n = write(fd, buf.baseAddress! + offset, min(buf.count - offset, 1 << 30))
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw n == 0 ? POSIXError(.EIO) : Self.posixError() }
                    offset += n
                }
            }
            return true
        }
    }

    /// rename(2) that fails with EEXIST instead of replacing `to`. exFAT and FAT32 reject RENAME_EXCL and link(2) with ENOTSUP.
    /// Both names are in `dir`, a folder opened without following links.
    private static func renameExclusive(_ from: String, _ to: String, in dir: Int32) -> Int32 {
        if renameatx_np(dir, from, dir, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
        guard errno == ENOTSUP || errno == EOPNOTSUPP else { return -1 }
        // a hard link is just as exclusive: it fails with EEXIST
        if linkat(dir, from, dir, to, 0) == 0 { unlinkat(dir, from, 0); return 0 }
        guard errno == ENOTSUP || errno == EOPNOTSUPP else { return -1 }
        // shortcut: between the check and the rename a manifest created by another writer would be replaced; ids are
        // per-second timestamps and these filesystems have no flock anyway, upgrade if two writers can share an archive
        var st = stat()
        if fstatat(dir, to, &st, AT_SYMLINK_NOFOLLOW) == 0 { errno = EEXIST; return -1 }
        guard errno == ENOENT else { return -1 }
        return renameat(dir, from, dir, to)
    }
}

/// SHA-256 of a file read in 4 MB chunks, so large files never sit in memory.
func streamHash(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    return try streamHash(h)
}

private func streamHash(_ h: FileHandle) throws -> String {
    var hasher = SHA256()
    // a pool per chunk: without it every 4 MB read stays alive until the whole backup ends (a 2 GB file = 2 GB)
    var done = false
    while !done {
        try autoreleasepool {
            if let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk); Activity.beat() } else { done = true }
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
