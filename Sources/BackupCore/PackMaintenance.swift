import Foundation

public struct CleanupOptions {
    public init() {}
    /// Files this call may delete from the destination, of any kind. nil: no limit, as before containers.
    public var maxDeletions: Int? = nil
    /// Move small single-file objects into containers (Task 8).
    public var convert = false
    /// Whether a container can be relied on. nil: `Repository.packIsConfirmed`.
    public var confirmed: ((String) -> Bool)? = nil
}

/// What the last collection found: the manifests it read and the objects none of them uses. Kept in the references
/// cache as `cleanup`, so the calls between two collections delete from it without reading every manifest again.
// shortcut: a JSON list of hashes, a binary file like the references cache when the condemned are millions
struct CleanupPlan: Codable {
    var snapshots: [String]
    var condemned: [String]
    var conversionDone = false

    static func url(in refsCache: URL) -> URL { refsCache.appending(path: "cleanup") }

    /// nil without a plan, and for one that doesn't decode.
    static func read(_ refsCache: URL?) -> CleanupPlan? {
        refsCache.flatMap { try? Data(contentsOf: url(in: $0)) }.flatMap { try? JSONDecoder().decode(CleanupPlan.self, from: $0) }
    }
}

/// The hashes the last collection found unused: what a new backup must not reuse. Empty without a plan.
public func condemnedObjects(refsCache: URL) -> Set<String> { Set(CleanupPlan.read(refsCache)?.condemned ?? []) }

/// Steps 5-11 of `prune`: deletes what `plan` condemns, never more than `left` files, and saves what is left to do.
/// `ids`: the manifests still listed. Returns the single-file objects and the files deleted.
func deleteCondemned(_ plan: CleanupPlan, ids: [String], repository: Repository, refsCache: URL?, collected: Bool,
                     left: inout Int, confirmed: (String) -> Bool) throws -> (objects: Int, files: Int) {
    var plan = plan, condemned = Set(plan.condemned)
    // 5. a backup made since the collection may use a condemned object (one that wasn't told, or reused it anyway)
    let known = Set(plan.snapshots)
    do {
        for id in ids where !known.contains(id) {
            Activity.beat()
            condemned.subtract(try references(of: id, in: repository, cache: refsCache))
        }
    } catch {
        // a manifest that can't be read may use any of them: nothing is deleted until it reads or the next collection
        return (0, 0)
    }

    // 6. condemned objects with no copy in a container; one in a container is judged with its container below
    try repository.loadPackIndex()
    var objects = 0, files = 0, gone: [String] = []
    for h in condemned where repository.packOf(h) == nil {
        guard left > 0 else { break }
        Activity.beat()
        let removed = try repository.deleteObject(h)
        gone.append(h)
        if removed > 0 { objects += 1; files += removed; left -= removed }
    }
    condemned.subtract(gone)

    // 7. dead containers: none of their entries is both the copy that counts and still used
    let live = Set(try repository.packIndex().filter { !condemned.contains($0.key) }.map(\.value.pack))
    for id in try repository.packIDs() where !live.contains(id) {
        guard left >= 2 else { break }
        // judged only on a whole index: one that locates part of its container says nothing of the rest
        guard let entries = repository.wholePackEntries(id) else { continue }
        let used = entries.filter { !condemned.contains($0.hash) }
        // a copy the loaded index doesn't place anywhere counts as this one: never deleted on a doubt
        guard !used.contains(where: { (repository.packOf($0.hash) ?? id) == id }) else { continue }
        // asked container by container: the one the backup just published isn't uploaded yet, and must not stop the others
        guard Set(used.compactMap { repository.packOf($0.hash) }).allSatisfy(confirmed) else { continue }
        Activity.beat()
        try repository.deletePack(id)
        try repository.loadPackIndex()
        files += 2
        left -= 2
    }

    // 9. compaction (Task 8)

    // 10. conversion (Task 8)

    // 11.
    if let refsCache, collected || !gone.isEmpty {
        plan.condemned = Array(condemned)
        try? JSONEncoder().encode(plan).write(to: CleanupPlan.url(in: refsCache), options: .atomic)
    }
    return (objects, files)
}

extension Repository {
    /// Uploaded, when the cloud client says; where it doesn't, in a cloud folder (`CloudFolder.installed()`) once
    /// the container is an hour old, elsewhere at once.
    public func packIsConfirmed(_ id: String, now: Date) -> Bool {
        guard Self.isPackID(id) else { return false }
        let urls = ["pack", "idx"].map { packsDir.appending(path: "\(id).\($0)") }
        let said = urls.compactMap { url -> Bool? in
            let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
            return v?.isUbiquitousItem == true ? v?.ubiquitousItemIsUploaded : nil
        }
        if said.contains(false) { return false }
        if said.count == urls.count { return true }
        let path = root.resolvingSymlinksInPath().path
        guard CloudFolder.installed().contains(where: { path.hasPrefix($0.url.resolvingSymlinksInPath().path + "/") }) else { return true }
        // a client that doesn't say: an hour is what it takes to upload a container, with margin
        guard let date = try? fm.attributesOfItem(atPath: urls[0].path)[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(date) >= 3600
    }
}
