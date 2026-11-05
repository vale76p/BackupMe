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
    var search = ""
    var busy: String?
    var error: String?
    private var loaded: [String: Snapshot] = [:]

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
                loaded[id] = try await withRepository { try $0.readSnapshot(id) }
                fixSource()
            } catch { self.error = AppModel.describe(error) }
        }
    }

    private func fixSource() {
        if source == nil || !sources.contains(source!) { source = sources.first; currentPath = "" }
    }

    func children() -> [Entry] {
        guard let s = selected, let source else { return [] }
        return s.entries
            .filter { $0.source == source && !$0.path.isEmpty && ($0.path as NSString).deletingLastPathComponent == currentPath }
            .sorted { ($0.kind == .directory ? 0 : 1, $0.name.lowercased()) < ($1.kind == .directory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Searches file names in every snapshot, loading the manifests not opened yet.
    func runSearch() {
        let query = search.lowercased()
        guard !query.isEmpty else { return }
        let missing = snapshots.map(\.id).filter { loaded[$0] == nil }
        guard !missing.isEmpty else { return }
        busy = "Carico \(missing.count) backup per la ricerca…"
        Task {
            for id in missing { loaded[id] = try? await withRepository { try $0.readSnapshot(id) } }
            busy = nil
        }
    }

    func searchResults() -> [SearchHit] {
        let query = search.lowercased()
        guard !query.isEmpty else { return [] }
        return snapshots.flatMap { s in
            (loaded[s.id]?.entries ?? [])
                .filter { $0.kind != .directory && $0.name.lowercased().contains(query) }
                .map { SearchHit(snapshotID: s.id, entry: $0) }
        }
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
