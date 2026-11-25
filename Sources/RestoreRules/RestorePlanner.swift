import BackupCore
import Foundation

/// The line the inspector and the bar give to several selected items.
public enum SelectionSummary {
    /// "3 elementi selezionati", "1 elemento selezionato".
    public static func count(_ n: Int) -> String { n == 1 ? "1 elemento selezionato" : "\(n) elementi selezionati" }

    /// "2 cartelle e 1 file · 2,4 MB": the folders, then the files, then the size of the files when there is one.
    public static func text(_ entries: [Entry], locale: Locale = Locale(identifier: "it_IT")) -> String {
        let folders = entries.filter { $0.kind == .directory }.count
        let files = entries.count - folders
        let size = entries.filter { $0.kind == .file }.reduce(Int64(0)) { $0 + $1.size }
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 cartella" : "\(folders) cartelle") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) file") }
        var text = parts.joined(separator: " e ")
        if !parts.isEmpty, size > 0 { text += " · " + BackupTimeline.bytesText(size, locale: locale) }
        return text
    }
}

/// What tells a row from another: the saved folder it comes from and its path in it.
public extension Entry {
    var restoreID: String { source + "\u{0}" + path }
    /// A file or a link always has its content in the index: one without it is on disk today and not in the backup.
    var hasContent: Bool { kind == .directory || hash != nil || linkTarget != nil }
}

/// Says what «Ripristina» acts on, and what the bar tells about it.
public enum RestorePlanner {
    public struct Backup: Equatable, Sendable {
        public var id: String
        public var date: Date
        public init(id: String, date: Date) { self.id = id; self.date = date }
    }

    /// A file as a search result, or as one of its saved versions.
    public struct Hit: Equatable, Sendable {
        public var backup: Backup
        public var entry: Entry
        public init(backup: Backup, entry: Entry) { self.backup = backup; self.entry = entry }
    }

    /// What the window has selected.
    public struct Selection: Equatable, Sendable {
        /// The backup being browsed; nil until it is loaded.
        public var backup: Backup?
        public var searching = false
        /// The selected search result.
        public var hit: Hit?
        /// nil at «Tutte le cartelle», where the rows are the saved folders.
        public var source: String?
        /// "" at the root of a saved folder.
        public var path = ""
        /// The rows the list shows, after the filter.
        public var visible: [Entry] = []
        /// The selected rows: one the filter hides isn't selected any more.
        public var selectedIDs: Set<String> = []
        /// The chosen version of the only selected file.
        public var version: Hit?
        /// The saved folders of the backup.
        public var sources: [String] = []

        public init(backup: Backup? = nil, searching: Bool = false, hit: Hit? = nil, source: String? = nil, path: String = "",
                    visible: [Entry] = [], selectedIDs: Set<String> = [], version: Hit? = nil, sources: [String] = []) {
            self.backup = backup; self.searching = searching; self.hit = hit; self.source = source; self.path = path
            self.visible = visible; self.selectedIDs = selectedIDs; self.version = version; self.sources = sources
        }
    }

    public struct Item: Equatable, Sendable {
        public var source: String
        public var path: String
        /// nil for the folder being viewed.
        public var entry: Entry?
        public init(source: String, path: String, entry: Entry? = nil) { self.source = source; self.path = path; self.entry = entry }
        public init(_ entry: Entry) { self.init(source: entry.source, path: entry.path, entry: entry) }
    }

    public struct Plan: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            /// Nothing to restore: the button is off.
            case nothing
            /// Beside the original.
            case items([Item])
            /// The chosen version.
            case version(Item)
            /// A whole saved folder: it asks first.
            case wholeFolder(String)
            /// Every saved folder, into a folder of choice.
            case wholeBackup
        }

        public var action: Action
        /// The backup the restore reads from.
        public var from: Backup?
        /// `from` holds a chosen version, not the backup being browsed or the result's.
        public var isVersion: Bool { if case .version = action { return true }; return false }
        /// A whole saved folder asks before anything is written.
        public var asksFirst: Bool { if case .wholeFolder = action { return true }; return false }

        /// What the action restores, the saved folders included; nothing for `.nothing` and `.wholeBackup`.
        public var items: [Item] {
            switch action {
            case .nothing, .wholeBackup: []
            case .items(let items): items
            case .version(let item): [item]
            case .wholeFolder(let source): [Item(source: source, path: "")]
            }
        }

        init(action: Action, from: Backup?) { self.action = action; self.from = from }
    }

    /// The same rules as ever: what is selected is what gets restored, beside the original, and a whole saved folder asks first.
    public static func resolve(_ s: Selection) -> Plan {
        // a result stands on its own: it is restored even while no backup is browsed yet (its index still loads)
        if s.searching {
            guard let hit = s.hit else { return Plan(action: .nothing, from: nil) }
            if let v = otherVersion(s.version, of: hit.entry, than: hit.backup) {
                return Plan(action: .version(Item(v.entry)), from: v.backup)
            }
            return Plan(action: .items([Item(hit.entry)]), from: hit.backup)
        }
        guard let backup = s.backup else { return Plan(action: .nothing, from: nil) }
        // a row without content («Nuovo») is on disk today and not in the backup: nothing comes back from it
        let restorable = s.visible.filter { s.selectedIDs.contains($0.restoreID) && $0.hasContent }
        if restorable.count == 1, let v = otherVersion(s.version, of: restorable[0], than: backup) {
            return Plan(action: .version(Item(v.entry)), from: v.backup)
        }
        if !restorable.isEmpty {
            if restorable.count == 1, restorable[0].path.isEmpty { return Plan(action: .wholeFolder(restorable[0].source), from: backup) }
            return Plan(action: .items(restorable.map { Item($0) }), from: backup)
        }
        // only rows without content are selected, or none inside the folder being viewed
        let picked = s.visible.contains { s.selectedIDs.contains($0.restoreID) }
        guard !picked, let source = s.source else {
            return picked ? Plan(action: .nothing, from: nil) : Plan(action: .wholeBackup, from: backup)
        }
        if s.path.isEmpty { return Plan(action: .wholeFolder(source), from: backup) }
        return Plan(action: .items([Item(source: source, path: s.path)]), from: backup)
    }

    /// The chosen version of the one file `entry`, when a backup other than `own` holds it: that backup's own version is not another version.
    private static func otherVersion(_ v: Hit?, of entry: Entry, than own: Backup) -> Hit? {
        guard let v, entry.kind == .file, v.backup.id != own.id, v.entry.source == entry.source, v.entry.path == entry.path else { return nil }
        return v
    }

    /// What the bar shows.
    public struct Bar: Equatable, Sendable {
        public enum Icon: Hashable, Sendable { case none, file, folder, stack, drive }
        public enum Button: Hashable, Sendable { case preview, compare, reveal, restore, restoreAll }
        public var icon: Icon
        public var name: String
        /// «dal backup di ieri alle 15:00», «versione del 30 ott, 20:00», or «2,4 MB · dal backup di …».
        public var detail: String
        public var buttons: [Button]
    }

    /// The bar for a plan. `compare`: the file differs from today's, so the two can be put side by side.
    public static func bar(_ plan: Plan, selection s: Selection, compare: Bool, now: Date = Date(), calendar: Calendar = .current,
                           locale: Locale = Locale(identifier: "it_IT")) -> Bar {
        let from = plan.from.map { WhenText.from($0.date, now: now, calendar: calendar, locale: locale) } ?? ""
        var fileButtons: [Bar.Button] = [.preview]
        if compare { fileButtons.append(.compare) }
        fileButtons.append(.restore)
        switch plan.action {
        case .nothing:
            // nothing comes back, but where the items are today can still be shown
            return Bar(icon: .none, name: s.searching ? "Seleziona un risultato" : "Niente da ripristinare qui", detail: "", buttons: [.reveal])
        case .wholeBackup:
            let n = s.sources.count
            return Bar(icon: .drive, name: "Tutte le cartelle",
                       detail: (n == 1 ? "1 cartella" : "\(n) cartelle") + (from.isEmpty ? "" : " · " + from), buttons: [.restoreAll])
        case .wholeFolder(let source):
            return Bar(icon: .folder, name: (source as NSString).lastPathComponent,
                       detail: "cartella intera" + (from.isEmpty ? "" : " · " + from), buttons: [.restore])
        case .version(let item):
            return Bar(icon: .file, name: item.entry?.name ?? (item.path as NSString).lastPathComponent,
                       detail: plan.from.map { WhenText.version($0.date, now: now, calendar: calendar, locale: locale) } ?? "",
                       buttons: fileButtons)
        case .items(let items):
            if items.count == 1 {
                let item = items[0]
                if let e = item.entry {
                    if e.kind == .file { return Bar(icon: .file, name: e.name, detail: from, buttons: fileButtons) }
                    return Bar(icon: .folder, name: e.name, detail: from, buttons: [.restore])
                }
                // the folder being viewed, with nothing selected inside it
                return Bar(icon: .folder, name: (item.path as NSString).lastPathComponent, detail: from, buttons: [.restore])
            }
            return Bar(icon: .stack, name: items.count == 1 ? "1 elemento" : "\(items.count) elementi",
                       detail: SelectionSummary.text(items.compactMap(\.entry), locale: locale) + " · " + from, buttons: [.restore])
        }
    }
}
