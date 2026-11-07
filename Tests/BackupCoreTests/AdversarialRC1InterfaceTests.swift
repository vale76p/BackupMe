import Foundation
import Testing
@testable import BackupCore

/// Regression tests for the interface findings of the adversarial review for 1.0.0-rc1.
@Suite struct AdversarialRC1InterfaceTests {
    // M8: a destination whose disk is not plugged in is "not connected", never "no backups"
    @Test func unpluggedDestinationIsNotAvailable() throws {
        let dest = tmp()
        _ = try Repository(destination: dest, computerName: "Mac")
        #expect(Repository.isAvailable(destination: dest))
        let file = dest.appending(path: "file")
        write("x", to: file)
        #expect(!Repository.isAvailable(destination: file))
        try FileManager.default.removeItem(at: dest)
        #expect(!Repository.isAvailable(destination: dest))
        #expect(throws: RepositoryError.destinationMissing(dest.path)) {
            try Repository(destination: dest, computerName: "Mac", create: false)
        }
    }
}
