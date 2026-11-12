import Foundation
import Testing
@testable import BackupCore

@Suite struct RepositoryPackTests {
    let dest = tmp()

    func repo(packBelow: Int) throws -> Repository { try Repository(destination: dest, computerName: "Mac", packBelow: packBelow) }

    func put(_ r: Repository, _ text: String) throws -> String {
        let data = Data(text.utf8), h = sha256Hex(data)
        _ = try r.putObject(data, hash: h)
        return h
    }

    func packURL(_ r: Repository, _ id: String, _ ext: String = "pack") -> URL { r.root.appending(path: "packs/\(id).\(ext)") }

    /// Every file in packs/ with its bytes: what a read must leave as it is.
    func packFiles(_ r: Repository) throws -> [String: Data] {
        let dir = r.root.appending(path: "packs")
        return Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .map { ($0, try Data(contentsOf: dir.appending(path: $0))) })
    }

    func flip(_ url: URL, at offset: Int) throws {
        var data = try Data(contentsOf: url)
        data[offset] ^= 0xff
        try data.write(to: url)
    }

    @Test func smallObjectsGoIntoOneContainerAndLargeOnesStayFiles() throws {
        let r = try repo(packBelow: 100)
        let small = try put(r, "piccolo"), empty = try put(r, "")
        let big = Data((0..<4000).map { _ in UInt8.random(in: 0...255) })
        _ = try r.putObject(big, hash: sha256Hex(big))
        #expect(r.hasObject(small)) // in the open container, not yet published
        try r.flushPack()
        #expect(objectFile(r, small) == nil && objectFile(r, empty) == nil && objectFile(r, sha256Hex(big)) != nil)
        #expect(try r.packIDs().count == 1)
        let again = try repo(packBelow: 100)
        #expect(try again.readObject(small) == Data("piccolo".utf8) && again.readObject(empty).isEmpty)
        #expect(again.hasObject(small) && again.archiveFormat == 2)   // archiveFormat: test helper reading repo.json
        #expect(try again.allObjectHashes() == [small, empty, sha256Hex(big)])
        let id = try #require(try again.packIDs().first)
        #expect(try again.objectSizes() == [small: 7, empty: 0, sha256Hex(big): 4000])
        #expect(try again.looseObjectSizes() == [sha256Hex(big): 4000])
        #expect(try again.poolSize() == 4000 + again.packSize(id))
    }

    @Test func withoutPackBelowNothingChanges() throws {
        let r = try repo(packBelow: 0)
        let h = try put(r, "piccolo")
        try r.flushPack()
        #expect(try objectFile(r, h) != nil && r.packIDs().isEmpty && r.archiveFormat == 1)
        #expect(!FileManager.default.fileExists(atPath: r.root.appending(path: "packs").path))
    }

    @Test func missingOrWrongIndexIsRebuiltFromTheContainer() throws {
        let r = try repo(packBelow: 100)
        let a = try put(r, "uno"), c = try put(r, "tre")
        try r.flushPack()
        let b = try put(r, "dodici") // another size: its index doesn't fit the first container
        try r.flushPack()
        let ids = try r.packIDs()
        try #require(ids.count == 2)
        let idx = packURL(r, ids[0], "idx")
        let scanned = try Pack.scan(try Data(contentsOf: packURL(r, ids[0])), id: ids[0])
        func packs() throws -> [String: Data] { try packFiles(r) }
        func readsAll(_ r: Repository) throws -> Bool {
            try r.readObject(a) == Data("uno".utf8) && r.readObject(c) == Data("tre".utf8) && r.readObject(b) == Data("dodici".utf8)
        }
        func rebuilt(_ wrong: Data?) throws {
            if let wrong { try wrong.write(to: idx) } else { try FileManager.default.removeItem(at: idx) }
            let before = try packs()
            // browsing: the rebuilt index is used in memory only
            #expect(try readsAll(try repo(packBelow: 100)))
            #expect(try packs() == before)
            let again = try repo(packBelow: 100)
            #expect(try again.withLock { try readsAll(again) })
            #expect(try Pack.decodeIndex(try Data(contentsOf: idx), id: ids[0]) == scanned)
        }
        try rebuilt(nil)
        // the valid index of another container
        try rebuilt(try Data(contentsOf: packURL(r, ids[1], "idx")))
        // a valid index with an entry past the container's end
        try rebuilt(Pack.encodeIndex([scanned[0], PackEntry(hash: String(repeating: "ab", count: 32), offset: 1000, length: 5, compressed: false)]))
        // the right size with two records swapped: found only when an object is read
        var swapped = scanned
        (swapped[0].offset, swapped[1].offset) = (scanned[1].offset, scanned[0].offset)
        try rebuilt(Pack.encodeIndex(swapped))
    }

    @Test func damagedRecordHeaderWithIntactContentStillReads() throws {
        let r = try repo(packBelow: 100)
        let h = try put(r, "intatto")
        try r.flushPack()
        let id = try #require(try r.packIDs().first)
        let e = try #require(try r.packEntries(id).first)
        try flip(packURL(r, id), at: e.offset - Pack.headerSize) // a byte of the hash in the record header
        try flip(packURL(r, id), at: e.offset - 5)               // the encoding byte
        let before = try packFiles(r)
        #expect(try repo(packBelow: 100).readObject(h) == Data("intatto".utf8))
        let again = try repo(packBelow: 100)
        #expect(try again.withLock { try again.readObject(h) } == Data("intatto".utf8))
        #expect(try packFiles(r) == before) // the index that locates it is not replaced by a scan of the header
    }

    @Test func containerCutShortKeepsWhatItsIndexLocates() throws {
        let r = try repo(packBelow: 100)
        let a = try put(r, "primo"), b = try put(r, "secondo")
        try r.flushPack()
        let pack = packURL(r, try #require(try r.packIDs().first))
        try Data(contentsOf: pack).dropLast(1).write(to: pack) // cut in its last record, the index intact
        let before = try packFiles(r)
        for locked in [false, true] {
            let again = try repo(packBelow: 100)
            func reads() throws {
                #expect(try again.readObject(a) == Data("primo".utf8))
                #expect(throws: (any Error).self) { try again.readObject(b) }
            }
            if locked { try again.withLock { try reads() } } else { try reads() }
        }
        #expect(try packFiles(r) == before)
    }

    @Test func openingAndAskingNeverReadsAContainer() throws {
        let r = try repo(packBelow: 100)
        let h = try put(r, "solo l'indice")
        try r.flushPack()
        let id = try #require(try r.packIDs().first)
        // unreadable, as a container only online is undownloaded: its index and its size are enough
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: packURL(r, id).path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: packURL(r, id).path) }
        let again = try repo(packBelow: 100)
        try again.loadPackIndex()
        #expect(again.hasObject(h) && again.packOf(h) == id)
        #expect(try repo(packBelow: 100).allObjectHashes() == [h])
    }

    @Test func damagedContainerHidesOnlyItsOwnObjects() throws {
        let r = try repo(packBelow: 100)
        let a = try put(r, "uno")
        try r.flushPack()
        let b = try put(r, "due")
        try r.flushPack()
        let ids = try r.packIDs()
        // cut short and without its index: it can't be rebuilt
        try FileManager.default.removeItem(at: packURL(r, ids[0], "idx"))
        try Data(contentsOf: packURL(r, ids[0])).dropLast(1).write(to: packURL(r, ids[0]))
        let again = try repo(packBelow: 100)
        #expect(try again.readObject(b) == Data("due".utf8))
        #expect(!again.hasObject(a)) // the next backup stores it again
        #expect(throws: RepositoryError.damagedPack(ids[0])) { try again.packEntries(ids[0]) }
    }

    @Test func newestCopyCountsAndAnOlderOneRescuesIt() throws {
        let r = try repo(packBelow: 0)
        let h = try put(r, "contenuto da salvare")
        try r.repack([h])
        try r.repack([h])
        try r.deleteObject(h) // only the two copies in containers are left
        let ids = try r.packIDs()
        try #require(ids.count == 2)
        #expect(r.packOf(h) == ids[1])
        let entry = try #require(try r.packEntries(ids[1]).first)
        try flip(packURL(r, ids[1]), at: entry.offset)
        #expect(try repo(packBelow: 0).readObject(h) == Data("contenuto da salvare".utf8))
        #expect(try repo(packBelow: 0).verifyObject(h))
        try flip(packURL(r, ids[0]), at: entry.offset)
        #expect(throws: RepositoryError.corruptObject(h)) { try repo(packBelow: 0).readObject(h) }
    }

    @Test func corruptOnlyCopyIsRepairedAsAFile() throws {
        let r = try repo(packBelow: 100)
        let source = tmp().appending(path: "nota.txt")
        write("una nota", to: source)
        let h = try put(r, "una nota")
        try r.flushPack()
        let id = try #require(try r.packIDs().first)
        try flip(packURL(r, id), at: try #require(try r.packEntries(id).first).offset)
        let damaged = try Data(contentsOf: packURL(r, id))
        #expect(try !r.verifyObject(h))
        #expect(try r.repairObject(h, from: source))
        #expect(objectFile(r, h) != nil)
        #expect(try Data(contentsOf: packURL(r, id)) == damaged)
        #expect(try repo(packBelow: 100).readObject(h) == Data("una nota".utf8))
    }

    @Test func condemnedObjectIsNotReusedButStillRead() throws {
        let r = try repo(packBelow: 100)
        let h = try put(r, "condannato")
        try r.flushPack()
        r.condemned = [h]
        #expect(!r.hasObject(h))
        #expect(try r.readObject(h) == Data("condannato".utf8))
    }

    @Test func idsGrowEvenWhenTheClockGoesBack() throws {
        let r = try repo(packBelow: 100)
        try FileManager.default.createDirectory(at: r.root.appending(path: "packs"), withIntermediateDirectories: true)
        try Pack.magic.write(to: packURL(r, "ffffffffffff0000"))
        let h = try put(r, "dopo")
        try r.flushPack()
        #expect(try r.packIDs() == ["ffffffffffff0000", "ffffffffffff0001"])
        #expect(r.packOf(h) == "ffffffffffff0001")
    }

    /// A copy is relied on only once read back: a container that doesn't read back as written is removed, and what was
    /// left open by a repack that stopped is never published.
    @Test func repackReadsBackWhatItPublished() throws {
        let r = try repo(packBelow: 0)
        let a = try put(r, "uno"), b = try put(r, "due")
        #expect(throws: CocoaError.self) { try r.repack([a, String(repeating: "0", count: 64)]) }
        try r.flushPack()
        #expect(try r.packIDs().isEmpty)
        try FileManager.default.createDirectory(at: r.root.appending(path: "packs"), withIntermediateDirectories: true)
        try Pack.magic.write(to: packURL(r, "7fffffffffffff00"))
        try Pack.encodeIndex([]).write(to: packURL(r, "7fffffffffffff00", "idx"))
        // what reading the next one back will find: none of what was written
        r.rebuiltIndexes["7fffffffffffff01"] = []
        #expect(throws: RepositoryError.damagedPack("7fffffffffffff01")) { try r.repack([a, b]) }
        #expect(try r.packIDs() == ["7fffffffffffff00"])
        #expect(r.packOf(a) == nil && objectFile(r, a) != nil && objectFile(r, b) != nil)
        try r.repack([a, b])
        #expect(try r.packIDs() == ["7fffffffffffff00", "7fffffffffffff01"] && r.packOf(b) == "7fffffffffffff01")
    }

    @Test func packsFolderSwappedForALinkIsRefused() throws {
        let r = try repo(packBelow: 100)
        let elsewhere = tmp()
        try FileManager.default.createSymbolicLink(at: r.root.appending(path: "packs"), withDestinationURL: elsewhere)
        _ = try put(r, "attraverso")
        #expect(throws: (any Error).self) { try r.flushPack() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(r.archiveFormat == 1)
    }

    @Test func unreadableContainerIsNotCorrupt() throws {
        let r = try repo(packBelow: 100)
        let h = try put(r, "illeggibile")
        try r.flushPack()
        let pack = packURL(r, try #require(try r.packIDs().first))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: pack.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pack.path) }
        do {
            _ = try repo(packBelow: 100).readObject(h)
            Issue.record("an unreadable container was read")
        } catch {
            #expect(error as? RepositoryError != .corruptObject(h))
        }
        // without its index: the rebuild can't read the container either, and that is not damage
        try FileManager.default.removeItem(at: packURL(r, pack.deletingPathExtension().lastPathComponent, "idx"))
        let again = try repo(packBelow: 100)
        do {
            _ = try again.withLock { try again.readObject(h) }
            Issue.record("an unreadable container was read")
        } catch {
            #expect((error as? POSIXError)?.code == .EACCES, "\(error)")
        }
    }

    @Test func leftoversInPacksAreRemoved() throws {
        let r = try repo(packBelow: 100)
        let h = try put(r, "resta")
        try r.flushPack()
        let id = try #require(try r.packIDs().first)
        write("avanzo", to: packURL(r, id, "pack.tmp"))
        write("avanzo", to: packURL(r, "0000000000000001", "idx")) // an index without its container
        #expect(try r.removeTemporaryFiles() == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.root.appending(path: "packs").path).sorted()
            == ["\(id).idx", "\(id).pack"])
        #expect(try repo(packBelow: 100).readObject(h) == Data("resta".utf8))
        try r.deletePack(id)
        #expect(try r.packIDs().isEmpty && !r.hasObject(h))
    }

    func engine(_ r: Repository, _ cache: URL) -> BackupEngine {
        BackupEngine(repository: r, cache: HashCache(url: cache), excludes: ExcludeRules(patterns: []))
    }

    @Test func mixedArchiveRestoresBothBackups() throws {
        let src = tmp().appending(path: "progetto", directoryHint: .isDirectory), cache = tmp().appending(path: "cache.json")
        write("uno", to: src.appending(path: "a.txt")); write("due", to: src.appending(path: "b.txt")); write("", to: src.appending(path: "vuoto.txt"))
        let r1 = try repo(packBelow: 0)
        let s1 = try #require(try engine(r1, cache).run(sources: [src], now: Date(timeIntervalSince1970: 1_700_000_000)).snapshotID)
        let loose = try r1.allObjectHashes()
        write("uno modificato", to: src.appending(path: "a.txt")); write("tre", to: src.appending(path: "c.txt"))
        let r2 = try repo(packBelow: 4 << 20)
        let s2 = try #require(try engine(r2, cache).run(sources: [src], now: Date(timeIntervalSince1970: 1_700_000_100)).snapshotID)
        #expect(try r2.looseObjectSizes().keys.sorted() == loose.sorted() && r2.packIDs().count == 1)
        for (id, files) in [(s1, ["a.txt": "uno", "b.txt": "due", "vuoto.txt": ""]),
                            (s2, ["a.txt": "uno modificato", "b.txt": "due", "c.txt": "tre", "vuoto.txt": ""])] {
            let out = tmp(), snap = try r2.readSnapshot(id)
            let dir = try Restorer(repository: r2).restore(snap, source: src.path, path: "", mode: .into(out))
            for (name, text) in files { #expect(try String(contentsOf: dir.appending(path: name), encoding: .utf8) == text) }
        }
    }

    @Test func interruptedBackupKeepsWhatItCopied() throws {
        let src = tmp().appending(path: "progetto", directoryHint: .isDirectory), cache = tmp().appending(path: "cache.json")
        for i in 0..<20 { write("contenuto \(i)", to: src.appending(path: "f\(String(format: "%02d", i)).txt")) }
        let r = try repo(packBelow: 4 << 20)
        var ticks = 0
        #expect(throws: BackupError.cancelled) {
            try engine(r, cache).run(sources: [src], progress: { _ in ticks += 1 }, isCancelled: { ticks >= 11 }) // the source folder itself is the first tick, then 10 files
        }
        #expect(try r.packIDs().count == 1)
        let again = try engine(r, cache).run(sources: [src], now: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(again.newBytes == (10..<20).reduce(0) { $0 + Int64("contenuto \($1)".utf8.count) })
    }

    @Test(arguments: ["ExFAT", "MS-DOS"]) func containerOnFATFilesystems(fs: String) throws {
        let dir = tmp(), mount = dir.appending(path: "vol"), image = dir.appending(path: "vol.dmg")
        func hdiutil(_ args: String...) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try #require(try hdiutil("create", "-quiet", "-size", "20m", "-fs", fs, "-volname", "T", image.path) == 0)
        try #require(try hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path) == 0)
        defer { _ = try? hdiutil("detach", "-quiet", "-force", mount.path) }

        let r = try Repository(destination: mount, computerName: "Mac", packBelow: 100)
        let a = try put(r, "primo"), b = try put(r, "secondo")
        try r.flushPack()
        let c = try put(r, "terzo")
        try r.flushPack()
        let again = try Repository(destination: mount, computerName: "Mac", packBelow: 100)
        #expect(try again.readObject(a) == Data("primo".utf8) && again.readObject(b) == Data("secondo".utf8)
            && again.readObject(c) == Data("terzo".utf8))
        #expect(try again.packIDs().count == 2 && again.archiveFormat == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: r.root.appending(path: "packs").path)
        #expect(names.filter { !$0.hasPrefix(".") }.count == 4) // two containers, two indexes, no leftover .tmp
    }
}
