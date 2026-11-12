import CryptoKit
import Foundation

public struct PruneResult: Equatable, Sendable {
    public var deletedSnapshots: [String]
    public var deletedObjects: Int
    public var poolSize: Int64
    public var overCap: Bool
    /// True when object cleanup was skipped because known manifests vanished from the listing (e.g. OneDrive re-sync).
    public var gcSkipped = false
    /// Manifests of this same archive vanished from the listing: worth telling the user. False when the only missing
    /// ones belonged to an earlier archive at this destination, deleted and made again from nothing.
    public var vanished = false
    /// This run found a different archive id in repo.json: the archive was made again from nothing, and the
    /// backups of the earlier one are gone from the destination. Told once, in the run that notices it.
    public var archiveReplaced = false
    /// Unreferenced objects were looked for (and deleted): the full listing ran.
    public var collected = false
    /// Objects that kept manifests use but the archive listing lacks (counted only when object cleanup ran).
    public var missingObjects = 0
    /// Manifests, single-file objects, and 2 for each container: what the destination saw deleted.
    public var deletedFiles = 0
    /// The cap loop stopped for the budget, not for lack of backups to delete.
    public var capPending = false
    /// Single-file objects below `Repository.packThreshold` still there; nil when not counted.
    public var smallFilesLeft: Int?
}

/// Applies retention, then deletes oldest snapshots while the pool exceeds `capBytes` (never the newest),
/// then removes objects no manifest references. Object cleanup runs only when a snapshot was deleted or
/// `forceGC` is set. The app never forces it: the orphans of a failed backup are what the next attempt reuses.
///
/// `refsCache` is a local folder remembering which objects each manifest uses (manifests are immutable), so
/// manifests on OneDrive are read once. It also detects cached manifests that disappeared without this code
/// deleting them: then the listing can't be trusted and no object is deleted.
///
/// `pinned` snapshots are never deleted, neither by retention nor by the cap (e.g. the last complete backup
/// while newer ones are partial).
///
/// Objects are deleted from a plan kept in `refsCache` (`CleanupPlan`): the collection writes it, the calls in between
/// delete from it within `options.maxDeletions`, and without one no object is deleted.
public func prune(repository: Repository, policy: RetentionPolicy, capBytes: Int64?, now: Date,
                  calendar: Calendar = .backup, refsCache: URL? = nil, forceGC: Bool = false,
                  pinned: Set<String> = [], gcDue: Bool = true, options: CleanupOptions = .init()) throws -> PruneResult {
    try repository.withLock {
        var ids = try repository.snapshotIDs()
        let tracked = refsCache.map { trackVanished(ids: Set(ids), archive: repository.archiveID, cache: $0, now: now) }
        let gcSkipped = tracked?.wait ?? false
        // files this call may still delete: a cloud service alerts on many deleted at once
        var left = options.maxDeletions ?? .max

        // ids that don't parse as dates are not ours to judge: keep them
        let dated = ids.compactMap { id in Snapshot.date(fromID: id).map { (id: id, date: $0) } }
        let keep = snapshotsToKeep(dated, policy: policy, now: now, calendar: calendar).union(pinned)
        var deleted: [String] = []
        for s in dated where !keep.contains(s.id) {
            guard left > 0 else { break }
            try repository.deleteSnapshot(s.id)
            deleted.append(s.id)
            left -= 1
        }
        ids.removeAll { deleted.contains($0) }

        var size: Int64 = 0, capPending = false
        // object → how many kept manifests use it: one entry per object, not one set per manifest (that was
        // gigabytes with a million files), and taking a manifest out updates the size without recounting
        var users: [String: Int]?
        var objectSizes: [String: Int64] = [:], manifestSizes: [String: Int64] = [:], total: Int64 = 0
        if capBytes != nil {
            // objects/ listed once: the sizes of objectSizes() for the backups to delete, the bytes on disk of
            // poolSize() for whether it fits (a container counts whole, its dead entries and its index too)
            let loose = try repository.looseObjectSizes()
            objectSizes = try repository.packIndex().mapValues { Int64($0.entry.length) }.merging(loose) { $1 }
            manifestSizes = try repository.snapshotSizes()
            total = loose.values.reduce(0, +) + (try repository.packIDs()).reduce(0) { $0 + repository.packSize($1) }
                + manifestSizes.values.reduce(0, +)
        }
        // everything stored, unreferenced objects included, fits: nothing to delete, and no reason to read every
        // manifest's references at every backup (seconds to minutes with a million files, much more on SMB)
        let fits = capBytes.map { total <= $0 } ?? true
        if fits { size = total } else if let cap = capBytes {
            var counts: [String: Int] = [:]
            for id in ids {
                Activity.beat()
                for h in try references(of: id, in: repository, cache: refsCache) { counts[h, default: 0] += 1 }
            }
            size = counts.keys.reduce(0) { $0 + (objectSizes[$1] ?? 0) } + manifestSizes.values.reduce(0, +)
            // oldest first, never the newest, never a pinned one or an id that isn't ours
            while size > cap, let oldest = ids.dropLast().first(where: { !pinned.contains($0) && Snapshot.date(fromID: $0) != nil }) {
                guard left > 0 else { capPending = true; break }
                left -= 1
                let gone = try references(of: oldest, in: repository, cache: refsCache) // read again rather than kept
                ids.removeAll { $0 == oldest }
                try repository.deleteSnapshot(oldest)
                deleted.append(oldest)
                for h in gone {
                    counts[h, default: 1] -= 1
                    if counts[h] == 0 { counts[h] = nil; size -= objectSizes[h] ?? 0 }
                }
                size -= manifestSizes.removeValue(forKey: oldest) ?? 0
            }
            users = counts
        }

        var deleting: (objects: Int, files: Int, smallLeft: Int?) = (0, 0, nil)
        var missingObjects = 0
        // with hourly backups one leaves the last 24 hours every hour: collecting their objects each time reads every
        // manifest's references. `gcDue` (once a day) lets the orphans wait while the archive fits with them; over the
        // cap they go now, also when nothing left in this run (orphans of an earlier one), and the references are counted.
        // The conversion starts from a plan
        let saved = CleanupPlan.read(refsCache)
        let collect = (!deleted.isEmpty && gcDue) || !fits || forceGC || (options.convert && saved == nil)
        // known manifests vanished (a re-sync): the listing can't be trusted, no object or container is deleted
        if !gcSkipped {
            var plan = saved
            if collect {
                var reachable = users.map { Set($0.keys) } ?? []
                if users == nil { for id in ids { reachable.formUnion(try references(of: id, in: repository, cache: refsCache)) } }
                let stored = try repository.allObjectHashes()
                plan = CleanupPlan(snapshots: ids, condemned: Array(stored.subtracting(reachable)),
                                   conversionDone: saved?.conversionDone ?? false)
                missingObjects = reachable.subtracting(stored).count
            }
            if let plan {
                let confirmed = options.confirmed ?? { repository.packIsConfirmed($0, now: now) }
                deleting = try deleteCondemned(plan, ids: ids, repository: repository, refsCache: refsCache, collected: collect,
                                               capBytes: capBytes, convert: options.convert, left: &left, confirmed: confirmed)
            }
            // leftovers of interrupted writes, not counted: what is left of a file that never was
            if collect { try repository.removeTemporaryFiles() }
        }
        if let dir = refsCache {
            for id in deleted {
                try? FileManager.default.removeItem(at: dir.appending(path: id))
                try? FileManager.default.removeItem(at: dir.appending(path: id + ".seen"))
            }
        }
        return PruneResult(deletedSnapshots: deleted, deletedObjects: deleting.objects, poolSize: size,
                           overCap: capBytes.map { size > $0 } ?? false, gcSkipped: gcSkipped, vanished: tracked?.warn ?? false,
                           archiveReplaced: tracked?.replaced ?? false, collected: collect && !gcSkipped,
                           missingObjects: missingObjects, deletedFiles: deleted.count + deleting.files, capPending: capPending,
                           smallFilesLeft: deleting.smallLeft)
    }
}

/// Deletes the manifests among `ids` that can't be read: those backups can't be restored, and keep the archive
/// marked damaged until retention takes them. A readable one is never deleted. They also leave the references
/// cache, or the next cleanup would take them for vanished. Returns the ones deleted.
public func deleteDamagedSnapshots(_ ids: [String], repository: Repository, refsCache: URL?) throws -> [String] {
    try repository.withLock {
        var deleted: [String] = []
        for id in ids where repository.snapshotExists(id) && !repository.snapshotIsIntact(id) {
            try repository.deleteSnapshot(id)
            deleted.append(id)
            for name in [id, id + ".seen", id + ".gone", id + ".previous"] {
                try? refsCache.map { try FileManager.default.removeItem(at: $0.appending(path: name)) }
            }
        }
        return deleted
    }
}

/// Remembers every manifest seen (`<id>.seen`, or `<id>` once its references are cached). Marks the ones
/// missing from the listing as `<id>.gone`, and restores them if they come back.
/// `wait` while any manifest has been missing for less than 3 days: object cleanup must wait. `warn` only when
/// they are of the same archive: those of an archive made again from nothing (a new id in repo.json) become
/// `<id>.previous`, still waited for (a re-sync could rewrite repo.json too) but expected to stay away.
private func trackVanished(ids: Set<String>, archive: String?, cache dir: URL, now: Date) -> (wait: Bool, warn: Bool, replaced: Bool) {
    let fm = FileManager.default
    let markers = [".seen", ".gone", ".previous"]
    // the archive's id and the cleanup plan: not manifests
    let reserved: Set = ["archive", "cleanup"]
    func id(of name: String) -> String { markers.first(where: name.hasSuffix).map { String(name.dropLast($0.count)) } ?? name }
    func mark(_ url: URL, as name: String) {
        let to = dir.appending(path: name)
        // already marked (a manifest that left before): keep its date, or the 3 days would restart at every run
        if fm.fileExists(atPath: to.path) { try? fm.removeItem(at: url); return }
        try? fm.moveItem(at: url, to: to)
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: to.path)
    }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let idFile = dir.appending(path: "archive")
    var replaced = false
    if let archive, let known = try? String(contentsOf: idFile, encoding: .utf8), known != archive {
        let cached = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !reserved.contains($0) }
        // repo.json written again over the same backups (lost, or damaged and repaired) is the same archive
        replaced = !cached.isEmpty && !cached.contains { ids.contains(id(of: $0)) }
        for name in cached where replaced && !ids.contains(id(of: name)) {
            mark(dir.appending(path: name), as: id(of: name) + ".previous")
        }
    }
    // a cache from before this file existed takes the current archive as its own
    if let archive { try? archive.write(to: idFile, atomically: true, encoding: .utf8) }

    let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    // a manifest marked gone or previous that is listed again is restored below, not seen anew: both a marker
    // and a ".seen" would make the same id leave twice later
    for id in ids where !names.contains(id) && !names.contains(id + ".seen") && !names.contains(id + ".gone")
        && !names.contains(id + ".previous") {
        fm.createFile(atPath: dir.appending(path: id + ".seen").path, contents: nil)
    }
    var wait = false, warn = false
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !reserved.contains(name) {
        let url = dir.appending(path: name)
        let id = id(of: name)
        if name.hasSuffix(".gone") || name.hasSuffix(".previous") {
            if ids.contains(id) { try? fm.moveItem(at: url, to: dir.appending(path: id)); continue }
            let since = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(since) < 3 * 86400 { wait = true; warn = warn || name.hasSuffix(".gone") }
            else { try? fm.removeItem(at: url) }
        } else if !ids.contains(id) {
            mark(url, as: id + ".gone")
            wait = true; warn = true
        }
    }
    return (wait, warn, replaced)
}

/// Object hashes used by one manifest. A manifest that can't be read throws, which aborts pruning before any delete.
/// Cached as 32-byte hashes under a checksum: 64 hex digits a line were ~65 MB per manifest with a million files.
/// A cached file that doesn't verify is read from the manifest again; the text of earlier versions is still read.
func references(of id: String, in repository: Repository, cache: URL?) throws -> Set<String> {
    let cached = cache?.appending(path: id)
    // an empty file is a manifest that came back after vanishing before its references were cached (its ".gone"
    // marker renamed back): read the manifest, or every object it uses would look unreferenced
    if let cached, let data = try? Data(contentsOf: cached), !data.isEmpty {
        if data.starts(with: refsMagic) {
            let body = data.dropFirst(refsMagic.count), hashes = body.dropFirst(32)
            if body.count >= 32, hashes.count % 32 == 0, Data(SHA256.hash(data: hashes)) == body.prefix(32) {
                return hashes.withUnsafeBytes { raw in
                    Set((0 ..< raw.count / 32).map { hex(UnsafeRawBufferPointer(rebasing: raw[$0 * 32 ..< $0 * 32 + 32])) })
                }
            }
        } else if let text = String(data: data, encoding: .utf8) {
            // only when every line is a hash: anything else (a damaged file) is read from the manifest
            let hashes = Set(text.split(separator: "\n").map(String.init))
            if let binary = refsData(hashes) {
                try? binary.write(to: cached, options: .atomic) // half the space from now on
                return hashes
            }
        }
    }
    let hashes = try autoreleasepool { Set(try repository.readSnapshot(id).entries.compactMap(\.hash)) }
    // not cached when a hash isn't one (a tampered manifest): read again each time, as its objects can't exist
    if let cached, let dir = cache, let binary = refsData(hashes) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? binary.write(to: cached, options: .atomic)
        try? FileManager.default.removeItem(at: dir.appending(path: id + ".seen"))
    }
    return hashes
}

private let refsMagic = Data("BMREFS1\n".utf8)
private let hexDigits = Array("0123456789abcdef".utf8)

/// The cached form of `hashes`: magic, SHA-256 of the rest, 32 bytes per hash. Nil if one isn't a hash.
private func refsData(_ hashes: Set<String>) -> Data? {
    var bytes = [UInt8]()
    bytes.reserveCapacity(hashes.count * 32)
    func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 } // "0"-"9", "a"-"f"
    for h in hashes {
        guard Repository.isHash(h) else { return nil }
        var digits = h.utf8.makeIterator()
        while let hi = digits.next(), let lo = digits.next() { bytes.append(nibble(hi) << 4 | nibble(lo)) }
    }
    return refsMagic + Data(SHA256.hash(data: bytes)) + Data(bytes)
}

private func hex(_ bytes: UnsafeRawBufferPointer) -> String {
    String(unsafeUninitializedCapacity: bytes.count * 2) { out in
        for (i, b) in bytes.enumerated() { out[2 * i] = hexDigits[Int(b >> 4)]; out[2 * i + 1] = hexDigits[Int(b & 15)] }
        return bytes.count * 2
    }
}
