import AppKit
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
        .menuBarExtraStyle(.menu)

        Window("Impostazioni BackupMe", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Sfoglia backup", id: "restore") {
            Text("Ripristino").padding()
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
            return "Ultimo backup: \(f.string(from: last))"
        }
    }
}

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        if model.settings.paused { Text("Backup sospesi") }
        Divider()
        if model.isRunning {
            Button("Interrompi backup") { model.cancelBackup() }
        } else {
            Button("Esegui backup ora") { model.backupNow() }
        }
        Button("Sfoglia backup…") { show("restore") }
        Button(model.settings.paused ? "Riprendi backup" : "Sospendi backup") { model.settings.paused.toggle() }
        Divider()
        Button("Impostazioni…") { show("settings") }
        Button("Esci") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
