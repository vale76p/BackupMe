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
    /// The right-hand panel: details and saved versions of the selected item.
    @AppStorage("restoreInspector") private var showInspector = true
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
            // after every backup, and when coming back to the app: the list may have changed meanwhile
            .onChange(of: model.app.lastReport?.date) { model.refreshList() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshList() }
            .onVolumeChange { model.refreshList() } // a destination disk plugged in or pulled out
            .background {
                Group {
                    Button("Cartella superiore", action: goUp).keyboardShortcut(.upArrow, modifiers: .command)
                        .disabled(model.source == nil || !model.search.isEmpty)
                    // the chips take no keyboard focus: newer and older backup from the keyboard
                    Button("Backup più recente") { stepBackup(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button("Backup più vecchio") { stepBackup(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
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
            Text("Per mostrarlo va estratto dall'archivio in una cartella temporanea (\(ByteCountFormatter.string(fromByteCount: bigPreview?.size ?? 0, countStyle: .file))); se l'archivio è in una cartella cloud può dover essere scaricato.")
        }
        .alert(model.error?.title ?? "", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") {}
        } message: { Text(model.error?.message ?? "") }
    }

    private var window: some View {
        // backups in the sidebar, where they are always visible; details and versions in the inspector
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } detail: {
            Group {
                if !model.hasDestination {
                    ContentUnavailableView {
                        Label("Nessuna destinazione", systemImage: "externaldrive.badge.xmark")
                    } description: {
                        Text("Scegli dove salvare i backup per poterli sfogliare e ripristinare.")
                    } actions: {
                        SettingsLink { Text("Apri Impostazioni…") }
                    }
                } else if let text = model.notConnectedText {
                    ContentUnavailableView(text, systemImage: "externaldrive.badge.xmark",
                                           description: Text("Collegala per sfogliare e ripristinare i backup."))
                } else {
                    VStack(spacing: 0) {
                        if model.search.isEmpty, model.selected != nil, model.showsStatus {
                            filterBar
                            Divider()
                        }
                        Group { if model.search.isEmpty { browser } else { results } }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        actionBar
                    }
                }
            }
            // minimums on the columns, not on the window: a window-wide minimum makes the sidebar jump when it
            // collapses, as the window is re-constrained on every frame of the animation
            .frame(minWidth: 460, minHeight: 420)
            .inspector(isPresented: $showInspector) {
                inspector.inspectorColumnWidth(min: 230, ideal: 270, max: 360)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarItems }
        .hidingToolbarTitle() // the path in the toolbar says where you are; the title stays for the Window menu
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Indietro", systemImage: "chevron.left", action: goBack)
                .keyboardShortcut("[").disabled(back.isEmpty || !model.search.isEmpty).help("Indietro")
            Button("Avanti", systemImage: "chevron.right", action: goForward)
                .keyboardShortcut("]").disabled(forward.isEmpty || !model.search.isEmpty).help("Avanti")
        }
        if model.search.isEmpty, model.selected != nil {
            ToolbarItem(placement: .navigation) { breadcrumb }
        }
        if model.computers.count > 1 {
            ToolbarItem(placement: .navigation) {
                Picker("Computer", selection: $model.computer) { ForEach(model.computers, id: \.self) { Text($0) } }
                    .pickerStyle(.menu)
                    .help("Computer di origine")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(showInspector ? "Nascondi dettagli" : "Mostra dettagli", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help(showInspector ? "Nascondi dettagli e versioni" : "Mostra dettagli e versioni")
        }
    }

    // MARK: sidebar

    /// One section per day of the last week with the hours as chips, then one per month with the days.
    private var sidebar: some View {
        let info = backupInfo
        // a native sidebar list, not a ScrollView: under the toolbar a hand-made scroll view took clicks a few
        // points away from where the chips are drawn
        return List {
            ForEach(groups, id: \.title) { group in
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: group.byHour ? 58 : 96), spacing: 5)],
                              alignment: .leading, spacing: 5) {
                        ForEach(group.items, id: \.id) { s in chip(s, label: chipLabel(s.date, in: group), info: info[s.id]) }
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 8, trailing: 8))
                    .listRowSeparator(.hidden)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.title)
                        Spacer()
                        let bytes = group.items.compactMap { info[$0.id]?.newBytes }
                        if !bytes.isEmpty {
                            Text("+" + bytes.reduce(0, +).formatted(.byteCount(style: .file)))
                                .monospacedDigit()
                                .help("Dati nuovi salvati da questi backup")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.isLoading, model.hasDestination { ProgressView() }
            else if model.snapshots.isEmpty, model.hasDestination, model.notConnectedText == nil {
                ContentUnavailableView("Nessun backup", systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Compariranno qui dopo il primo salvataggio."))
            }
        }
    }

    private func chip(_ s: (id: String, date: Date), label: String, info: (newBytes: Int64, warnings: Int)?) -> some View {
        let selected = model.selectedID == s.id
        let warned = (info?.warnings ?? 0) > 0
        var tip = s.date.formatted(date: .complete, time: .shortened)
        if let info { tip += " · \(info.newBytes.formatted(.byteCount(style: .file))) nuovi" }
        if warned { tip += " · \(info!.warnings == 1 ? "1 avviso" : "\(info!.warnings) avvisi")" }
        return Button {
            model.search = "" // a backup picked while searching: show it
            model.selectedID = s.id
        } label: {
            Text(label).font(.callout).monospacedDigit().lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .foregroundStyle(selected ? Color.white : warned ? Color.orange : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : warned ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.35),
                                                lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tip) // the label alone is only an hour or a day
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// New bytes and warnings of the backups this Mac made, from the app's history (its last 50 runs). Runs with
    /// no changes reused an older backup: only the run that wrote it counts.
    private var backupInfo: [String: (newBytes: Int64, warnings: Int)] {
        guard model.showsStatus else { return [:] }
        var info: [String: (newBytes: Int64, warnings: Int)] = [:]
        for r in model.app.history {
            guard let id = r.snapshotID, let made = Snapshot.date(fromID: id), abs(made.timeIntervalSince(r.date)) < 2 else { continue }
            // a partial backup (a folder unreadable, no room for some files) is marked too
            info[id] = (r.newBytes, r.warnings.count + (r.error?.split(separator: "\n").count ?? 0))
        }
        return info
    }

    // MARK: path and filter

    /// Every level is clickable; deep paths fold the middle levels into a "…" menu.
    private var breadcrumb: some View {
        HStack(spacing: 2) {
            crumb("Tutte le cartelle", icon: "externaldrive", current: model.source == nil) { go(Place(source: nil, path: "")) }
            if let source = model.source {
                let parts = model.currentPath.split(separator: "/").map(String.init)
                let folded = max(0, parts.count - 2)
                separator
                crumb((source as NSString).lastPathComponent, icon: "folder", current: parts.isEmpty) { open("") }
                if folded > 0 {
                    separator
                    Menu("…") {
                        ForEach(Array((0..<folded).reversed()), id: \.self) { i in
                            Button(parts[i], systemImage: "folder") { open(parts[...i].joined(separator: "/")) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                ForEach(Array(folded..<parts.count), id: \.self) { i in
                    separator
                    crumb(parts[i], icon: nil, current: i == parts.count - 1) { open(parts[...i].joined(separator: "/")) }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var filterBar: some View {
        HStack {
            Picker("Mostra", selection: $filter) {
                Text("Tutto").tag(ChangeFilter.all)
                Text(counted("Modificati", .modified)).tag(ChangeFilter.modified)
                Text(counted("Eliminati", .missing)).tag(ChangeFilter.missing)
                Text(counted("Nuovi", .added)).tag(ChangeFilter.added)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 12)
            Text("Confronto con oggi").font(.caption).foregroundStyle(.secondary)
        }
        .help("Mostra solo ciò che è cambiato, sparito o comparso dopo questo backup")
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
    }

    private func crumb(_ name: String, icon: String?, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(name).lineLimit(1).truncationMode(.middle) } icon: { if let icon { Image(systemName: icon) } }
                .fontWeight(current ? .semibold : .regular)
                .foregroundStyle(current ? .primary : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(current)
    }

    private func counted(_ name: String, _ f: ChangeFilter) -> String {
        guard model.statusReady else { return name }
        let n = f == .added ? model.added().count : model.children().filter { matches($0, f) }.count
        return n == 0 ? name : "\(name) \(n)"
    }

    // MARK: action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(selectionSummary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            // short names, big targets: what each one does exactly is in the tooltip
            if !wholeBackup {
                Button("Ripristina in…", systemImage: "folder", action: restoreTargetsInto)
                    .disabled(restoreDisabled)
                    .help("Scegli una cartella dove ripristinare: gli originali non vengono toccati")
            }
            Button(wholeBackup ? "Ripristina tutto…" : "Ripristina", systemImage: "arrow.uturn.backward") {
                if wholeBackup { restoreAllInto() } else { restoreTargets() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(restoreDisabled)
            .help(restoreHelp)
        }
        .controlSize(.extraLarge)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionSummary: String {
        if model.restoring { return "Ripristino in corso…" }
        let from = targetSnapshot.flatMap(Snapshot.date(fromID:)).map(Self.fromBackup) ?? ""
        if wholeBackup { return "Tutte le cartelle · " + from }
        let t = targets
        if t.isEmpty { return model.search.isEmpty ? "Niente da ripristinare qui" : "Seleziona un risultato" }
        if t.count == 1 { return "«\(t[0].entry?.name ?? title)»" + (t[0].entry == nil ? " intera" : "") + " · " + from }
        let size = t.compactMap(\.entry).filter { $0.kind == .file }.reduce(Int64(0)) { $0 + $1.size }
        return "\(t.count) elementi" + (size > 0 ? " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "") + " · " + from
    }

    private static func fromBackup(_ d: Date) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d) { return "dal backup di oggi alle " + time }
        if Calendar.current.isDateInYesterday(d) { return "dal backup di ieri alle " + time }
        return "dal backup del " + d.formatted(date: .abbreviated, time: .omitted) + " alle " + time
    }

    // MARK: inspector

    @ViewBuilder private var inspector: some View {
        let t = targets
        if t.count == 1, let e = t[0].entry, let id = targetSnapshot {
            EntryInspector(model: model, entry: e, snapshotID: id,
                           status: model.search.isEmpty ? model.status(of: e) : model.resultStatus[SearchHit(snapshotID: id, entry: e)].map { RowStatus(own: $0) },
                           preview: preview)
                .id(id + "\u{0}" + e.id)
        } else if t.count > 1 {
            ContentUnavailableView("\(t.count) elementi selezionati", systemImage: "square.stack.3d.up",
                                   description: Text("Le versioni si vedono selezionando un solo file."))
        } else {
            ContentUnavailableView("Nessuna selezione", systemImage: "info.circle",
                                   description: Text("Seleziona un file per vederne i dettagli e le versioni salvate."))
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
                                   description: Text("Scegline uno nella barra laterale."))
        } else if model.selected == nil {
            ProgressView() // the chosen backup's index is still loading
        } else {
            Table(of: Entry.self, selection: $selectedIDs, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("Nome", value: \.name) { e in
                    HStack(spacing: 6) { icon(e); Text(e.name).lineLimit(1).truncationMode(.middle) }
                }
                TableColumn("Rispetto a oggi") { e in statusPill(model.status(of: e), added: model.isAdded(e)) }
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
            TableColumn("Rispetto a oggi") { h in statusPill(model.resultStatus[h].map { RowStatus(own: $0) }) }
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
            Button("Mostra versioni del file") {
                // the inspector shows the selection: a right click alone doesn't change it
                if model.search.isEmpty { selectedIDs = [e.id] } else { hit = SearchHit(snapshotID: snapshotID, entry: e) }
                showInspector = true
            }
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
        case .modified, .missing: list = list.filter { matches($0, filter) }
        case .added: list = model.added()
        }
        return sortOrder.isEmpty ? list : list.sorted(using: sortOrder)
    }

    private func matches(_ e: Entry, _ f: ChangeFilter) -> Bool {
        guard let s = model.status(of: e) else { return false }
        return f == .modified ? s.own == .modified || s.modifiedInside : s.own == .missing || s.missingInside
    }

    private func icon(_ e: Entry) -> some View {
        Image(nsImage: FileIcon.image(for: e)).resizable().frame(width: 16, height: 16)
    }

    /// Words in a coloured capsule: the change since this backup reads without hovering.
    @ViewBuilder private func statusPill(_ s: RowStatus?, added: Bool = false) -> some View {
        if added { StatusPill(text: "Nuovo", color: .green) }
        else if let s {
            if s.own == .missing { StatusPill(text: "Eliminato", color: .red) }
            else if s.own == .modified { StatusPill(text: "Modificato", color: .orange) }
            else if s.modifiedInside { StatusPill(text: "Contiene modifiche", color: .orange) }
            else if s.missingInside { StatusPill(text: "Contiene eliminati", color: .red) }
        }
    }

    struct Place: Equatable { var source: String?; var path: String }

    private var here: Place { Place(source: model.source, path: model.currentPath) }

    private func open(_ path: String) { go(Place(source: model.source, path: path)) }
    /// -1 newer, +1 older, in the sidebar's order.
    private func stepBackup(_ by: Int) {
        guard let i = model.snapshots.firstIndex(where: { $0.id == model.selectedID }),
              model.snapshots.indices.contains(i + by) else { return }
        model.search = ""
        model.selectedID = model.snapshots[i + by].id
    }

    private func goUp() {
        if model.currentPath.isEmpty { go(Place(source: nil, path: "")) } else { open((model.currentPath as NSString).deletingLastPathComponent) }
    }

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
        // the path is in the path bar: here the backup being viewed
        return model.selected.map { "Backup del " + $0.date.formatted(date: .complete, time: .shortened) } ?? ""
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
            if check.newFiles > 0 {
                text += "\n\n\(check.newFiles == 1 ? "1 file è stato creato" : "\(check.newFiles) file sono stati creati") dopo il backup e non \(check.newFiles == 1 ? "c'è" : "ci sono"): \(check.newFiles == 1 ? "finirà" : "finiranno") nel Cestino."
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
        // fixed before the panel: a backup finishing while it is open may refresh the list and change the selection
        let t = targets
        guard let id = targetSnapshot else { return }
        chooseFolder { model.restore(snapshotID: id, items: t.map { ($0.source, $0.path) }, mode: .into($0)) }
    }

    /// Every saved folder this backup has: at the top level the rows are their roots. Folders with the same name
    /// go into a subfolder named after their parent ("Lavoro/src", "Personale/src"), not "src" and "src 2".
    private func restoreAllInto() {
        guard let id = model.selectedID else { return }
        let present = model.children().map(\.source)
        let missing = model.sources.filter { !present.contains($0) }
        let names = present.map { ($0 as NSString).lastPathComponent }
        var subfolders: [String: String] = [:]
        for s in present where names.filter({ $0 == (s as NSString).lastPathComponent }).count > 1 {
            subfolders[s] = ((s as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        // a partial backup lists a folder it couldn't read: say so before a folder is chosen, not after
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Non tutto è in questo backup"
            alert.informativeText = "Non sono in questo backup, che è parziale: "
                + missing.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
                + ". Per riaverle scegli un backup precedente."
            alert.addButton(withTitle: "Ripristina il resto…")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        chooseFolder { dir in
            model.restore(snapshotID: id, items: present.map { (source: $0, path: "") }, mode: .into(dir), subfolders: subfolders)
        }
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

    // MARK: sidebar grouping

    private struct BackupGroup {
        var title: String
        /// Days of the last week list hours; months list days.
        var byHour: Bool
        var items: [(id: String, date: Date)]
    }

    /// Newest first: today, yesterday and each other day of the last week, then one section per month.
    private var groups: [BackupGroup] {
        let cal = Calendar.current
        let weekAgo = cal.startOfDay(for: Date()).addingTimeInterval(-6 * 86400)
        var result: [BackupGroup] = []
        for s in model.snapshots {
            let byHour = s.date >= weekAgo
            let t = cal.isDateInToday(s.date) ? "Oggi" : cal.isDateInYesterday(s.date) ? "Ieri"
                : byHour ? s.date.formatted(.dateTime.weekday(.wide).day()).capitalized
                : s.date.formatted(.dateTime.month(.wide).year()).capitalized
            if result.last?.title == t { result[result.count - 1].items.append(s) } else { result.append(BackupGroup(title: t, byHour: byHour, items: [s])) }
        }
        return result
    }

    /// An hour, or a day; a day with more than one backup in its month also gets the hour.
    private func chipLabel(_ date: Date, in group: BackupGroup) -> String {
        if group.byHour { return date.formatted(date: .omitted, time: .shortened) }
        let cal = Calendar.current
        let day = date.formatted(.dateTime.weekday(.abbreviated).day())
        return group.items.filter { cal.isDate($0.date, inSameDayAs: date) }.count > 1
            ? day + " " + date.formatted(date: .omitted, time: .shortened) : day
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

private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// The selected item: what it is, how it differs from today and, for a file, every saved version.
private struct EntryInspector: View {
    let model: RestoreModel
    let entry: Entry
    let snapshotID: String
    let status: RowStatus?
    let preview: (Entry) -> Void
    @State private var versions: [SearchHit]? // nil while loading
    @State private var picked: SearchHit?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline).lineLimit(2).textSelection(.enabled)
                        badge
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if entry.kind == .file { row("Dimensione", ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) }
                    row("Modificato", entry.mtime.formatted(date: .abbreviated, time: .shortened))
                    row("Posizione", ((entry.source as NSString).abbreviatingWithTildeInPath as NSString)
                        .appendingPathComponent((entry.path as NSString).deletingLastPathComponent))
                }
                if entry.kind == .file { versionsList }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard entry.kind == .file else { return }
            // moving through files with the arrows cancels this before any manifest is read
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.versions(of: entry, preferring: snapshotID).map { SearchHit(snapshotID: $0.snapshotID, entry: $0.entry) }
            guard !Task.isCancelled else { return }
            versions = found
            picked = found.first { $0.snapshotID == snapshotID } ?? found.first
        }
    }

    @ViewBuilder private var badge: some View {
        if let status, status.own == .missing { StatusPill(text: "Eliminato da allora", color: .red) }
        else if let status, status.own == .modified { StatusPill(text: "Modificato da allora", color: .orange) }
        else if let status, status.modifiedInside { StatusPill(text: "Contiene modifiche", color: .orange) }
        else if let status, status.missingInside { StatusPill(text: "Contiene eliminati", color: .red) }
        else if model.showsStatus, status != nil { StatusPill(text: "Uguale a oggi", color: .secondary) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }.font(.callout)
    }

    @ViewBuilder private var versionsList: some View {
        Divider()
        Text("Versioni salvate").font(.subheadline.weight(.semibold))
        if let versions {
            if versions.isEmpty { Text("Nessuna versione leggibile").foregroundStyle(.secondary) }
            VStack(spacing: 2) {
                ForEach(versions) { v in
                    Button { picked = v } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Snapshot.date(fromID: v.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? v.snapshotID)
                                    .monospacedDigit()
                                if v.entry.hash == entry.hash { Text("in questo backup").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: v.entry.size, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(picked == v ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Una riga per ogni contenuto diverso, dalla più recente.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Anteprima") { preview(picked?.entry ?? entry) }
                // the version picked, as Anteprima and Ripristina use
                if model.showsStatus, let v = picked, Restorer.status(of: v.entry) == .modified {
                    Button("Confronta con oggi") { model.compare(v.entry) }
                }
                Spacer()
                Button("Ripristina") {
                    if let v = picked { model.restore(snapshotID: v.snapshotID, source: v.entry.source, path: v.entry.path, mode: .besideOriginal) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked == nil || model.restoring)
                .help("Ripristina la versione scelta accanto all'originale, senza sovrascrivere")
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

extension View {
    @ViewBuilder fileprivate func hidingToolbarTitle() -> some View {
        if #available(macOS 15, *) { toolbar(removing: .title) } else { self }
    }
}

extension Entry: Identifiable {
    public var id: String { source + "\u{0}" + path }
}
