import AppKit
import BackupCore
import SwiftUI

/// The standard macOS settings window: one tab per pane in the toolbar, ⌘, from the app menu.
struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("settingsPane") private var pane = Pane.folders

    enum Pane: String, CaseIterable {
        case folders, archive, schedule, retention, excludes

        var title: String {
            switch self {
            case .folders: "Cartelle"
            case .archive: "Destinazione"
            case .schedule: "Pianificazione"
            case .retention: "Conservazione"
            case .excludes: "Esclusioni"
            }
        }

        var icon: String {
            switch self {
            case .folders: "folder"
            case .archive: "externaldrive"
            case .schedule: "calendar.badge.clock"
            case .retention: "clock.arrow.circlepath"
            case .excludes: "nosign"
            }
        }
    }

    var body: some View {
        TabView(selection: $pane) {
            ForEach(Pane.allCases, id: \.self) { p in
                Form { content(for: p) }
                    .formStyle(.grouped)
                    .tabItem { Label(p.title, systemImage: p.icon) }
                    .tag(p)
            }
        }
        // one size for every pane: the window doesn't jump when switching tabs
        .frame(width: 580, height: 460)
    }

    @ViewBuilder private func content(for pane: Pane) -> some View {
        switch pane {
        case .folders: FoldersSection(model: model)
        case .archive:
            DestinationSection(model: model)
            SpaceSection(model: model)
        case .schedule: ScheduleSection(model: model)
        case .retention: RetentionSection(model: model)
        case .excludes: ExcludesSection(model: model)
        }
    }
}

// Sections are separate views so the first-run window can reuse folders and destination as they are.

struct FoldersSection: View {
    @Bindable var model: AppModel
    @State private var error: String?

    var body: some View {
        Section {
            if model.settings.sources.isEmpty {
                Text("Nessuna cartella: aggiungi quelle dei progetti da salvare.").foregroundStyle(.secondary)
            }
            ForEach(model.settings.sources, id: \.self) { path in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading) {
                        Text((path as NSString).lastPathComponent)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Rimuovi", systemImage: "minus.circle.fill", role: .destructive) { remove(path) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Rimuovi \((path as NSString).lastPathComponent)")
                }
                .contextMenu {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Rimuovi", role: .destructive) { remove(path) }
                }
            }
            if let error { ErrorRow(text: error) }
            // controls go in the section body: footers of a grouped form don't take clicks reliably
            Button("Aggiungi cartelle…", systemImage: "plus", action: addSources)
        } header: {
            Text("Cartelle da salvare")
        }
    }

    private func remove(_ path: String) { model.settings.sources.removeAll { $0 == path } }

    private func addSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi"
        guard panel.runModal() == .OK else { return }
        error = nil
        for url in panel.urls where !model.settings.sources.contains(url.path) {
            if let dest = model.settings.destination,
               let err = BackupEngine.validate(sources: [url], repositoryRoot: URL(fileURLWithPath: dest)) {
                error = AppModel.describe(err)
                continue
            }
            model.settings.sources.append(url.path)
        }
    }
}

struct DestinationSection: View {
    @Bindable var model: AppModel
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Cartella") {
                HStack {
                    Text(model.settings.destination.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Nessuna")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.settings.destination == nil ? .secondary : .primary)
                    Button("Scegli…", action: choose)
                }
            }
            // personal and company OneDrive can both be present: offer each one
            let oneDrive = Self.oneDriveFolders
            if model.settings.destination == nil, !oneDrive.isEmpty {
                Menu("Usa OneDrive", systemImage: "cloud") {
                    ForEach(oneDrive, id: \.self) { od in Button(od.lastPathComponent) { set(od) } }
                }
                .fixedSize()
            }
            if let error { ErrorRow(text: error) }
        } header: {
            Text("Destinazione")
        } footer: {
            Text("Di solito una cartella sincronizzata, come OneDrive o Dropbox: il suo client carica i backup nel cloud.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url)
    }

    /// A destination may not contain a source or sit inside one (it would back itself up).
    private func set(_ picked: URL) {
        let url = Repository.destination(for: picked)
        if let err = BackupEngine.validate(sources: model.settings.sources.map { URL(fileURLWithPath: $0) }, repositoryRoot: url) {
            error = AppModel.describe(err)
            return
        }
        error = nil
        model.settings.destination = url.path
    }

    static var oneDriveFolders: [URL] {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? []
        return names.sorted().filter { $0.hasPrefix("OneDrive") }.map { cloud.appending(path: $0) }
    }
}

private struct SpaceSection: View {
    @Bindable var model: AppModel
    @State private var usage: (bytes: Int64, count: Int)?
    @State private var usageNote: String?

    var body: some View {
        Section("Spazio") {
            LabeledContent("Occupato") {
                if let usage {
                    Text("\(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)) · \(usage.count) backup")
                } else if let usageNote {
                    Text(usageNote).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let usage, let cap = model.settings.capGB {
                Gauge(value: min(Double(usage.bytes), cap * 1e9), in: 0...(cap * 1e9)) {}
                    .gaugeStyle(.accessoryLinearCapacity)
                    .accessibilityLabel("Spazio usato rispetto al tetto")
            }
            Toggle("Limita spazio occupato", isOn: Binding(
                get: { model.settings.capGB != nil },
                set: { model.settings.capGB = $0 ? (model.settings.capGB ?? 50) : nil }))
            if model.settings.capGB != nil {
                LabeledContent("Tetto") {
                    HStack(spacing: 4) {
                        TextField("Tetto", value: Binding(get: { model.settings.capGB ?? 50 },
                                                          set: { model.settings.capGB = max($0, 0.1) }),
                                  format: .number)
                            .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                        Text("GB").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: model.settings.destination) { await refresh() }
    }

    private func refresh() async {
        usage = nil
        usageNote = nil
        guard let dest = model.settings.destination else { usageNote = "Nessuna destinazione"; return }
        let archive = AppPaths.archiveName
        let result = await Task.detached(priority: .utility) { () -> (Int64, Int)? in
            guard let repo = try? Repository(destination: URL(fileURLWithPath: dest), computerName: archive, create: false) else { return nil }
            return ((try? repo.poolSize()) ?? 0, (try? repo.snapshotIDs().count) ?? 0)
        }.value
        if let result { usage = (result.0, result.1) } else { usageNote = "Nessun backup ancora" }
    }
}

private struct ScheduleSection: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = SystemServices.launchAtLogin
    @State private var loginError: String?

    var body: some View {
        Section {
            Toggle("Backup automatici", isOn: Binding(get: { !model.settings.paused }, set: { model.settings.paused = !$0 }))
            Picker("Backup ogni", selection: $model.settings.intervalHours) {
                ForEach(AppSettings.intervals, id: \.self) { Text($0 == 1 ? "1 ora" : "\($0) ore").tag($0) }
            }
            .disabled(model.settings.paused)
            LabeledContent("Prossimo backup", value: nextBackup)
            Toggle("Avvia al login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { try SystemServices.setLaunchAtLogin(on); loginError = nil } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SystemServices.launchAtLogin
                    }
                }
            if let loginError { ErrorRow(text: loginError) }
        }
        if model.notificationsDenied {
            Section {
                LabeledContent {
                    Button("Apri Impostazioni di Sistema") { SystemServices.openNotificationSettings() }
                } label: {
                    Label("Notifiche disattivate", systemImage: "bell.slash")
                    Text("Senza notifiche gli errori dei backup non vengono segnalati.")
                }
            }
        }
    }

    private var nextBackup: String {
        guard model.settings.isConfigured else { return "Scegli cartelle e destinazione" }
        guard !model.settings.paused else { return "Sospesi" }
        guard let last = model.lastSuccess else { return "Entro un minuto" }
        let next = last.addingTimeInterval(Double(model.settings.intervalHours) * 3600)
        return next < Date() ? "A breve" : next.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct RetentionSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Stepper(value: $model.settings.retention.days, in: 0...90) {
                LabeledContent("Giornalieri", value: count(model.settings.retention.days, "giorno", "giorni"))
            }
            Stepper(value: $model.settings.retention.weeks, in: 0...52) {
                LabeledContent("Settimanali", value: count(model.settings.retention.weeks, "settimana", "settimane"))
            }
            Stepper(value: $model.settings.retention.months, in: 0...120) {
                LabeledContent("Mensili", value: count(model.settings.retention.months, "mese", "mesi"))
            }
        } header: {
            Text("Backup da conservare")
        } footer: {
            Text("Si tengono sempre tutti i backup delle ultime 24 ore; poi l'ultimo di ogni giorno, settimana e mese per il periodo scelto.")
        }
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 0 ? "Disattivati" : n == 1 ? "1 \(one)" : "\(n) \(many)"
    }
}

private struct ExcludesSection: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @State private var confirmDefaults = false

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textEditorStyle(.plain)
                .frame(minHeight: 220)
                .onChange(of: text) { _, t in
                    model.settings.excludes = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            HStack {
                Spacer()
                Button("Ripristina predefinite…") { confirmDefaults = true }
            }
        } header: {
            Text("Un nome di cartella per riga")
        } footer: {
            Text("Es. node_modules. I pattern con * o che iniziano con . valgono anche per i file (es. *.log). Mai applicate dentro .git.")
        }
        .onAppear { text = model.settings.excludes.joined(separator: "\n") }
        .confirmationDialog("Sostituire le esclusioni con quelle predefinite?", isPresented: $confirmDefaults) {
            Button("Ripristina predefinite") { text = ExcludeRules.defaults.joined(separator: "\n") }
            Button("Annulla", role: .cancel) {}
        }
    }
}

private struct ErrorRow: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }
}
