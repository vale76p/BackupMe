import AppKit
import BackupCore
import SwiftUI

struct RestoreView: View {
    @State var model: RestoreModel
    @State private var entryID: Entry.ID?
    @State private var hit: SearchHit?
    @State private var confirmWhole = false
    @State private var versionsOf: Entry?

    private var selection: Entry? { entryID.flatMap(entry) }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items, id: \.id) { s in Text(label(s.date, in: group.title)).tag(s.id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                if model.search.isEmpty { browser } else { results }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                Button("Tutte le cartelle", systemImage: "externaldrive") { model.source = nil; open("") }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Cartella superiore", systemImage: "chevron.up") {
                    if model.currentPath.isEmpty { model.source = nil; open("") }
                    else { open((model.currentPath as NSString).deletingLastPathComponent) }
                }
                .disabled(model.source == nil || !model.search.isEmpty)
                .help("Cartella superiore")
            }
            if model.computers.count > 1 {
                ToolbarItem {
                    Picker("Computer", selection: $model.computer) { ForEach(model.computers, id: \.self) { Text($0) } }
                        .help("Computer di origine")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // one native pull-down: click restores beside the original, the arrow offers the rest
                Menu {
                    Button("Ripristina in…", systemImage: "folder.badge.plus") { if let t = target { restoreInto(path: t.path) } }
                    Button("Mostra versioni del file", systemImage: "clock.arrow.circlepath") { versionsOf = target?.entry }
                        .disabled(target?.entry?.kind != .file)
                } label: {
                    Label("Ripristina", systemImage: "arrow.uturn.backward")
                } primaryAction: {
                    guard let t = target else { return }
                    if t.path.isEmpty { confirmWhole = true } else { restore(path: t.path, mode: .besideOriginal) }
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.large)
                .disabled(target == nil || model.busy != nil)
                .help("Ripristina accanto all'originale, senza sovrascrivere")
            }
        }
        .searchable(text: $model.search, prompt: "Cerca in tutti i backup")
        .onChange(of: model.selectedID) { entryID = nil }
        .onChange(of: model.search) { hit = nil }
        .onChange(of: model.computer) { hit = nil; entryID = nil }
        .onAppear { model.reload() }
        .frame(minWidth: 860, minHeight: 500)
        .confirmationDialog("Ripristinare l'intera cartella?", isPresented: $confirmWhole) {
            // replacing in place only for folders this Mac backs up now: a tampered or foreign manifest
            // must not be able to send an arbitrary folder to the Trash
            if let t = target, model.app.settings.sources.contains(t.source) {
                Button("Sostituisci", role: .destructive) { restore(path: "", mode: .replace) }
            }
            Button("Ripristina in…") { restoreInto(path: "") }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Sostituisci sposta nel Cestino la cartella attuale, comprese le cartelle escluse dal backup (es. node_modules) e i file più recenti del backup, e la rimpiazza con la versione salvata.")
        }
        .sheet(item: $versionsOf) { VersionsSheet(model: model, entry: $0) }
        .alert("Errore", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") {}
        } message: { Text(model.error ?? "") }
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
                                   description: Text("Seleziona una data nella barra laterale."))
        } else if model.selected == nil {
            ProgressView() // the chosen backup's index is still loading
        } else {
            Table(model.children(), selection: $entryID) {
                TableColumn("Nome") { e in
                    HStack(spacing: 6) {
                        icon(e)
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        switch Restorer.status(of: e) {
                        case .modified: Tag(text: "modificato")
                        case .missing: Tag(text: "non più presente oggi")
                        case .unchanged: EmptyView()
                        }
                    }
                }
                TableColumn("Dimensione") { e in
                    Text(e.kind == .file ? ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file) : "—")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Modificato") { e in
                    Text(e.mtime.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 120, ideal: 150, max: 200)
            }
            .contextMenu(forSelectionType: Entry.ID.self) { ids in
                if let e = ids.first.flatMap(entry), let id = model.selectedID {
                    rowMenu(snapshotID: id, entry: e)
                }
            } primaryAction: { ids in
                if let e = ids.first.flatMap(entry), e.kind == .directory { enter(e) }
            }
        }
    }

    private var results: some View {
        Table(model.results, selection: $hit) {
            TableColumn("Nome") { h in
                HStack(spacing: 6) { icon(h.entry); Text(h.entry.name).lineLimit(1) }
            }
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
            if let h = hits.first { rowMenu(snapshotID: h.snapshotID, entry: h.entry) }
        }
        .overlay {
            if model.results.isEmpty, model.busy == nil { ContentUnavailableView.search(text: model.search) }
        }
    }

    @ViewBuilder private func rowMenu(snapshotID: String, entry e: Entry) -> some View {
        if e.kind == .directory, model.search.isEmpty { Button("Apri") { enter(e) } }
        Button("Ripristina") { model.restore(snapshotID: snapshotID, source: e.source, path: e.path, mode: .besideOriginal) }
        Button("Ripristina in…") { restoreInto(snapshotID: snapshotID, source: e.source, path: e.path) }
        if e.kind == .file {
            Divider()
            Button("Mostra versioni del file") { versionsOf = e }
        }
    }

    private func icon(_ e: Entry) -> some View {
        Image(systemName: e.kind == .directory ? "folder.fill" : e.kind == .symlink ? "arrow.turn.up.right" : "doc")
            .foregroundStyle(e.kind == .directory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 16)
    }

    private func entry(_ id: Entry.ID) -> Entry? { model.children().first { $0.id == id } }

    private func open(_ path: String) {
        model.currentPath = path
        entryID = nil
    }

    /// Works at the top level too, where the rows are the saved folders.
    private func enter(_ e: Entry) {
        model.source = e.source
        open(e.path)
    }

    private var rootName: String { model.source.map { ($0 as NSString).lastPathComponent } ?? "Tutte le cartelle" }

    private var title: String {
        guard model.search.isEmpty else { return "Ricerca" }
        return model.currentPath.isEmpty ? rootName : (model.currentPath as NSString).lastPathComponent
    }

    private var subtitle: String {
        if let busy = model.busy { return busy }
        if !model.search.isEmpty { return model.results.count == 1 ? "1 risultato" : "\(model.results.count) risultati" }
        return model.selected.map { "Backup del " + $0.date.formatted(date: .abbreviated, time: .shortened) } ?? ""
    }

    // MARK: actions

    /// What the toolbar buttons act on: a search hit, the selected item, or the folder being viewed.
    private var target: (snapshotID: String, source: String, path: String, entry: Entry?)? {
        if !model.search.isEmpty {
            return hit.map { ($0.snapshotID, $0.entry.source, $0.entry.path, $0.entry) }
        }
        guard let id = model.selectedID else { return nil }
        if let e = selection { return (id, e.source, e.path, e) }
        guard let source = model.source else { return nil } // top level, nothing selected
        return (id, source, model.currentPath, nil)
    }

    private func restore(path: String, mode: RestoreMode) {
        guard let t = target else { return }
        model.restore(snapshotID: t.snapshotID, source: t.source, path: path, mode: mode)
    }

    private func restoreInto(path: String) {
        guard let t = target else { return }
        restoreInto(snapshotID: t.snapshotID, source: t.source, path: path)
    }

    private func restoreInto(snapshotID: String, source: String, path: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Ripristina qui"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        model.restore(snapshotID: snapshotID, source: source, path: path, mode: .into(dir))
    }

    // MARK: sidebar grouping

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

    private func label(_ date: Date, in group: String) -> String {
        group == "Oggi" || group == "Ieri"
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        // a fill, not glass: glass is for controls, and dozens of glass views in a scrolling table glitch
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

private struct VersionsSheet: View {
    let model: RestoreModel
    let entry: Entry
    @State private var versions: [(snapshotID: String, entry: Entry)] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("Versioni di \(entry.name)").font(.headline)
            List(versions, id: \.snapshotID) { v in
                HStack {
                    Text(Snapshot.date(fromID: v.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? v.snapshotID)
                    Text(ByteCountFormatter.string(fromByteCount: v.entry.size, countStyle: .file)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ripristina", systemImage: "arrow.uturn.backward") {
                        model.restore(snapshotID: v.snapshotID, source: v.entry.source, path: v.entry.path, mode: .besideOriginal)
                        dismiss()
                    }
                    .glassButton()
                }
            }
            .frame(minHeight: 200)
            HStack { Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction).glassButton() }
        }
        .padding()
        .frame(width: 460)
        .task { versions = await model.versions(of: entry) }
    }
}

extension Entry: Identifiable {
    public var id: String { source + "\u{0}" + path }
}
