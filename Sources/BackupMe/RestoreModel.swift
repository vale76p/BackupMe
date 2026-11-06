import AppKit
import BackupCore
import Foundation

struct SearchHit: Hashable, Identifiable {
    var snapshotID: String
    var entry: Entry
    var id: Self { self }
}

/// A row against this Mac's disk; folders also say whether something inside them changed or disappeared.
struct RowStatus: Equatable, Sendable {
    var own: EntryStatus
    var modifiedInside = false
    var missingInside = false
}

enum ChangeFilter: String, CaseIterable { case all, modified, missing, added }

@MainActor @Observable final class RestoreModel {
    let app: AppModel
    var computers: [String] = []
    var computer = AppPaths.archiveName { didSet { if computer != oldValue { reload() } } }
    var snapshots: [(id: String, date: Date)] = []
    var selectedID: String? { didSet { load(selectedID) } }
    var source: String?
    var currentPath = ""
    var search = "" { didSet { searchChanged() } }
    var results: [SearchHit] = []
    /// Search hits against this Mac's disk, filled in as the search goes: "deleted" means missing today.
    var resultStatus: [SearchHit: EntryStatus] = [:]
    var resultsTruncated = false
    /// Selected once "Mostra nel backup" has opened its folder.
    var pendingSelection: Entry.ID?
    /// Search progress only; a restore has its own flag so neither can cancel or block the other.
    var busy: String?
    var restoring = false
    var error: (title: String, message: String)?
    /// True until the snapshot list arrives: "no backups" must not flash while it loads.
    var isLoading = true
    /// Only the few snapshots opened recently stay in memory: one manifest can be tens of MB.
    private var loaded: [String: Snapshot] = [:]
    private var loadOrder: [String] = []
    /// snapshot id → source → parent path → children, built once off the main thread
    private var index: [String: [String: [String: [Entry]]]] = [:]
    /// snapshot id + source + folder → entry id → status against this Mac's disk, computed once per folder
    private var statuses: [String: [String: RowStatus]] = [:]
    /// Per folder: what is on this Mac's disk now but not in the backup (and not excluded), as rows without content.
    private var addedItems: [String: [Entry]] = [:]
    private var searchTask: Task<Void, Never>?
    /// Bumped on reload: results of tasks started for another computer or destination are dropped.
    private var generation = 0

    init(app: AppModel) { self.app = app }

    var selected: Snapshot? { selectedID.flatMap { loaded[$0] } }
    var sources: [String] { selected?.sources ?? [] }
    var hasDestination: Bool { destination != nil }
    /// Comparing with this Mac's disk is meaningless for another computer's archive.
    var showsStatus: Bool { computer == AppPaths.archiveName }

    private var destination: URL? { app.settings.destination.map { URL(fileURLWithPath: $0) } }

    /// Runs `body` off the main thread with the chosen computer's archive (opened, never created).
    private func withRepository<T: Sendable>(_ body: @escaping @Sendable (Repository) throws -> T) async throws -> T {
        guard let dest = destination else { throw RepositoryError.destinationMissing("") }
        let computer = computer
        return try await Task.detached(priority: .userInitiated) {
            try body(try Repository(destination: dest, computerName: computer, create: false))
        }.value
    }

    func reload() {
        guard let dest = destination else {
            generation += 1; computers = []; snapshots = []; selectedID = nil; isLoading = false; return
        }
        computers = Repository.computers(in: dest)
        if !computers.contains(computer), let first = computers.first { computer = first; return }
        generation += 1
        let gen = generation
        searchTask?.cancel()
        results = []
        loaded = [:]
        loadOrder = []
        index = [:]
        statuses = [:]
        addedItems = [:]
        snapshots = []
        selectedID = nil
        isLoading = true
        Task {
            do {
                let ids = try await withRepository { try $0.snapshotIDs() }
                guard gen == generation else { return }
                snapshots = ids.reversed().compactMap { id in Snapshot.date(fromID: id).map { (id, $0) } }
                selectedID = snapshots.first?.id
            } catch RepositoryError.destinationMissing where computers.isEmpty {
                // no archive yet: the window shows its empty state, not an alert
            } catch { if gen == generation { self.error = ("Impossibile aprire il backup", AppModel.describe(error)) } }
            if gen == generation { isLoading = false }
        }
    }

    private func load(_ id: String?) {
        guard let id, loaded[id] == nil else { fixSource(); return }
        let gen = generation
        Task {
            do {
                let snapshot = try await withRepository { try $0.readSnapshot(id) }
                let built = await Task.detached(priority: .userInitiated) { Self.buildIndex(snapshot) }.value
                guard gen == generation else { return }
                loaded[id] = snapshot
                index[id] = built
                loadOrder.append(id)
                while loadOrder.count > 3 {
                    let old = loadOrder.removeFirst()
                    if old != selectedID { loaded[old] = nil; index[old] = nil } else { loadOrder.append(old) }
                }
                fixSource()
            } catch { if gen == generation { self.error = ("Impossibile aprire il backup", AppModel.describe(error)) } }
        }
    }

    /// nil source = the top level, which lists the saved folders themselves.
    private func fixSource() {
        if let s = source, !sources.contains(s) { source = nil; currentPath = "" }
        // a folder missing from this backup falls back to its nearest saved parent, not an empty table
        guard let id = selectedID, let s = source, let tree = index[id] else { return }
        let dirs = tree[s] ?? [:]
        while !currentPath.isEmpty {
            let parent = (currentPath as NSString).deletingLastPathComponent
            if dirs[parent]?.contains(where: { $0.path == currentPath && $0.kind == .directory }) == true { break }
            currentPath = parent
        }
    }

    func children() -> [Entry] {
        guard let id = selectedID else { return [] }
        return index[id]?[source ?? ""]?[source == nil ? "" : currentPath] ?? []
    }

    func status(of e: Entry) -> RowStatus? { statuses[folderKey]?[e.id] }

    /// nil while the folder's status is still being computed.
    var statusReady: Bool { !showsStatus || (statuses[folderKey] != nil && (source == nil || addedItems[folderKey] != nil)) }

    func added() -> [Entry] { addedItems[folderKey] ?? [] }
    func isAdded(_ e: Entry) -> Bool { e.kind != .directory && e.hash == nil && e.linkTarget == nil && added().contains(e) }

    private var folderKey: String { "\(selectedID ?? "")\u{0}\(source ?? "")\u{0}\(currentPath)" }

    /// Stats the folder being viewed off the main thread, once: table redraws only read the cache.
    func refreshStatus() async {
        guard showsStatus, selected != nil else { return }
        let key = folderKey, gen = generation
        guard statuses[key] == nil else { return }
        let rows = children()
        guard let tree = selectedID.flatMap({ index[$0] }) else { return }
        let found = await Task.detached(priority: .utility) {
            Dictionary(rows.map { ($0.id, Self.rowStatus($0, tree: tree)) }, uniquingKeysWith: { a, _ in a })
        }.value
        if gen == generation, !Task.isCancelled { statuses[key] = found }
        guard let source else { return }
        let folder = currentPath, rules = ExcludeRules(patterns: app.settings.excludes)
        let new = await Task.detached(priority: .utility) { Self.addedSince(rows, source: source, folder: folder, rules: rules) }.value
        if gen == generation, !Task.isCancelled { addedItems[key] = new }
    }

    /// Disk items of a folder that the backup lacks, skipping what the backup would exclude (same rules as today).
    nonisolated private static func addedSince(_ rows: [Entry], source: String, folder: String, rules: ExcludeRules) -> [Entry] {
        let dir = folder.isEmpty ? source : source + "/" + folder
        let known = Set(rows.map(\.name))
        let inGit = folder == ".git" || folder.hasPrefix(".git/") || folder.contains("/.git/") || folder.hasSuffix("/.git")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.sorted().compactMap { name in
            guard !known.contains(name) else { return nil }
            let path = folder.isEmpty ? name : folder + "/" + name
            let url = URL(fileURLWithPath: dir).appending(path: name)
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            else { return nil }
            let isDir = v.isDirectory == true && v.isSymbolicLink != true
            if !inGit, rules.excludes(name: name, isDirectory: isDir, path: path) { return nil }
            return Entry(source: source, path: path, kind: isDir ? .directory : v.isSymbolicLink == true ? .symlink : .file,
                         hash: nil, size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate ?? .distantPast,
                         mode: 0, linkTarget: nil)
        }
    }

    /// A folder walks what the backup holds inside it (excluded folders aren't there), stopping once both flags are set.
    nonisolated private static func rowStatus(_ e: Entry, tree: [String: [String: [Entry]]]) -> RowStatus {
        var r = RowStatus(own: Restorer.status(of: e))
        guard e.kind == .directory, r.own != .missing else { return r } // a missing folder: all of it is missing
        var stack = tree[e.source]?[e.path] ?? []
        while !(r.modifiedInside && r.missingInside), let c = stack.popLast() {
            switch Restorer.status(of: c) {
            case .missing: r.missingInside = true; continue
            case .modified where c.kind != .directory: r.modifiedInside = true
            default: break
            }
            if c.kind == .directory { stack += tree[c.source]?[c.path] ?? [] }
        }
        return r
    }

    nonisolated private static func buildIndex(_ s: Snapshot) -> [String: [String: [Entry]]] {
        var result: [String: [String: [Entry]]] = [:]
        for e in s.entries {
            // the saved folders themselves go under "" (never an absolute source path): the top level
            if e.path.isEmpty { result["", default: [:]]["", default: []].append(e); continue }
            result[e.source, default: [:]][(e.path as NSString).deletingLastPathComponent, default: []].append(e)
        }
        for (source, dirs) in result {
            for (parent, list) in dirs {
                result[source]![parent] = list.sorted {
                    ($0.kind == .directory ? 0 : 1, $0.name.lowercased()) < ($1.kind == .directory ? 0 : 1, $1.name.lowercased())
                }
            }
        }
        return result
    }

    /// Debounced search of file and folder names across every snapshot, newest first. Manifests are read one at a
    /// time and released, so memory stays at one manifest; each distinct version of an item appears once.
    /// shortcut: every query re-reads the manifests; add a persistent name index if searches feel slow.
    private func searchChanged() {
        searchTask?.cancel()
        let query = search.lowercased()
        resultsTruncated = false
        guard !query.isEmpty else { results = []; resultStatus = [:]; busy = nil; return }
        let ids = snapshots.map(\.id)
        let gen = generation
        let compare = showsStatus
        busy = "Cerco…" // set now: during the debounce the window would show "no results"
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            var hits: [SearchHit] = []
            var seen = Set<String>()
            for (n, id) in ids.enumerated() {
                guard !Task.isCancelled, gen == generation, hits.count < 500 else { break }
                busy = "Cerco in \(n + 1) di \(ids.count) backup…"
                let found = (try? await withRepository { repo in
                    try autoreleasepool { try repo.readSnapshot(id).entries.filter { !$0.path.isEmpty && $0.name.lowercased().contains(query) } }
                }) ?? []
                var new: [SearchHit] = []
                // symlinks keyed by target too: two links with different targets are different versions
                for e in found where seen.insert("\(e.source)\u{0}\(e.path)\u{0}\(e.hash ?? e.linkTarget ?? "dir")").inserted {
                    new.append(SearchHit(snapshotID: id, entry: e))
                }
                hits += new
                results = hits
                if compare, !new.isEmpty {
                    let found = await Task.detached(priority: .utility) { new.map { ($0, Restorer.status(of: $0.entry)) } }.value
                    guard gen == generation, !Task.isCancelled else { break }
                    for (h, s) in found { resultStatus[h] = s }
                }
            }
            if !Task.isCancelled {
                busy = nil
                resultsTruncated = hits.count >= 500
            }
        }
    }

    func versions(of entry: Entry) async -> [(snapshotID: String, entry: Entry)] {
        (try? await withRepository { try Restorer(repository: $0).versions(source: entry.source, path: entry.path) }) ?? []
    }

    func restore(snapshotID: String, source: String, path: String, mode: RestoreMode) {
        restore(snapshotID: snapshotID, items: [(source, path)], mode: mode)
    }

    /// Restores several items from one backup in a row; one failing doesn't stop the others.
    func restore(snapshotID: String, items: [(source: String, path: String)], mode: RestoreMode) {
        guard !restoring else { error = ("Ripristino non riuscito", "Un ripristino è già in corso: attendi che finisca"); return }
        guard !items.isEmpty else { return }
        restoring = true
        Log.restore.info("Ripristino dal backup \(snapshotID) (\(mode)): \(items.map { $0.path.isEmpty ? $0.source : $0.source + "/" + $0.path }.joined(separator: ", "))")
        Task {
            let outcome = await (try? withRepository { repo -> ([URL], [String]) in
                let snapshot = try repo.readSnapshot(snapshotID)
                let restorer = Restorer(repository: repo)
                var done: [URL] = [], failed: [String] = []
                for item in items {
                    do { done.append(try restorer.restore(snapshot, source: item.source, path: item.path, mode: mode)) }
                    catch { failed.append(AppModel.describe(error)) }
                }
                return (done, failed)
            }) ?? ([], ["Impossibile aprire il backup"])
            Log.restore.debug("Ripristinati: \(outcome.0.map(\.path).joined(separator: ", "))")
            for e in outcome.1 { Log.restore.error("Ripristino non riuscito: \(e)") }
            if !outcome.0.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outcome.0) }
            if let first = outcome.1.first {
                let more = outcome.1.count > 1 ? " (e altri \(outcome.1.count - 1) errori)" : ""
                error = ("Ripristino non riuscito", first + more)
            }
            restoring = false
        }
    }

    /// A read-only temporary copy for Quick Look or comparing; nil (with an error shown) if it can't be read.
    func extracted(_ e: Entry) async -> URL? {
        do { return try await withRepository { try Restorer(repository: $0).extract(e) } } catch {
            self.error = ("Anteprima non disponibile", AppModel.describe(error))
            return nil
        }
    }

    /// Opens the backed-up and current versions side by side in FileMerge (it comes with Xcode); the merge result
    /// goes to a temporary file, so saving in FileMerge never touches the real one. Without it, shows both in the Finder.
    func compare(_ e: Entry) {
        Task {
            guard let copy = await extracted(e) else { return }
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FileMerge") else {
                NSWorkspace.shared.activateFileViewerSelecting([copy, e.url])
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            // a new instance: a running FileMerge would ignore the arguments
            config.createsNewApplicationInstance = true
            config.arguments = ["-left", copy.path, "-right", e.url.path,
                                "-merge", copy.deletingLastPathComponent().appending(path: "unione-" + e.name).path]
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
    }

    /// A writable copy named "<name> (ripristinato …)" for dragging into the Finder: dropped back in its own
    /// folder it lands beside the original instead of offering to replace it.
    func dragCopy(_ e: Entry) async -> URL? {
        guard let copy = await extracted(e), let date = selected?.date else { return nil }
        let url = copy.deletingLastPathComponent().appending(path: "trascina", directoryHint: .isDirectory)
            .appending(path: Restorer.restoredName(e.name, date: date))
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: copy, to: url)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Leaves the search and opens the folder holding `hit` in its backup, with it selected.
    func reveal(_ hit: SearchHit) {
        search = ""
        // source and folder first: changing the backup checks them against it
        source = hit.entry.source
        currentPath = (hit.entry.path as NSString).deletingLastPathComponent
        pendingSelection = hit.entry.id
        selectedID = hit.snapshotID
    }

    func replaceCheck(source: String) async -> Restorer.ReplaceCheck? {
        guard showsStatus, let snapshot = selected else { return nil }
        return await Task.detached(priority: .userInitiated) { Restorer.replaceCheck(snapshot, source: source) }.value
    }
}
