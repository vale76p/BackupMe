import Foundation
import Testing
@testable import BackupCore

@Suite struct VerifyTests {
    let dest = tmp()
    let src = tmp().appending(path: "progetto", directoryHint: .isDirectory)
    let cacheURL = tmp().appending(path: "cache.json")

    func backup() throws -> Repository {
        let repo = try Repository(destination: dest, computerName: "Mac")
        _ = try BackupEngine(repository: repo, cache: HashCache(url: cacheURL), excludes: ExcludeRules(patterns: [])).run(sources: [src])
        return repo
    }

    func damage(_ url: URL) throws {
        let h = try FileHandle(forUpdating: url)
        try h.write(contentsOf: Data([0xFF, 0x00, 0xFF]))
        try h.close()
    }

    @Test func corruptObjectRepairedFromSource() throws {
        let text = Data(String(repeating: "contenuto ", count: 100).utf8)
        write(String(decoding: text, as: UTF8.self), to: src.appending(path: "a.txt"))
        write("altro", to: src.appending(path: "b.txt"))
        let repo = try backup()
        let h = sha256Hex(text)
        try damage(objectFile(repo, h)!)
        let r = try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: .max)
        #expect(r.checked == 2 && r.repaired == [h] && r.corrupt.isEmpty && r.bytes > 0)
        #expect(try repo.readObject(h) == text)
    }

    @Test func corruptObjectWithoutGoodSourceIsKept() throws {
        write("originale", to: src.appending(path: "a.txt"))
        let repo = try backup()
        let h = sha256Hex(Data("originale".utf8))
        let object = objectFile(repo, h)!
        try damage(object)
        write("cambiato", to: src.appending(path: "a.txt"))
        let r = try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: .max)
        #expect(r.corrupt == [h] && r.repaired.isEmpty)
        #expect(FileManager.default.fileExists(atPath: object.path))
    }

    @Test func budgetLimitsTheSample() throws {
        for i in 0..<3 { write("file \(i)", to: src.appending(path: "\(i).txt")) }
        let r = try verifySample(repository: try backup(), cache: HashCache(url: cacheURL), budgetBytes: 1)
        #expect(r.checked == 1 && r.corrupt.isEmpty)
    }

    @Test func largeRawObjectVerifiedAsStreamAndRepaired() throws {
        let big = Data(repeating: 7, count: Int(Repository.streamThreshold))
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try big.write(to: src.appending(path: "grande.bin"))
        let repo = try backup()
        let h = sha256Hex(big)
        let object = objectFile(repo, h)!
        #expect(object.pathExtension == "raw")
        try damage(object)
        let r = try verifySample(repository: repo, cache: HashCache(url: cacheURL), budgetBytes: .max)
        #expect(r.repaired == [h] && r.bytes == Repository.streamThreshold)
        #expect(try streamHash(object) == h)
    }
}
