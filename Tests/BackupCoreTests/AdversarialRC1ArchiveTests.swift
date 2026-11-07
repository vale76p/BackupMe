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
}
