import AppKit
import BackupCore
import SwiftUI

struct RestoreView: View {
    @State var model: RestoreModel
    @State private var selection: Entry?
    @State private var hit: SearchHit?
    @State private var confirmWhole = false
    @State private var versionsOf: Entry?

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
            .safeAreaInset(edge: .bottom) {
                actions.padding(.horizontal, 10).padding(.vertical, 8).glassPanel(in: Capsule()).padding(12)
            }
        }
        .toolbar {
            if model.computers.count > 1 {
                Picker("Computer", selection: $model.computer) { ForEach(model.computers, id: \.self) { Text($0) } }
            }
            Picker("Cartella", selection: $model.source) {
                // full path: two sources can share a folder name
                ForEach(model.sources, id: \.self) { Text(($0 as NSString).abbreviatingWithTildeInPath).tag(Optional($0)) }
            }
            .onChange(of: model.source) { model.currentPath = ""; selection = nil }
        }
        .searchable(text: $model.search, prompt: "Cerca file e cartelle in tutti i backup")
        .onChange(of: model.selectedID) { selection = nil }
        .onChange(of: model.search) { hit = nil }
        .onChange(of: model.computer) { hit = nil; selection = nil }
        .onAppear { model.reload() }
        .frame(minWidth: 760, minHeight: 460)
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

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassPanel(in: Capsule())
                .padding(8)
            List(model.children(), id: \.self, selection: $selection) { e in row(e) }
                .contextMenu(forSelectionType: Entry.self) { _ in } primaryAction: { items in
                    if let e = items.first, e.kind == .directory { model.currentPath = e.path; selection = nil }
                }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            let parts = model.currentPath.split(separator: "/").map(String.init)
            Button((model.source.map { ($0 as NSString).lastPathComponent }) ?? "—") { model.currentPath = ""; selection = nil }
            ForEach(parts.indices, id: \.self) { i in
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                Button(parts[i]) { model.currentPath = parts[...i].joined(separator: "/"); selection = nil }
            }
            Spacer()
            if let s = model.selected { Text(s.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
        }
        .buttonStyle(.link)
    }

    private func row(_ e: Entry) -> some View {
        HStack {
            Image(systemName: e.kind == .directory ? "folder" : e.kind == .symlink ? "arrow.turn.up.right" : "doc")
            Text(e.name)
            switch Restorer.status(of: e) {
            case .modified: Tag(text: "modificato")
            case .missing: Tag(text: "non più presente oggi")
            case .unchanged: EmptyView()
            }
            Spacer()
            if e.kind == .file { Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)).foregroundStyle(.secondary) }
            Text(e.mtime.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
        }
    }

    private var results: some View {
        VStack {
            if let busy = model.busy { ProgressView(busy).padding() }
            List(model.results, id: \.self, selection: $hit) { h in
                HStack {
                    Image(systemName: h.entry.kind == .directory ? "folder" : "doc")
                    VStack(alignment: .leading) {
                        Text(h.entry.name)
                        Text(h.entry.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Snapshot.date(fromID: h.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? "").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: actions

    /// What the buttons act on: a search hit, the selected item, or the folder being viewed.
    private var target: (snapshotID: String, source: String, path: String, entry: Entry?)? {
        if !model.search.isEmpty {
            return hit.map { ($0.snapshotID, $0.entry.source, $0.entry.path, $0.entry) }
        }
        guard let id = model.selectedID, let source = model.source else { return nil }
        if let e = selection { return (id, source, e.path, e) }
        return (id, source, model.currentPath, nil)
    }

    private var actions: some View {
        HStack {
            if let busy = model.busy, model.search.isEmpty { ProgressView().controlSize(.small); Text(busy) }
            Spacer()
            Button("Mostra versioni del file", systemImage: "clock") { versionsOf = target?.entry }
                .disabled(target?.entry?.kind != .file)
                .glassButton()
            Button("Ripristina in…", systemImage: "folder") { if let t = target { restoreInto(path: t.path) } }
                .disabled(target == nil || model.busy != nil)
                .glassButton()
            Button("Ripristina", systemImage: "arrow.uturn.backward") {
                guard let t = target else { return }
                if t.path.isEmpty { confirmWhole = true } else { restore(path: t.path, mode: .besideOriginal) }
            }
            .glassButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            .disabled(target == nil || model.busy != nil)
        }
    }

    private func restore(path: String, mode: RestoreMode) {
        guard let t = target else { return }
        model.restore(snapshotID: t.snapshotID, source: t.source, path: path, mode: mode)
    }

    private func restoreInto(path: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Ripristina qui"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        restore(path: path, mode: .into(dir))
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
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
            .glassPanel(in: Capsule())
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
