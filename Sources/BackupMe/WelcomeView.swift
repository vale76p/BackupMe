import AppKit
import BackupCore
import SwiftUI

/// First run: folders, destination and frequency in one step, then the first backup.
struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    /// Names the cloud services found on this Mac, none when there are none.
    private var intro: String {
        let saved = "Salva le cartelle dei tuoi progetti, .git compreso, "
        return saved + (CloudFolder.serviceList(CloudFolder.installed()).map { "in una cartella sincronizzata come \($0)." }
            ?? "su un disco esterno o in una cartella sincronizzata con il cloud.") + " Non servono permessi di amministratore."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Benvenuto in BackupMe").font(.title.bold())
                Text(intro)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
            .padding(.horizontal, 40)

            Form {
                FoldersSection(model: model)
                DestinationSection(model: model)
                Section("Frequenza") {
                    Picker("Backup ogni", selection: $model.settings.intervalHours) {
                        ForEach(AppSettings.intervals, id: \.self) { Text($0 == 1 ? "1 ora" : "\($0) ore").tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !model.settings.isConfigured {
                    Text("Scegli almeno una cartella e la destinazione.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Più tardi") { dismissWindow(id: "welcome") }
                    .keyboardShortcut(.cancelAction)
                Button("Avvia il primo backup") {
                    SystemServices.requestNotificationPermission()
                    model.backupNow()
                    dismissWindow(id: "welcome")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.settings.isConfigured)
            }
            .padding(16)
        }
        .frame(width: 560, height: 660)
    }
}
