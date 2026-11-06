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
        Image(nsImage: Self.icon(model.iconName))
            .accessibilityLabel("BackupMe")
            .accessibilityValue(model.statusText)
            .task {
                Log.app.info("BackupMe \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") avviato, log \(Log.level.rawValue)")
                // the label lives as long as the app: the one place with the window actions at hand
                SystemServices.onAction = { action in
                    switch action {
                    case .retry: model.backupNow()
                    case .settings: openSettings(); SystemServices.windowOpened()
                    }
                }
                // first run: nothing to back up yet, so the setup window opens by itself
                if !model.settings.isConfigured { openWindow(id: "welcome") }
            }
    }

    /// A symbol at the menu bar's default 13 pt looks small next to Apple's items, and its badge shrinks the
    /// drive further: 15 pt matches them. Template, so it follows the menu bar's light/dark and tint.
    private static func icon(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "BackupMe")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

extension AppModel {
    var iconName: String {
        switch status {
        case .running: "externaldrive.badge.timemachine"
        case .failed: "externaldrive.badge.exclamationmark"
        case .idle:
            !settings.isConfigured ? "externaldrive.badge.xmark"
                : settings.paused ? "externaldrive.badge.minus" : "externaldrive.badge.checkmark"
        }
    }

    var statusText: String {
        switch status {
        case .running(let p): return "Backup in corso… \(Int(p * 100))%"
        case .failed(let msg): return "Errore: \(msg)"
        case .idle:
            if let deferral { return "Backup rinviato: \(deferral)" }
            guard let last = lastSuccess else { return "Nessun backup ancora" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            // no changes: the run reused the previous manifest, so the backup list shows nothing new; say why
            if let r = lastReport, r.error == nil, let id = r.snapshotID, let saved = Snapshot.date(fromID: id),
               saved < r.date.addingTimeInterval(-2) {
                return "Nessuna modifica dal \(f.string(from: saved)) · controllato \(r.date.formatted(date: .omitted, time: .shortened))"
            }
            return "Ultimo backup: \(f.string(from: last))"
        }
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
                        if let r = model.lastReport, !r.warnings.isEmpty { warningsMenu(r.warnings) }
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
        !model.settings.isConfigured ? "Configura BackupMe…" : model.isRunning ? "Interrompi backup" : "Esegui backup ora"
    }

    private var primaryIcon: String {
        !model.settings.isConfigured ? "gearshape" : model.isRunning ? "stop.fill" : "play.fill"
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: model.settings.paused || !model.settings.isConfigured ? .gray : .green
        case .running: .accentColor
        case .failed: .red
        }
    }

    private var statusSymbol: String {
        switch model.status {
        case .failed: "exclamationmark"
        case .running: "arrow.triangle.2.circlepath"
        case .idle: !model.settings.isConfigured ? "gearshape" : model.settings.paused ? "pause.fill" : "checkmark"
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
        Menu {
            ForEach(Array(warnings.prefix(15).enumerated()), id: \.offset) { Text($0.element) }
            if warnings.count > 15 { Text("… e altri \(warnings.count - 15)") }
            Divider()
            Button("Copia tutti gli avvisi") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(warnings.joined(separator: "\n"), forType: .string)
            }
        } label: {
            Label("\(warnings.count)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Avvisi dell'ultimo backup")
        .accessibilityLabel("\(warnings.count) avvisi dell'ultimo backup")
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
