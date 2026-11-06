import AppKit
import BackupCore
import SwiftUI

@main
struct BackupMeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.iconName)
        }
        .menuBarExtraStyle(.window)

        Window("Impostazioni BackupMe", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Sfoglia backup", id: "restore") {
            RestoreView(model: RestoreModel(app: model))
        }
    }
}

extension AppModel {
    var iconName: String {
        switch status {
        case .idle: "externaldrive"
        case .running: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch status {
        case .running(let p): return "Backup in corso… \(Int(p * 100))%"
        case .failed(let msg): return "Errore: \(msg)"
        case .idle:
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // state changes swap content in fixed-size slots: a row appearing would resize the panel
            // and move the buttons under the pointer
            HStack(spacing: 10) {
                Group {
                    if case .running(let p) = model.status {
                        ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                    } else {
                        Image(systemName: model.iconName).font(.title3).foregroundStyle(statusColor)
                    }
                }
                .frame(width: 38, height: 38)
                .glassPanel(in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("BackupMe").font(.headline)
                        // nil under `swift run`, which has no Info.plist
                        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                            Text("v\(v)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if model.settings.paused {
                            Text("Sospeso").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                .padding(.horizontal, 6).glassPanel(in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if model.notificationsDenied {
                            Image(systemName: "bell.slash").foregroundStyle(.secondary)
                                .help("Notifiche disattivate: gli errori non verranno segnalati")
                        }
                        if let r = model.lastReport, !r.warnings.isEmpty { warningsMenu(r.warnings) }
                    }
                    // one line, full text on hover: a two-line error would grow the panel
                    Text(model.statusText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle).help(model.statusText)
                }
            }

            // one button whose label changes: swapping two buttons makes the glass flicker
            Button {
                if model.isRunning { model.cancelBackup() } else { model.backupNow() }
            } label: {
                wide(model.isRunning ? "Interrompi backup" : "Esegui backup ora", model.isRunning ? "stop.fill" : "play.fill")
            }
            .glassButton(prominent: true)
            .controlSize(.large)

            HStack(spacing: 8) {
                tile("Sfoglia", "clock.arrow.circlepath") { show("restore") }
                tile(model.settings.paused ? "Riprendi" : "Sospendi",
                     model.settings.paused ? "play.circle" : "pause.circle") { model.settings.paused.toggle() }
                tile("Impostazioni", "gearshape") { show("settings") }
            }

            HStack {
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }.keyboardShortcut("q").glassButton()
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: model.settings.paused ? .secondary : .green
        case .running: .accentColor
        case .failed: .red
        }
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
            Label("\(warnings.count)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .help("Avvisi dell'ultimo backup")
    }

    private func wide(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).frame(maxWidth: .infinity)
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .glassButton()
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
