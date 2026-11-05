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

    @State private var page: Page? = .folders

    enum Page: String, CaseIterable, Identifiable {
        case folders, archive, schedule, retention, excludes
        var id: Self { self }

        var title: String {
            switch self {
            case .folders: "Cartelle"
            case .archive: "Destinazione e spazio"
            case .schedule: "Pianificazione"
            case .retention: "Conservazione"
            case .excludes: "Esclusioni"
            }
        }

        var icon: String {
            switch self {
            case .folders: "folder.fill"
            case .archive: "externaldrive.fill"
            case .schedule: "calendar.badge.clock"
            case .retention: "clock.arrow.circlepath"
            case .excludes: "nosign"
            }
        }

        var color: Color {
            switch self {
            case .folders: .blue
            case .archive: .indigo
            case .schedule: .orange
            case .retention: .green
            case .excludes: .red
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label {
                    Text(p.title)
                } icon: {
                    Image(systemName: p.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(p.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form { content(for: page ?? .folders) }
                .formStyle(.grouped)
                .navigationTitle((page ?? .folders).title)
        }
        .frame(width: 720, height: 500)
        .onAppear {
            excludesText = model.settings.excludes.joined(separator: "\n")
            refreshUsage()
        }
    }

    @ViewBuilder private func content(for page: Page) -> some View {
        switch page {
        case .folders:
            Section {
                if model.settings.sources.isEmpty {
                    Text("Nessuna cartella: aggiungi quelle dei progetti da salvare.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.sources, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text((path as NSString).lastPathComponent)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { model.settings.sources.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless)
                    }
                }
                // controls go in the section body: footers of a grouped form don't take clicks reliably
                Button("Aggiungi cartelle…", systemImage: "plus", action: addSources).glassButton()
            } header: {
                Text("Cartelle da salvare")
            } footer: {
                if let sourceError { Text(sourceError).foregroundStyle(.red).font(.caption) }
            }

        case .archive:
            Section {
                HStack {
                    Image(systemName: "externaldrive.fill").foregroundStyle(.tint)
                    Text(model.settings.destination.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Nessuna")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Scegli…", action: chooseDestination).glassButton()
                }
                if model.settings.destination == nil {
                    // personal and company OneDrive can both be present: offer each one
                    ForEach(Self.oneDriveFolders, id: \.self) { od in
                        Button("Usa \(od.lastPathComponent)", systemImage: "cloud") { setDestination(od) }.glassButton()
                    }
                }
            } header: {
                Text("Destinazione")
            } footer: {
                if let sourceError { Text(sourceError).foregroundStyle(.red).font(.caption) }
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
                Text(usage).foregroundStyle(.secondary)
            }

        case .schedule:
            Section {
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
            } footer: {
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
            }

        case .retention:
            Section {
                Stepper("giorno, per gli ultimi \(model.settings.retention.days) giorni", value: $model.settings.retention.days, in: 0...90)
                Stepper("settimana, per le ultime \(model.settings.retention.weeks) settimane", value: $model.settings.retention.weeks, in: 0...52)
                Stepper("mese, per gli ultimi \(model.settings.retention.months) mesi", value: $model.settings.retention.months, in: 0...120)
            } header: {
                Text("Tutti i backup delle ultime 24 ore, più l'ultimo di ogni…")
            }

        case .excludes:
            Section {
                TextEditor(text: $excludesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .onChange(of: excludesText) { _, text in
                        model.settings.excludes = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                Button("Ripristina predefinite") { excludesText = ExcludeRules.defaults.joined(separator: "\n") }.glassButton()
            } header: {
                Text("Un nome di cartella per riga")
            } footer: {
                Text("Es. node_modules. I pattern con * o che iniziano con . valgono anche per i file (es. *.log). Mai applicate dentro .git.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
