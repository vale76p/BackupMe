import Foundation
import Testing
@testable import BackupCore

@Suite struct ArchiveWriteSafetyTests {
    private let fm = FileManager.default

    private func sentinel() throws -> URL {
        let url = tmp().appending(path: "sentinel")
        try Data("keep me".utf8).write(to: url)
        return url
    }

    private func plant(_ target: URL, at url: URL) throws {
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
    }

    private func unchanged(_ url: URL) throws {
        #expect(try Data(contentsOf: url) == Data("keep me".utf8))
    }

    @Test func infoCreationAndRepairIgnorePlantedTemporaryLinks() throws {
        let dest = tmp(), victim = try sentinel()
        let root = dest.appending(path: "BackupMe/Mac")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appending(path: "repo.json.tmp")
        try plant(victim, at: link)
        let created = try Repository(destination: dest, computerName: "Mac")
        #expect(created.archiveID != nil)
        try unchanged(victim)
        try Data("broken".utf8).write(to: root.appending(path: "repo.json"))
        let repaired = try Repository(destination: dest, computerName: "Mac")
        #expect(repaired.repairedInfo)
        #expect(repaired.archiveID != nil)
        try unchanged(victim)
        // the planted link is removed, never followed
        #expect(!fm.fileExists(atPath: link.path) && (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    @Test(arguments: [false, true]) func objectsAndRepairIgnorePlantedLinks(compressible: Bool) throws {
        let r = try Repository(destination: tmp(), computerName: "Mac"), victim = try sentinel()
        let data = compressible ? Data(repeating: 65, count: 10000) : Data("short".utf8)
        let hash = sha256Hex(data), ext = compressible ? "lzfse" : "raw"
        let object = r.root.appending(path: "objects/\(hash.prefix(2))/\(hash).\(ext)")
        try fm.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plant(victim, at: object.appendingPathExtension("tmp"))
        _ = try r.putObject(data, hash: hash)
        #expect(try r.readObject(hash) == data)
        try unchanged(victim)
        try Data("corrupt".utf8).write(to: object)
        let source = tmp().appending(path: "source")
        try data.write(to: source)
        // Integrity checks open without creating an archive, but may repair existing objects.
        let reopened = try Repository(destination: r.root.deletingLastPathComponent().deletingLastPathComponent(),
                                      computerName: "Mac", create: false)
        #expect(try reopened.repairObject(hash, from: source))
        #expect(try r.readObject(hash) == data)
        try unchanged(victim)
    }

    @Test func snapshotPublicationIsStillExclusive() throws {
        let r = try Repository(destination: tmp(), computerName: "Mac"), victim = try sentinel()
        let snapshot = Snapshot(date: Date(), sources: [], entries: [], warnings: [])
        let final = r.root.appending(path: "snapshots/\(snapshot.id).json.lzfse")
        try plant(victim, at: final.appendingPathExtension("tmp"))
        try r.writeSnapshot(snapshot)
        let original = try Data(contentsOf: final)
        #expect(throws: (any Error).self) { try r.writeSnapshot(snapshot) }
        #expect(try Data(contentsOf: final) == original)
        #expect(try r.readSnapshot(snapshot.id).id == snapshot.id)
        try unchanged(victim)
        let files = try fm.contentsOfDirectory(atPath: final.deletingLastPathComponent().path)
        #expect(!files.contains { $0.hasSuffix(".tmp") })
    }

    @Test(arguments: ["BackupMe", "BackupMe/Mac", "BackupMe/Mac/objects", "BackupMe/Mac/snapshots"])
    func initializationRejectsLinkedDirectories(component: String) throws {
        let dest = tmp(), outside = tmp()
        let link = dest.appending(path: component)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plant(outside, at: link)
        #expect(throws: (any Error).self) { try Repository(destination: dest, computerName: "Mac") }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test(arguments: [false, true]) func writersRejectLinkedFanout(streamed: Bool) throws {
        let r = try Repository(destination: tmp(), computerName: "Mac"), outside = tmp()
        let data = Data("source".utf8), hash = sha256Hex(data)
        try plant(outside, at: r.root.appending(path: "objects/\(hash.prefix(2))"))
        if streamed {
            let source = tmp().appending(path: "source")
            try data.write(to: source)
            #expect(throws: (any Error).self) { try r.putObjectFile(from: source, hash: hash) }
        } else {
            #expect(throws: (any Error).self) { try r.putObject(data, hash: hash) }
        }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func directorySwapAfterOpeningIsRejected() throws {
        let r = try Repository(destination: tmp(), computerName: "Mac"), outside = tmp()
        let snapshots = r.root.appending(path: "snapshots")
        try fm.removeItem(at: snapshots)
        try plant(outside, at: snapshots)
        #expect(throws: (any Error).self) {
            try r.writeSnapshot(Snapshot(date: Date(), sources: [], entries: [], warnings: []))
        }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func publicationPreservesReadableModesAndLinkedDestination() throws {
        let destination = tmp(), alias = tmp().appending(path: "selected")
        try plant(destination, at: alias)
        let r = try Repository(destination: alias, computerName: "Mac")
        let data = Data("source".utf8), hash = sha256Hex(data)
        _ = try r.putObject(data, hash: hash)
        let object = r.root.appending(path: "objects/\(hash.prefix(2))/\(hash).raw")
        #expect(try fm.attributesOfItem(atPath: object.path)[.posixPermissions] as? Int == 0o644)
        let source = tmp().appending(path: "source")
        try data.write(to: source)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        #expect(try r.putObjectFile(from: source, hash: hash) == Int64(data.count))
        #expect(try fm.attributesOfItem(atPath: object.path)[.posixPermissions] as? Int == 0o640)
        #expect(try r.readObject(hash) == data)
    }

    @Test func streamedHashMismatchDoesNotPublishOrLeakTemporaryFiles() throws {
        let r = try Repository(destination: tmp(), computerName: "Mac")
        let source = tmp().appending(path: "source")
        try Data("source".utf8).write(to: source)
        let hash = sha256Hex(Data("other".utf8))
        #expect(try r.putObjectFile(from: source, hash: hash) == nil)
        #expect(try fm.contentsOfDirectory(atPath: r.root.appending(path: "objects/\(hash.prefix(2))").path).isEmpty)
    }

    @Test func lockIgnoresPlantedLink() throws {
        let r = try Repository(destination: tmp(), computerName: "Mac"), outside = tmp()
        try plant(outside.appending(path: "created"), at: r.root.appending(path: "lock"))
        #expect(throws: (any Error).self) { try r.withLock {} }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func lockRefusesAPipe() throws {
        let r = try Repository(destination: tmp(), computerName: "Mac")
        #expect(mkfifo(r.root.appending(path: "lock").path, 0o644) == 0)
        var ran = false
        #expect(throws: (any Error).self) { try r.withLock { ran = true } }
        #expect(!ran)
    }

    @Test func restoreKitIgnoresLinkedBackupMeFolder() throws {
        let dest = tmp(), outside = tmp()
        try plant(outside, at: dest.appending(path: "BackupMe"))
        #expect(Repository.updateRestoreKit(destination: dest) == .noArchive)
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func restoreKitReplacesPlantedFiles() throws {
        let dest = tmp(), victim = try sentinel()
        let base = dest.appending(path: "BackupMe")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try plant(victim, at: base.appending(path: "RIPRISTINO.command"))
        // a pipe: never read (a plain read would wait forever), only replaced
        #expect(mkfifo(base.appending(path: "LEGGIMI.txt").path, 0o644) == 0)
        _ = try Repository(destination: dest, computerName: "Mac")
        try unchanged(victim)
        for (name, mode) in [("RIPRISTINO.command", 0o755), ("LEGGIMI.txt", 0o644)] {
            let attributes = try fm.attributesOfItem(atPath: base.appending(path: name).path)
            #expect(attributes[.type] as? FileAttributeType == .typeRegular)
            #expect(attributes[.posixPermissions] as? Int == mode)
        }
        #expect(Repository.updateRestoreKit(destination: dest) == .current(RestoreKit.version))
    }

    /// The physical address of a file's first byte: the same for a clone and its source.
    private func firstBlock(_ url: URL) throws -> off_t {
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        var l2p = log2phys()
        l2p.l2p_contigbytes = 1
        guard fd >= 0, fcntl(fd, F_LOG2PHYS_EXT, &l2p) == 0 else { throw POSIXError(.EIO) }
        return l2p.l2p_devoffset
    }

    @Test func largeObjectIsAClone() throws {
        let r = try Repository(destination: tmp(), computerName: "Mac")
        let source = tmp().appending(path: "source")
        let data = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try data.write(to: source)
        let fd = open(source.path, O_RDONLY)
        fsync(fd); close(fd)
        let hash = sha256Hex(data)
        #expect(try r.putObjectFile(from: source, hash: hash) == Int64(data.count))
        let object = r.root.appending(path: "objects/\(hash.prefix(2))/\(hash).raw")
        // same APFS volume (the temporary folder): stored without taking its size again
        #expect(try firstBlock(object) == firstBlock(source))
        #expect(try r.readObject(hash) == data)
    }

    @Test(arguments: [false, true]) func interruptedCopyLeavesNoSpaceBehind(streamed: Bool) throws {
        let r = try Repository(destination: tmp(), computerName: "Mac")
        // incompressible: stored raw by both writers
        let data = Data((0..<4096).map { _ in UInt8.random(in: 0...255) }), hash = sha256Hex(data)
        let object = r.root.appending(path: "objects/\(hash.prefix(2))/\(hash).raw")
        try fm.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        // what a copy killed halfway leaves
        try Data(repeating: 1, count: 1000).write(to: object.appendingPathExtension("tmp"))
        if streamed {
            let source = tmp().appending(path: "source")
            try data.write(to: source)
            #expect(try r.putObjectFile(from: source, hash: hash) == Int64(data.count))
        } else {
            _ = try r.putObject(data, hash: hash)
        }
        #expect(try r.readObject(hash) == data)
        #expect(try fm.contentsOfDirectory(atPath: object.deletingLastPathComponent().path) == [object.lastPathComponent])
    }
}
