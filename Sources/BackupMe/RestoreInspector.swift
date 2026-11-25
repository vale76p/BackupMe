import AppKit
import BackupCore
import QuickLook
import QuickLookThumbnailing
import RestoreRules
import SwiftUI
import UniformTypeIdentifiers

/// The right-hand panel: the chosen item, its content and its saved versions; information only, the actions are in the bar.
struct RestoreInspector: View {
    let model: RestoreModel
    let selection: RestorePlanner.Selection
    /// A row against this Mac's disk.
    let status: (Entry) -> RowStatus?
    let showsStatus: Bool
    /// The chosen version of the file: what the bar's Anteprima, Confronta and Ripristina act on.
    @Binding var picked: SearchHit?
    let locale: Locale

    private var snapshotID: String? { selection.searching ? selection.hit?.backup.id : selection.backup?.id }

    var body: some View {
        let entries = chosen
        if entries.count == 1, let e = entries.first {
            detail(e).id((snapshotID ?? "") + "\u{0}" + e.restoreID)
        } else if entries.count > 1 {
            ContentUnavailableView {
                Label(SelectionSummary.count(entries.count), systemImage: "square.stack.3d.up")
            } description: {
                VStack(spacing: 4) {
                    Text(SelectionSummary.text(entries, locale: locale))
                    Text("Seleziona un solo file per vederne dettagli e versioni.")
                }
            }
        } else {
            ContentUnavailableView("Nessuna selezione", systemImage: "info.circle",
                                   description: Text("Seleziona un file per vederne dettagli e versioni."))
        }
    }

    /// The selected rows, or the selected search result.
    private var chosen: [Entry] {
        if selection.searching { return selection.hit.map { [$0.entry] } ?? [] }
        return selection.visible.filter { selection.selectedIDs.contains($0.restoreID) }
    }

    private func detail(_ entry: Entry) -> some View {
        let s = status(entry)
        // the window clears the pick when the selection changes, one update later: until then it is nobody's
        let version = picked.flatMap { $0.entry.source == entry.source && $0.entry.path == entry.path ? $0 : nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // the card shows the chosen version: what is seen is what Anteprima and Ripristina use
                if entry.kind == .file, let version {
                    PreviewCard(model: model, entry: version.entry, other: version.snapshotID == snapshotID ? nil : version, locale: locale)
                }
                HStack(spacing: 10) {
                    Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline).lineLimit(2).textSelection(.enabled)
                        if let b = StatusBadge.change(s, added: model.isAdded(entry), since: true) { b }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if entry.kind == .file { SizeRow(entry: entry, showsStatus: showsStatus) }
                    row("Modificato", entry.mtime.formatted(date: .abbreviated, time: .shortened))
                    row("Posizione", ((entry.source as NSString).abbreviatingWithTildeInPath as NSString)
                        .appendingPathComponent((entry.path as NSString).deletingLastPathComponent))
                }
                if entry.kind == .file {
                    EntryVersions(model: model, entry: entry, snapshotID: snapshotID ?? "", picked: $picked)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }.font(.callout)
    }
}

/// The size in the backup and, for a file still on this Mac, today's.
private struct SizeRow: View {
    let entry: Entry
    let showsStatus: Bool
    @State private var today: Int64?

    var body: some View {
        LabeledContent("Dimensione") {
            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
                 + (today.map { " allora · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " oggi" } ?? ""))
                .monospacedDigit()
        }
        .font(.callout)
        .task(id: entry) {
            guard showsStatus, Restorer.status(of: entry) != .missing else { today = nil; return }
            let url = entry.url
            today = await Task.detached(priority: .utility) { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) }.value
        }
    }
}

/// Every saved version of the file, one per distinct content, on a line: the chosen one is marked.
private struct EntryVersions: View {
    let model: RestoreModel
    let entry: Entry
    let snapshotID: String
    @Binding var picked: SearchHit?
    @State private var versions: [SearchHit]? // nil while loading
    /// Backups not yet read for versions: they are read only after «Cerca le versioni in tutti i backup».
    @State private var unread = 0
    @State private var searchAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Versioni").font(.subheadline.weight(.semibold))
                Spacer()
                if let versions {
                    Text(versions.count == 1 ? "1 salvata" : "\(versions.count) salvate")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let versions {
                if versions.isEmpty {
                    Text("Nessuna versione leggibile").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(versions) { v in version(v) }
                    }
                    Text("Una riga per ogni contenuto diverso, dalla più recente.").font(.caption).foregroundStyle(.secondary)
                }
                if unread > 0 {
                    if searchAll {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(unread == 1 ? "Resta 1 backup da leggere…" : "Restano \(unread) backup da leggere…")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Cerca le versioni in tutti i backup") { searchAll = true }
                            .help((unread == 1 ? "Legge l'altro backup" : "Legge gli altri \(unread) backup")
                                  + ": con molti file può richiedere qualche minuto")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: searchAll) {
            // the backups already open answer at once; the others only on request, as each manifest takes seconds
            await model.versions(of: entry, in: snapshotID, all: searchAll) { list, left in
                let found = list.map { SearchHit(snapshotID: $0.snapshotID, entry: $0.entry) }
                versions = found
                unread = left
                // the pick stays on its content: a newer backup holding it may now name the row
                picked = found.first { $0.entry.hash == picked?.entry.hash } ?? found.first { $0.snapshotID == snapshotID } ?? found.first
            }
        }
    }

    private func version(_ v: SearchHit) -> some View {
        let on = picked == v
        return Button { picked = v } label: {
            HStack(spacing: 0) {
                // the line the versions sit on, one row at a time
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1.5).frame(maxHeight: .infinity)
                    .overlay {
                        Circle().fill(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(on ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                    }
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Snapshot.date(fromID: v.snapshotID)?.formatted(date: .abbreviated, time: .shortened) ?? v.snapshotID)
                        .font(.callout.weight(on ? .semibold : .regular)).monospacedDigit()
                    if v.entry.hash == entry.hash { Text("in questo backup").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: v.entry.size, countStyle: .file))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(on ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The content of the chosen version, read from the archive once.
private struct PreviewCard: View {
    /// Above this the card keeps the icon: selecting a file must never read one of any size.
    static let limit: Int64 = 20_000_000

    enum Content { case text(String), thumbnail(NSImage) }

    let model: RestoreModel
    let entry: Entry
    /// The version isn't the one of the backup being viewed: the card says which one it is.
    let other: SearchHit?
    let locale: Locale
    @State private var content: Content?

    private var background: some View {
        RoundedRectangle(cornerRadius: 12).fill(LinearGradient(
            colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .underPageBackgroundColor)],
            startPoint: .top, endPoint: .bottom))
    }

    private var card: some View {
        ZStack { background; picture }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// What the card shows; the file's icon until something was read.
    @ViewBuilder private var picture: some View {
        switch content {
        case .thumbnail(let image): Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(14)
        case .text(let text):
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(30).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        case nil: Image(nsImage: FileIcon.image(for: entry)).resizable().frame(width: 56, height: 56)
        }
    }

    var body: some View {
        // the caption is hidden to accessibility, as part of the card: VoiceOver hears the version in the label
        let otherVersion = other.flatMap { Snapshot.date(fromID: $0.snapshotID) }.map { WhenText.version($0, locale: locale) }
        return VStack(alignment: .leading, spacing: 4) {
            card
            if let otherVersion {
                Text(otherVersion).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Anteprima di \(entry.name)" + (otherVersion.map { ", " + $0 } ?? ""))
        .task(id: entry.hash) { await load() } // the content tells one version from another
    }

    /// A card that arrives late must not replace a newer selection: the task is cancelled when the file changes, and nothing is shown once it is.
    private func load() async {
        content = nil
        guard entry.kind == .file, entry.size <= Self.limit else { return }
        // the copy, once started, can't be stopped: a row passed by with the arrow keys must not start one
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        let folder = RestoreModel.cardCopies.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // the card's own folder: no other card, Quick Look or FileMerge reads from it, so it goes once the card is made
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let url = await model.previewCopy(entry, in: folder), !Task.isCancelled else { return }
        // the reads stay off the main thread: only what was read comes back
        let read = await Task.detached(priority: .userInitiated) { PreviewLoader.read(url, name: entry.name) }.value
        if Task.isCancelled { return }
        switch read {
        case .text(let text):
            content = .text(text)
        case .thumbnail:
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 520, height: 300), scale: 2, representationTypes: [.thumbnail])
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request), !Task.isCancelled {
                content = .thumbnail(representation.nsImage)
            }
        case nil:
            break
        }
    }
}

private enum PreviewLoader {
    /// What was read off the main thread.
    enum Read: Sendable { case text(String), thumbnail }

    /// The first lines of a text, or a thumbnail for Quick Look to make: an image too, scaled off the main thread, not decoded whole.
    nonisolated static func read(_ url: URL, name: String) -> Read? {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if isText(type, at: url) { return firstLines(of: url).map(Read.text) }
        return .thumbnail
    }

    /// Text and code by their type; a file macOS knows nothing about is text if its first bytes read as UTF-8.
    nonisolated static func isText(_ type: UTType?, at url: URL) -> Bool {
        guard let type else { return looksLikeText(head(url)) }
        if type.conforms(to: .text) { return true }
        return type.isDynamic && looksLikeText(head(url))
    }

    nonisolated static func looksLikeText(_ head: Data?) -> Bool {
        guard let head else { return false }
        return !head.contains(0) && text(head) != nil
    }

    /// The text, or nil when it is not UTF-8; a character cut in half by the end is dropped first.
    nonisolated static func text(_ data: Data) -> String? {
        var data = data
        for _ in 0..<4 {
            if let text = String(data: data, encoding: .utf8) { return text }
            guard !data.isEmpty else { return nil }
            data.removeLast()
        }
        return nil
    }

    nonisolated static func head(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 4096)
    }

    /// The first 64 KB at most, cut at the end of a line so that no character is left half.
    nonisolated static func firstLines(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return nil }
        var bytes = data.prefix(65_536)
        if data.count > 65_536, let last = bytes.lastIndex(of: 0x0A) { bytes = bytes.prefix(last + 1) }
        guard let text = text(bytes) else { return nil }
        // a line ends with «\n», «\r\n» or «\r»: a Windows file shows its lines, not one cut line
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(40).map { String($0.prefix(160)) }.joined(separator: "\n")
    }
}
