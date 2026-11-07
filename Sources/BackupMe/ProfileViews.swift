import AppKit
import BackupCore
import SwiftUI

extension SizeScan {
    /// Measured off the main thread; cancelling the caller (the view going away) stops the walk.
    static func measureInBackground(_ source: String, rules: ExcludeRules) async -> SizeScan? {
        let job = Task.detached(priority: .utility) { SizeScan.measure(source, rules: rules) { Task.isCancelled } }
        return await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }

    static func describe(files: Int, bytes: Int64) -> String {
        "\(files.formatted()) file · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

/// What the backup of the profile saves, and its biggest folders, each with a box to leave it out.
struct FolderSizeList: View {
    let scan: SizeScan
    @Binding var excluded: Set<String>
    /// Left out elsewhere (picked by hand): counted in the total, without a row of their own.
    var also: Set<String> = []
    /// Top folders showing the folders inside them.
    @State private var open: Set<String> = []

    var body: some View {
        let left = scan.remaining(excluding: excluded.union(also))
        LabeledContent("Il backup salverà", value: SizeScan.describe(files: left.files, bytes: left.bytes))
            .fontWeight(.semibold)
        ForEach(scan.folders.filter { $0.bytes >= SizeScan.notable }, id: \.path) { f in
            let inside = f.children.filter { $0.bytes >= SizeScan.notable }
            row(f, top: true, hasInside: !inside.isEmpty)
            if open.contains(f.path) {
                // a folder inside an excluded one is left out with it
                ForEach(inside, id: \.path) { row($0).disabled(excluded.contains(f.path)) }
            }
        }
    }

    /// A top folder gets its own arrow: a DisclosureGroup took a click on the arrow as a click on the box.
    private func row(_ f: SizeScan.Folder, top: Bool = false, hasInside: Bool = false) -> some View {
        let name = (f.path as NSString).lastPathComponent
        let out = excluded.contains(f.path)
        let shown = open.contains(f.path)
        return HStack {
            if top {
                Button {
                    if shown { open.remove(f.path) } else { open.insert(f.path) }
                } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(shown ? 90 : 0))
                }
                .buttonStyle(.borderless)
                .frame(width: 14)
                .opacity(hasInside ? 1 : 0) // nothing inside worth a row: kept for the alignment
                .disabled(!hasInside)
                .accessibilityLabel(shown ? "Nascondi le cartelle in \(name)" : "Mostra le cartelle in \(name)")
            } else {
                Spacer().frame(width: 36) // inside a top folder
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading) {
                Text(name).strikethrough(out)
                Text(SizeScan.describe(files: f.files, bytes: f.bytes)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Escludi", isOn: Binding(get: { out }, set: { if $0 { excluded.insert(f.path) } else { excluded.remove(f.path) } }))
                .toggleStyle(.checkbox)
                .accessibilityLabel("Escludi \(name)")
        }
        .contextMenu {
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
        }
    }
}

/// One automatic exclusion, with why it is left out.
struct AutomaticRow: View {
    let item: ExcludeRules.Automatic

    var body: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading) {
                Text((item.path as NSString).lastPathComponent)
                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// Before the whole profile is saved: what is left out on its own, the biggest folders it would save, and what
/// the user leaves out too. Nothing changes until "Aggiungi profilo".
struct ProfileSheet: View {
    @Bindable var model: AppModel
    /// Adds the profile to the sources, checked against the destination like any other folder.
    let add: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scan: SizeScan?
    @State private var scanning = true
    @State private var excluded: Set<String> = []
    @State private var picked: [String] = []
    @State private var pickError: String?
    private static let home = NSHomeDirectory()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Profilo completo").font(.title2.bold())
                Text("Tutta la cartella Inizio, file e cartelle. Controlla cosa resta fuori e cosa verrà salvato.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 20).padding(.horizontal, 32)

            Form {
                Section {
                    if let scan {
                        FolderSizeList(scan: scan, excluded: $excluded, also: Set(picked))
                    } else if scanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Analisi della cartella Inizio…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Non è stato possibile leggere la cartella Inizio.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Cosa verrà salvato")
                } footer: {
                    Text("Le cartelle di oltre 100 MB, dalla più grande. Spunta Escludi per lasciarne fuori una.")
                }
                Section {
                    ForEach(picked, id: \.self) { path in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading) {
                                Text((path as NSString).lastPathComponent)
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Togli", systemImage: "minus.circle.fill", role: .destructive) { picked.removeAll { $0 == path } }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .help("Togli \((path as NSString).lastPathComponent) dalle esclusioni")
                        }
                    }
                    if let pickError { ErrorRow(text: pickError) }
                    Button("Escludi altre cartelle o file…", systemImage: "plus", action: pick)
                } header: {
                    Text("Altre esclusioni")
                }
                Section("Escluse in automatico") {
                    ForEach(model.settings.automaticExclusions(adding: Self.home), id: \.self) { AutomaticRow(item: $0) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Le esclusioni si cambiano poi in Impostazioni › Esclusioni.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aggiungi profilo", action: confirm).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .task {
            scan = await SizeScan.measureInBackground(Self.home, rules: model.settings.excludeRules)
            scanning = false
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Escludi"
        panel.directoryURL = URL(fileURLWithPath: Self.home)
        guard panel.runModal() == .OK else { return }
        pickError = nil
        for url in panel.urls where !picked.contains(url.path) {
            // outside the profile a rule has no effect, and the profile itself is what is being added
            guard url.path.hasPrefix(Self.home + "/") else {
                pickError = "\(url.lastPathComponent) non è nella cartella Inizio"
                continue
            }
            picked.append(url.path)
        }
    }

    private func confirm() {
        add()
        // refused (the profile is inside the archive): no rules for a profile that isn't saved
        if model.settings.sources.contains(Self.home) {
            for path in excluded.sorted() + picked where !model.settings.excludedPaths.contains(path) {
                model.settings.excludedPaths.append(path)
            }
        }
        dismiss()
    }
}
