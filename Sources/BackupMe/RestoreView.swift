import AppKit
import BackupCore
import QuickLook
import RestoreRules
import SwiftUI
import UniformTypeIdentifiers

struct RestoreView: View {
    @State var model: RestoreModel
    @State private var selectedIDs = Set<Entry.ID>()
    @State private var hit: SearchHit?
    @State private var check: Restorer.ReplaceCheck?
    /// The check of what Sostituisci would send to the Trash is running: it walks the whole folder.
    @State private var checking = false
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
    /// The saved version chosen in the inspector: what the bar's Anteprima, Confronta and Ripristina act on.
    @State private var picked: SearchHit?
    /// Bumped to scroll the timeline to the chosen backup when the choice comes from outside it.
    @State private var reveal = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The sidebar's width, read from inside it: the bar starts where the sidebar ends.
    @State private var sidebarWidth: CGFloat = 0

    // split in small parts: as one chain the body is too big for the type checker
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
        v.onChange(of: model.selectedID) { _, _ in selectedIDs = []; picked = nil }
            .onChange(of: model.search) { _, _ in hit = nil; picked = nil }
            // a filter hiding selected rows deselects them: actions act only on what is visible
            .onChange(of: rows.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
            .onChange(of: deletedOnly) { _, _ in if let h = hit, !shownResults.contains(h) { hit = nil } }
            // a new selection has no chosen version yet
            .onChange(of: selectedIDs) { _, _ in picked = nil }
            .onChange(of: hit) { _, _ in picked = nil }
            .onChange(of: model.computer, initial: true) {
                hit = nil; selectedIDs = []; back = []; forward = []; picked = nil; reveal += 1
                columns[visibility: "stato"] = model.showsStatus ? .automatic : .hidden
                if !model.showsStatus { filter = .all; deletedOnly = false }
            }
            // a sidebar that hides stops reporting its width: the bar must not keep room for it
            .onChange(of: columnVisibility) { _, v in if v == .detailOnly { sidebarWidth = 0 } }
            .onChange(of: model.app.settings.destination) { _, _ in model.reload() }
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
            .onChange(of: model.app.lastReport?.date) { _, _ in model.refreshList() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshList() }
            .onVolumeChange { model.refreshList() } // a destination disk plugged in or pulled out
            .background {
                Group {
                    Button("Cartella superiore", action: goUp).keyboardShortcut(.upArrow, modifiers: .command)
                        .disabled(model.source == nil || !model.search.isEmpty)
                    // the timeline takes no keyboard focus: newer and older backup from the keyboard
                    Button("Backup più recente") { stepBackup(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    Button("Backup più vecchio") { stepBackup(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    // here, not on the bar's menu: a Menu's shortcuts don't fire while it is closed
                    Button("Ripristina") { restoreTargets() }.keyboardShortcut("r").disabled(restoreDisabled)
                    Button("Ripristina in…") { restoreTargetsInto() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(restoreDisabled)
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
        // backups in the timeline on the left, where they are always visible; details and versions in the inspector
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                // minimums on the columns, not on the window: a window-wide minimum makes the sidebar jump when it
                // collapses, as the window is re-constrained on every frame of the animation
                .frame(minWidth: 440, minHeight: 420)
                .safeAreaPadding(.bottom, showsBar ? RestoreActionBar.height : 0)
                .inspector(isPresented: $showInspector) {
                    inspector.inspectorColumnWidth(min: 260, ideal: 310, max: 380)
                }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarItems }
        .hidingToolbarTitle() // the path in the toolbar says where you are; the title stays for the Window menu
        // the bar floats over the list and the inspector alike, so it is laid over the whole split view
        .overlay(alignment: .bottom) {
            if showsBar {
                let urls = todayURLs
                RestoreActionBar(
                    bar: bar, entry: barEntry, disabled: restoreDisabled, busy: busy, help: restoreHelp,
                    revealTitle: revealTitle, revealIcon: revealIcon, canReveal: !urls.isEmpty,
                    canShowVersions: barFile != nil, preview: barPreview,
                    compare: { if let e = barFile { model.compare(picked?.entry ?? e) } },
                    restore: restoreTargets, restoreInto: restoreTargetsInto, reveal: revealSelection,
                    showVersions: { showInspector = true })
                    .padding(.leading, sidebarWidth + 12)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    private var sidebar: some View {
        RestoreTimeline(
            model: model, items: timelineItems, reveal: reveal, showStatus: model.showsStatus,
            statusText: model.app.statusText, statusColor: model.app.statusColor, statusSymbol: model.app.statusSymbol,
            locale: .current
        ) { id in
            model.search = "" // a backup picked while searching: show it
            model.selectedID = id
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        .background {
            GeometryReader { g in
                Color.clear.onChange(of: g.size.width, initial: true) { _, width in sidebarWidth = width }
            }
        }
    }

    private var detail: some View {
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
                RestoreBrowser(
                    model: model, items: timelineItems, rows: rows, results: shownResults, actions: actions,
                    filter: $filter, deletedOnly: $deletedOnly,
                    selectedIDs: $selectedIDs, hit: $hit, showInspector: $showInspector, sortOrder: $sortOrder, columns: $columns,
                    locale: .current)
            }
        }
    }

    private var inspector: some View {
        RestoreInspector(model: model, selection: selection, status: statusOf, showsStatus: model.showsStatus,
                         picked: $picked, locale: .current)
            .safeAreaPadding(.bottom, showsBar ? RestoreActionBar.height : 0)
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

    // MARK: the bar

    private var timelineItems: [TimelineItem] {
        BackupTimeline.items(snapshots: model.snapshots, history: model.app.history) { model.warningCount($0) }
    }

    /// What the window has selected, for the rules: they say what «Ripristina» acts on, as they always did.
    private var selection: RestorePlanner.Selection {
        var s = RestorePlanner.Selection()
        s.backup = model.selected.map { .init(id: $0.id, date: $0.date) }
        s.searching = !model.search.isEmpty
        s.hit = hit.map { h in
            .init(backup: .init(id: h.snapshotID, date: Snapshot.date(fromID: h.snapshotID) ?? model.selected?.date ?? .distantPast),
                 entry: h.entry)
        }
        s.source = model.source
        s.path = model.currentPath
        s.visible = model.search.isEmpty ? rows : []
        s.selectedIDs = selectedIDs
        if let e = chosenFile, let picked, picked.entry.source == e.source, picked.entry.path == e.path {
            s.version = .init(backup: .init(id: picked.snapshotID, date: Snapshot.date(fromID: picked.snapshotID) ?? e.mtime),
                              entry: picked.entry)
        }
        s.sources = model.sources
        return s
    }

    private var plan: RestorePlanner.Plan { RestorePlanner.resolve(selection) }
    private var bar: RestorePlanner.Bar { RestorePlanner.bar(plan, selection: selection, compare: canCompare) }

    /// The rows chosen in the list, whatever they are.
    private var selectedRows: [Entry] { selection.visible.filter { selectedIDs.contains($0.restoreID) } }

    /// The only selected file, when there is just one: the one that has saved versions.
    private var chosenFile: Entry? {
        if !model.search.isEmpty { return hit.flatMap { $0.entry.kind == .file ? $0.entry : nil } }
        let files = model.children().filter { selectedIDs.contains($0.id) && $0.kind == .file }
        return files.count == 1 ? files.first : nil
    }

    /// The file the bar acts on: the chosen version when there is one, else the selected file.
    private var barFile: Entry? {
        if case .version(let item) = plan.action { return item.entry }
        return chosenFile
    }

    /// Confronta is for a saved file that differs from today's, on this Mac.
    private var canCompare: Bool {
        guard model.showsStatus, let e = barFile, e.kind == .file, e.hash != nil else { return false }
        return Restorer.status(of: e) == .modified
    }

    /// The file or folder the bar speaks of, for its icon.
    private var barEntry: Entry? { plan.items.count == 1 ? plan.items.first?.entry : nil }

    /// Nothing comes back from the plan, a restore runs, or the check before «Sostituisci» runs.
    private var restoreDisabled: Bool { plan.action == .nothing || model.restoring || checking }

    private var busy: String? {
        if model.restoring { return "Ripristino in corso…" }
        if checking { return "Controllo della cartella attuale…" }
        return nil
    }

    /// Hidden until there is a backup to act on, so that it doesn't flash while a backup loads.
    private var showsBar: Bool {
        model.hasDestination && model.notConnectedText == nil && (model.isLoading || !model.snapshots.isEmpty)
    }

    private var restoreHelp: String {
        // short names, big targets: what each one does exactly is in the tooltip
        switch plan.action {
        case .nothing: return "Seleziona un elemento da ripristinare"
        case .wholeBackup: return "Ripristina tutte le cartelle di questo backup in una cartella a scelta"
        case .wholeFolder: return "Ripristina «\(bar.name)»: chiede come, accanto all'originale, in una cartella… o sostituendo quella attuale"
        case .version: return "Ripristina la versione scelta accanto all'originale, senza sovrascrivere"
        case .items(let items):
            return items.count > 1 ? "Ripristina \(items.count) elementi accanto agli originali, senza sovrascrivere"
                : "Ripristina «\(bar.name)» accanto all'originale, senza sovrascrivere"
        }
    }

    /// In a search the Finder's place is taken by the backup that holds the result.
    private var revealTitle: String { model.search.isEmpty ? "Mostra nel Finder" : "Mostra nel backup" }
    private var revealIcon: String { model.search.isEmpty ? "folder" : "clock.arrow.circlepath" }

    /// What the action restores and is still on this Mac, to show in the Finder; with nothing to restore, the rows chosen.
    private var todayURLs: [URL] {
        guard model.search.isEmpty else { return hit.map { [$0.entry.url] } ?? [] }
        // «Nuovo» rows have nothing to restore: where they are today is the only thing there is to show
        let items = plan.action == .nothing ? selectedRows.map { RestorePlanner.Item($0) } : plan.items
        return items.compactMap { item in
            // the folder's rows were compared with the disk once, off the main thread; a chosen version wasn't, and there is one
            if let e = item.entry, e.kind != .directory {
                let missing = model.status(of: e).map { $0.own == .missing } ?? (Restorer.status(of: e) == .missing)
                if missing { return nil }
            }
            guard let e = item.entry else {
                // the folder being viewed
                let url = URL(fileURLWithPath: item.source).appending(path: item.path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return e.url
        }
    }

    private func statusOf(_ e: Entry) -> RowStatus? {
        // the inspector shows the selection: a search result is against the disk, by its own backup
        model.search.isEmpty ? model.status(of: e)
            : model.resultStatus[SearchHit(snapshotID: hit?.snapshotID ?? "", entry: e)].map { RowStatus(own: $0) }
    }

    private var actions: RestoreActions {
        RestoreActions(
            enter: enter,
            preview: preview,
            restore: { id, items in model.restore(snapshotID: id, items: items, mode: .besideOriginal) },
            restoreInto: { id, items in chooseFolder { dir in model.restore(snapshotID: id, items: items, mode: .into(dir)) } },
            compare: { model.compare($0) },
            reveal: { h in model.reveal(h); reveal += 1 },
            quickLook: quickLook,
            dragProvider: dragProvider)
    }

    // MARK: path

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

    /// No sort chosen keeps the index order: folders first, then names. The filter needs the folder's status.
    private var rows: [Entry] {
        var list = model.children()
        switch filter {
        case .all: break
        case .modified, .missing: list = list.filter { model.matches($0, filter) }
        case .added: list = model.added()
        }
        return sortOrder.isEmpty ? list : list.sorted(using: sortOrder)
    }

    private var shownResults: [SearchHit] {
        deletedOnly ? model.results.filter { model.resultStatus[$0] == .missing } : model.results
    }

    struct Place: Equatable { var source: String?; var path: String }

    private var here: Place { Place(source: model.source, path: model.currentPath) }

    private func open(_ path: String) { go(Place(source: model.source, path: path)) }

    /// -1 newer, +1 older, in the timeline's order.
    private func stepBackup(_ by: Int) {
        guard let i = model.snapshots.firstIndex(where: { $0.id == model.selectedID }),
              model.snapshots.indices.contains(i + by) else { return }
        model.search = ""
        model.selectedID = model.snapshots[i + by].id
        reveal += 1
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

    /// ⌘R, and the bar's button: what the plan says, beside the original, by the rules that always held (a whole saved folder asks first).
    private func restoreTargets() {
        guard !restoreDisabled, let id = plan.from?.id else { return }
        switch plan.action {
        case .nothing: break
        case .wholeBackup: restoreAllInto()
        case .wholeFolder(let source): askWholeFolder(source: source, id: id)
        case .items(let items):
            model.restore(snapshotID: id, items: items.map { ($0.source, $0.path) }, mode: .besideOriginal)
        case .version(let item):
            model.restore(snapshotID: id, items: [(item.source, item.path)], mode: .besideOriginal)
        }
    }

    /// ⇧⌘R, and «Ripristina in…» in the bar's menu: the same items, into a folder of choice.
    private func restoreTargetsInto() {
        guard !restoreDisabled, let id = plan.from?.id else { return }
        switch plan.action {
        case .nothing: break
        case .wholeBackup: restoreAllInto()
        case .wholeFolder, .items, .version:
            let items = plan.items.map { ($0.source, $0.path) }
            // fixed before the panel: a backup finishing while it is open may refresh the list and change the selection
            chooseFolder { dir in model.restore(snapshotID: id, items: items, mode: .into(dir)) }
        }
    }

    /// Anteprima in the bar: the chosen version, or the file as this backup has it.
    private func barPreview() {
        guard let e = barFile else { return }
        preview(picked?.entry ?? e)
    }

    /// «Mostra nel Finder», or «Mostra nel backup» in a search.
    private func revealSelection() {
        if let h = hit, !model.search.isEmpty {
            model.reveal(h)
            reveal += 1
        } else {
            let urls = todayURLs
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// Space in the list: Quick Look of the selected file, or close it.
    private func quickLook() -> Bool {
        guard let e = chosenFile else { return false }
        if previewURL != nil { previewURL = nil } else { preview(e) }
        return true
    }

    /// A whole saved folder asks first: replacing it is on offer there, and only there.
    private func askWholeFolder(source: String, id: String) {
        check = nil
        checking = true // a double click would start a second check, and ask twice
        Task {
            if model.showsStatus, model.app.settings.sources.contains(source) { check = await model.replaceCheck(source: source) }
            checking = false
            whole = (id, (source, "", nil))
        }
    }

    private var replaceMessage: String {
        var text = "Sostituisci sposta nel Cestino la cartella attuale, comprese le cartelle escluse dal backup (es. node_modules), e la rimpiazza con la versione salvata."
        if let check {
            if check.changedFiles > 0 {
                text += "\n\n\(check.changedFiles == 1 ? "1 file è cambiato" : "\(check.changedFiles) file sono cambiati") dopo il backup: le versioni di oggi finiranno nel Cestino."
            }
            if check.newFiles > 0 {
                text += "\n\n\(check.newFiles == 1 ? "1 file non è" : "\(check.newFiles) file non sono") nel backup (nuovi o non salvati): \(check.newFiles == 1 ? "finirà" : "finiranno") nel Cestino."
            }
            if check.repositoryChanged {
                text += "\n\nIl repository git ha commit o branch più recenti del backup: finiranno nel Cestino con la cartella."
            }
        }
        return text
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
}

extension View {
    @ViewBuilder fileprivate func hidingToolbarTitle() -> some View {
        if #available(macOS 15, *) { toolbar(removing: .title) } else { self }
    }
}

extension Entry: Identifiable {
    public var id: String { restoreID }
}
