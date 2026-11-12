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
/// `ids`: the manifests still listed. Returns the single-file objects and the files deleted, and the small single-file
/// objects still there when `convert` counted them.
func deleteCondemned(_ plan: CleanupPlan, ids: [String], repository: Repository, refsCache: URL?, collected: Bool,
                     capBytes: Int64?, convert: Bool, left: inout Int,
                     confirmed: (String) -> Bool) throws -> (objects: Int, files: Int, smallLeft: Int?) {
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
        return (0, 0, nil)
    }

    // 6. condemned objects with no copy in a container; one in a container is judged with its container below
    try repository.loadPackIndex()
    var objects = 0, files = 0, gone: [String] = []
    for h in condemned where repository.packOf(h) == nil {
        guard left > 0 else { break }
        Activity.beat()
        // every file counts: an object stored in both forms costs 2, and one left by the budget waits in the plan
        let (removed, kept) = try repository.deleteObject(h, limit: left)
        files += removed
        left -= removed
        if !kept { gone.append(h); if removed > 0 { objects += 1 } }
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

    // 9. compaction: nothing is deleted here, the old container is dead from now on and step 7 takes it
    try repository.loadPackIndex()
    var packs: [(id: String, live: [String], liveBytes: Int, dead: Int, small: Bool)] = []
    for id in try repository.packIDs() {
        guard let entries = repository.wholePackEntries(id) else { continue }
        var seen = Set<String>()
        let live = entries.filter { repository.packOf($0.hash) == id && !condemned.contains($0.hash) && seen.insert($0.hash).inserted }
        guard !live.isEmpty else { continue } // dead: step 7's
        let liveBytes = live.reduce(0) { $0 + $1.length }
        packs.append((id, live.map(\.hash), liveBytes, entries.reduce(0) { $0 + $1.length } - liveBytes,
                      repository.packSize(id) < Int64(Repository.packTarget / 4)))
    }
    let over = try packs.contains { $0.dead > 0 } && (capBytes.map { try repository.poolSize() > $0 } ?? false)
    let smalls = packs.filter(\.small)
    var picked: [(id: String, live: [String], liveBytes: Int, dead: Int, small: Bool)] = [], bytes = 0
    for p in packs.filter({ $0.liveBytes < $0.dead || ($0.dead > 0 && over) }).sorted(by: { $0.dead > $1.dead })
        + (smalls.count >= 8 ? smalls : []) where bytes < Repository.packTarget && !picked.contains(where: { $0.id == p.id }) {
        picked.append(p)
        bytes += p.liveBytes
    }
    while !picked.isEmpty {
        do { try repository.repack(picked.flatMap(\.live)); break } catch RepositoryError.corruptObject(let h) {
            // a container with a live object that doesn't read stays where it is
            guard let i = picked.firstIndex(where: { $0.live.contains(h) }) else { break }
            picked.remove(at: i)
        } catch { break } // out of reach now (an offline file): tried again at the next call
    }

    // 10. conversion: small single-file objects copied into containers, then deleted as duplicates
    var smallLeft: Int?
    if convert && !plan.conversionDone {
        try repository.loadPackIndex()
        let loose = try repository.looseObjectSizes()
        let small = loose.filter { $0.value < Int64(Repository.packThreshold) }
        let doubles = loose.keys.filter { repository.packOf($0) != nil }
        var doublesLeft = doubles.count, smallGone = 0
        do {
            for h in doubles {
                guard left > 0 else { break }
                // the copy that counts, relied on and read back now: a file written to repair a damaged copy is the good one
                guard let copy = try repository.packIndex()[h], confirmed(copy.pack),
                      try repository.readPacked(h, copy.entry, in: copy.pack) != nil else { continue }
                Activity.beat()
                let (removed, kept) = try repository.deleteObject(h, limit: left)
                files += removed
                left -= removed
                if !kept { doublesLeft -= 1; smallGone += small[h] == nil ? 0 : 1; if removed > 0 { objects += 1 } }
            }
        } catch {} // out of reach now: the duplicates wait, and so does the next container
        smallLeft = small.count - smallGone
        let candidates = small.keys.filter { !condemned.contains($0) && repository.packOf($0) == nil }
        if collected && doubles.isEmpty && candidates.isEmpty { plan.conversionDone = true }
        // one container at a time: the next only once the copies of the last have left, and never over the cap
        if doublesLeft == 0, !candidates.isEmpty, try capBytes.map({ try repository.poolSize() <= $0 }) ?? true {
            let newest = (try? ids.last.map { try references(of: $0, in: repository, cache: refsCache) } ?? []) ?? []
            var take: [String] = [], bytes: Int64 = 0
            // the newest backup first: its files are the ones a restore asks for
            for h in candidates.filter(newest.contains) + candidates.filter({ !newest.contains($0) })
            where bytes + small[h]! <= Int64(Repository.packTarget) {
                take.append(h)
                bytes += small[h]!
            }
            while !take.isEmpty {
                do { try repository.repack(take); break } catch RepositoryError.corruptObject(let h) {
                    // never converted, never deleted: the others go on
                    guard let i = take.firstIndex(of: h) else { break }
                    take.remove(at: i)
                } catch { break }
            }
        }
    }

    // 11.
    if let refsCache, collected || !gone.isEmpty {
        plan.condemned = Array(condemned)
        try? JSONEncoder().encode(plan).write(to: CleanupPlan.url(in: refsCache), options: .atomic)
    }
    return (objects, files, smallLeft)
}

/// When the conversion ends at the pace kept since `startDate`; nil when nothing has left yet.
public func conversionEnd(startCount: Int, startDate: Date, left: Int, now: Date) -> Date? {
    let done = startCount - left, elapsed = now.timeIntervalSince(startDate)
    guard done > 0, elapsed > 0 else { return nil }
    return startDate.addingTimeInterval(elapsed * Double(startCount) / Double(done))
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
