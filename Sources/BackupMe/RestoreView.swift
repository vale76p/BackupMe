import AppKit
import BackupCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct RestoreView: View {
    @State var model: RestoreModel
    @State private var selectedIDs = Set<Entry.ID>()
    @State private var hit: SearchHit?
    @State private var check: Restorer.ReplaceCheck?
    @State private var versionsOf: Entry?
    @State private var previewURL: URL?
    /// Bumped on every preview request: a slow extraction finishing late must not replace a newer preview.
    @State private var previewToken = 0
    /// What the "whole folder" dialog acts on, fixed when it opens: selecting something else meanwhile must not
    /// redirect Sostituisci.
    @State private var whole: (snapshotID: String, target: Target)?
    @State private var bigPreview: Entry?
    @State private var filter = ChangeFilter.all
    @State private var deletedOnly = false
    @State private var sortOrder: [KeyPathComparator<Entry>] = []
    /// Finder-style Back / Forward (⌘[ ⌘]) over the folders visited in this window.
    @State private var back: [Place] = []
    @State private var forward: [Place] = []
    @State private var columns = TableColumnCustomization<Entry>()

    // split in steps: as one chain the body is too big for the type checker
    var body: some View {
        withDialogs(withReactions(window
            .searchable(text: $model.search, prompt: "Cerca in tutti i backup")
            .searchScopes($deletedOnly) {
                Text("Tutti").tag(false)
                if model.showsStatus { Text("Solo eliminati").tag(true) }
            }))
            .frame(minWidth: 860, minHeight: 500)
            .quickLookPreview($previewURL)
    }

    private func withReactions(_ v: some View) -> some View {
        v.onChange(of: model.selectedID) { selectedIDs = [] }
            .onChange(of: model.search) { hit = nil }
            // a filter hiding selected rows deselects them: actions act only on what is visible
            .onChange(of: rows.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
            .onChange(of: deletedOnly) { if let h = hit, !shownResults.contains(h) { hit = nil } }
            .onChange(of: model.computer, initial: true) {
                hit = nil; selectedIDs = []; back = []; forward = []
                columns[visibility: "stato"] = model.showsStatus ? .automatic : .hidden
                if !model.showsStatus { filter = .all; deletedOnly = false }
            }
            .onChange(of: model.app.settings.destination) { model.reload() }
            .task(id: [model.selectedID, model.source, model.currentPath, model.selected?.id, model.pendingSelection,
                       String(model.statusEpoch)]) {
                if let p = model.pendingSelection, model.children().contains(where: { $0.id == p }) {
                    selectedIDs = [p]
                    model.pendingSelection = nil
                }
                await model.refreshStatus()
            }
            .onAppear { model.reload() }
            // Back / Forward have no toolbar buttons (the toolbar stays short): keyboard only, as ⌘[ ⌘] in the Finder
            .background {
                Group {
                    Button("Indietro", action: goBack).keyboardShortcut("[").disabled(back.isEmpty)
                    Button("Avanti", action: goForward).keyboardShortcut("]").disabled(forward.isEmpty)
                    // here, not on the toolbar pull-down: a Menu's shortcuts don't fire while it is closed
                    Button("Ripristina") { if wholeBackup { restoreAllInto() } else { restoreTargets() } }
                        .keyboardShortcut("r").disabled(restoreDisabled)
                    Button("Ripristina in…") { if wholeBackup { restoreAllInto() } else { restoreTargetsInto() } }
                        .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(restoreDisabled)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
    }

    private func withDialogs(_ v: some View) -> some View {
        v.confirmationDialog(Text("Ripristinare l'intera cartella «\(((whole?.target.source ?? "") as NSString).lastPathComponent)»?"),
                             isPresented: Binding(get: { whole != nil }, set: { if !$0 { whole = nil } }), presenting: whole) { w in
            let item = [(source: w.target.source, path: w.target.path)]
            // replacing in place only for folders this Mac backs up now, from this Mac's own archive, and only once
            // the check of what would go to the Trash is done (a tampered or foreign manifest, another computer's
            // folder at the same path, a backup still loading: no Sostituisci)
            if check != nil, model.app.settings.sources.contains(w.target.source) {
                Button("Sostituisci", role: .destructive) { model.restore(snapshotID: w.snapshotID, items: item, mode: .replace) }
            }
            Button("Ripristina accanto") { model.restore(snapshotID: w.snapshotID, items: item, mode: .besideOriginal) }
            Button("Ripristina in…") { chooseFolder { model.restore(snapshotID: w.snapshotID, items: item, mode: .into($0)) } }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text(replaceMessage)
        }
        .confirmationDialog("Aprire l'anteprima di un file grande?",
                            isPresented: Binding(get: { bigPreview != nil }, set: { if !$0 { bigPreview = nil } })) {
            Button("Apri anteprima") { if let e = bigPreview { bigPreview = nil; preview(e, confirmed: true) } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Per mostrarlo va estratto dall'archivio in una cartella temporanea (\(ByteCountFormatter.string(fromByteCount: bigPreview?.size ?? 0, countStyle: .file))); se l'archivio è su OneDrive può dover essere scaricato.")
        }
        .sheet(item: $versionsOf) { VersionsSheet(model: model, entry: $0) }
        .alert(model.error?.title ?? "", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") {}
        } message: { Text(model.error?.message ?? "") }
    }

    private var window: some View {
        // a standard window, no sidebar: the backup is chosen from a pop-up in the toolbar
        Group {
            if !model.hasDestination {
                ContentUnavailableView {
                    Label("Nessuna destinazione", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text("Scegli dove salvare i backup per poterli sfogliare e ripristinare.")
                } actions: {
                    SettingsLink { Text("Apri Impostazioni…") }
                }
            } else if model.search.isEmpty { browser } else { results }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // native window chrome only: title = folder being viewed, its menu = the path, subtitle = date or progress
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbarTitleMenu {
            if model.search.isEmpty, model.source != nil {
                let parts = model.currentPath.split(separator: "/").map(String.init)
                ForEach(parts.indices.reversed(), id: \.self) { i in
                    if i < parts.count - 1 { Button(parts[i], systemImage: "folder") { open(parts[...i].joined(separator: "/")) } }
                }
                if !parts.isEmpty { Button(rootName, systemImage: "folder") { open("") } }
                Button("Tutte le cartelle", systemImage: "externaldrive") { go(Place(source: nil, path: "")) }
            }
        }
        .toolbar { toolbarItems }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
            ToolbarItem(placement: .navigation) {
                Button("Cartella superiore", systemImage: "chevron.up") {
                    if model.currentPath.isEmpty { go(Place(source: nil, path: "")) }
                    else { open((model.currentPath as NSString).deletingLastPathComponent) }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.source == nil || !model.search.isEmpty)
                .help("Cartella superiore")
            }
            ToolbarItem(placement: .navigation) {
                Picker("Backup", selection: $model.selectedID) {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items, id: \.id) { s in Text(label(s.date, in: group.title)).tag(Optional(s.id)) }
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.snapshots.isEmpty || !model.search.isEmpty)
                .help("Backup da sfogliare")
            }
            if model.computers.count > 1 {
                ToolbarItem(placement: .navigation) {
                    Picker("Computer", selection: $model.computer) { ForEach(model.computers, id: \.self) { Text($0) } }
                        .pickerStyle(.menu)
                        .help("Computer di origine")
                }
            }
            if model.showsStatus, model.search.isEmpty {
                ToolbarItem {
                    // compare with today: only what changed or disappeared since this backup
                    Menu {
                        Picker("Mostra", selection: $filter) {
                            Text("Tutti gli elementi").tag(ChangeFilter.all)
                            Text("Modificati da allora").tag(ChangeFilter.modified)
                            Text("Eliminati da allora").tag(ChangeFilter.missing)
                            Text("Aggiunti da allora").tag(ChangeFilter.added)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Filtro", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help("Confronta con oggi: mostra solo ciò che è cambiato o sparito dopo questo backup")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // one native pull-down: click restores beside the original, the arrow offers the rest
                Menu {
                    if wholeBackup {
                        Button("Ripristina tutto il backup in…", systemImage: "folder.badge.plus", action: restoreAllInto)
                    } else {
                        Button("Ripristina in…", systemImage: "folder.badge.plus", action: restoreTargetsInto)
                    }
                    Button("Anteprima", systemImage: "eye") { singleFile.map(preview) }
                        .disabled(singleFile == nil)
                    Button("Mostra versioni del file", systemImage: "clock.arrow.circlepath") { versionsOf = singleFile }
                        .disabled(singleFile == nil)
                } label: {
                    Label("Ripristina", systemImage: "arrow.uturn.backward")
                } primaryAction: {
                    if wholeBackup { restoreAllInto() } else { restoreTargets() }
                }
                .labelStyle(.titleAndIcon)
                .disabled(restoreDisabled)
                .help(restoreHelp)
            }
    }

    // MARK: browser

    @ViewBuilder private var browser: some View {
        if model.isLoading {
            ProgressView()
        } else if model.snapshots.isEmpty {
            ContentUnavailableView("Nessun backup", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("I backup di questo Mac compariranno qui dopo il primo salvataggio."))
        } else if model.selectedID == nil {
            ContentUnavailableView("Scegli un backup", systemImage: "clock.arrow.circlepath",
                                   description: Text("Scegline uno dal menu Backup nella barra degli strumenti."))
        } else if model.selected == nil {
            ProgressView() // the chosen backup's index is still loading
        } else {
            Table(of: Entry.self, selection: $selectedIDs, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("Nome", value: \.name) { e in
                    HStack(spacing: 6) { icon(e); Text(e.name).lineLimit(1).truncationMode(.middle) }
                }
                TableColumn("Stato") { e in
                    if model.isAdded(e) { statusSymbol("plus.circle", "aggiunto dopo questo backup") } else { statusIcon(model.status(of: e)) }
                }
                    .width(min: 36, ideal: 44, max: 60)
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
                ForEach(rows) { e in TableRow(e).itemProvider { dragProvider(e) } }
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
                if e.kind == .directory { enter(e) } else if e.kind == .file { preview(e) }
            }
            .onKeyPress(.space) {
                guard let e = singleFile else { return .ignored }
                if previewURL != nil { previewURL = nil } else { preview(e) }
                return .handled
            }
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
    }

    private var results: some View {
        Table(shownResults, selection: $hit) {
            TableColumn("Nome") { h in
                HStack(spacing: 6) { icon(h.entry); Text(h.entry.name).lineLimit(1) }
            }
            TableColumn("Stato") { h in statusIcon(model.resultStatus[h].map { RowStatus(own: $0) }) }
                .width(min: 36, ideal: 44, max: 60)
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
                Button("Mostra nel backup") { model.reveal(h) }
                Divider()
                rowMenu(snapshotID: h.snapshotID, entries: [h.entry])
            }
        } primaryAction: { hits in
            if let h = hits.first { model.reveal(h) }
        }
        .overlay {
            if shownResults.isEmpty, model.busy == nil {
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

    private var shownResults: [SearchHit] {
        deletedOnly ? model.results.filter { model.resultStatus[$0] == .missing } : model.results
    }

    @ViewBuilder private func rowMenu(snapshotID: String, entries: [Entry]) -> some View {
        if entries.count == 1, let e = entries.first {
            if e.kind == .directory, model.search.isEmpty { Button("Apri") { enter(e) } }
            if e.kind == .file { Button("Anteprima") { preview(e) } }
        }
        let items = entries.map { (source: $0.source, path: $0.path) }
        let n = entries.count == 1 ? "" : " \(entries.count) elementi"
        Button("Ripristina\(n)") { model.restore(snapshotID: snapshotID, items: items, mode: .besideOriginal) }
        Button("Ripristina\(n) in…") { chooseFolder { model.restore(snapshotID: snapshotID, items: items, mode: .into($0)) } }
        if entries.count == 1, let e = entries.first, e.kind == .file {
            Divider()
            Button("Mostra versioni del file") { versionsOf = e }
            if model.showsStatus, Restorer.status(of: e) == .modified {
                Button("Confronta con la versione attuale") { model.compare(e) }
            }
        }
    }

    /// No sort chosen keeps the index order: folders first, then names. The filter needs the folder's status.
    private var rows: [Entry] {
        var list = model.children()
        switch filter {
        case .all: break
        case .modified: list = list.filter { model.status(of: $0).map { $0.own == .modified || $0.modifiedInside } ?? false }
        case .missing: list = list.filter { model.status(of: $0).map { $0.own == .missing || $0.missingInside } ?? false }
        case .added: list = model.added()
        }
        return sortOrder.isEmpty ? list : list.sorted(using: sortOrder)
    }

    private func icon(_ e: Entry) -> some View {
        Image(nsImage: FileIcon.image(for: e)).resizable().frame(width: 16, height: 16)
    }

    @ViewBuilder private func statusIcon(_ s: RowStatus?) -> some View {
        if let s {
            if s.own == .missing { statusSymbol("minus.circle", "non più presente oggi") }
            else if s.own == .modified { statusSymbol("pencil.circle", "modificato") }
            else if s.modifiedInside { statusSymbol("pencil.circle", "contiene file modificati") }
            else if s.missingInside { statusSymbol("minus.circle", "contiene file non più presenti oggi") }
        }
    }

    private func statusSymbol(_ name: String, _ text: String) -> some View {
        Image(systemName: name).foregroundStyle(.secondary).help(text).accessibilityLabel(text)
    }

    struct Place: Equatable { var source: String?; var path: String }

    private var here: Place { Place(source: model.source, path: model.currentPath) }

    private func open(_ path: String) { go(Place(source: model.source, path: path)) }

    /// Works at the top level too, where the rows are the saved folders.
    private func enter(_ e: Entry) { go(Place(source: e.source, path: e.path)) }

    private func go(_ place: Place) {
        guard place != here else { return }
        back.append(here)
        forward = []
        show(place)
    }

    private func show(_ place: Place) {
        model.source = place.source
        model.currentPath = place.path
        model.pendingSelection = nil
        model.fixLocation() // Back / Forward may lead to a folder this backup doesn't have
        selectedIDs = []
    }

    private func goBack() {
        guard let place = back.popLast() else { return }
        forward.append(here)
        show(place)
    }

    private func goForward() {
        guard let place = forward.popLast() else { return }
        back.append(here)
        show(place)
    }

    /// Dragging a file out restores a copy where it's dropped, named so it never replaces the original.
    private func dragProvider(_ e: Entry) -> NSItemProvider? {
        guard e.kind == .file, e.hash != nil, model.search.isEmpty else { return nil }
        let provider = NSItemProvider()
        let model = model
        let type = UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                if let url = await model.dragCopy(e) { done(url, false, nil) } else { done(nil, false, CocoaError(.fileReadUnknown)) }
            }
            return nil
        }
        return provider
    }

    private var rootName: String { model.source.map { ($0 as NSString).lastPathComponent } ?? "Tutte le cartelle" }

    private var title: String {
        guard model.search.isEmpty else { return "Ricerca" }
        return model.currentPath.isEmpty ? rootName : (model.currentPath as NSString).lastPathComponent
    }

    private var subtitle: String {
        if model.restoring { return "Ripristino in corso…" }
        if let busy = model.busy { return busy }
        if !model.search.isEmpty {
            let n = shownResults.count
            return (n == 1 ? "1 risultato" : "\(n) risultati") + (model.resultsTruncated ? " (i primi 500)" : "")
        }
        if selectedIDs.count > 1 { return "\(selectedIDs.count) elementi selezionati" }
        // the date is in the backup pop-up: here the full path of the folder being viewed
        guard let source = model.source else { return "" }
        let folder = (source as NSString).lastPathComponent
        return model.currentPath.isEmpty ? folder : folder + "/" + model.currentPath
    }

    // MARK: actions

    private typealias Target = (source: String, path: String, entry: Entry?)

    /// What the toolbar acts on: a search hit, the selected items, or the folder being viewed.
    private var targets: [Target] {
        if !model.search.isEmpty { return hit.map { [($0.entry.source, $0.entry.path, $0.entry)] } ?? [] }
        guard model.selectedID != nil else { return [] }
        let visible = Set(rows.map(\.id))
        let picked = model.children().filter { selectedIDs.contains($0.id) && visible.contains($0.id) }
        if !picked.isEmpty { return picked.map { ($0.source, $0.path, $0) } }
        guard selectedIDs.isEmpty else { return [] } // only items added after the backup: nothing to restore
        guard let source = model.source else { return [] } // top level, nothing selected
        return [(source, model.currentPath, nil)]
    }

    private var targetSnapshot: String? { model.search.isEmpty ? model.selectedID : hit?.snapshotID }

    /// Also while the chosen backup is still loading: its folders aren't checked yet, and Sostituisci couldn't
    /// say what would go to the Trash.
    private var restoreDisabled: Bool {
        (targets.isEmpty && !wholeBackup) || model.restoring || (model.search.isEmpty && model.selected == nil)
    }

    /// Top level with nothing selected: every saved folder of the backup, into a folder of choice (a new Mac).
    private var wholeBackup: Bool {
        model.search.isEmpty && model.source == nil && selectedIDs.isEmpty && model.selected != nil
    }

    private var singleFile: Entry? {
        guard targets.count == 1, let e = targets[0].entry, e.kind == .file else { return nil }
        return e
    }

    private var restoreHelp: String {
        if wholeBackup { return "Ripristina tutte le cartelle di questo backup in una cartella a scelta" }
        if targets.count > 1 { return "Ripristina \(targets.count) elementi accanto agli originali, senza sovrascrivere" }
        guard let t = targets.first else { return "Seleziona un elemento da ripristinare" }
        return "Ripristina «\(t.entry?.name ?? title)» accanto all'originale, senza sovrascrivere"
    }

    private var replaceMessage: String {
        var text = "Sostituisci sposta nel Cestino la cartella attuale, comprese le cartelle escluse dal backup (es. node_modules), e la rimpiazza con la versione salvata."
        if let check {
            if check.changedFiles > 0 {
                text += "\n\n\(check.changedFiles == 1 ? "1 file è cambiato" : "\(check.changedFiles) file sono cambiati") dopo il backup: le versioni di oggi finiranno nel Cestino."
            }
            if check.repositoryChanged {
                text += "\n\nIl repository git ha commit o branch più recenti del backup: finiranno nel Cestino con la cartella."
            }
        }
        return text
    }

    /// A whole saved folder asks first: replacing it is on offer there, and only there.
    private func restoreTargets() {
        let t = targets
        guard let id = targetSnapshot, !t.isEmpty else { return }
        if t.count == 1, t[0].path.isEmpty {
            check = nil
            let source = t[0].source
            Task {
                if model.showsStatus, model.app.settings.sources.contains(source) { check = await model.replaceCheck(source: source) }
                whole = (id, t[0])
            }
            return
        }
        restore(t, mode: .besideOriginal)
    }

    private func restore(_ t: [Target], mode: RestoreMode) {
        guard let id = targetSnapshot else { return }
        model.restore(snapshotID: id, items: t.map { ($0.source, $0.path) }, mode: mode)
    }

    private func restoreTargetsInto() {
        let t = targets
        chooseFolder { restore(t, mode: .into($0)) }
    }

    private func restoreAllInto() {
        guard let id = model.selectedID else { return }
        let items = model.sources.map { (source: $0, path: "") }
        chooseFolder { model.restore(snapshotID: id, items: items, mode: .into($0)) }
    }

    private func chooseFolder(_ then: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Ripristina qui"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        then(dir)
    }

    private func preview(_ e: Entry) { preview(e, confirmed: false) }

    private func preview(_ e: Entry, confirmed: Bool) {
        if !confirmed, e.size > 200_000_000 { bigPreview = e; return }
        previewToken += 1
        let token = previewToken
        Task {
            let url = await model.extracted(e)
            if token == previewToken { previewURL = url }
        }
    }

    // MARK: backup pop-up grouping

    private var groups: [(title: String, items: [(id: String, date: Date)])] {
        let cal = Calendar.current
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let order = ["Oggi", "Ieri", "Ultimi 7 giorni", "Più vecchi"]
        let grouped = Dictionary(grouping: model.snapshots) { s -> String in
            if cal.isDateInToday(s.date) { return "Oggi" }
            if cal.isDateInYesterday(s.date) { return "Ieri" }
            return s.date > weekAgo ? "Ultimi 7 giorni" : "Più vecchi"
        }
        return order.compactMap { t in grouped[t].map { (t, $0) } }
    }

    /// The pop-up shows only the chosen item, without its section: today and yesterday say so.
    private func label(_ date: Date, in group: String) -> String {
        switch group {
        case "Oggi": "Oggi, " + date.formatted(date: .omitted, time: .shortened)
        case "Ieri": "Ieri, " + date.formatted(date: .omitted, time: .shortened)
        default: date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

/// One NSWorkspace lookup per extension: the table asks for an icon on every redraw.
@MainActor private enum FileIcon {
    static var cache: [String: NSImage] = [:]

    static func image(for e: Entry) -> NSImage {
        let key = e.kind == .directory ? "/" : e.kind == .symlink ? "@" : (e.name as NSString).pathExtension.lowercased()
        if let image = cache[key] { return image }
        let type: UTType = e.kind == .directory ? .folder : e.kind == .symlink ? .symbolicLink : UTType(filenameExtension: key) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

private struct VersionsSheet: View {
    let model: RestoreModel
    let entry: Entry
    @State private var versions: [SearchHit]? // nil while loading
    @State private var selection: SearchHit?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let versions {
                    Table(versions, selection: $selection) {
                        TableColumn("Data") { v in
                            Text(Snapshot.date(fromID: v.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? v.snapshotID)
                                .monospacedDigit()
                        }
                        TableColumn("Dimensione") { v in
                            Text(ByteCountFormatter.string(fromByteCount: v.entry.size, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .width(min: 70, ideal: 90, max: 120)
                    }
                    .contextMenu(forSelectionType: SearchHit.self) { _ in } primaryAction: { hits in hits.first.map(restore) }
                    .overlay {
                        if versions.isEmpty {
                            ContentUnavailableView("Nessuna versione", systemImage: "clock.arrow.circlepath",
                                                   description: Text("Questo file non compare in nessun backup."))
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Versioni di \(entry.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ripristina") { selection.map(restore) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || model.restoring)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .task { versions = await model.versions(of: entry).map { SearchHit(snapshotID: $0.snapshotID, entry: $0.entry) } }
    }

    private func restore(_ v: SearchHit) {
        model.restore(snapshotID: v.snapshotID, source: v.entry.source, path: v.entry.path, mode: .besideOriginal)
        dismiss()
    }
}

extension Entry: Identifiable {
    public var id: String { source + "\u{0}" + path }
}
