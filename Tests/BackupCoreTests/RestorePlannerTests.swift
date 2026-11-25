import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct RestorePlannerTests {
    let source = Rules.source, other = "/Users/x/Documenti"
    // the backup being browsed, and an older one
    var backup: RestorePlanner.Backup { .init(id: Snapshot.id(for: Rules.d(2026, 11, 23, 15)), date: Rules.d(2026, 11, 23, 15)) }
    var older: RestorePlanner.Backup { .init(id: Snapshot.id(for: Rules.d(2026, 10, 30, 20)), date: Rules.d(2026, 10, 30, 20)) }
    var file: Entry { Rules.entry("BackupMe/README.md", size: 15_000) }
    var folder: Entry { Rules.entry("BackupMe", kind: .directory) }
    var saved: Entry { Rules.entry("", kind: .directory) }
    var savedOther: Entry { Rules.entry("", kind: .directory, source: other) }
    /// On disk today and not in the backup: it has no hash.
    var added: Entry {
        Entry(source: source, path: "BackupMe/AGENTS.md", kind: .file, hash: nil, size: 366, mtime: Rules.d(2026, 11, 8),
              mode: 0o644, linkTarget: nil)
    }

    /// Browsing a folder: `visible` is what the list shows, `selected` the rows chosen among them.
    func browsing(source: String? = Rules.source, path: String = "BackupMe", visible: [Entry], selected: [Entry],
                  version: RestorePlanner.Hit? = nil) -> RestorePlanner.Selection {
        RestorePlanner.Selection(backup: backup, source: source, path: path, visible: visible,
                                 selectedIDs: Set(selected.map(\.restoreID)), version: version, sources: [Rules.source, other])
    }

    func bar(_ selection: RestorePlanner.Selection, compare: Bool = false) -> RestorePlanner.Bar {
        RestorePlanner.bar(RestorePlanner.resolve(selection), selection: selection, compare: compare,
                           now: Rules.d(2026, 11, 24, 20, 15), calendar: Rules.cal, locale: Rules.it)
    }

    @Test func nothingWithoutABackup() {
        #expect(RestorePlanner.resolve(RestorePlanner.Selection()).action == .nothing)
    }

    @Test func insideAFolderWithNothingSelectedTheFolderIsRestored() {
        let plan = RestorePlanner.resolve(browsing(path: "BackupMe/Sources", visible: [folder, file], selected: []))
        #expect(plan.action == .items([.init(source: source, path: "BackupMe/Sources")]))
        #expect(plan.from == backup)
        #expect(!plan.asksFirst)
    }

    @Test func theSelectedRowsAndOnlyThose() {
        let plan = RestorePlanner.resolve(browsing(visible: [folder, file, added], selected: [file, folder]))
        #expect(plan.action == .items([.init(folder), .init(file)]))
        // a link has no hash: its target is its content, so it is restored like a file
        var link = Rules.entry("BackupMe/link", kind: .symlink)
        link.linkTarget = "../README.md"
        #expect(RestorePlanner.resolve(browsing(visible: [link], selected: [link])).action == .items([.init(link)]))
    }

    @Test func aRowTheFilterHidesIsNotSelected() {
        // both were selected, then a filter hid the file: only the folder is still selected
        let plan = RestorePlanner.resolve(browsing(visible: [folder], selected: [file, folder]))
        #expect(plan.action == .items([.init(folder)]))
    }

    @Test func anAddedItemRestoresNothing() {
        #expect(RestorePlanner.resolve(browsing(visible: [added, file], selected: [added])).action == .nothing)
        // chosen together with a real one, only the real one is restored
        #expect(RestorePlanner.resolve(browsing(visible: [added, file], selected: [added, file])).action == .items([.init(file)]))
    }

    @Test func aSavedFolderAsksFirst() {
        let selected = RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved], selected: [saved]))
        #expect(selected.action == .wholeFolder(source))
        #expect(selected.asksFirst)
        // at the root of a saved folder with nothing selected, the folder itself is what gets restored
        let here = RestorePlanner.resolve(browsing(path: "", visible: [folder, file], selected: []))
        #expect(here.action == .wholeFolder(source))
        #expect(here.asksFirst)
    }

    @Test func twoSavedFoldersRestoreBesideWithoutAsking() {
        let plan = RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved, savedOther], selected: [saved, savedOther]))
        #expect(plan.action == .items([.init(saved), .init(savedOther)]))
        #expect(!plan.asksFirst)
    }

    @Test func atTheTopLevelWithNothingSelectedEverythingIsRestored() {
        let plan = RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved, savedOther], selected: []))
        #expect(plan.action == .wholeBackup)
        #expect(plan.from == backup)
    }

    @Test func theChosenVersionComesFromItsOwnBackup() {
        let plan = RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: older, entry: file)))
        #expect(plan.action == .version(.init(file)))
        #expect(plan.from == older)
        #expect(plan.isVersion)
        // the browsed backup's own version is not another version: the file is simply restored from it
        let own = RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: backup, entry: file)))
        #expect(own.action == .items([.init(file)]))
        #expect(own.from == backup)
        #expect(!own.isVersion)
    }

    @Test func aVersionOfAnotherFileIsIgnored() {
        let plan = RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: older, entry: Rules.entry("BackupMe/Altro.md"))))
        #expect(plan.action == .items([.init(file)]))
        #expect(plan.from == backup)
        #expect(!plan.isVersion)
    }

    @Test func aFolderHasNoVersion() {
        // the same path held as a file by another backup: a folder row never becomes a version
        let plan = RestorePlanner.resolve(browsing(visible: [folder], selected: [folder],
                                                   version: .init(backup: older, entry: Rules.entry("BackupMe", size: 15_000))))
        #expect(plan.action == .items([.init(folder)]))
        #expect(plan.from == backup)
    }

    @Test func aSearchResult() {
        let hit = RestorePlanner.Hit(backup: older, entry: file)
        let plan = RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true, hit: hit))
        #expect(plan.action == .items([.init(file)]))
        // the result is restored from the backup that holds it, not from the one being browsed
        #expect(plan.from == older)
        let versioned = RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true, hit: hit,
                                                                        version: .init(backup: backup, entry: file)))
        #expect(versioned.action == .version(.init(file)))
        #expect(versioned.from == backup)
        #expect(versioned.isVersion)
        // before any backup is browsed (its index still loads), a result is restored all the same
        let early = RestorePlanner.resolve(RestorePlanner.Selection(searching: true, hit: hit))
        #expect(early.action == .items([.init(file)]))
        #expect(early.from == older)
        // a version held by the result's own backup is the result itself
        #expect(RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true, hit: hit,
                                                              version: .init(backup: older, entry: file))).action == .items([.init(file)]))
    }

    @Test func aSearchWithNothingSelectedRestoresNothing() {
        #expect(RestorePlanner.resolve(RestorePlanner.Selection(backup: backup, searching: true)).action == .nothing)
    }

    @Test func theBarOfAFile() {
        let selection = browsing(visible: [file], selected: [file])
        #expect(bar(selection) == .init(icon: .file, name: "README.md", detail: "dal backup di ieri alle 15:00", buttons: [.preview, .restore]))
        #expect(bar(selection, compare: true) == .init(icon: .file, name: "README.md", detail: "dal backup di ieri alle 15:00",
                                                        buttons: [.preview, .compare, .restore]))
    }

    @Test func theBarOfAFolderAndOfTheFolderBeingViewed() {
        let selected = browsing(path: "BackupMe/Sources", visible: [folder], selected: [folder])
        #expect(bar(selected) == .init(icon: .folder, name: "BackupMe", detail: "dal backup di ieri alle 15:00", buttons: [.restore]))
        let none = browsing(path: "BackupMe/Sources", visible: [folder], selected: [])
        #expect(bar(none) == .init(icon: .folder, name: "Sources", detail: "dal backup di ieri alle 15:00", buttons: [.restore]))
    }

    @Test func theBarOfSeveralItems() {
        let selection = browsing(visible: [folder, file], selected: [folder, file])
        #expect(bar(selection) == .init(icon: .stack, name: "2 elementi", detail: "1 cartella e 1 file · 15 kB · dal backup di ieri alle 15:00",
                                        buttons: [.restore]))
    }

    @Test func theBarOfAVersion() {
        let selection = browsing(visible: [file], selected: [file], version: .init(backup: older, entry: file))
        #expect(bar(selection) == .init(icon: .file, name: "README.md", detail: "versione del 30 ott, 20:00", buttons: [.preview, .restore]))
        #expect(bar(selection, compare: true) == .init(icon: .file, name: "README.md", detail: "versione del 30 ott, 20:00",
                                                        buttons: [.preview, .compare, .restore]))
        // the bar names a version only when it comes from another backup than the one being viewed
        let own = browsing(visible: [file], selected: [file], version: .init(backup: backup, entry: file))
        #expect(bar(own) == .init(icon: .file, name: "README.md", detail: "dal backup di ieri alle 15:00", buttons: [.preview, .restore]))
    }

    @Test func theBarOfASavedFolderAndOfAllOfThem() {
        let one = browsing(source: nil, path: "", visible: [saved], selected: [saved])
        #expect(bar(one) == .init(icon: .folder, name: "Progetti", detail: "cartella intera · dal backup di ieri alle 15:00", buttons: [.restore]))
        let all = browsing(source: nil, path: "", visible: [saved, savedOther], selected: [])
        #expect(bar(all) == .init(icon: .drive, name: "Tutte le cartelle", detail: "2 cartelle · dal backup di ieri alle 15:00", buttons: [.restoreAll]))
        var single = browsing(source: nil, path: "", visible: [saved], selected: [])
        single.sources = [source]
        #expect(bar(single) == .init(icon: .drive, name: "Tutte le cartelle", detail: "1 cartella · dal backup di ieri alle 15:00", buttons: [.restoreAll]))
    }

    @Test func thePlanListsWhatItRestores() {
        #expect(RestorePlanner.resolve(browsing(visible: [folder, file], selected: [folder, file])).items == [.init(folder), .init(file)])
        #expect(RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved], selected: [saved])).items == [.init(source: source, path: "")])
        #expect(RestorePlanner.resolve(browsing(source: nil, path: "", visible: [saved], selected: [])).items.isEmpty)
        #expect(RestorePlanner.resolve(browsing(visible: [file], selected: [file], version: .init(backup: older, entry: file))).items == [.init(file)])
        #expect(RestorePlanner.resolve(RestorePlanner.Selection()).items.isEmpty)
    }

    @Test func theBarWhenNothingCanBeRestored() {
        #expect(bar(browsing(visible: [added], selected: [added])) == .init(icon: .none, name: "Niente da ripristinare qui", detail: "", buttons: [.reveal]))
        #expect(bar(RestorePlanner.Selection(backup: backup, searching: true)) == .init(icon: .none, name: "Seleziona un risultato", detail: "", buttons: [.reveal]))
    }
}

@Suite struct SelectionSummaryTests {
    @Test func countsFoldersThenFilesThenTheSizeOfTheFiles() {
        let folder = Rules.entry("a", kind: .directory), file = Rules.entry("b", size: 2_400_000), link = Rules.entry("c", kind: .symlink)
        #expect(SelectionSummary.text([folder, file, link], locale: Rules.it) == "1 cartella e 2 file · 2,4 MB")
        #expect(SelectionSummary.text([file], locale: Rules.it) == "1 file · 2,4 MB")
        #expect(SelectionSummary.text([folder, folder], locale: Rules.it) == "2 cartelle")
        #expect(SelectionSummary.text([link], locale: Rules.it) == "1 file")
    }

    @Test func saysHowManyAreSelected() {
        #expect(SelectionSummary.count(1) == "1 elemento selezionato")
        #expect(SelectionSummary.count(3) == "3 elementi selezionati")
    }
}
