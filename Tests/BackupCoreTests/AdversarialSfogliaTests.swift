import Foundation
import Testing
@testable import BackupCore
@testable import RestoreRules

/// Regression tests for the findings of the adversarial review of the new Sfoglia window (1.1.0).
@Suite struct AdversarialSfogliaTests {
    let now = Rules.d(2026, 11, 24, 20, 15)
    var backup: RestorePlanner.Backup { .init(id: Snapshot.id(for: Rules.d(2026, 11, 23, 15)), date: Rules.d(2026, 11, 23, 15)) }
    var file: Entry { Rules.entry("BackupMe/README.md") }
    /// A folder created after the backup: like a saved folder, it has no hash.
    var addedFolder: Entry {
        Entry(source: Rules.source, path: "BackupMe/nuova", kind: .directory, hash: nil, size: 0, mtime: Rules.d(2026, 11, 24),
              mode: 0o755, linkTarget: nil)
    }

    func browsing(selected: [Entry]) -> RestorePlanner.Selection {
        RestorePlanner.Selection(backup: backup, source: Rules.source, path: "BackupMe", visible: [addedFolder, file],
                                 selectedIDs: Set(selected.map(\.restoreID)), sources: [Rules.source],
                                 addedIDs: [addedFolder.restoreID])
    }

    // a «Nuova» folder lit «Ripristina», and the restore then failed: «… non è in questo backup»
    @Test func anAddedFolderRestoresNothing() {
        #expect(RestorePlanner.resolve(browsing(selected: [addedFolder])).action == .nothing)
        #expect(RestorePlanner.resolve(browsing(selected: [addedFolder, file])).action == .items([.init(file)]))
    }

    // «del 8 novembre», «versione del 1 nov»: the days read with a vowel take «dell'»
    @Test func daysReadWithAVowelTakeTheApostrophe() {
        func from(_ d: Date) -> String { WhenText.from(d, now: now, calendar: Rules.cal, locale: Rules.it) }
        func version(_ d: Date) -> String { WhenText.version(d, now: now, calendar: Rules.cal, locale: Rules.it) }
        #expect(from(Rules.d(2026, 11, 8)) == "dal backup dell'8 novembre alle 20:00")
        #expect(from(Rules.d(2026, 11, 11)) == "dal backup dell'11 novembre alle 20:00")
        #expect(from(Rules.d(2026, 11, 1)) == "dal backup dell'1 novembre alle 20:00")
        #expect(from(Rules.d(2026, 11, 10)) == "dal backup del 10 novembre alle 20:00")
        #expect(version(Rules.d(2026, 11, 8)) == "versione dell'8 nov, 20:00")
        #expect(version(Rules.d(2026, 10, 18)) == "versione del 18 ott, 20:00")
        #expect(version(Rules.d(2026, 11, 24, 19)) == "versione di oggi, 19:00")
    }

    // «Stai guardando il backup di» stood before «9 novembre alle 20:00» too
    @Test func theTitleTakesTheArticleOfItsDay() {
        #expect(WhenText.article("Ieri alle 15:00") == "di")
        #expect(WhenText.article("Domenica 22 alle 20:00") == "di")
        #expect(WhenText.article("9 novembre alle 20:00") == "del")
        #expect(WhenText.article("8 novembre alle 20:00") == "dell'")
        #expect(WhenText.article("11 novembre 2025 alle 20:00") == "dell'")
        #expect(WhenText.article("18 novembre alle 20:00") == "del")
    }

    // the timeline worked out the largest backup once per row
    @Test func barWidthAgainstTheLargestWorkedOutOnce() {
        let items = [Rules.item(Rules.d(2026, 11, 24), 200), Rules.item(Rules.d(2026, 11, 23), 50), Rules.item(Rules.d(2026, 11, 22))]
        let largest = BackupTimeline.largest(items)
        #expect(largest == 200_000_000)
        for item in items { #expect(BackupTimeline.barWidth(item, largest: largest) == BackupTimeline.barWidth(item, in: items)) }
        #expect(BackupTimeline.largest([]) == 0)
    }
}
