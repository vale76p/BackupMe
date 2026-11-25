import AppKit
import BackupCore
import RestoreRules
import SwiftUI
import UniformTypeIdentifiers

/// What the list can ask the window to do.
struct RestoreActions {
    var enter: (Entry) -> Void
    var preview: (Entry) -> Void
    /// From a backup, beside the originals.
    var restore: (String, [(source: String, path: String)]) -> Void
    /// From a backup, into a folder of choice.
    var restoreInto: (String, [(source: String, path: String)]) -> Void
    var compare: (Entry) -> Void
    /// Leaves the search and opens the folder holding a result, the file selected.
    var reveal: (SearchHit) -> Void
    /// Space in the list: Quick Look of the selected file, or close it. False when there is nothing to show.
    var quickLook: () -> Bool
    var dragProvider: (Entry) -> NSItemProvider?
}

/// The middle column: the title, the filters and the list of files.
struct RestoreBrowser: View {
    let model: RestoreModel
    /// Every backup with what is known about it: the title speaks of the chosen one.
    let items: [TimelineItem]
    /// The rows the list shows, filter and sort applied.
    let rows: [Entry]
    /// The search results left by the scope.
    let results: [SearchHit]
    let actions: RestoreActions
    @Binding var filter: ChangeFilter
    @Binding var deletedOnly: Bool
    @Binding var selectedIDs: Set<Entry.ID>
    @Binding var hit: SearchHit?
    @Binding var showInspector: Bool
    @Binding var sortOrder: [KeyPathComparator<Entry>]
    @Binding var columns: TableColumnCustomization<Entry>
    let locale: Locale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            Group { if model.search.isEmpty { table } else { resultsTable } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: title and filters

    @ViewBuilder private var heading: some View {
        if model.search.isEmpty {
            if let s = model.selected, let item = items.first(where: { $0.id == s.id }) {
                title("Stai guardando il backup di", WhenText.title(s.date, locale: locale),
                      WhenText.subtitle(item, locale: locale))
                // comparing with this Mac's disk is meaningless for another computer's archive
                if model.showsStatus { tags }
            }
        } else {
            let n = results.count
            title("Ricerca in tutti i backup", "«\(model.search)»",
                  (n == 1 ? "1 risultato" : "\(n) risultati") + (model.resultsTruncated ? " (i primi 500)" : ""))
            HStack(spacing: 6) {
                scope(false)
                if model.showsStatus { scope(true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private func title(_ eyebrow: String, _ big: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(big).font(.system(size: 26, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var tags: some View {
        HStack(spacing: 6) {
            ForEach(ChangeFilter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    capsule(counted(f), dot: f == .all ? nil : dot(f), on: filter == f)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == f ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 10)
        .help("Mostra solo ciò che è cambiato, sparito o comparso dopo questo backup")
    }

    private func scope(_ deleted: Bool) -> some View {
        Button { deletedOnly = deleted } label: {
            capsule(deleted ? "Solo eliminati" : "Tutti", dot: deleted ? Color.red : nil, on: deletedOnly == deleted)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(deletedOnly == deleted ? .isSelected : [])
    }

    /// A filter as a tag: dark when it is the one in use; a pale capsule in Dark Mode, where primary is white.
    private func capsule(_ text: String, dot: Color? = nil, on: Bool) -> some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text).monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10).frame(height: 26)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(on ? (colorScheme == .dark ? Color.white.opacity(0.28) : Color.primary) : Color.secondary.opacity(0.16), in: Capsule())
        .contentShape(Capsule())
    }

    private func dot(_ f: ChangeFilter) -> Color { f == .added ? .green : f == .modified ? .orange : .red }

    private func counted(_ f: ChangeFilter) -> String {
        let name = f == .all ? "Tutto" : f == .modified ? "Modificati" : f == .missing ? "Eliminati" : "Nuovi"
        guard model.statusReady else { return name }
        // «Nuovi» are kept apart from the rows of the backup: they are counted where they are
        let n = f == .added ? model.added().count : model.children().filter { model.matches($0, f) }.count
        return n == 0 ? name : "\(name) \(n)"
    }

    // MARK: list

    @ViewBuilder private var table: some View {
        if model.isLoading {
            ProgressView()
        } else if model.snapshots.isEmpty {
            ContentUnavailableView("Nessun backup", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("I backup di questo Mac compariranno qui dopo il primo salvataggio."))
        } else if model.selectedID == nil {
            ContentUnavailableView("Scegli un backup", systemImage: "clock.arrow.circlepath",
                                   description: Text("Scegline uno nella barra laterale."))
        } else if model.selected == nil {
            ProgressView() // the chosen backup's index is still loading
        } else {
            fileTable
        }
    }

    private var fileTable: some View {
        Table(of: Entry.self, selection: $selectedIDs, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Nome", value: \.name) { e in
                HStack(spacing: 7) { icon(e); Text(e.name).lineLimit(1).truncationMode(.middle) }
            }
            TableColumn("Rispetto a oggi") { e in
                if let b = StatusBadge.change(model.status(of: e), added: model.isAdded(e), since: false) { b }
            }
            .width(min: 90, ideal: 130, max: 170)
            .customizationID("stato")
            TableColumn("Dimensione", value: \.size) { e in
                Text(e.kind == .file ? ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file) : "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Modificato", value: \.mtime) { e in
                Text(e.mtime.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 120, ideal: 150, max: 200)
        } rows: {
            ForEach(rows) { e in TableRow(e).itemProvider { actions.dragProvider(e) } }
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            let picked = model.children().filter { ids.contains($0.id) }
            let new = model.added().filter { ids.contains($0.id) }
            if let id = model.selectedID, !picked.isEmpty { rowMenu(snapshotID: id, entries: picked) }
            // items added after the backup have nothing to restore: only where they are today
            else if !new.isEmpty { Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(new.map(\.url)) } }
        } primaryAction: { ids in
            if let e = model.added().first(where: { ids.contains($0.id) }) {
                NSWorkspace.shared.activateFileViewerSelecting([e.url])
                return
            }
            guard ids.count == 1, let e = model.children().first(where: { ids.contains($0.id) }) else { return }
            if e.kind == .directory { actions.enter(e) } else if e.kind == .file { actions.preview(e) }
        }
        .onKeyPress(.space) { actions.quickLook() ? .handled : .ignored }
        .overlay {
            if filter != .all, model.statusReady, rows.isEmpty {
                ContentUnavailableView(filter == .modified ? "Nessuna modifica" : filter == .missing ? "Nessun elemento eliminato" : "Niente di nuovo",
                                       systemImage: "checkmark.circle",
                                       description: Text("In questa cartella niente è cambiato rispetto a questo backup."))
            } else if filter != .all, !model.statusReady {
                ProgressView("Confronto con oggi…")
            }
        }
    }

    private var resultsTable: some View {
        Table(results, selection: $hit) {
            TableColumn("Nome") { h in
                HStack(spacing: 7) { icon(h.entry); Text(h.entry.name).lineLimit(1) }
            }
            TableColumn("Rispetto a oggi") { h in
                if let b = StatusBadge.change(model.resultStatus[h].map { RowStatus(own: $0) }, added: false, since: false) { b }
            }
            .width(min: 90, ideal: 130, max: 170)
            TableColumn("Percorso") { h in
                Text(((h.entry.source as NSString).lastPathComponent as NSString).appendingPathComponent(h.entry.path))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Backup del") { h in
                Text(Snapshot.date(fromID: h.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 120, ideal: 150, max: 200)
        }
        .contextMenu(forSelectionType: SearchHit.self) { hits in
            if let h = hits.first {
                Button("Mostra nel backup") { actions.reveal(h) }
                Divider()
                rowMenu(snapshotID: h.snapshotID, entries: [h.entry])
            }
        } primaryAction: { hits in
            if let h = hits.first { actions.reveal(h) }
        }
        .overlay {
            if results.isEmpty, model.busy == nil {
                if deletedOnly {
                    ContentUnavailableView("Nessun file eliminato", systemImage: "magnifyingglass",
                                           description: Text(model.resultsTruncated
                                               ? "Nessuno tra i primi 500 risultati: affina la ricerca per vedere gli altri."
                                               : "Tutto ciò che corrisponde a «\(model.search)» esiste ancora su questo Mac."))
                } else {
                    ContentUnavailableView.search(text: model.search)
                }
            }
        }
    }

    @ViewBuilder private func rowMenu(snapshotID: String, entries: [Entry]) -> some View {
        if entries.count == 1, let e = entries.first {
            if e.kind == .directory, model.search.isEmpty { Button("Apri") { actions.enter(e) } }
            if e.kind == .file { Button("Anteprima") { actions.preview(e) } }
        }
        let items = entries.map { (source: $0.source, path: $0.path) }
        let n = entries.count == 1 ? "" : " \(entries.count) elementi"
        Button("Ripristina\(n)") { actions.restore(snapshotID, items) }
        Button("Ripristina\(n) in…") { actions.restoreInto(snapshotID, items) }
        if entries.count == 1, let e = entries.first, e.kind == .file {
            Divider()
            Button("Mostra versioni del file") {
                // the inspector shows the selection: a right click alone doesn't change it
                if model.search.isEmpty { selectedIDs = [e.id] } else { hit = SearchHit(snapshotID: snapshotID, entry: e) }
                showInspector = true
            }
            if model.showsStatus, Restorer.status(of: e) == .modified {
                Button("Confronta con la versione attuale") { actions.compare(e) }
            }
        }
    }

    // MARK: rows

    private func icon(_ e: Entry) -> some View {
        Image(nsImage: FileIcon.image(for: e)).resizable().frame(width: 20, height: 20)
    }
}

/// Words in a tinted box: the change since this backup reads without hovering.
struct StatusBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) { self.text = text; self.color = color }

    /// The badge of a row, nil when nothing changed; `since` asks for the inspector's words, that say when ("Modificato da allora").
    static func change(_ s: RowStatus?, added: Bool, since: Bool) -> StatusBadge? {
        if added { return StatusBadge("Nuovo", color: .green) }
        guard let s else { return nil }
        if s.own == .missing { return StatusBadge(since ? "Eliminato da allora" : "Eliminato", color: .red) }
        if s.own == .modified { return StatusBadge(since ? "Modificato da allora" : "Modificato", color: .orange) }
        if s.modifiedInside { return StatusBadge("Contiene modifiche", color: .orange) }
        if s.missingInside { return StatusBadge("Contiene eliminati", color: .red) }
        // only the inspector says of an item that stayed the same that it is like today's
        return since ? StatusBadge("Uguale a oggi", color: .secondary) : nil
    }

    var body: some View {
        Text(text).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// One NSWorkspace lookup per extension: the table asks for an icon on every redraw.
@MainActor enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for e: Entry) -> NSImage {
        let key = e.kind == .directory ? "/" : e.kind == .symlink ? "@" : (e.name as NSString).pathExtension.lowercased()
        if let image = cache[key] { return image }
        let type: UTType = e.kind == .directory ? .folder : e.kind == .symlink ? .symbolicLink : UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
