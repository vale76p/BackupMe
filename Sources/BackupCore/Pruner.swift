import Foundation

public struct PruneResult: Equatable, Sendable {
    public var deletedSnapshots: [String]
    public var deletedObjects: Int
    public var poolSize: Int64
    public var overCap: Bool
}

/// Applies retention, removes unreferenced objects, then deletes oldest snapshots while the pool exceeds `capBytes`.
/// The newest snapshot is never deleted.
public func prune(repository: Repository, policy: RetentionPolicy, capBytes: Int64?, now: Date,
                  calendar: Calendar = .current) throws -> PruneResult {
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
        var deletedObjects = try collectGarbage(repository)
        var size = try repository.poolSize()
        if let cap = capBytes {
            var remaining = try repository.snapshotIDs()
            while size > cap, remaining.count > 1 {
                let oldest = remaining.removeFirst()
                try repository.deleteSnapshot(oldest)
                deleted.append(oldest)
                deletedObjects += try collectGarbage(repository)
                size = try repository.poolSize()
            }
        }
        return PruneResult(deletedSnapshots: deleted, deletedObjects: deletedObjects, poolSize: size,
                           overCap: capBytes.map { size > $0 } ?? false)
    }
}

/// Deletes objects no remaining manifest references. A manifest that can't be read aborts (throws) before any delete.
private func collectGarbage(_ repository: Repository) throws -> Int {
    var reachable = Set<String>()
    for id in try repository.snapshotIDs() {
        for e in try repository.readSnapshot(id).entries { if let h = e.hash { reachable.insert(h) } }
    }
    let unreachable = try repository.allObjectHashes().subtracting(reachable)
    for h in unreachable { try repository.deleteObject(h) }
    try repository.removeTemporaryFiles()
    return unreachable.count
}
