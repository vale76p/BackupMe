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
        // a pool per object: every read would otherwise stay in memory until the whole check ends. The copy checked is the
        // one the kit reads first: a damaged one the app would read past is still a file the kit marks damaged
        if try autoreleasepool(invoking: { try repository.firstCopyVerifies(hash) }) { continue }
        if try autoreleasepool(invoking: { try repository.rewriteFromAnotherCopy(hash) }) {
            r.repaired.append(hash)
        } else if let p = cache.path(for: hash), (try? repository.repairObject(hash, from: URL(fileURLWithPath: p))) == true {
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
    /// Containers that don't parse: the objects in them are reported missing or are stored again by a backup.
    public var damagedPacks: [String]

    public var isHealthy: Bool { unreadableSnapshots.isEmpty && missingObjects == 0 && objects.corrupt.isEmpty && damagedPacks.isEmpty }
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
        var damagedPacks: [String] = []
        for id in try repository.packIDs() {
            if isCancelled() { throw BackupError.cancelled }
            Activity.beat()
            // a container that can't be read throws: not read is not damaged
            do { try autoreleasepool { try repository.scanPack(id) } } catch RepositoryError.damagedPack { damagedPacks.append(id) }
        }
        let sizes = try repository.objectSizes()
        let missing = needed.subtracting(sizes.keys).count
        // only what a backup uses: objects no manifest needs go at the next cleanup, reading them is a waste
        // (on a cloud folder, a download)
        let objects = try verify(sizes.filter { needed.contains($0.key) }.map { ($0.key, $0.value) }, in: repository, cache: cache,
                                 budgetBytes: .max, isCancelled: isCancelled, progress: progress)
        return ArchiveCheck(snapshots: ids.count, unreadableSnapshots: unreadable, missingObjects: missing, objects: objects, damagedPacks: damagedPacks)
    }
}

public struct UpgradeReport: Equatable, Sendable {
    /// Fixed on its own: only what can be rebuilt (restore kit, repo.json, temporary files).
    public var fixed: [String]
    /// Found and left as it is: nothing is deleted or followed, the user decides ("Controlla ora", "Elimina…").
    public var attention: [String]
    /// false when some manifests couldn't be read at all (offline cloud files): the check runs again at the next backup.
    public var complete = true

    public var isClean: Bool { fixed.isEmpty && attention.isEmpty }
}

/// The light check after an update: repo.json, objects/ and snapshots/ as listed, every manifest against its checksum,
/// and what opening the archive for a backup fixed (kit, repo.json). Stored objects are never read: on OneDrive or
/// iCloud that would download the whole archive, which only "Controlla ora" does. An archive of a newer format
/// throws `newerFormat` before any write.
public func upgradeCheck(repository: Repository) throws -> UpgradeReport {
    try repository.withLock {
        let fm = FileManager.default
        var r = UpgradeReport(fixed: repository.restoreKitChanges, attention: [])
        if repository.repairedInfo {
            r.fixed.append("repo.json, il file che identifica l'archivio, era illeggibile: riscritto")
        } else if repository.archiveID == nil {
            r.attention.append("repo.json, il file che identifica l'archivio, non si legge (forse non ancora scaricato dal cloud)")
        }
        do {
            let n = try repository.removeTemporaryFiles()
            if n > 0 { r.fixed.append(n == 1 ? "Rimosso 1 file temporaneo rimasto da un backup interrotto" : "Rimossi \(n) file temporanei rimasti da backup interrotti") }
        } catch {
            r.attention.append("File temporanei rimasti nell'archivio non rimossi: \(error.localizedDescription)")
        }
        func examples(_ names: [String]) -> String { names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "") }

        // hidden names (.DS_Store of the Finder, cloud placeholders) are the system's, not strays
        let objects = repository.root.appending(path: "objects", directoryHint: .isDirectory)
        var strays: [String] = []
        for dir in try fm.contentsOfDirectory(atPath: objects.path).sorted() where !dir.hasPrefix(".") {
            let d = objects.appending(path: dir)
            // the item itself, never what a link points to
            guard (try? fm.attributesOfItem(atPath: d.path)[.type] as? FileAttributeType) == .typeDirectory, dir.utf8.count == 2,
                  dir.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { strays.append("objects/\(dir)"); continue }
            Activity.beat()
            // types from the listing itself (getattrlistbulk): no stat, and no read, per object
            autoreleasepool {
                for url in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)) ?? [] {
                    let name = url.lastPathComponent, hash = (name as NSString).deletingPathExtension
                    if ["lzfse", "raw"].contains((name as NSString).pathExtension), Repository.isHash(hash), hash.hasPrefix(dir),
                       (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { continue }
                    strays.append("objects/\(dir)/\(name)")
                }
            }
        }
        if !strays.isEmpty {
            r.attention.append("Elementi estranei in objects/ (\(strays.count)): collegamenti, cartelle o nomi che non sono di un file "
                + "salvato, lasciati dove sono e mai seguiti: \(examples(strays))")
        }

        // containers: only <16 hex>.pack and .idx files; a missing packs/ is an archive without containers
        let packs = repository.root.appending(path: "packs", directoryHint: .isDirectory)
        let packStrays = ((try? fm.contentsOfDirectory(atPath: packs.path)) ?? []).sorted().filter { name in
            guard !name.hasPrefix(".") else { return false }
            let ext = (name as NSString).pathExtension
            return !(["pack", "idx"].contains(ext) && Repository.isPackID((name as NSString).deletingPathExtension)
                && (try? fm.attributesOfItem(atPath: packs.appending(path: name).path)[.type] as? FileAttributeType) == .typeRegular)
        }.map { "packs/\($0)" }
        if !packStrays.isEmpty {
            r.attention.append("Elementi estranei in packs/ (\(packStrays.count)): collegamenti, cartelle o nomi che non sono di un contenitore, "
                + "lasciati dove sono e mai seguiti: \(examples(packStrays))")
        }

        let snapshots = repository.root.appending(path: "snapshots", directoryHint: .isDirectory)
        var unnamed: [String] = [], damaged: [String] = [], unread: [String] = []
        for name in try fm.contentsOfDirectory(atPath: snapshots.path).sorted() where !name.hasPrefix(".") {
            let id = String(name.dropLast(11))
            guard name.hasSuffix(".json.lzfse"), Snapshot.date(fromID: id) != nil,
                  (try? fm.attributesOfItem(atPath: snapshots.appending(path: name).path)[.type] as? FileAttributeType) == .typeRegular
            else { unnamed.append("snapshots/\(name)"); continue }
            Activity.beat()
            // the checksum as a stream; a manifest from before it (0.9.1 and earlier) is decoded whole
            // unreadable is not damaged: a manifest only in the cloud, without network, would push to delete a sound backup
            if !repository.snapshotIsIntact(id) {
                if (try? Data(contentsOf: snapshots.appending(path: name))) == nil { unread.append(id) } else { damaged.append(id) }
            }
        }
        if !damaged.isEmpty {
            let dates = damaged.map { Snapshot.date(fromID: $0)?.formatted(date: .abbreviated, time: .shortened) ?? $0 }
            r.attention.append("\(BackupEngine.damagedPrefix) " + (damaged.count == 1
                ? "il backup del \(dates[0]) non si legge e non si può ripristinare. Dopo «Controlla ora» lo elimini"
                : "\(damaged.count) backup non si leggono e non si possono ripristinare (\(examples(dates))). Dopo «Controlla ora» li elimini")
                + " da Impostazioni › Avanzate.")
        }
        if !unread.isEmpty {
            r.complete = false
            r.attention.append(unread.count == 1
                ? "1 indice dei backup non si è potuto leggere (forse non ancora scaricato dal cloud): la verifica riparte al prossimo backup"
                : "\(unread.count) indici dei backup non si sono potuti leggere (forse non ancora scaricati dal cloud): la verifica riparte al prossimo backup")
        }
        if !unnamed.isEmpty {
            r.attention.append("Elementi in snapshots/ con un nome che non è di un backup (\(unnamed.count)), lasciati dove sono: \(examples(unnamed))")
        }
        return r
    }
}

/// `upgradeCheck` once per build and archive: nil when `build` already checked it. Remembered only after a check
/// that ran to the end, so one stopped by an unplugged disk runs again at the next backup.
public func upgradeCheckIfNeeded(repository: Repository, build: String, defaults: UserDefaults = .standard) throws -> UpgradeReport? {
    let key = "upgradeCheckedBuild-\(repository.root.path)"
    guard defaults.string(forKey: key) != build else { return nil }
    // a new archive (first backup ever, or a new destination) holds nothing from an earlier version: nothing to report
    if try repository.snapshotIDs().isEmpty { defaults.set(build, forKey: key); return nil }
    let report = try upgradeCheck(repository: repository)
    if report.complete { defaults.set(build, forKey: key) }
    return report
}
