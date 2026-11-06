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
    /// Objects that kept manifests use but the archive listing lacks (counted only when object cleanup ran).
    public var missingObjects = 0
}

/// Applies retention, then deletes oldest snapshots while the pool exceeds `capBytes` (never the newest),
/// then removes objects no manifest references. Object cleanup runs only when a snapshot was deleted or
/// `forceGC` is set (after a failed backup that may have left orphan objects).
///
/// `refsCache` is a local folder remembering which objects each manifest uses (manifests are immutable), so
/// manifests on OneDrive are read once. It also detects cached manifests that disappeared without this code
/// deleting them: then the listing can't be trusted and no object is deleted.
///
/// `pinned` snapshots are never deleted, neither by retention nor by the cap (e.g. the last complete backup
/// while newer ones are partial).
public func prune(repository: Repository, policy: RetentionPolicy, capBytes: Int64?, now: Date,
                  calendar: Calendar = .backup, refsCache: URL? = nil, forceGC: Bool = false,
                  pinned: Set<String> = []) throws -> PruneResult {
    try repository.withLock {
        var ids = try repository.snapshotIDs()
        let tracked = refsCache.map { trackVanished(ids: Set(ids), archive: repository.archiveID, cache: $0, now: now) }
        let gcSkipped = tracked?.wait ?? false

        // ids that don't parse as dates are not ours to judge: keep them
        let dated = ids.compactMap { id in Snapshot.date(fromID: id).map { (id: id, date: $0) } }
        let keep = snapshotsToKeep(dated, policy: policy, now: now, calendar: calendar).union(pinned)
        var deleted: [String] = []
        for s in dated where !keep.contains(s.id) {
            try repository.deleteSnapshot(s.id)
            deleted.append(s.id)
        }
        ids.removeAll { deleted.contains($0) }

        var size: Int64 = 0
        // object → how many kept manifests use it: one entry per object, not one set per manifest (that was
        // gigabytes with a million files), and taking a manifest out updates the size without recounting
        var users: [String: Int]?
        if let cap = capBytes {
            var counts: [String: Int] = [:]
            for id in ids { for h in try references(of: id, in: repository, cache: refsCache) { counts[h, default: 0] += 1 } }
            let objectSizes = try repository.objectSizes()
            var manifestSizes = try repository.snapshotSizes()
            size = counts.keys.reduce(0) { $0 + (objectSizes[$1] ?? 0) } + manifestSizes.values.reduce(0, +)
            // oldest first, never the newest, never a pinned one or an id that isn't ours
            while size > cap, let oldest = ids.dropLast().first(where: { !pinned.contains($0) && Snapshot.date(fromID: $0) != nil }) {
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

        var deletedObjects = 0
        var missingObjects = 0
        if !deleted.isEmpty || forceGC, !gcSkipped {
            var reachable = users.map { Set($0.keys) } ?? []
            if users == nil { for id in ids { reachable.formUnion(try references(of: id, in: repository, cache: refsCache)) } }
            let stored = try repository.allObjectHashes()
            let unreachable = stored.subtracting(reachable)
            for h in unreachable { try repository.deleteObject(h) }
            try repository.removeTemporaryFiles()
            deletedObjects = unreachable.count
            missingObjects = reachable.subtracting(stored).count
        }
        if let dir = refsCache {
            for id in deleted {
                try? FileManager.default.removeItem(at: dir.appending(path: id))
                try? FileManager.default.removeItem(at: dir.appending(path: id + ".seen"))
            }
        }
        return PruneResult(deletedSnapshots: deleted, deletedObjects: deletedObjects, poolSize: size,
                           overCap: capBytes.map { size > $0 } ?? false, gcSkipped: gcSkipped, vanished: tracked?.warn ?? false,
                           archiveReplaced: tracked?.replaced ?? false, missingObjects: missingObjects)
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
        replaced = true
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != "archive" && !ids.contains(id(of: name)) {
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
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != "archive" {
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
private func references(of id: String, in repository: Repository, cache: URL?) throws -> Set<String> {
    let cached = cache?.appending(path: id)
    // an empty file is a manifest that came back after vanishing before its references were cached (its ".gone"
    // marker renamed back): read the manifest, or every object it uses would look unreferenced
    if let cached, let text = try? String(contentsOf: cached, encoding: .utf8), !text.isEmpty {
        return Set(text.split(separator: "\n").map(String.init))
    }
    let hashes = try autoreleasepool { Set(try repository.readSnapshot(id).entries.compactMap(\.hash)) }
    if let cached, let dir = cache {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? hashes.joined(separator: "\n").write(to: cached, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appending(path: id + ".seen"))
    }
    return hashes
}
