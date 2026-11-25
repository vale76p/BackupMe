import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct RowFilterTests {
    let changed = RowStatus(own: .modified), same = RowStatus(own: .unchanged), gone = RowStatus(own: .missing)
    let holdsChanged = RowStatus(own: .unchanged, modifiedInside: true), holdsGone = RowStatus(own: .unchanged, missingInside: true)

    @Test func modifiedAndDeletedLookAtTheStatus() {
        #expect(changed.passes(.modified) && !changed.passes(.missing))
        #expect(gone.passes(.missing) && !gone.passes(.modified))
        // a folder counts when something inside it changed or vanished
        #expect(holdsChanged.passes(.modified) && !holdsChanged.passes(.missing))
        #expect(holdsGone.passes(.missing) && !holdsGone.passes(.modified))
        #expect(!same.passes(.modified) && !same.passes(.missing))
    }

    @Test func everythingPassesTuttoAndNoRowOfTheBackupIsNew() {
        // «Tutto» once counted the deletions: its number was that of «Eliminati»
        for s in [changed, same, gone, holdsChanged, holdsGone] {
            #expect(s.passes(.all))
            #expect(!s.passes(.added))
        }
    }
}
