import Foundation

public struct PruneResult: Equatable, Sendable {
    public var deletedSnapshots: [String]
    public var deletedObjects: Int
    public var poolSize: Int64
    public var overCap: Bool
}

/// Applies retention, removes unreferenced objects, then deletes oldest snapshots while the pool exceeds `capBytes`.
/// The newest snapshot is never deleted. `refsCache` is a local folder remembering which objects each manifest uses
/// (manifests never change), so manifests on OneDrive are read once, not on every run.
public func prune(repository: Repository, policy: RetentionPolicy, capBytes: Int64?, now: Date,
                  calendar: Calendar = .current, refsCache: URL? = nil) throws -> PruneResult {
    try repository.withLock {
        var deleted: [String] = []
        let ids = try repository.snapshotIDs()
        // ids that don't parse as dates are not ours to judge: keep them
        let dated = ids.compactMap { id in Snapshot.date(fromID: id).map { (id: id, date: $0) } }
        let keep = snapshotsToKeep(dated, policy: policy, now: now, calendar: calendar)
        for s in dated where !keep.contains(s.id) {
            try repository.deleteSnapshot(s.id)
            deleted.append(s.id)
        }
        var remaining = try repository.snapshotIDs()
        var refs: [String: Set<String>] = [:]
        for id in remaining { refs[id] = try references(of: id, in: repository, cache: refsCache) }
        var deletedObjects = try collectGarbage(repository, reachable: refs)
        var size = try repository.poolSize()
        if let cap = capBytes {
            while size > cap, remaining.count > 1 {
                let oldest = remaining.removeFirst()
                try repository.deleteSnapshot(oldest)
                refs[oldest] = nil
                deleted.append(oldest)
                deletedObjects += try collectGarbage(repository, reachable: refs)
                size = try repository.poolSize()
            }
        }
        if let dir = refsCache, let cached = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in cached where refs[name] == nil { try? FileManager.default.removeItem(at: dir.appending(path: name)) }
        }
        return PruneResult(deletedSnapshots: deleted, deletedObjects: deletedObjects, poolSize: size,
                           overCap: capBytes.map { size > $0 } ?? false)
    }
}

/// Object hashes used by one manifest. A manifest that can't be read throws, which aborts pruning before any delete.
private func references(of id: String, in repository: Repository, cache: URL?) throws -> Set<String> {
    let cached = cache?.appending(path: id)
    if let cached, let text = try? String(contentsOf: cached, encoding: .utf8) {
        return Set(text.split(separator: "\n").map(String.init))
    }
    let hashes = Set(try repository.readSnapshot(id).entries.compactMap(\.hash))
    if let cached, let dir = cache {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? hashes.joined(separator: "\n").write(to: cached, atomically: true, encoding: .utf8)
    }
    return hashes
}

private func collectGarbage(_ repository: Repository, reachable refs: [String: Set<String>]) throws -> Int {
    let reachable = refs.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    let unreachable = try repository.allObjectHashes().subtracting(reachable)
    for h in unreachable { try repository.deleteObject(h) }
    try repository.removeTemporaryFiles()
    return unreachable.count
}
