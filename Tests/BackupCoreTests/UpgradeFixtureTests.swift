import Foundation
import Testing
@testable import BackupCore

/// The check after an update, on archives really written by older versions: only the kit is rewritten (when older),
/// nothing needs attention, and the same build doesn't check twice.
extension FormatFixtureTests {
    @Test(arguments: FormatFixtureTests.versions) func upgradeCheckOnReleasedArchive(_ version: String) throws {
        let (dest, _) = try copy(version)
        let repo = try Repository(destination: dest, computerName: Self.archive(version))
        let report = try upgradeCheck(repository: repo)
        #expect(report.attention.isEmpty, "\(version): \(report.attention)")
        #expect(report.fixed.allSatisfy { $0.contains("kit di ripristino") }, "\(version): \(report.fixed)")
        if version != "1.0-rc1" && version != "2.0" { #expect(!report.fixed.isEmpty, "\(version): kit vecchio non riscritto") }

        let defaults = try #require(UserDefaults(suiteName: "upgrade-fixture-\(UUID().uuidString)"))
        #expect(try upgradeCheckIfNeeded(repository: repo, build: "1.0 (19)", defaults: defaults) != nil)
        #expect(try upgradeCheckIfNeeded(repository: repo, build: "1.0 (19)", defaults: defaults) == nil)
        #expect(try checkArchive(repository: repo, cache: HashCache(url: dest.appending(path: "hc"))).isHealthy)
    }
}
