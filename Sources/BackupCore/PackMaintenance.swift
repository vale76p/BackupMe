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
/// `ids`: the manifests still listed. `room`: the bytes the cap still allows on disk (negative over it), nil without a
/// cap; `sizes`: the objects' sizes from the listing `room` was counted on. Returns the single-file objects and the files
/// deleted, and the small single-file objects still to convert when `convert` counted them.
func deleteCondemned(_ plan: CleanupPlan, ids: [String], repository: Repository, refsCache: URL?, collected: Bool,
                     room: Int64?, sizes: [String: Int64], convert: Bool, left: inout Int,
                     confirmed ask: (String) -> Bool) throws -> (objects: Int, files: Int, smallLeft: Int?) {
    var plan = plan, condemned = Set(plan.condemned), room = room
    let planned = condemned.count
    // 5. a backup made since the collection may use a condemned object (one that wasn't told, or reused it anyway)
    let known = Set(plan.snapshots), checked = ids.filter { !known.contains($0) }
    do {
        for id in checked {
            Activity.beat()
            condemned.subtract(try references(of: id, in: repository, cache: refsCache))
        }
    } catch {
        // a manifest that can't be read may use any of them: nothing is deleted until it reads or the next collection
        return (0, 0, nil)
    }
    // asked once per container in this call: in a cloud folder whose client says nothing each answer lists the clients
    var answers: [String: Bool] = [:]
    func confirmed(_ id: String) -> Bool { if answers[id] == nil { answers[id] = ask(id) }; return answers[id]! }

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
        if removed > 0 { room? += sizes[h] ?? 0 }
        if !kept { gone.append(h); if removed > 0 { objects += 1 } }
    }
    condemned.subtract(gone)

    /// The copy that counts reads back now from its own container, never from another: what is relied on when a copy goes.
    func readsBack(_ h: String) throws -> Bool {
        guard let copy = try repository.packIndex()[h] else { return false }
        return try repository.readPacked(h, copy.entry, in: copy.pack) != nil
    }

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
        // a copy damaged since it was written is never relied on; out of reach: the next call
        guard (try? used.allSatisfy { try readsBack($0.hash) }) == true else { continue }
        let freed = repository.packSize(id)
        try repository.deletePack(id)
        files += 2
        left -= 2
        room? += freed
        // not loaded: `packOf` answers nil, and nothing more is deleted on that doubt
        try? repository.loadPackIndex()
    }

    // 9 and 10 are opportunistic: an error ends them, what 6 and 7 deleted stays counted and the plan is saved below
    var smallLeft: Int?
    do {
        // 9. compaction: nothing is deleted here, the old container is dead from now on and step 7 takes it. Judged on the
        // index in memory and the containers' sizes, bytes on disk with the record headers: only a chosen one's index is read again
        var counting: [String: [(hash: String, length: Int)]] = [:]
        for (h, copy) in try repository.packIndex() where !condemned.contains(h) {
            counting[copy.pack, default: []].append((h, copy.entry.length))
        }
        typealias Candidate = (id: String, live: [String], liveBytes: Int64, dead: Int64, size: Int64)
        var packs: [Candidate] = []
        for id in try repository.packIDs() {
            guard let entries = counting[id] else { continue } // dead: step 7's
            let pack = repository.packFileSize(id, "pack")
            let liveBytes = Int64(entries.reduce(0) { $0 + Pack.headerSize + $1.length })
            packs.append((id, entries.map(\.hash), liveBytes, pack - Int64(Pack.magic.count) - liveBytes,
                          pack + repository.packFileSize(id, "idx")))
        }
        let over = packs.contains { $0.dead > 0 } && (room.map { $0 < 0 } ?? false)
        let smalls = packs.filter { $0.size < Int64(Repository.packTarget / 4) }
        var picked: [Candidate] = [], bytes: Int64 = 0
        // a read downloads whole containers: what one call reads is capped at a container's worth, one always allowed
        for p in packs.filter({ $0.liveBytes < $0.dead || ($0.dead > 0 && over) }).sorted(by: { $0.dead > $1.dead })
            + (smalls.count >= 8 ? smalls : [])
        where (picked.isEmpty || bytes + p.size <= Int64(Repository.packTarget)) && !picked.contains(where: { $0.id == p.id })
            // never one whose index is not whole: what it holds beyond it is unknown
            && repository.wholePackEntries(p.id) != nil {
            picked.append(p)
            bytes += p.size
        }
        while !picked.isEmpty {
            do {
                try repository.repack(picked.flatMap(\.live))
                room? -= picked.reduce(0) { $0 + $1.liveBytes }
                break
            } catch RepositoryError.corruptObject(let h) {
                // a container with a live object that doesn't read stays where it is
                guard let i = picked.firstIndex(where: { $0.live.contains(h) }) else { break }
                picked.remove(at: i)
            } catch { break } // out of reach now (an offline file): tried again at the next call
        }

        // 10. conversion: small single-file objects copied into containers, then deleted as duplicates
        if convert && !plan.conversionDone {
            try repository.loadPackIndex()
            let loose = try repository.looseObjectSizes()
            let small = loose.filter { $0.value < Int64(Repository.packThreshold) }
            let doubles = loose.keys.filter { repository.packOf($0) != nil }
            var doublesLeft = doubles.count
            for h in doubles {
                guard left > 0 else { break }
                // a file written to repair a damaged copy in a container is the good one
                guard let pack = repository.packOf(h), confirmed(pack), try readsBack(h) else { continue }
                Activity.beat()
                let (removed, kept) = try repository.deleteObject(h, limit: left)
                files += removed
                left -= removed
                if removed > 0 { room? += loose[h] ?? 0 }
                if !kept { doublesLeft -= 1; if removed > 0 { objects += 1 } }
            }
            let candidates = small.keys.filter { !condemned.contains($0) && repository.packOf($0) == nil }
            // the condemned ones wait for the budget, not for the conversion: 0 when the conversion is done
            smallLeft = candidates.count + doublesLeft
            if collected && doubles.isEmpty && candidates.isEmpty { plan.conversionDone = true }
            // one container at a time: the next only once the copies of the last have left, and never over the cap
            if doublesLeft == 0, !candidates.isEmpty, room.map({ $0 >= 0 }) ?? true {
                let newest = (try? ids.last.map { try references(of: $0, in: repository, cache: refsCache) } ?? []) ?? []
                var take: [String] = [], bytes: Int64 = 0
                // the newest backup first: its files are the ones a restore asks for. Each record has a header, and the
                // container is published at packTarget: kept below it, all of them go into one
                for h in candidates.filter(newest.contains) + candidates.filter({ !newest.contains($0) })
                where bytes + small[h]! + Int64(Pack.headerSize) < Int64(Repository.packTarget - Pack.magic.count) {
                    take.append(h)
                    bytes += small[h]! + Int64(Pack.headerSize)
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
    } catch {}

    // 11. saved also when a newer backup took objects off the list, or `hasObject` stores them again at every backup. The
    // plan's manifests become those listed, the ones checked in 5 included: the saved list never names an object one of
    // them uses, and one that left and comes back is read again
    if let refsCache, collected || condemned.count < planned {
        plan.condemned = Array(condemned)
        plan.snapshots = ids
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
