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
        var r = VerifyReport(checked: 0, bytes: 0, corrupt: [], repaired: [])
        for (hash, size) in try repository.objectSizes().shuffled() where r.bytes < budgetBytes {
            r.checked += 1
            r.bytes += size
            if try repository.verifyObject(hash) { continue }
            if let p = cache.path(for: hash), (try? repository.repairObject(hash, from: URL(fileURLWithPath: p))) == true {
                r.repaired.append(hash)
            } else {
                r.corrupt.append(hash)
            }
        }
        return r
    }
}
