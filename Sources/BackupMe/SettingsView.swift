import AppKit
import BackupCore
import SwiftUI

/// The standard macOS settings window: one tab per pane in the toolbar, ⌘, from the app menu.
struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("settingsPane") private var pane = Pane.folders

    enum Pane: String, CaseIterable {
        case folders, archive, schedule, retention, excludes, log, advanced

        var title: String {
            switch self {
            case .folders: "Cartelle"
            case .archive: "Destinazione"
            case .schedule: "Pianificazione"
            case .retention: "Conservazione"
            case .excludes: "Esclusioni"
            case .log: "Registro"
            case .advanced: "Avanzate"
            }
        }

        var icon: String {
            switch self {
            case .folders: "folder"
            case .archive: "externaldrive"
            case .schedule: "calendar.badge.clock"
            case .retention: "clock.arrow.circlepath"
            case .excludes: "nosign"
            case .log: "doc.text.magnifyingglass"
            case .advanced: "gearshape.2"
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
        case .log:
            LogViewSection()
            LoggingSection()
        case .advanced: ArchiveCheckSection(model: model)
        }
    }
}

// Sections are separate views so the first-run window can reuse folders and destination as they are.

struct FoldersSection: View {
    @Bindable var model: AppModel
    @State private var error: String?
    private static let home = NSHomeDirectory()

    var body: some View {
        Section {
            if model.settings.sources.isEmpty {
                Text("Niente da salvare: aggiungi le cartelle dei progetti, singoli file o il profilo completo.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.sources, id: \.self) { path in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading) {
                        Text(path == Self.home ? "Profilo completo" : (path as NSString).lastPathComponent)
                        Text(detail(path))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let parent = model.settings.source(containing: path) {
                            Label("Già compreso in \((parent as NSString).abbreviatingWithTildeInPath)", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
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
            HStack {
                Button("Aggiungi cartelle o file…", systemImage: "plus", action: addSources)
                if !model.settings.sources.contains(Self.home) {
                    Button("Aggiungi profilo completo", systemImage: "person.crop.circle") { add([URL(fileURLWithPath: Self.home)]) }
                        .help("Tutta la cartella Inizio, file e cartelle; Libreria e Cestino esclusi")
                }
            }
        } header: {
            Text("Cartelle e file da salvare")
        } footer: {
            if model.settings.sources.contains(Self.home) {
                Text("Il profilo completo salva tutte le cartelle e i file della cartella Inizio. Libreria, Cestino e destinazione sono esclusi in automatico: per salvare una cartella della Libreria aggiungila qui.")
            }
        }
    }

    private func detail(_ path: String) -> String {
        let place = (path as NSString).abbreviatingWithTildeInPath
        if path == Self.home { return "\(place) · tutte le cartelle e i file" }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular, let size = attrs[.size] as? Int64 else { return place }
        return "\(place) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private func remove(_ path: String) { model.settings.sources.removeAll { $0 == path } }

    private func addSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        error = nil
        for url in urls where !model.settings.sources.contains(url.path) {
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
            if let path = model.settings.destination {
                DestinationCard(model: model, path: path)
                HStack {
                    Spacer()
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Button("Cambia…", action: choose)
                }
            } else {
                LabeledContent("Cartella") {
                    HStack {
                        Text("Nessuna").foregroundStyle(.secondary)
                        Button("Scegli…", action: choose)
                    }
                }
            }
            // only the services found on this Mac; personal and company accounts of one service are offered each
            if model.settings.destination == nil {
                if cloud.count == 1, let only = cloud.first {
                    Button("Usa \(only.title)", systemImage: "cloud") { set(only.url) }
                } else if !cloud.isEmpty {
                    Menu("Usa una cartella cloud", systemImage: "cloud") {
                        ForEach(cloud, id: \.self) { c in Button(c.title) { set(c.url) } }
                    }
                    .fixedSize()
                }
            }
            if let error { ErrorRow(text: error) }
        } header: {
            Text("Destinazione")
        } footer: {
            Text(Self.hint(cloud))
        }
    }

    private var cloud: [CloudFolder] { CloudFolder.installed() }

    /// Names the services this Mac has; without any, a cloud folder is only one of the options.
    static func hint(_ cloud: [CloudFolder]) -> String {
        CloudFolder.serviceList(cloud).map { "Di solito una cartella sincronizzata, come \($0): il suo client carica i backup nel cloud." }
            ?? "Una cartella su un disco esterno, o sincronizzata con un servizio cloud se ne installi uno."
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

}

/// The destination at a glance, like Time Machine's: where it is, space, the span of the backups, the next one.
private struct DestinationCard: View {
    let model: AppModel
    let path: String
    @State private var info: Info?

    struct Info: Sendable {
        var available: Int64?
        var used: Int64
        var dates: [Date]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3).lineLimit(1).truncationMode(.middle)
                Group {
                    Text(spaceLine)
                    Text(backupsLine)
                    Text("Prossimo backup: \(model.nextBackupText)")
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .help((path as NSString).abbreviatingWithTildeInPath)
        // reloaded after every backup: the span and the space change with it
        .task(id: "\(path)\u{0}\(model.lastSuccess?.timeIntervalSince1970 ?? 0)") { info = await Self.load(path) }
    }

    /// "TEST – Dropbox": the folder, then the cloud service it syncs with, or the disk it is on.
    private var title: String {
        let url = URL(fileURLWithPath: path)
        let parts = url.pathComponents
        var place = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? ""
        if let i = parts.firstIndex(of: "CloudStorage"), i + 1 < parts.count {
            // "OneDrive-Personal", "GoogleDrive-name@example.com": the service, then the account
            place = parts[i + 1].replacingOccurrences(of: "-", with: " ")
        }
        return place.isEmpty ? url.lastPathComponent : "\(url.lastPathComponent) – \(place)"
    }

    private var spaceLine: String {
        guard let info else { return "Calcolo dello spazio…" }
        let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        var parts: [String] = []
        if let a = info.available { parts.append("\(f(a)) disponibili") }
        parts.append("\(f(info.used)) occupati dai backup")
        if let cap = model.settings.capGB { parts.append("tetto \(f(Int64(cap * 1e9)))") }
        return parts.joined(separator: ", ")
    }

    private var backupsLine: String {
        guard let info else { return "Lettura dei backup…" }
        let f = { (d: Date) in d.formatted(date: .numeric, time: .shortened) }
        switch info.dates.count {
        case 0: return "Nessun backup ancora"
        case 1: return "Backup: \(f(info.dates[0]))"
        default: return "Backup: \(f(info.dates.first!)) – \(f(info.dates.last!)) (\(info.dates.count))"
        }
    }

    private static func load(_ path: String) async -> Info {
        let archive = AppPaths.archiveName
        return await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            let available = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            let repo = try? Repository(destination: url, computerName: archive, create: false)
            let dates = ((try? repo?.snapshotIDs()) ?? []).compactMap(Snapshot.date(fromID:)).sorted()
            return Info(available: available, used: (try? repo?.poolSize()) ?? 0, dates: dates)
        }.value
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
        // after every backup too, like the destination card above: the two "occupati" must agree
        .task(id: "\(model.settings.destination ?? "")\u{0}\(model.lastSuccess?.timeIntervalSince1970 ?? 0)") { await refresh() }
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
            LabeledContent("Prossimo backup", value: model.nextBackupText)
            Toggle("Avvia al login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do { try SystemServices.setLaunchAtLogin(on); loginError = nil } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SystemServices.launchAtLogin
                    }
                }
            if let loginError { ErrorRow(text: loginError) }
        }
        Section {
            Toggle("Solo con l'alimentatore collegato", isOn: $model.settings.onlyOnPower)
            Toggle("Rimanda sulle reti a consumo", isOn: $model.settings.deferOnMetered)
                .help("Hotspot dell'iPhone o reti Wi-Fi segnate come «a consumo» in Impostazioni di Sistema")
        } header: {
            Text("Quando rimandare")
        } footer: {
            Text("Il backup pianificato aspetta anche con il Risparmio energetico, la batteria sotto il 20% o il Mac troppo caldo, ma mai oltre un giorno senza backup. «Esegui backup ora» parte sempre.")
        }
        .disabled(model.settings.paused)
        Section {
            Picker("Notifiche", selection: $model.settings.notify) {
                Text("Solo problemi").tag(AppSettings.NotifyLevel.errors)
                Text("Anche gli avvisi").tag(AppSettings.NotifyLevel.warnings)
                Text("Ogni backup").tag(AppSettings.NotifyLevel.all)
            }
            if model.notificationsDenied {
                LabeledContent {
                    Button("Apri Impostazioni di Sistema") { SystemServices.openNotificationSettings() }
                } label: {
                    Label("Notifiche disattivate", systemImage: "bell.slash")
                    Text("Senza notifiche gli errori dei backup non vengono segnalati.")
                }
            }
        } footer: {
            Text("Backup non riusciti, archivio danneggiato e nessun backup da 3 giorni vengono sempre notificati.")
        }
    }
}

private struct RetentionSection: View {
    @Bindable var model: AppModel
    /// The archive's backups, read once: the preview then follows the steppers as they move.
    @State private var dated: [(id: String, date: Date)]?

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
        .task(id: model.settings.destination) { await load() }
        if let dated, !dated.isEmpty {
            Section {
                let keep = snapshotsToKeep(dated, policy: model.settings.retention, now: Date(), calendar: .backup).count
                LabeledContent("Con queste regole") {
                    Text(dated.count == 1 ? "Si tiene l'unico backup" : keep == dated.count ? "Si tengono tutti i \(dated.count) backup"
                         : "Si tengono \(keep) backup su \(dated.count), \(dated.count - keep) da eliminare alla prossima pulizia")
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Senza contare il tetto allo spazio, che può eliminarne altri partendo dai più vecchi.")
            }
        }
    }

    private func load() async {
        guard let dest = model.settings.destination else { dated = nil; return }
        let archive = AppPaths.archiveName
        dated = await Task.detached(priority: .utility) {
            let ids = (try? Repository(destination: URL(fileURLWithPath: dest), computerName: archive, create: false).snapshotIDs()) ?? []
            return ids.compactMap { id in Snapshot.date(fromID: id).map { (id: id, date: $0) } }
        }.value
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 0 ? "Disattivati" : n == 1 ? "1 \(one)" : "\(n) \(many)"
    }
}

private struct ExcludesSection: View {
    @Bindable var model: AppModel
    @State private var newPattern = ""
    @State private var error: String?
    @State private var pathError: String?
    @State private var confirmDefaults = false
    private static let suggestions = ["*.log", "*.tmp", ".cache", "coverage", ".next", ".terraform", "*.xcarchive"]

    var body: some View {
        patternsSection
        pathsSection
        sizeSection
        automaticSection
        lastBackupSection
        unreadableSection
    }

    // MARK: name patterns

    private var patternsSection: some View {
        Section {
            ForEach(model.settings.excludes, id: \.self) { p in
                HStack {
                    Image(systemName: icon(p)).foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading) {
                        Text(p).font(.body.monospaced())
                        Text(describe(p)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    removeButton(p) { model.settings.excludes.removeAll { $0 == p } }
                }
            }
            HStack {
                TextField("Nuova regola", text: $newPattern, prompt: Text("es. *.log o apps/*/dist"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .onSubmit { addPattern(newPattern) }
                Button("Aggiungi") { addPattern(newPattern) }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                let missing = Self.suggestions.filter { !model.settings.excludes.contains($0) }
                if !missing.isEmpty {
                    Menu("Suggerite") {
                        ForEach(missing, id: \.self) { s in Button("\(s)  —  \(describe(s))") { addPattern(s) } }
                    }
                    .fixedSize()
                }
            }
            if let error { ErrorRow(text: error) }
            HStack {
                Spacer()
                Button("Ripristina predefinite…") { confirmDefaults = true }
            }
        } header: {
            Text("Regole per nome")
        } footer: {
            Text("Un nome vale per le cartelle (build); con * o un punto iniziale anche per i file (*.log, .DS_Store); con una / per il percorso dentro la cartella salvata (apps/*/dist, /build solo in cima). Mai applicate dentro .git.")
        }
        .confirmationDialog("Sostituire le regole con quelle predefinite?", isPresented: $confirmDefaults) {
            Button("Ripristina predefinite") { model.settings.excludes = ExcludeRules.defaults; error = nil }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(ExcludeRules.defaults.joined(separator: "  "))
        }
    }

    private func addPattern(_ raw: String) {
        let p = raw.trimmingCharacters(in: .whitespaces)
        if let problem = ExcludeRules.problem(with: p, in: model.settings.excludes) { error = problem; return }
        model.settings.excludes.append(p)
        newPattern = ""
        error = nil
    }

    private func icon(_ p: String) -> String {
        switch ExcludeRules.kind(of: p) {
        case .folders: "folder"
        case .foldersAndFiles: "doc.on.doc"
        case .path, .rootPath: "arrow.turn.down.right"
        }
    }

    private func describe(_ p: String) -> String {
        switch ExcludeRules.kind(of: p) {
        case .folders: "Cartelle con questo nome, ovunque"
        case .foldersAndFiles: "File e cartelle con questo nome, ovunque"
        case .path: "Percorso dentro ogni cartella salvata"
        case .rootPath: "Solo in cima a ogni cartella salvata"
        }
    }

    // MARK: specific paths

    private var pathsSection: some View {
        Section {
            if model.settings.excludedPaths.isEmpty {
                Text("Nessuno. Escludi una cartella o un file preciso, per esempio una cartella di video, senza toccare gli altri con lo stesso nome.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.excludedPaths, id: \.self) { path in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading) {
                        Text((path as NSString).lastPathComponent)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if model.settings.source(containing: path) == nil {
                            Label("Non è dentro nessun elemento salvato: non ha effetto", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    removeButton((path as NSString).lastPathComponent) { model.settings.excludedPaths.removeAll { $0 == path } }
                }
                .contextMenu {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
            if let pathError { ErrorRow(text: pathError) }
            Button("Escludi cartelle o file…", systemImage: "plus", action: addPaths)
        } header: {
            Text("Cartelle e file esclusi")
        }
    }

    private func addPaths() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Escludi"
        // where the user most likely wants to cut: inside what is saved
        if let first = model.settings.sources.first { panel.directoryURL = URL(fileURLWithPath: first) }
        guard panel.runModal() == .OK else { return }
        pathError = nil
        for url in panel.urls where !model.settings.excludedPaths.contains(url.path) {
            // a saved item always wins over its own exclusion: say so instead of keeping a rule with no effect
            if model.settings.sources.contains(url.path) {
                pathError = "\(url.lastPathComponent) è tra gli elementi da salvare: per non salvarlo rimuovilo da Cartelle"
                continue
            }
            model.settings.excludedPaths.append(url.path)
        }
    }

    // MARK: size

    private var sizeSection: some View {
        Section {
            Toggle("Escludi i file più grandi di un limite", isOn: Binding(
                get: { model.settings.maxFileGB != nil },
                set: { model.settings.maxFileGB = $0 ? (model.settings.maxFileGB ?? 1) : nil }))
            if model.settings.maxFileGB != nil {
                LabeledContent("Limite") {
                    HStack(spacing: 4) {
                        TextField("Limite", value: Binding(get: { model.settings.maxFileGB ?? 1 },
                                                           set: { model.settings.maxFileGB = max($0, 0.01) }),
                                  format: .number)
                            .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                        Text("GB").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("File grandi")
        } footer: {
            Text("Un file viene salvato di nuovo per intero a ogni modifica: immagini disco, macchine virtuali e database grandi riempiono presto l'archivio. Mai applicato dentro .git; un file aggiunto in Cartelle viene sempre salvato.")
        }
    }

    // MARK: automatic

    /// Automatic exclusions inside a saved folder; one inside another listed one (Library holds CloudStorage) is left out.
    private var automatic: [ExcludeRules.Automatic] {
        let s = model.settings
        // only what exists here: no line for a cloud service this Mac doesn't have
        let inside = ExcludeRules.automatic(destination: s.destination).filter { a in
            FileManager.default.fileExists(atPath: a.path) && s.sources.contains { a.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        }
        return inside.filter { a in !inside.contains { a.path.hasPrefix($0.path + "/") } }
    }

    private var automaticSection: some View {
        Section {
            let list = automatic
            if list.isEmpty {
                Text("Nessuna: nessun elemento salvato contiene la destinazione, la Libreria o il Cestino.")
                    .foregroundStyle(.secondary)
            }
            ForEach(list, id: \.self) { a in
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading) {
                        Text((a.path as NSString).lastPathComponent)
                        Text(a.reason).font(.caption).foregroundStyle(.secondary)
                        Text((a.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        } header: {
            Text("Escluse in automatico")
        } footer: {
            Text("Una cartella aggiunta in Cartelle viene sempre salvata, anche se è qui dentro: per esempio una cartella della Libreria.")
        }
    }

    // MARK: last backup

    // a default like build or target can also hit real sources: show what was actually left out, and by which rule
    @ViewBuilder private var lastBackupSection: some View {
        if let excluded = model.lastReport?.excluded, !excluded.isEmpty {
            Section {
                DisclosureGroup(excluded.count >= 200 ? "200 o più elementi esclusi nell'ultimo backup"
                                : excluded.count == 1 ? "1 elemento escluso nell'ultimo backup"
                                : "\(excluded.count) elementi esclusi nell'ultimo backup") {
                    let rules = model.settings.excludeRules
                    ForEach(excluded, id: \.self) { item in
                        HStack {
                            Text(item).font(.callout.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(reason(item, rules)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            } footer: {
                Text("Controlla che non ci siano cartelle con codice da salvare. Sono escluse anche le cartelle con un file CACHEDIR.TAG, usato dagli strumenti di build per segnare le cache.")
            }
        }
    }

    /// `item` is "<saved folder name>/<path>", as the backup reports it.
    private func reason(_ item: String, _ rules: ExcludeRules) -> String {
        guard let slash = item.firstIndex(of: "/") else { return "" }
        let path = String(item[item.index(after: slash)...])
        if let p = rules.matchingPattern(name: (path as NSString).lastPathComponent, isDirectory: true, path: path) { return p }
        let name = String(item[..<slash])
        let full = model.settings.sources.first { ($0 as NSString).lastPathComponent == name }.map { $0 + "/" + path }
        if full.map({ rules.paths.contains(ExcludeRules.resolved($0)) }) == true { return "esclusa per percorso" }
        var isDir: ObjCBool = false
        if let full, FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { return "troppo grande" }
        return "CACHEDIR.TAG"
    }

    // MARK: unreadable files

    private var unreadableSection: some View {
        Section {
            Toggle("Salta in automatico i file senza permessi di lettura", isOn: $model.settings.skipUnreadable)
            if let skipped = model.lastReport?.skipped, !skipped.isEmpty {
                DisclosureGroup(skipped.count >= 200 ? "200 o più file saltati nell'ultimo backup"
                                : skipped.count == 1 ? "1 file saltato nell'ultimo backup"
                                : "\(skipped.count) file saltati nell'ultimo backup") {
                    ForEach(skipped, id: \.self) { path in
                        Text((path as NSString).abbreviatingWithTildeInPath).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .contextMenu {
                                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            }
                    }
                }
            }
            if let n = model.lastReport?.warnings.count, n > 0 {
                HStack {
                    Text(n == 1 ? "1 avviso nell'ultimo backup" : "\(n) avvisi nell'ultimo backup")
                    Spacer()
                    Button("Cancella avvisi", role: .destructive) { model.clearWarnings() }
                }
            }
        } header: {
            Text("File non leggibili")
        } footer: {
            Text("I file che macOS non ti lascia aprire (\"non hai i privilegi necessari\") non sono nel backup: con l'opzione attiva vengono elencati qui invece di comparire tra gli avvisi.")
        }
    }

    private func removeButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button("Rimuovi", systemImage: "minus.circle.fill", role: .destructive, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Rimuovi \(name)")
    }
}

private struct LogViewSection: View {
    @State private var lines: [String] = []
    @State private var onlyErrors = false

    var body: some View {
        Section {
            let shown = onlyErrors ? lines.filter { $0.contains(" ERROR ") } : lines
            ScrollView {
                Text(shown.isEmpty ? "Nessuna riga" : shown.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 220)
            HStack {
                Toggle("Solo errori", isOn: $onlyErrors)
                Spacer()
                Button("Aggiorna", systemImage: "arrow.clockwise", action: reload)
                Button("Copia") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.joined(separator: "\n"), forType: .string)
                }
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
                    .disabled(lines.isEmpty)
                Button("Svuota", role: .destructive) { Log.clear(); reload() }
            }
        } header: {
            Text("Registro di BackupMe")
        } footer: {
            Text("Avvii, esiti, rinvii ed errori di backup, ripristini e controlli, anche dopo un riavvio. Con il livello Debug anche i dettagli di ogni passaggio.")
        }
        .task { reload() }
    }

    private func reload() { lines = Log.lines() }
}

private struct ArchiveCheckSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            if let p = model.checkProgress {
                HStack {
                    ProgressView(value: p)
                    Button("Interrompi", action: model.cancelCheck)
                }
            } else {
                LabeledContent("Controllo completo") {
                    Button("Controlla ora", action: model.checkArchiveNow)
                        .disabled(model.isRunning || model.settings.destination == nil)
                }
            }
            if let r = model.checkResult {
                Label(r.text, systemImage: r.healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.healthy ? Color.green : Color.red)
            }
        } header: {
            Text("Integrità dell'archivio")
        } footer: {
            Text("Rilegge ogni backup e ogni file dell'archivio di questo Mac e ripara i file danneggiati quando la copia attuale è ancora uguale. Ogni giorno ne viene già controllato un campione. Se la destinazione è nel cloud con i file su richiesta, scarica l'intero archivio; i backup aspettano la fine del controllo.")
        }
    }
}

private struct LoggingSection: View {
    @AppStorage(Log.levelKey) private var level = Log.Level.info
    private static let command = "log stream --predicate 'subsystem == \"\(Log.subsystem)\"' --level debug"

    var body: some View {
        Section {
            Picker("Livello", selection: $level) {
                Text("Info").tag(Log.Level.info)
                Text("Debug").tag(Log.Level.debug)
            }
            .pickerStyle(.segmented)
            .onChange(of: level) { _, l in Log.app.info("Livello di log: \(l.rawValue)") }
            LabeledContent("Dove leggerlo") {
                HStack {
                    Button("Apri Console") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Copia comando") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.command, forType: .string)
                    }
                    .help(Self.command)
                }
            }
        } header: {
            Text("Registro di sistema")
        } footer: {
            Text(level == .debug
                 ? "Debug aggiunge i dettagli di ogni passaggio: cartelle ed esclusioni, scansione, pulizia, verifica, caricamento nel cloud. In Console filtra per \(Log.subsystem) e attiva Azione › Includi messaggi di debug; oppure incolla il comando nel Terminale."
                 : "Info registra avvii, esiti ed errori di backup e ripristini. In Console filtra per \(Log.subsystem) e attiva Azione › Includi messaggi informativi; oppure incolla il comando nel Terminale.")
        }
    }
}

private struct ErrorRow: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }
}
