import AppKit
import BackupCore
import SwiftUI

@main
struct BackupMeApp: App {
    @State private var model = AppModel()

    init() { SystemServices.watchWindowsClosing() }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model).onAppear { SystemServices.windowOpened() }
        }

        Window("Sfoglia backup", id: "restore") {
            RestoreView(model: RestoreModel(app: model)).onAppear { SystemServices.windowOpened() }
        }
        .defaultSize(width: 1000, height: 640)

        Window("Benvenuto in BackupMe", id: "welcome") {
            WelcomeView(model: model).onAppear { SystemServices.windowOpened() }
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar icon. Its badge tells the state at a glance; VoiceOver reads the status text.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: Self.icon(model.iconName, colors: model.iconColors))
            .accessibilityLabel("BackupMe")
            .accessibilityValue(model.statusText)
            .task {
                Log.app.info("BackupMe \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") avviato, log \(Log.level.rawValue)")
                // the label lives as long as the app: the one place with the window actions at hand
                SystemServices.onAction = { action in
                    switch action {
                    case .retry: model.backupNow()
                    case .settings: openSettings(); SystemServices.windowOpened()
                    case .check: model.checkArchiveNow()
                    }
                }
                // first run: nothing to back up yet, so the setup window opens by itself
                if !model.settings.isConfigured { openWindow(id: "welcome") }
            }
    }

    /// A symbol at the menu bar's default 13 pt looks small next to Apple's items, and its badge shrinks the
    /// drive further: 15 pt matches them, medium weight so its thin strokes read as well as theirs. Template (it follows
    /// the menu bar's light/dark), except for the states whose badge has a color: blue arrow while a backup runs,
    /// green check when all is well, yellow triangle for warnings, red triangle for errors.
    private static func icon(_ name: String, colors: [NSColor]?) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let colors { config = config.applying(.init(paletteColors: colors)) }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "BackupMe")?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = colors == nil
        return image
    }
}

extension AppModel {
    /// Warnings of the last backup (until "Cancella avvisi"), an archive problem not yet checked clean, or backups
    /// not reaching the cloud: the menu bar badge and the panel say the same.
    var hasWarnings: Bool { lastReport?.warnings.isEmpty == false || uploadProblem != nil || archiveProblem != nil }

    /// What the panel's warnings menu lists: the archive problem first when the last backup no longer says it.
    var shownWarnings: [String] {
        let w = lastReport?.warnings ?? []
        return (archiveProblem.map { w.contains($0) ? [] : [$0] } ?? []) + w
    }

    var iconName: String {
        switch status {
        // the drive with the circular arrow of the app icon, as a badge: the icon keeps its shape while it runs
        case .running: "externaldrive.badge.timemachine"
        case .failed: "externaldrive.trianglebadge.exclamationmark"
        case .idle:
            !settings.isConfigured ? "externaldrive.badge.xmark"
                : settings.paused ? "externaldrive.badge.minus"
                : hasWarnings ? "externaldrive.trianglebadge.exclamationmark" : "externaldrive.badge.checkmark"
        }
    }

    /// nil keeps the icon a template, in the menu bar's own color.
    var iconColors: [NSColor]? {
        switch status {
        // palette order for these symbols: badge first, then the drive (the drive keeps the menu bar's text color)
        case .running: [.systemBlue, .labelColor]
        case .failed: [.systemRed, .labelColor]
        case .idle:
            !settings.isConfigured || settings.paused ? nil
                : hasWarnings ? [.systemYellow, .labelColor]
                : [.systemGreen, .labelColor]
        }
    }

    /// "Prossimo backup" in Impostazioni, like Time Machine's.
    var nextBackupText: String {
        guard settings.isConfigured else { return "Scegli cartelle e destinazione" }
        guard !settings.paused else { return "Backup automatici sospesi" }
        if isRunning { return "In corso" }
        if let deferral { return deferral.until }
        if case .failed = status { return "Nuovo tentativo tra al massimo 15 minuti" } // retryAfterFailure
        guard let last = lastSuccess else { return "Entro un minuto" }
        let next = last.addingTimeInterval(Double(settings.intervalHours) * 3600)
        return next < Date() ? "A breve" : next.formatted(date: .abbreviated, time: .shortened)
    }

    var statusText: String {
        switch status {
        case .running(let p): return "Backup in corso… \(Int(p * 100))%"
        case .failed(let msg): return "Errore: \(msg)"
        case .idle:
            if let deferral { return "Backup rinviato: \(deferral.reason)" }
            guard let last = lastSuccess else { return "Nessun backup ancora" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            // no changes: the run reused the previous manifest, so the backup list shows nothing new; say why
            if let r = lastReport, r.error == nil, let id = r.snapshotID, let saved = Snapshot.date(fromID: id),
               saved < r.date.addingTimeInterval(-2) {
                return "Nessuna modifica · ultimo backup \(f.string(from: saved)) · controllato \(r.date.formatted(date: .omitted, time: .shortened))"
            }
            return "Ultimo backup: \(f.string(from: last))"
        }
    }
}

/// Where the backups go, as Impostazioni › Destinazione shows it, in the panel's width.
private struct DestinationRow: View {
    let model: AppModel
    let path: String
    @State private var info: DestinationCard.Info?
    @State private var volumes = 0

    var body: some View {
        let key = DestinationCard.key(path, model)
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(DestinationCard.title(path)).font(.callout.weight(.medium))
                Group {
                    Text(space)
                    Text("Prossimo: \(model.nextBackupText)")
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        // fixed: the lines filling in after the load must not resize the panel
        .frame(height: 46)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .help((path as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .combine)
        .task(id: "\(key)\u{0}\(volumes)") {
            let loaded = await DestinationCard.info(path, key: key)
            if !Task.isCancelled { info = loaded } // a newer load has started: this one may be older
        }
        .onVolumeChange { volumes += 1 }
    }

    private var space: String {
        guard let info else { return "Calcolo dello spazio…" }
        guard info.connected else { return "Destinazione non collegata" } // the name is the line above
        let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        return (info.available.map { "\(f($0)) liberi · " } ?? "") + "\(f(info.used)) di backup"
    }
}

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // every row has a fixed height and state changes swap content inside it: a row growing or appearing
            // would resize the panel and move the buttons under the pointer
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(statusColor.gradient)
                    if case .running(let p) = model.status {
                        ProgressView(value: p).progressViewStyle(.circular).controlSize(.small).tint(.white)
                            .accessibilityLabel("Backup in corso")
                    } else {
                        Image(systemName: statusSymbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("BackupMe").font(.headline)
                        // nil under `swift run`, which has no Info.plist
                        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("v\(v)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if model.settings.paused {
                            Text("Sospeso").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 6).frame(height: 16)
                                .background(.orange.opacity(0.15), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if let problem = model.uploadProblem {
                            Image(systemName: "icloud.slash").imageScale(.small).foregroundStyle(.orange)
                                .help(problem)
                                .accessibilityLabel("Backup non caricati nel cloud")
                        }
                        if model.notificationsDenied {
                            Image(systemName: "bell.slash").imageScale(.small).foregroundStyle(.secondary)
                                .help("Notifiche disattivate: gli errori non verranno segnalati")
                                .accessibilityLabel("Notifiche disattivate")
                        }
                        if !model.shownWarnings.isEmpty { warningsMenu(model.shownWarnings) }
                        moreMenu
                    }
                    .frame(height: 20)
                    // one line, full text on hover: a two-line error would grow the panel
                    Text(model.statusText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1).truncationMode(.middle).help(model.statusText)
                        .frame(height: 16)
                }
            }

            if let path = model.settings.destination { DestinationRow(model: model, path: path) }

            // one button whose label changes: swapping two buttons makes the glass flicker
            Button {
                if !model.settings.isConfigured { show("welcome") }
                else if model.isRunning { model.cancelBackup() } else { model.backupNow() }
            } label: {
                Label(primaryTitle, systemImage: primaryIcon).frame(maxWidth: .infinity)
            }
            .glassButton(prominent: true)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            // a backup can't start while the full check holds the archive, or during a restore
            .disabled((model.checkProgress != nil || model.restoring) && !model.isRunning && model.settings.isConfigured)

            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    tile("Sfoglia", "clock.arrow.circlepath") { show("restore") }
                        .keyboardShortcut("o")
                    tile(model.settings.paused ? "Riprendi" : "Sospendi",
                         model.settings.paused ? "play.circle" : "pause.circle") { model.settings.paused.toggle() }
                    tile("Impostazioni", "gearshape", action: showSettings)
                        .keyboardShortcut(",")
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        // ⌘Q while the panel is open, as with every menu bar app; Esci is also in the "…" menu
        .background { Button("Esci da BackupMe") { NSApp.terminate(nil) }.keyboardShortcut("q").opacity(0).accessibilityHidden(true) }
    }

    private var primaryTitle: String {
        !model.settings.isConfigured ? "Configura BackupMe…" : model.isRunning ? "Interrompi backup"
            : model.checkProgress != nil ? "Controllo dell'archivio…" : model.restoring ? "Ripristino in corso…" : "Esegui backup ora"
    }

    private var primaryIcon: String {
        !model.settings.isConfigured ? "gearshape" : model.isRunning ? "stop.fill" : "play.fill"
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: model.settings.paused || !model.settings.isConfigured ? .gray : model.hasWarnings ? .orange : .green
        case .running: .accentColor
        case .failed: .red
        }
    }

    private var statusSymbol: String {
        switch model.status {
        case .failed: "exclamationmark"
        case .running: "arrow.triangle.2.circlepath"
        case .idle: !model.settings.isConfigured ? "gearshape" : model.settings.paused ? "pause.fill"
            : model.hasWarnings ? "exclamationmark.triangle" : "checkmark"
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Info su BackupMe") {
                SystemServices.windowOpened()
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Button("Impostazioni…", action: showSettings).keyboardShortcut(",")
            Divider()
            Button("Esci da BackupMe") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle").imageScale(.medium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Altro")
        .accessibilityLabel("Altro")
    }

    private func warningsMenu(_ warnings: [String]) -> some View {
        // the engine's last "… e altri N avvisi" line is no warning: it stands for N more
        let count = Restorer.boundedCount(warnings)
        return Menu {
            ForEach(Array(warnings.prefix(15).enumerated()), id: \.offset) { Text($0.element) }
            if warnings.count > 15 { Text("… e altri \(count - 15)") }
            Divider()
            Button("Copia tutti gli avvisi") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(warnings.joined(separator: "\n"), forType: .string)
            }
            Button("Cancella avvisi") { model.clearWarnings() }
            if model.archiveProblem != nil {
                Text("Un problema dell'archivio resta finché Impostazioni › Avanzate › Controlla ora non lo trova integro")
            }
        } label: {
            Label("\(count)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Avvisi dell'ultimo backup")
        .accessibilityLabel(count == 1 ? "1 avviso dell'ultimo backup" : "\(count) avvisi dell'ultimo backup")
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .glassButton()
    }

    private func show(_ id: String) {
        openWindow(id: id)
        SystemServices.windowOpened()
    }

    private func showSettings() {
        openSettings()
        SystemServices.windowOpened()
    }
}
