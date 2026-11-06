import Foundation

public struct PruneResult: Equatable, Sendable {
    public var deletedSnapshots: [String]
    public var deletedObjects: Int
    public var poolSize: Int64
    public var overCap: Bool
    /// True when object cleanup was skipped because known manifests vanished from the listing (e.g. OneDrive re-sync).
    public var gcSkipped = false
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
        let gcSkipped = refsCache.map { trackVanished(ids: Set(ids), cache: $0, now: now) } ?? false

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
                           overCap: capBytes.map { size > $0 } ?? false, gcSkipped: gcSkipped, missingObjects: missingObjects)
    }
}

/// Remembers every manifest seen (`<id>.seen`, or `<id>` once its references are cached). Marks the ones
/// missing from the listing as `<id>.gone`, and restores them if they come back.
/// Returns true while any manifest has been gone for less than 3 days: object cleanup must wait.
private func trackVanished(ids: Set<String>, cache dir: URL, now: Date) -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    for id in ids where !names.contains(id) && !names.contains(id + ".seen") {
        fm.createFile(atPath: dir.appending(path: id + ".seen").path, contents: nil)
    }
    var waiting = false
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
        let url = dir.appending(path: name)
        if name.hasSuffix(".gone") {
            let id = String(name.dropLast(5))
            if ids.contains(id) { try? fm.moveItem(at: url, to: dir.appending(path: id)); continue }
            let since = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(since) < 3 * 86400 { waiting = true } else { try? fm.removeItem(at: url) }
        } else if !ids.contains(name.hasSuffix(".seen") ? String(name.dropLast(5)) : name) {
            let id = name.hasSuffix(".seen") ? String(name.dropLast(5)) : name
            let gone = dir.appending(path: id + ".gone")
            try? fm.moveItem(at: url, to: gone)
            try? fm.setAttributes([.modificationDate: now], ofItemAtPath: gone.path)
            waiting = true
        }
    }
    return waiting
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
