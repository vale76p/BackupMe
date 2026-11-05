import Foundation
import Testing
@testable import BackupCore

@Suite struct RepositoryTests {
    let dest = tmp()

    @Test func missingDestinationThrows() {
        let missing = dest.appending(path: "non-esiste")
        #expect(throws: RepositoryError.destinationMissing(missing.path)) {
            try Repository(destination: missing, computerName: "Mac")
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func pickingTheArchiveOrItsFolderMeansTheDestination() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let d = dest.standardizedFileURL.path
        #expect(Repository.destination(for: r.root).path == d)
        #expect(Repository.destination(for: r.root.deletingLastPathComponent()).path == d)
        #expect(Repository.destination(for: dest).path == d)
        // a folder merely named BackupMe, with no archive in it, is taken as is
        let other = tmp().appending(path: "BackupMe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(Repository.destination(for: other).path == other.standardizedFileURL.path)
    }

    @Test func createsLayout() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        #expect(r.root.path.hasSuffix("BackupMe/Mac"))
        for name in ["repo.json", "objects", "snapshots"] {
            #expect(FileManager.default.fileExists(atPath: r.root.appending(path: name).path))
        }
        #expect(Repository.computers(in: dest) == ["Mac"])
    }

    @Test func objectRoundTrip() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let data = Data("ciao".utf8)
        let h = sha256Hex(data)
        _ = try r.putObject(data, hash: h)
        #expect(r.hasObject(h))
        #expect(try r.readObject(h) == data)
        #expect(objectFile(r, h) != nil)
        // a fresh instance sees it via listing
        #expect(try Repository(destination: dest, computerName: "Mac").hasObject(h))
    }

    @Test func emptyObjectRoundTrip() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let h = sha256Hex(Data())
        _ = try r.putObject(Data(), hash: h)
        #expect(try r.readObject(h) == Data())
    }

    @Test func corruptObjectDetected() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let data = Data("originale".utf8)
        let h = sha256Hex(data)
        _ = try r.putObject(data, hash: h)
        let other = Data("altro".utf8)
        _ = try r.putObject(other, hash: sha256Hex(other))
        let dst = objectFile(r, h)!
        try FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: objectFile(r, sha256Hex(other))!, to: dst)
        #expect(throws: RepositoryError.corruptObject(h)) { try r.readObject(h) }
    }

    @Test func snapshotRoundTripAndOrder() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let d5 = Snapshot.date(fromID: "2026-11-05T10-00-00Z")!
        let d4 = Snapshot.date(fromID: "2026-11-04T10-00-00Z")!
        let entry = Entry(source: "/src", path: "a.txt", kind: .file, hash: "abc", size: 3,
                          mtime: Date(timeIntervalSince1970: 1000.5), mode: 0o644, linkTarget: nil)
        let s5 = Snapshot(date: d5, sources: ["/src"], entries: [entry], warnings: ["w"])
        try r.writeSnapshot(s5)
        try r.writeSnapshot(Snapshot(date: d4, sources: ["/src"], entries: [], warnings: []))
        #expect(try r.snapshotIDs() == ["2026-11-04T10-00-00Z", "2026-11-05T10-00-00Z"])
        let back = try r.readSnapshot("2026-11-05T10-00-00Z")
        #expect(back.entries == [entry])
        #expect(back.warnings == ["w"])
        #expect(back.date == d5)
        try r.deleteSnapshot("2026-11-04T10-00-00Z")
        #expect(try r.snapshotIDs() == ["2026-11-05T10-00-00Z"])
    }

    @Test func snapshotIDFormat() {
        #expect(Snapshot.id(for: Date(timeIntervalSince1970: 0)) == "1970-01-01T00-00-00Z")
        #expect(Snapshot.date(fromID: "1970-01-01T00-00-00Z") == Date(timeIntervalSince1970: 0))
        #expect(Snapshot.date(fromID: "x") == nil)
    }

    @Test func liveLockRefuses() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        try r.withLock {
            #expect(throws: RepositoryError.self) { try r.withLock {} }
        }
    }

    @Test func staleLockRemoved() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let lock = r.root.appending(path: "lock")
        let json = #"{"pid":999999,"host":"Mac"}"#
        try Data(json.utf8).write(to: lock)
        var ran = false
        try r.withLock { ran = true }
        #expect(ran)
    }

    @Test func temporaryFilesRemoved() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let t = r.root.appending(path: "objects/ab/x.tmp")
        write("x", to: t)
        try r.removeTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: t.path))
    }

    @Test func poolSizeCountsObjects() throws {
        let r = try Repository(destination: dest, computerName: "Mac")
        let before = try r.poolSize()
        let data = Data(repeating: 7, count: 10)
        _ = try r.putObject(data, hash: sha256Hex(data))
        #expect(try r.poolSize() > before)
    }
}
