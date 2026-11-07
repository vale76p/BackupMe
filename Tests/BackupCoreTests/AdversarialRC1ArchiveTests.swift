import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Regression tests for the archive findings of the adversarial review for 1.0.0-rc1.
@Suite struct AdversarialRC1ArchiveTests {
    let dest = tmp()
    let src = tmp()
    let fm = FileManager.default
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func backup(_ repo: Repository) throws -> BackupReport {
        try BackupEngine(repository: repo, cache: HashCache(url: tmp().appending(path: "c.json")),
                         excludes: ExcludeRules(patterns: [])).run(sources: [src])
    }

    /// Bytes that differ from block to block: just above the stream threshold, stored as a copy.
    func bigFile(_ name: String) throws -> URL {
        let url = src.appending(path: name)
        var data = Data(count: Int(Repository.streamThreshold) + (1 << 20))
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try data.write(to: url)
        return url
    }

    func lock(_ url: URL, _ on: Bool) { _ = try? fm.setAttributes([.immutable: on], ofItemAtPath: url.path) }

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

    // MARK: A1 / A2 / B4: exFAT and FAT32

    /// These volumes say 0 bytes free for important usage. The 33 MB file, locked in the Finder, is copied in chunks
    /// (no clone across volumes) and verifies; on FAT32 a file over 4 GiB is a warning, not a failed backup.
    @Test(arguments: ["ExFAT", "MS-DOS"]) func bigFilesOnFATFilesystems(fs: String) throws {
        let dir = tmp(), mount = dir.appending(path: "vol"), image = dir.appending(path: "vol.dmg")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try #require(try hdiutil("create", "-quiet", "-size", "80m", "-fs", fs, "-volname", "T", image.path) == 0)
        try #require(try hdiutil("attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path) == 0)
        defer { _ = try? hdiutil("detach", "-quiet", "-force", mount.path) }

        let big = try bigFile("video.mov")
        lock(big, true)
        defer { lock(big, false) }
        let huge = src.appending(path: "disco.img")
        if fs == "MS-DOS" {
            // sparse: never read, the size alone decides
            #expect(fm.createFile(atPath: huge.path, contents: nil))
            try FileHandle(forWritingTo: huge).truncate(atOffset: (1 << 32) + 1)
        }
        let repo = try Repository(destination: mount, computerName: "Mac")
        #expect((repo.availableCapacity() ?? 0) > Repository.streamThreshold)
        let report = try backup(repo)
        #expect(report.error == nil, "\(report.error ?? "")")
        let id = try #require(report.snapshotID)
        let s = try repo.readSnapshot(id)
        let hash = try #require(s.entries.first { $0.path == "video.mov" }?.hash)
        #expect(try repo.verifyObject(hash))
        if fs == "MS-DOS" {
            #expect(report.warnings.contains { $0.hasPrefix(huge.path) && $0.contains("FAT32") }, "\(report.warnings)")
            #expect(!s.entries.contains { $0.path == "disco.img" })
        } else {
            #expect(repo.maxFileSize == .max)
        }
    }

    // MARK: A2: files locked in the Finder

    @Test func lockedBigFileIsStoredAndRestored() throws {
        let big = try bigFile("bloccato.bin")
        lock(big, true)
        defer { lock(big, false) }
        let repo = try Repository(destination: dest, computerName: "Mac")
        let report = try backup(repo) // same volume: the object starts as a clone, flags included
        #expect(report.error == nil)
        let id = try #require(report.snapshotID)
        let hash = try #require(try repo.readSnapshot(id).entries.first { $0.path == "bloccato.bin" }?.hash)
        let object = try #require(objectFile(repo, hash))
        var st = stat()
        #expect(lstat(object.path, &st) == 0 && st.st_flags & UInt32(UF_IMMUTABLE) == 0)
        let restored = tmp().appending(path: "r.bin")
        try repo.restoreObject(hash, to: restored)
        #expect(try Data(contentsOf: restored) == Data(contentsOf: big))
    }

    @Test func lockedLeftoverTemporaryFilesAreRemoved() throws {
        let big = try bigFile("grande.bin")
        let hash = try streamHash(big)
        let repo = try Repository(destination: dest, computerName: "Mac")
        // left by 0.9.4: the clone of a locked file, which nothing could remove
        let fanout = repo.root.appending(path: "objects/\(hash.prefix(2))", directoryHint: .isDirectory)
        try fm.createDirectory(at: fanout, withIntermediateDirectories: true)
        let leftovers = [fanout.appending(path: "\(hash).raw.tmp"), repo.root.appending(path: "objects/00/x.raw.tmp")]
        for url in leftovers { write("vecchio", to: url); lock(url, true) }
        defer { for url in leftovers { lock(url, false) } }

        #expect(try backup(repo).error == nil) // the leftover under the same name is replaced
        #expect(!fm.fileExists(atPath: leftovers[0].path))
        _ = try prune(repository: repo, policy: RetentionPolicy(), capBytes: nil, now: t0, forceGC: true)
        #expect(!fm.fileExists(atPath: leftovers[1].path))
    }

    // MARK: A3: links in objects/

    @Test func cleanupNeverDeletesThroughALinkInObjects() throws {
        let repo = try Repository(destination: dest, computerName: "Mac")
        let photos = tmp(), lookalike = tmp()
        let photo = photos.appending(path: "IMG_0001.raw"), stray = photos.appending(path: "x.tmp")
        let hashNamed = lookalike.appending(path: "ab" + String(repeating: "0", count: 62) + ".raw")
        for url in [photo, stray, hashNamed] { write("foto", to: url) }
        try fm.createSymbolicLink(at: repo.root.appending(path: "objects/IM"), withDestinationURL: photos)
        try fm.createSymbolicLink(at: repo.root.appending(path: "objects/ab"), withDestinationURL: lookalike)

        #expect(try repo.allObjectHashes().isEmpty)
        #expect(try repo.objectSizes().isEmpty)
        _ = try prune(repository: repo, policy: RetentionPolicy(), capBytes: nil, now: t0, forceGC: true)
        try repo.deleteObject(hashNamed.deletingPathExtension().lastPathComponent)
        try repo.deleteObject("../../IM/IMG_0001")
        for url in [photo, stray, hashNamed] { #expect(fm.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
    }
}
