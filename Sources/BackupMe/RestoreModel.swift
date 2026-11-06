import AppKit
import BackupCore
import Foundation

struct SearchHit: Hashable, Identifiable {
    var snapshotID: String
    var entry: Entry
    var id: Self { self }
}

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
    /// Search progress only; a restore has its own flag so neither can cancel or block the other.
    var busy: String?
    var restoring = false
    var error: String?
    /// True until the snapshot list arrives: "no backups" must not flash while it loads.
    var isLoading = true
    /// Only the few snapshots opened recently stay in memory: one manifest can be tens of MB.
    private var loaded: [String: Snapshot] = [:]
    private var loadOrder: [String] = []
    /// snapshot id → source → parent path → children, built once off the main thread
    private var index: [String: [String: [String: [Entry]]]] = [:]
    private var searchTask: Task<Void, Never>?
    /// Bumped on reload: results of tasks started for another computer or destination are dropped.
    private var generation = 0

    init(app: AppModel) { self.app = app }

    var selected: Snapshot? { selectedID.flatMap { loaded[$0] } }
    var sources: [String] { selected?.sources ?? [] }

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
        guard let dest = destination else { error = "Nessuna destinazione configurata"; isLoading = false; return }
        computers = Repository.computers(in: dest)
        if !computers.contains(computer), let first = computers.first { computer = first; return }
        generation += 1
        let gen = generation
        searchTask?.cancel()
        results = []
        loaded = [:]
        loadOrder = []
        index = [:]
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
            } catch { if gen == generation { self.error = AppModel.describe(error) } }
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
            } catch { if gen == generation { self.error = AppModel.describe(error) } }
        }
    }

    /// nil source = the top level, which lists the saved folders themselves.
    private func fixSource() {
        if let s = source, !sources.contains(s) { source = nil; currentPath = "" }
    }

    func children() -> [Entry] {
        guard let id = selectedID else { return [] }
        return index[id]?[source ?? ""]?[source == nil ? "" : currentPath] ?? []
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
        guard !query.isEmpty else { results = []; busy = nil; return }
        let ids = snapshots.map(\.id)
        let gen = generation
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
                for e in found where seen.insert("\(e.source)\u{0}\(e.path)\u{0}\(e.hash ?? "dir")").inserted {
                    hits.append(SearchHit(snapshotID: id, entry: e))
                }
                results = hits
            }
            if !Task.isCancelled { busy = nil }
        }
    }

    func versions(of entry: Entry) async -> [(snapshotID: String, entry: Entry)] {
        (try? await withRepository { try Restorer(repository: $0).versions(source: entry.source, path: entry.path) }) ?? []
    }

    func restore(snapshotID: String, source: String, path: String, mode: RestoreMode) {
        guard !restoring else { error = "Un ripristino è già in corso: attendi che finisca"; return }
        restoring = true
        Task {
            do {
                let url = try await withRepository { repo in
                    try Restorer(repository: repo).restore(try repo.readSnapshot(snapshotID), source: source, path: path, mode: mode)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = AppModel.describe(error) }
            restoring = false
        }
    }
}
