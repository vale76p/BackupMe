import Foundation

public struct VerifyReport: Equatable, Sendable {
    public var checked: Int
    public var bytes: Int64
    public var corrupt: [String]
    public var repaired: [String]
}

/// Reads random objects until about `budgetBytes` (size in the archive) have been checked. A corrupt object is
/// rewritten from the source file the hash cache knows, if that file still has the same content; it is never deleted.
public func verifySample(repository: Repository, cache: HashCache, budgetBytes: Int64) throws -> VerifyReport {
    try repository.withLock {
        // a few folders at random: listing a million objects to read 100 MB of them took longer than the reads
        try verify(try repository.objectSizes(sampleDirs: 4).shuffled(), in: repository, cache: cache, budgetBytes: budgetBytes)
    }
}

private func verify(_ objects: [(key: String, value: Int64)], in repository: Repository, cache: HashCache, budgetBytes: Int64,
                    isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> VerifyReport {
    var r = VerifyReport(checked: 0, bytes: 0, corrupt: [], repaired: [])
    for (i, (hash, size)) in objects.enumerated() where r.bytes < budgetBytes {
        if isCancelled() { throw BackupError.cancelled }
        Activity.beat()
        // an object bigger than what's left would overshoot the budget (on Files On-Demand, a download of GBs)
        guard size <= budgetBytes - r.bytes else { continue }
        r.checked += 1
        r.bytes += size
        progress(Double(i + 1) / Double(objects.count))
        // a pool per object: every read would otherwise stay in memory until the whole check ends
        if try autoreleasepool(invoking: { try repository.verifyObject(hash) }) { continue }
        if let p = cache.path(for: hash), (try? repository.repairObject(hash, from: URL(fileURLWithPath: p))) == true {
            r.repaired.append(hash)
        } else {
            r.corrupt.append(hash)
        }
    }
    return r
}

public struct ArchiveCheck: Sendable {
    public var snapshots: Int
    /// Manifests that can't be read or decoded: those backups can't be restored at all.
    public var unreadableSnapshots: [String]
    /// Objects some backup needs that aren't in the archive.
    public var missingObjects: Int
    public var objects: VerifyReport

    public var isHealthy: Bool { unreadableSnapshots.isEmpty && missingObjects == 0 && objects.corrupt.isEmpty }
}

/// Reads every manifest and every object they use back: what the daily sample does, for the whole archive. Corrupt objects
/// are repaired from the source files when possible, as in `verifySample`.
public func checkArchive(repository: Repository, cache: HashCache, isCancelled: () -> Bool = { false },
                         progress: (Double) -> Void = { _ in }) throws -> ArchiveCheck {
    try repository.withLock {
        let ids = try repository.snapshotIDs()
        var unreadable: [String] = []
        var needed = Set<String>()
        for id in ids {
            if isCancelled() { throw BackupError.cancelled }
            Activity.beat()
            do { try autoreleasepool { needed.formUnion(try repository.readSnapshot(id).entries.compactMap(\.hash)) } }
            catch { unreadable.append(id) }
        }
        let sizes = try repository.objectSizes()
        let missing = needed.subtracting(sizes.keys).count
        // only what a backup uses: objects no manifest needs go at the next cleanup, reading them is a waste
        // (on a cloud folder, a download)
        let objects = try verify(sizes.filter { needed.contains($0.key) }.map { ($0.key, $0.value) }, in: repository, cache: cache,
                                 budgetBytes: .max, isCancelled: isCancelled, progress: progress)
        return ArchiveCheck(snapshots: ids.count, unreadableSnapshots: unreadable, missingObjects: missing, objects: objects)
    }
}
