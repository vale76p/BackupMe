import BackupCore
import RestoreRules
import SwiftUI

/// One place for the actions, floating under the list and the inspector.
struct RestoreActionBar: View {
    /// Room the list and the inspector leave for it.
    static let height: CGFloat = 76

    let bar: RestorePlanner.Bar
    /// The file or folder the bar speaks of, for its icon.
    let entry: Entry?
    /// Off while nothing can be restored, a restore runs, or the check before «Sostituisci» runs.
    let disabled: Bool
    /// «Ripristino in corso…» or «Controllo della cartella attuale…»: the bar says it, and does nothing else.
    let busy: String?
    let help: String
    /// In a search the Finder's place is taken by the backup that holds the result.
    let revealTitle: String
    let revealIcon: String
    let canReveal: Bool
    let canShowVersions: Bool
    let preview: () -> Void
    let compare: () -> Void
    let restore: () -> Void
    let restoreInto: () -> Void
    let reveal: () -> Void
    let showVersions: () -> Void

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(busy ?? bar.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(bar.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .opacity(busy == nil ? 1 : 0) // kept: the bar must not change height
                }
                Spacer(minLength: 12)
                ForEach(bar.buttons, id: \.self) { button in control(button) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .glassPanel(in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var icon: some View {
        switch bar.icon {
        case .none: EmptyView()
        case .file, .folder:
            if let entry { Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 28, height: 28) }
        case .stack: Image(systemName: "square.stack.3d.up").font(.system(size: 22)).foregroundStyle(.secondary)
        case .drive: Image(systemName: "externaldrive").font(.system(size: 22)).foregroundStyle(.secondary)
        }
    }

    /// The menu's shortcuts are not set here: a closed Menu doesn't fire them, so the window keeps them.
    @ViewBuilder private func control(_ button: RestorePlanner.Bar.Button) -> some View {
        switch button {
        case .preview:
            Button("Anteprima", systemImage: "eye", action: preview)
                .help("La versione salvata, in Quick Look")
                .glassButton()
        case .compare:
            Button("Confronta con oggi", systemImage: "arrow.left.arrow.right", action: compare)
                .help("La versione salvata e quella di oggi, una accanto all'altra")
                .glassButton()
        case .reveal:
            Button(revealTitle, systemImage: revealIcon, action: reveal)
                .disabled(!canReveal)
                .glassButton()
        case .restore:
            Menu {
                Button("Ripristina in…", action: restoreInto).disabled(disabled)
                Divider()
                Button(revealTitle, action: reveal).disabled(!canReveal)
                Button("Mostra versioni del file", action: showVersions).disabled(!canShowVersions)
            } label: {
                Label("Ripristina", systemImage: "arrow.uturn.backward")
            } primaryAction: {
                restore()
            }
            .disabled(disabled)
            .help(help)
            .glassButton(prominent: true)
        case .restoreAll:
            Button("Ripristina tutto…", systemImage: "arrow.uturn.backward", action: restore)
                .disabled(disabled)
                .help(help)
                .glassButton(prominent: true)
        }
    }
}
