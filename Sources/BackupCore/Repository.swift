import Darwin
import Compression
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
    /// The archive belongs to another account of this Mac (repo.json "owner"): see `claim(owner:)`.
    case otherOwner
    /// A container or its index that doesn't parse or doesn't match its checksum: what it holds can't be trusted.
    case damagedPack(String)
}

/// Archive layout: <destination>/BackupMe/<archive name>/{repo.json, objects/, snapshots/, lock}
/// Objects are stored as `<hash>.lzfse` (compressed) or `<hash>.raw` (incompressible or large files).
public final class Repository {
    /// The highest archive layout this version reads and writes (repo.json "format"): 2 has containers.
    public static let format = 2
    /// Stored forms below this go into containers (`packBelow` of the app); a container is published at about this size.
    public static let packThreshold = 4 << 20, packTarget = 32 << 20
    public let root: URL
    let fm = FileManager.default
    var knownObjects: Set<String>?
    private let computer: String
    /// Objects whose stored form is smaller than this go into a container; 0 never puts anything in one.
    let packBelow: Int
    /// Hashes `hasObject` answers false for: scheduled for deletion, never reused by a new backup.
    public var condemned: Set<String> = []
    /// The container being filled, in memory until `flushPack`.
    var openPack = Data()
    var openEntries: [PackEntry] = []
    /// Every published container's entries by hash, the greatest id winning; nil until first needed.
    var packed: [String: (pack: String, entry: PackEntry)]?
    /// Indexes rebuilt from their container, used instead of the file (written back only while holding the lock).
    var rebuiltIndexes: [String: [PackEntry]] = [:]
    /// Inside `withLock`'s body: the only time a rebuilt index may be written to the destination.
    private(set) var holdsLock = false
    private var destinationFD: Int32 = -1

    deinit { if destinationFD >= 0 { close(destinationFD) } }

    private var objectsDir: URL { root.appending(path: "objects", directoryHint: .isDirectory) }
    private var snapshotsDir: URL { root.appending(path: "snapshots", directoryHint: .isDirectory) }

    /// `create: false` opens an existing archive only (browsing must never write to the destination).
    /// repo.json was there but unreadable and has been written again (same layout, a new id).
    public private(set) var repairedInfo = false
    /// The restore kit files this opening rewrote (missing, older, modified or damaged), in words.
    public private(set) var restoreKitChanges: [String] = []

    public init(destination: URL, computerName: String, create: Bool = true, packBelow: Int = 0) throws {
        self.packBelow = packBelow
        guard Self.isAvailable(destination: destination) else { throw RepositoryError.destinationMissing(destination.path) }
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
            // 1 until the first container (`flushPack`): without one, older versions still read the whole archive. 2 when
            // packs/ holds one: a damaged repo.json written again must not hide its containers from an older kit
            let format = (try? packIDs().isEmpty) == false ? Self.format : 1
            let json = #"{"format":\#(format),"id":"\#(UUID().uuidString)","created":\#(Date().timeIntervalSince1970)}"#
            try atomicWrite(Data(json.utf8), to: info, sync: .file)
        }
        // the BackupMe folder opened again without following links: a link swapped in since is never written through
        if let base = try? Self.childDirectory("BackupMe", in: destinationFD) { restoreKitChanges = RestoreKit.install(in: base); close(base) }
    }

    /// The destination folder is there: false for a disk not plugged in (its folder under /Volumes is gone), so
    /// "no backups" is never shown, or remembered, for an archive that is only out of reach.
    public static func isAvailable(destination: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir) && isDir.boolValue
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
        return RestoreKit.install(in: base).isEmpty ? .current(RestoreKit.version) : .installed(from: old, to: RestoreKit.version)
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

    /// Every stored object with its size: a file's size on disk, an object in a container its stored length (the
    /// file when it has both forms). `sampleDirs`: only that many of the 256 fan-out folders, picked at random, and
    /// one container (a sample, without listing the whole archive).
    public func objectSizes(sampleDirs: Int? = nil) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        if sampleDirs == nil {
            for (hash, copy) in try packIndex() { result[hash] = Int64(copy.entry.length) }
        } else if let id = try packIDs().randomElement() {
            // a damaged container hides its objects, as in the full listing
            for e in try readableEntries(id) { result[e.hash] = Int64(e.length) }
        }
        result.merge(try looseObjectSizes(sampleDirs: sampleDirs)) { $1 }
        return result
    }

    /// Single-file objects only, with their size on disk, from one listing of objects/.
    public func looseObjectSizes(sampleDirs: Int? = nil) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        var dirs = try fm.contentsOfDirectory(atPath: objectsDir.path)
        if let n = sampleDirs { dirs = Array(dirs.shuffled().prefix(n)) }
        for dir in dirs {
            for (hash, size) in objects(in: dir, sizes: true) { result[hash] = size }
        }
        return result
    }

    public func allObjectHashes() throws -> Set<String> {
        var result = Set(try packIndex().keys)
        for dir in try fm.contentsOfDirectory(atPath: objectsDir.path) {
            for (hash, _) in objects(in: dir) { result.insert(hash) }
        }
        return result
    }

    /// The objects in one fan-out folder: only `<hash>.<ext>` under its own prefix, never through a link. A link
    /// planted in objects/ would otherwise list files outside the archive as unreferenced objects, for cleanup.
    /// `sizes`: read in the same listing (getattrlistbulk), 8 times faster than a stat per object.
    private func objects(in dir: String, sizes: Bool = false) -> [(hash: String, size: Int64)] {
        let d = objectsDir.appending(path: dir)
        guard (try? fm.attributesOfItem(atPath: d.path)[.type] as? FileAttributeType) == .typeDirectory else { return [] }
        func hash(_ name: String) -> String? {
            let hash = (name as NSString).deletingPathExtension
            return Self.extensions.contains((name as NSString).pathExtension) && Self.isHash(hash) && hash.hasPrefix(dir) ? hash : nil
        }
        // a pool per folder: the listing's URLs and names are otherwise kept until the whole backup or cleanup ends
        return autoreleasepool {
            guard sizes else { return ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).compactMap { hash($0).map { ($0, 0) } } }
            return ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? []).compactMap { url in
                hash(url.lastPathComponent).map { ($0, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
            }
        }
    }

    public func hasObject(_ hash: String) -> Bool {
        if condemned.contains(hash) { return false }
        // shortcut: the first call lists the whole archive (a set of every hash, ~100 MB with a million objects);
        // check the object's file instead if that listing is too slow on a network destination
        if knownObjects == nil { knownObjects = ((try? allObjectHashes()) ?? []).union(openEntries.map(\.hash)) }
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

    /// The form an object is stored in: kept raw when compression saves less than 5%.
    static func storedForm(_ data: Data) -> (body: Data, compressed: Bool) {
        let compressed = data.isEmpty ? nil : try? (data as NSData).compressed(using: .lzfse) as Data
        let useCompressed = compressed.map { $0.count < data.count * 95 / 100 } ?? false
        return (useCompressed ? compressed! : data, useCompressed)
    }

    /// Stores in-memory content, in the open container when its stored form is below `packBelow`. Returns the bytes written.
    public func putObject(_ data: Data, hash: String) throws -> Int64 {
        let (body, useCompressed) = Self.storedForm(data)
        if body.count < packBelow {
            try addToOpenPack(body, hash: hash, compressed: useCompressed)
            return Int64(body.count)
        }
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

    /// The content of a stored form, nil when it doesn't decode to `hash`.
    static func decoded(_ raw: Data, compressed: Bool, hash: String) -> Data? {
        let data = !compressed || raw.isEmpty ? raw : (try? (raw as NSData).decompressed(using: .lzfse)) as Data?
        return data.flatMap { sha256Hex($0) == hash ? $0 : nil }
    }

    /// Reads and verifies an object: its file, else the copy in the container with the greatest id, else any other
    /// copy; the first that verifies. A mismatch throws but never deletes: the copy may still be syncing,
    /// and OneDrive version history can only help while the file is still there. A read that fails throws its error.
    public func readObject(_ hash: String) throws -> Data {
        var damaged = false
        if let url = existingObjectURL(hash) {
            if let data = Self.decoded(try Data(contentsOf: url), compressed: url.pathExtension == "lzfse", hash: hash) { return data }
            damaged = true
        }
        if let best = try packIndex()[hash] {
            if let data = try readPacked(hash, best.entry, in: best.pack) { return data }
            damaged = true
            for id in try packIDs().reversed() {
                for e in try readableEntries(id) where e.hash == hash && (id != best.pack || e.offset != best.entry.offset) {
                    if let data = try readPacked(hash, e, in: id) { return data }
                }
            }
        }
        guard damaged else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: hash]) }
        throw RepositoryError.corruptObject(hash)
    }

    /// True if the object's content matches its hash; large raw objects are hashed as a stream.
    func verifyObject(_ hash: String) throws -> Bool {
        if let url = existingObjectURL(hash), url.pathExtension == "raw",
           ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0) >= Self.streamThreshold {
            return try streamHash(url) == hash
        }
        do { _ = try readObject(hash) } catch RepositoryError.corruptObject { return false }
        return true
    }

    /// Whether the copy read first, by the restore kit as by `readObject`, verifies: the object's file when there is one,
    /// else the copy in the container that counts. A copy that can't be read throws.
    func firstCopyVerifies(_ hash: String) throws -> Bool {
        // no container copy: the file is the only form, large raw ones hashed as a stream
        guard let best = try packIndex()[hash] else { return try verifyObject(hash) }
        if let url = existingObjectURL(hash) {
            return Self.decoded(try Data(contentsOf: url), compressed: url.pathExtension == "lzfse", hash: hash) != nil
        }
        return try readPacked(hash, best.entry, in: best.pack) != nil
    }

    /// When the copy read first doesn't verify and another copy does, saves that content again as the object's file, which
    /// the app and the restore kit read first; a container is never touched. True if the file now verifies.
    func rewriteFromAnotherCopy(_ hash: String) throws -> Bool {
        // without a copy in a container the file was the only one
        guard packOf(hash) != nil else { return false }
        let data: Data
        do { data = try readObject(hash) } catch RepositoryError.corruptObject { return false }
        // in the damaged file's own form, which it replaces: a file of the other form would still be read after it
        let lzfse = existingObjectURL(hash).map { $0.pathExtension == "lzfse" } ?? Self.storedForm(data).compressed
        let url = objectURL(hash, lzfse ? "lzfse" : "raw")
        try prepareFanout(url)
        try atomicWrite(lzfse ? try (data as NSData).compressed(using: .lzfse) as Data : data, to: url, sync: .file)
        knownObjects?.insert(hash)
        return try firstCopyVerifies(hash)
    }

    /// Rewrites a corrupt object from a file with the same content, under the same name so it replaces the bad
    /// copy atomically; one only in containers becomes a file, the container untouched. Nothing changes unless
    /// `source` hashes to `hash`. True if the object now verifies.
    func repairObject(_ hash: String, from source: URL) throws -> Bool {
        let url = existingObjectURL(hash)
        guard url != nil || packOf(hash) != nil else { return false }
        if let url, url.pathExtension == "lzfse" {
            let data = try Data(contentsOf: source)
            guard sha256Hex(data) == hash else { return false }
            try atomicWrite(try (data as NSData).compressed(using: .lzfse) as Data, to: url, sync: .file)
        } else {
            guard try putObjectFile(from: source, hash: hash) != nil else { return false }
        }
        return try verifyObject(hash)
    }

    /// Writes an object's content to `destination` (which must not exist), verifying its hash.
    public func restoreObject(_ hash: String, to destination: URL) throws {
        if let url = existingObjectURL(hash), url.pathExtension == "raw" {
            let parent = try parentDirectory(of: url)
            defer { close(parent) }
            // never through a link planted as the object: it would come back as a link to a file outside the archive
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.posixError() }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw Self.posixError() }
            guard st.st_mode & S_IFMT == S_IFREG else { throw RepositoryError.corruptObject(hash) }
            if st.st_size >= Self.streamThreshold {
                // a clone on the same volume, elsewhere a copy of the data; never over an existing file
                if fclonefileat(fd, AT_FDCWD, destination.path, 0) != 0 {
                    guard errno == ENOTSUP || errno == EOPNOTSUPP || errno == EXDEV else { throw Self.posixError() }
                    let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard out >= 0 else { throw Self.posixError() }
                    defer { close(out) }
                    if fcopyfile(fd, out, nil, copyfile_flags_t(COPYFILE_DATA)) != 0 {
                        let error = Self.posixError()
                        try? fm.removeItem(at: destination)
                        throw error
                    }
                }
                guard (try? streamHash(destination)) == hash else {
                    try? fm.removeItem(at: destination)
                    throw RepositoryError.corruptObject(hash)
                }
                return
            }
        }
        try readObject(hash).write(to: destination, options: .withoutOverwriting)
    }

    /// Deletes the object's files (both forms when it has two), at most `limit` of them; a copy in a container stays.
    /// Returns the files removed, and whether one is still there: past `limit`, or one that couldn't be removed.
    @discardableResult
    public func deleteObject(_ hash: String, limit: Int = .max) throws -> (removed: Int, kept: Bool) {
        var removed = 0, kept = false
        defer { if !kept, packed?[hash] == nil { knownObjects?.remove(hash) } }
        // by descriptor, opened without following links: a fan-out folder swapped for a link deletes nothing outside
        guard Self.isHash(hash), let fanout = try? parentDirectory(of: objectURL(hash, "raw")) else { return (0, false) }
        defer { close(fanout) }
        for ext in Self.extensions {
            var st = stat()
            if removed < limit {
                if unlinkat(fanout, "\(hash).\(ext)", 0) == 0 { removed += 1 } else if errno != ENOENT { kept = true }
            } else if fstatat(fanout, "\(hash).\(ext)", &st, AT_SYMLINK_NOFOLLOW) == 0 { kept = true }
        }
        return (removed, kept)
    }

    /// Returns how many were removed.
    @discardableResult
    public func removeTemporaryFiles() throws -> Int {
        var removed = 0
        for dir in [snapshotsDir, objectsDir] {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "tmp" {
                // a locked leftover (cloned from a file locked in the Finder) would fail every cleanup. Flags belong to
                // the inode: a hard link planted to a user's locked file is never unlocked
                var st = stat()
                // only files and links: this archive never makes a folder named .tmp, and one is not removed with what it holds
                guard lstat(url.path, &st) == 0, [S_IFREG, S_IFLNK].contains(st.st_mode & S_IFMT) else { continue }
                if st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 { lchflags(url.path, 0) }
                try fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed + (try removePackLeftovers())
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
        try looseObjectSizes().values.reduce(0, +) + packIDs().reduce(0) { $0 + packSize($1) } + snapshotSizes().values.reduce(0, +)
    }

    // MARK: snapshots

    private func snapshotURL(_ id: String) -> URL { snapshotsDir.appending(path: "\(id).json.lzfse") }

    public func snapshotIDs() throws -> [String] {
        try fm.contentsOfDirectory(atPath: snapshotsDir.path)
            .filter { $0.hasSuffix(".json.lzfse") }
            .map { String($0.dropLast(11)) }
            // a planted "...json.lzfse" is the id "..": joined to a path (the references cache), it names the parent
            .filter { (try? Self.checkComponent($0)) != nil }
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
        // the manifest is the last write: every object it names is published first
        try flushPack()
        // a pool: the JSON and its compressed copy (hundreds of MB with a million files) are freed here, not at the end of the run
        try autoreleasepool {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            enc.outputFormatting = .sortedKeys
            // entry by entry into one buffer, the same bytes as encoding the Snapshot whole: that built a tree of every
            // entry (GBs with a million files) and the checksum took two more copies of the JSON
            var head = s
            head.entries = []
            let skeleton = try enc.encode(head) // {"date":…,"entries":[],"id":…}: keys sorted, "entries" right after the date
            guard let split = skeleton.range(of: Data(#""entries":["#.utf8))?.upperBound else {
                throw EncodingError.invalidValue(s, .init(codingPath: [], debugDescription: "no entries key"))
            }
            // a checksum as the first key: one byte flipped in the compressed file can still decode, into other hashes
            // and names. Readers that don't know it (RIPRISTINO.command, older versions) skip an unknown key
            var sealed = Data(Self.checkPrefix.utf8) + Data(repeating: 0, count: 64) + Data("\",".utf8)
            let body = sealed.count // what the checksum covers: the JSON without "{"
            sealed.reserveCapacity(skeleton.count + s.entries.count * 256) // growing a buffer of hundreds of MB copies it
            sealed.append(skeleton[skeleton.startIndex + 1 ..< split])
            for (i, e) in s.entries.enumerated() {
                if i > 0 { sealed.append(UInt8(ascii: ",")) }
                try autoreleasepool { sealed.append(try enc.encode(e)) }
            }
            sealed.append(skeleton[split...])
            sealed.replaceSubrange(Self.checkPrefix.utf8.count ..< body - 2, with: Data(sha256Hex(sealed[body...]).utf8))
            // full flush: the manifest makes the backup exist, so everything before it must be on disk
            try atomicWrite(try (sealed as NSData).compressed(using: .lzfse) as Data, to: snapshotURL(s.id), sync: .device, exclusive: true)
        }
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
            // decompressed and hashed as a stream: the JSON of a million entries is hundreds of MB, and this runs at
            // every backup that finds nothing changed. nil: no checksum (before 0.9.2), decoded whole as before
            guard let sealed = try? checksumMatches(id) else { return (try? readSnapshot(id)) != nil }
            return sealed
        }
    }

    /// Whether the manifest's bytes can be read at all. False for one only in the cloud with the client off or
    /// without network: that one is not damaged, and deleting it would throw away a sound backup.
    public func snapshotCanBeRead(_ id: String) -> Bool { (try? Data(contentsOf: snapshotURL(id))) != nil }

    /// Whether the manifest's checksum matches its content; nil when it has none. Throws when it doesn't decompress.
    private func checksumMatches(_ id: String) throws -> Bool? {
        let raw = try Data(contentsOf: snapshotURL(id))
        let prefix = Data(Self.checkPrefix.utf8), headSize = prefix.count + 66 // {"check":"<64 hex>",
        var head = Data(), hasher = SHA256(), bodySize = 0
        let filter = try OutputFilter(.decompress, using: .lzfse) { chunk in
            guard let chunk else { return }
            let fill = min(headSize - head.count, chunk.count)
            head.append(chunk.prefix(fill))
            hasher.update(data: chunk.dropFirst(fill))
            bodySize += chunk.count - fill
        }
        try filter.write(raw)
        try filter.finalize()
        guard head.starts(with: prefix) else { return nil }
        return head.count == headSize && bodySize > 0 && head.suffix(2) == Data("\",".utf8)
            && String(decoding: head[prefix.count ..< prefix.count + 64], as: UTF8.self)
            == hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The manifest's JSON, its checksum verified when it has one.
    private func sealedJSON(_ id: String) throws -> Data {
        let raw = try Data(contentsOf: snapshotURL(id))
        guard let json = try? (raw as NSData).decompressed(using: .lzfse) as Data else { throw RepositoryError.damagedSnapshot(id) }
        let prefix = Data(Self.checkPrefix.utf8)
        guard json.starts(with: prefix) else { return json }
        let start = json.startIndex + prefix.count
        guard json.count > prefix.count + 66, json[start + 64] == UInt8(ascii: "\""), json[start + 65] == UInt8(ascii: ","),
              String(decoding: json[start ..< start + 64], as: UTF8.self) == sha256Hex(json[(start + 66)...]) else {
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
        // browsing never writes to the destination: a rebuilt container index is written back only now
        holdsLock = true
        defer { holdsLock = false }
        return try body()
    }

    // MARK: helpers

    enum Sync { case file, device }

    static func posixError() -> POSIXError {
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

    func archiveDirectory(create: Bool = false) throws -> Int32 {
        guard destinationFD >= 0 else { throw POSIXError(.EBADF) }
        let base = try Self.childDirectory("BackupMe", in: destinationFD, create: create)
        defer { close(base) }
        let fd = try Self.childDirectory(computer, in: base, create: create)
        // private files (~/.ssh) must not be readable by the other accounts of a shared disk or NAS; an archive made
        // before is fixed too. Disks that ignore ownership refuse or ignore it
        if create { fchmod(fd, 0o700) }
        return fd
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
        // flags belong to the inode: a hard link planted to a user's locked file is never unlocked
        var st = stat()
        if fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 { fchflags(fd, 0) }
        close(fd)
        return unlinkat(dir, name, 0)
    }

    func atomicWrite(_ data: Data, to url: URL, sync: Sync, exclusive: Bool = false) throws {
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
