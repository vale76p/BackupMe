import Foundation
import Testing
@testable import BackupCore

/// Regression tests for the app lifecycle findings of the adversarial review for 1.0.0-rc1.
@Suite struct AdversarialRC1LifecycleTests {
    let dest = tmp()

    func report(snapshot: String?, error: String?) -> BackupReport {
        BackupReport(snapshotID: snapshot, date: Date(), duration: 0, fileCount: 0, newBytes: 0, warnings: [], error: error)
    }

    // MARK: R2 / M6, cleanup after a backup

    @Test func interruptedRunHasNoCleanup() {
        let d = cleanupDecision(thrown: BackupError.cancelled, report: report(snapshot: nil, error: "Backup interrotto"),
                                lastComplete: "20260101-000000")
        #expect(d == .skip)
    }

    @Test func lockedArchiveHasNoCleanup() {
        // a check stuck on a read still holds the lock: cleanup would fail and report a damaged archive
        let d = cleanupDecision(thrown: RepositoryError.locked(pid: 0, host: "Mac"),
                                report: report(snapshot: nil, error: "Un altro backup è già in corso"), lastComplete: "20260101-000000")
        #expect(d == .skip)
    }

    @Test func partialRunPinsTheLastCompleteBackup() {
        let d = cleanupDecision(thrown: nil, report: report(snapshot: "20260102-000000", error: "Cartella non trovata"),
                                lastComplete: "20260101-000000")
        #expect(d == .prune(pinned: ["20260101-000000", "20260102-000000"]))
    }

    @Test func partialRunWithoutCompleteBackupHasNoCleanup() {
        let d = cleanupDecision(thrown: nil, report: report(snapshot: "20260102-000000", error: "Cartella non trovata"),
                                lastComplete: nil)
        #expect(d == .skip)
    }

    @Test func completeRunPinsOnlyItself() {
        let d = cleanupDecision(thrown: nil, report: report(snapshot: "20260102-000000", error: nil), lastComplete: "20260101-000000")
        #expect(d == .prune(pinned: ["20260102-000000"]))
    }

    @Test func failedRunWithoutBackupStillCollectsOrphans() {
        // a write that failed halfway leaves objects without a manifest: cleanup collects them
        let d = cleanupDecision(thrown: POSIXError(.ENOSPC), report: report(snapshot: nil, error: "spazio esaurito"), lastComplete: nil)
        #expect(d == .prune(pinned: []))
    }

    // MARK: A4, one archive per account

    func info(_ r: Repository) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(contentsOf: r.root.appending(path: "repo.json"))) as? [String: Any]
    }

    @Test func secondAccountIsRefused() throws {
        let a = try Repository(destination: dest, computerName: "iMac-1A2B3C4D")
        try a.withLock { try a.claim(owner: 501, name: "anna") }
        let b = try Repository(destination: dest, computerName: "iMac-1A2B3C4D")
        #expect(throws: RepositoryError.otherOwner) { try b.withLock { try b.claim(owner: 502, name: "bruno") } }
        // the owner itself, at every later backup
        try a.claim(owner: 501, name: "anna")
    }

    @Test func archiveFromBeforeTheOwnerGoesToTheFirstClaimant() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let id = r.archiveID
        try r.claim(owner: 501, name: "anna")
        #expect(r.archiveID == id) // same archive: its id is kept
        let json = try info(r)
        #expect(json?["owner"] as? Int == 501)
        #expect(json?["ownerName"] as? String == "anna")
        #expect(json?["format"] as? Int == Repository.format)
        #expect(throws: RepositoryError.otherOwner) { try r.claim(owner: 502, name: "bruno") }
    }

    @Test func sameAccountWithNewUIDKeepsItsArchive() throws {
        // Migration Assistant with 501 already taken: the same account comes back as 502
        let r = try Repository(destination: dest, computerName: "Mac")
        try r.claim(owner: 501, name: "anna")
        try r.claim(owner: 502, name: "anna")
        #expect(try info(r)?["owner"] as? Int == 502)
        #expect(throws: RepositoryError.otherOwner) { try r.claim(owner: 501, name: "bruno") }
    }

    @Test func ownerWithoutNameIsComparedByUID() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        write(#"{"format":1,"id":"X","owner":501}"#, to: r.root.appending(path: "repo.json"))
        #expect(throws: RepositoryError.otherOwner) { try r.claim(owner: 502, name: "anna") }
        try r.claim(owner: 501, name: "anna")
        #expect(try info(r)?["ownerName"] as? String == "anna")
    }

    @Test func readOnlyArchiveDoesNotStopTheBackup() throws {
        // a full or read-only destination: recording the owner fails, the backup and its cleanup still run
        let r = try Repository(destination: dest, computerName: "Mac")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: r.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r.root.path) }
        try r.claim(owner: 501, name: "anna")
        #expect(try info(r)?["owner"] == nil)
    }
}
