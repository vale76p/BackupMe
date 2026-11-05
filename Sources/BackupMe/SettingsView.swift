import AppKit
import BackupCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var sourceError: String?
    @State private var launchAtLogin = SystemServices.launchAtLogin
    @State private var loginError: String?
    @State private var usage = "Calcolo…"
    @State private var excludesText = ""

    var body: some View {
        Form {
            Section("Cartelle da salvare") {
                ForEach(model.settings.sources, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { model.settings.sources.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless)
                    }
                }
                Button("Aggiungi cartelle…", action: addSources)
                if let sourceError { Text(sourceError).foregroundStyle(.red).font(.caption) }
            }

            Section("Destinazione") {
                HStack {
                    Text(model.settings.destination ?? "Nessuna").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Scegli…", action: chooseDestination)
                }
                if model.settings.destination == nil {
                    // personal and company OneDrive can both be present: offer each one
                    ForEach(Self.oneDriveFolders, id: \.self) { od in
                        Button("Usa \(od.lastPathComponent)") { setDestination(od) }
                    }
                }
            }

            Section("Pianificazione") {
                Picker("Backup ogni", selection: $model.settings.intervalHours) {
                    ForEach(AppSettings.intervals, id: \.self) { Text($0 == 1 ? "1 ora" : "\($0) ore").tag($0) }
                }
                Toggle("Avvia al login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try SystemServices.setLaunchAtLogin(on); loginError = nil } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SystemServices.launchAtLogin
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
            }

            Section("Conservazione: tutti i backup delle ultime 24 ore, più l'ultimo di ogni…") {
                Stepper("giorno, per gli ultimi \(model.settings.retention.days) giorni", value: $model.settings.retention.days, in: 0...90)
                Stepper("settimana, per le ultime \(model.settings.retention.weeks) settimane", value: $model.settings.retention.weeks, in: 0...52)
                Stepper("mese, per gli ultimi \(model.settings.retention.months) mesi", value: $model.settings.retention.months, in: 0...120)
            }

            Section("Spazio") {
                Toggle("Limita spazio occupato", isOn: Binding(
                    get: { model.settings.capGB != nil },
                    set: { model.settings.capGB = $0 ? (model.settings.capGB ?? 50) : nil }))
                if model.settings.capGB != nil {
                    TextField("Tetto (GB)", value: Binding(get: { model.settings.capGB ?? 50 },
                                                          set: { model.settings.capGB = max($0, 0.1) }),
                              format: .number)
                }
                Text(usage).foregroundStyle(.secondary).font(.caption)
            }

            Section("Esclusioni: un nome di cartella per riga (es. node_modules); i pattern con * o che iniziano con . valgono anche per i file (es. *.log). Mai applicate dentro .git") {
                TextEditor(text: $excludesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: excludesText) { _, text in
                        model.settings.excludes = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                Button("Ripristina predefinite") { excludesText = ExcludeRules.defaults.joined(separator: "\n") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .onAppear {
            excludesText = model.settings.excludes.joined(separator: "\n")
            refreshUsage()
        }
    }

    private func addSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi"
        guard panel.runModal() == .OK else { return }
        sourceError = nil
        for url in panel.urls where !model.settings.sources.contains(url.path) {
            if let dest = model.settings.destination,
               let err = BackupEngine.validate(sources: [url], repositoryRoot: URL(fileURLWithPath: dest)) {
                sourceError = AppModel.describe(err)
                continue
            }
            model.settings.sources.append(url.path)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDestination(url)
    }

    /// A destination may not contain a source or sit inside one (it would back itself up).
    private func setDestination(_ url: URL) {
        if let err = BackupEngine.validate(sources: model.settings.sources.map { URL(fileURLWithPath: $0) }, repositoryRoot: url) {
            sourceError = AppModel.describe(err)
            return
        }
        sourceError = nil
        model.settings.destination = url.path
        refreshUsage()
    }

    private func refreshUsage() {
        guard let dest = model.settings.destination else {
            usage = "Nessun archivio"
            return
        }
        let archive = AppPaths.archiveName
        Task.detached(priority: .utility) {
            guard let repo = try? Repository(destination: URL(fileURLWithPath: dest), computerName: archive, create: false) else {
                await MainActor.run { usage = "Nessun backup ancora in questa destinazione" }
                return
            }
            let size = (try? repo.poolSize()) ?? 0
            let count = (try? repo.snapshotIDs().count) ?? 0
            let text = "Spazio occupato: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(count) backup"
            await MainActor.run { usage = text }
        }
    }

    static var oneDriveFolders: [URL] {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? []
        return names.sorted().filter { $0.hasPrefix("OneDrive") }.map { cloud.appending(path: $0) }
    }
}
