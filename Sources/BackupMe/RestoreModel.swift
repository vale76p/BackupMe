import AppKit
import BackupCore
import Foundation

struct SearchHit: Hashable { var snapshotID: String; var entry: Entry }

@MainActor @Observable final class RestoreModel {
    let app: AppModel
    var computers: [String] = []
    var computer = AppPaths.computerName { didSet { reload() } }
    var snapshots: [(id: String, date: Date)] = []
    var selectedID: String? { didSet { load(selectedID) } }
    var source: String?
    var currentPath = ""
    var search = "" { didSet { searchChanged() } }
    var results: [SearchHit] = []
    var busy: String?
    var error: String?
    private var loaded: [String: Snapshot] = [:]
    /// snapshot id → source → parent path → children, built once off the main thread
    private var index: [String: [String: [String: [Entry]]]] = [:]
    private var loadAll: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    var selected: Snapshot? { selectedID.flatMap { loaded[$0] } }
    var sources: [String] { selected?.sources ?? [] }

    private var destination: URL? { app.settings.destination.map { URL(fileURLWithPath: $0) } }

    /// Runs `body` off the main thread with a fresh Repository for the chosen computer.
    private func withRepository<T: Sendable>(_ body: @escaping @Sendable (Repository) throws -> T) async throws -> T {
        guard let dest = destination else { throw RepositoryError.destinationMissing("") }
        let computer = computer
        return try await Task.detached(priority: .userInitiated) {
            try body(try Repository(destination: dest, computerName: computer))
        }.value
    }

    func reload() {
        guard let dest = destination else { error = "Nessuna destinazione configurata"; return }
        computers = Repository.computers(in: dest)
        if !computers.contains(computer), let first = computers.first { computer = first; return }
        loaded = [:]
        index = [:]
        loadAll = nil
        Task {
            do {
                let ids = try await withRepository { try $0.snapshotIDs() }
                snapshots = ids.reversed().compactMap { id in Snapshot.date(fromID: id).map { (id, $0) } }
                selectedID = snapshots.first?.id
            } catch { self.error = AppModel.describe(error) }
        }
    }

    private func load(_ id: String?) {
        guard let id, loaded[id] == nil else { fixSource(); return }
        Task {
            do {
                let snapshot = try await withRepository { try $0.readSnapshot(id) }
                loaded[id] = snapshot
                index[id] = await Task.detached(priority: .userInitiated) { Self.buildIndex(snapshot) }.value
                fixSource()
            } catch { self.error = AppModel.describe(error) }
        }
    }

    private func fixSource() {
        if source == nil || !sources.contains(source!) { source = sources.first; currentPath = "" }
    }

    func children() -> [Entry] {
        guard let id = selectedID, let source else { return [] }
        return index[id]?[source]?[currentPath] ?? []
    }

    nonisolated private static func buildIndex(_ s: Snapshot) -> [String: [String: [Entry]]] {
        var result: [String: [String: [Entry]]] = [:]
        for e in s.entries where !e.path.isEmpty {
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

    /// Debounced search over every snapshot. Manifests not opened yet are loaded once, by a single shared task.
    private func searchChanged() {
        searchTask?.cancel()
        let query = search.lowercased()
        guard !query.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await loadAllSnapshots()
            let snaps = snapshots.compactMap { s in loaded[s.id].map { (s.id, $0) } }
            let found = await Task.detached(priority: .userInitiated) { Self.search(query, in: snaps) }.value
            if !Task.isCancelled { results = found }
        }
    }

    private func loadAllSnapshots() async {
        if loadAll == nil {
            let missing = snapshots.map(\.id).filter { loaded[$0] == nil }
            guard !missing.isEmpty else { return }
            loadAll = Task {
                busy = "Carico \(missing.count) backup per la ricerca…"
                for id in missing { loaded[id] = try? await withRepository { try $0.readSnapshot(id) } }
                busy = nil
            }
        }
        await loadAll?.value
    }

    nonisolated private static func search(_ query: String, in snaps: [(String, Snapshot)]) -> [SearchHit] {
        var hits: [SearchHit] = []
        for (id, s) in snaps {
            for e in s.entries where e.kind != .directory && e.name.lowercased().contains(query) {
                hits.append(SearchHit(snapshotID: id, entry: e))
                if hits.count >= 500 { return hits }  // enough to pick from; refine the query for more
            }
        }
        return hits
    }

    func versions(of entry: Entry) async -> [(snapshotID: String, entry: Entry)] {
        (try? await withRepository { try Restorer(repository: $0).versions(source: entry.source, path: entry.path) }) ?? []
    }

    func restore(snapshotID: String, source: String, path: String, mode: RestoreMode) {
        busy = "Ripristino in corso…"
        Task {
            do {
                let url = try await withRepository { repo in
                    try Restorer(repository: repo).restore(try repo.readSnapshot(snapshotID), source: source, path: path, mode: mode)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = AppModel.describe(error) }
            busy = nil
        }
    }
}
