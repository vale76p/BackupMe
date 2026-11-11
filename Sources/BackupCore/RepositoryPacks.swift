import Darwin
import Foundation

/// Containers: packs/<id>.pack with its index packs/<id>.idx (`Pack`). Ids are 16 hex digits, strictly increasing.
extension Repository {
    var packsDir: URL { root.appending(path: "packs", directoryHint: .isDirectory) }

    static func isPackID(_ s: String) -> Bool { s.utf8.count == 16 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// packs/, opened without following links: a link swapped in is never read or written through.
    private func packsDirectory(create: Bool = false) throws -> Int32 {
        let archive = try archiveDirectory()
        defer { close(archive) }
        return try Self.childDirectory("packs", in: archive, create: create)
    }

    /// Bytes of a file in packs/, all of it or `length` from `offset`; fewer when the file is shorter.
    private func readPackFile(_ name: String, in packs: Int32, at offset: Int = 0, length: Int? = nil) throws -> Data {
        // non-blocking: a pipe planted under the name never hangs the read
        let fd = openat(packs, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Self.posixError() }
        guard st.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        var data = Data(count: length ?? Int(st.st_size)), done = 0
        try data.withUnsafeMutableBytes { buf in
            while done < buf.count {
                let n = pread(fd, buf.baseAddress! + done, buf.count - done, off_t(offset + done))
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { throw Self.posixError() }
                if n == 0 { break }
                done += n
            }
        }
        return data.prefix(done)
    }

    /// The copy of `hash` described by `e`, nil when it doesn't verify (a container cut short reads as damaged).
    func readPacked(_ hash: String, _ e: PackEntry, in id: String) throws -> Data? {
        let packs = try packsDirectory()
        defer { close(packs) }
        return Self.decoded(try readPackFile("\(id).pack", in: packs, at: e.offset, length: e.length), compressed: e.compressed, hash: hash)
    }

    /// Ids of the published containers, ascending.
    public func packIDs() throws -> [String] {
        var st = stat()
        if lstat(packsDir.path, &st) != 0 {
            if errno == ENOENT { return [] }
            throw Self.posixError()
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        return try fm.contentsOfDirectory(atPath: packsDir.path).filter { $0.hasSuffix(".pack") }
            .map { String($0.dropLast(5)) }.filter(Self.isPackID).sorted()
    }

    /// A container's entries, from its index; one missing, damaged or not matching the container is rebuilt from it.
    public func packEntries(_ id: String) throws -> [PackEntry] {
        guard Self.isPackID(id) else { throw RepositoryError.damagedPack(id) }
        let packs = try packsDirectory()
        defer { close(packs) }
        var st = stat()
        guard fstatat(packs, "\(id).pack", &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError() }
        if let entries = try? Pack.decodeIndex(try readPackFile("\(id).idx", in: packs), id: id) {
            // the index of another container, or one with entries past the end, would hide objects or point into others
            let end = entries.map { $0.offset + $0.length }.max() ?? Pack.magic.count
            guard end == Int(st.st_size) else { return try rebuildIndex(id, in: packs) }
            guard let first = entries.first else { return entries }
            guard first.offset == Pack.magic.count + Pack.headerSize else { return try rebuildIndex(id, in: packs) }
            let h = try readPackFile("\(id).pack", in: packs, at: Pack.magic.count, length: Pack.headerSize)
            if h.count == Pack.headerSize, h.prefix(32).map({ String(format: "%02x", $0) }).joined() == first.hash,
               h[32] == (first.compressed ? 1 : 0), h.suffix(4).reduce(0, { $0 << 8 | Int($1) }) == first.length {
                return entries
            }
        }
        return try rebuildIndex(id, in: packs)
    }

    /// A damaged container hides only its own objects: `packEntries` still reports it to the verification, the
    /// others stay readable, and a backup stores its objects again.
    func readableEntries(_ id: String) throws -> [PackEntry] {
        do { return try packEntries(id) } catch RepositoryError.damagedPack { return [] }
    }

    private func rebuildIndex(_ id: String, in packs: Int32) throws -> [PackEntry] {
        let entries = try Pack.scan(try readPackFile("\(id).pack", in: packs), id: id)
        // best effort: on a read-only destination the objects are still read, from the rebuilt entries
        try? Self.atomicWrite(Pack.encodeIndex(entries), named: "\(id).idx", in: packs, sync: .file)
        return entries
    }

    /// Every published container's entries by hash, loaded once; the greatest id wins.
    func packIndex() throws -> [String: (pack: String, entry: PackEntry)] {
        if let packed { return packed }
        // shortcut: every index is read at each opening, a local cache when a million objects make it slow
        var index: [String: (pack: String, entry: PackEntry)] = [:]
        for id in try packIDs() {
            Activity.beat()
            for e in try readableEntries(id) { index[e.hash] = (id, e) }
        }
        packed = index
        return index
    }

    /// The container holding the copy that counts: the one with the greatest id.
    func packOf(_ hash: String) -> String? { (try? packIndex())?[hash]?.pack }

    /// Container plus index, on disk.
    public func packSize(_ id: String) -> Int64 {
        guard Self.isPackID(id) else { return 0 }
        return ["pack", "idx"].reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: packsDir.appending(path: "\(id).\($1)").path)[.size] as? Int64) ?? 0) }
    }

    func addToOpenPack(_ body: Data, hash: String, compressed: Bool) throws {
        // a record holds a 64-hex hash and a 4-byte length
        guard Self.isHash(hash), body.count <= Int(UInt32.max) else { throw POSIXError(.EINVAL) }
        openEntries.append(Pack.append(body, hash: hash, compressed: compressed, to: &openPack))
        knownObjects?.insert(hash)
        if openPack.count >= Self.packTarget { try flushPack() }
    }

    /// Publishes the open container and its index; nothing when empty.
    public func flushPack() throws {
        guard !openEntries.isEmpty else { return }
        let packs = try packsDirectory(create: true)
        defer { close(packs) }
        // before the first container: an archive with containers marked 1 would be restored only in part by an older kit
        let info = root.appending(path: "repo.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: info)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: info.path])
        }
        if (json["format"] as? Int ?? 1) < Self.format {
            json["format"] = Self.format
            try atomicWrite(try JSONSerialization.data(withJSONObject: json, options: .sortedKeys), to: info, sync: .device)
        }
        let last = try packIDs().last.flatMap { UInt64($0, radix: 16) } ?? 0
        guard last < .max else { throw POSIXError(.EOVERFLOW) }
        // strictly increasing, also with the clock set back
        let id = String(format: "%016llx", max(last + 1, UInt64(Date().timeIntervalSince1970 * 1000)))
        try Self.atomicWrite(openPack, named: "\(id).pack", in: packs, sync: .file, exclusive: true)
        try Self.atomicWrite(Pack.encodeIndex(openEntries), named: "\(id).idx", in: packs, sync: .file)
        for e in openEntries { packed?[e.hash] = (id, e) }
        openPack = Data()
        openEntries = []
    }

    /// Index first, then container: a container without its index is rebuilt, an index without its container is a leftover.
    public func deletePack(_ id: String) throws {
        guard Self.isPackID(id) else { throw POSIXError(.EINVAL) }
        let packs = try packsDirectory()
        defer { close(packs) }
        for ext in ["idx", "pack"] {
            if unlinkat(packs, "\(id).\(ext)", 0) != 0, errno != ENOENT { throw Self.posixError() }
        }
        // an older container may hold a copy of what this one did: found again at the next question
        packed = nil
        knownObjects = nil
    }

    /// Copies these objects into new containers, whatever form they have now. Each is read and verified first;
    /// one that doesn't verify throws `corruptObject` before anything is written for it.
    public func repack(_ hashes: [String]) throws {
        for h in hashes {
            let (body, compressed) = Self.storedForm(try readObject(h))
            try addToOpenPack(body, hash: h, compressed: compressed)
        }
        try flushPack()
    }

    /// `.tmp` leftovers in packs/ and indexes without their container; by descriptor, never through a link.
    func removePackLeftovers() throws -> Int {
        guard let packs = try? packsDirectory() else { return 0 }
        defer { close(packs) }
        let names = Set(try fm.contentsOfDirectory(atPath: packsDir.path))
        var removed = 0
        for n in names where n.hasSuffix(".tmp") || (n.hasSuffix(".idx") && !names.contains(String(n.dropLast(3)) + "pack")) {
            var st = stat()
            // only files and links, as for objects/
            guard fstatat(packs, n, &st, AT_SYMLINK_NOFOLLOW) == 0, [S_IFREG, S_IFLNK].contains(st.st_mode & S_IFMT) else { continue }
            guard unlinkat(packs, n, 0) == 0 else { throw Self.posixError() }
            removed += 1
        }
        return removed
    }
}
