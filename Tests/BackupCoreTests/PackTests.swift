import Testing
import Foundation
@testable import BackupCore

@Suite struct PackTests {
    @Test func recordsRoundTripThroughScanAndIndex() throws {
        var pack = Data()
        let a = Data("ciao".utf8), empty = Data()
        let e1 = Pack.append(a, hash: sha256Hex(a), compressed: false, to: &pack)
        let e2 = Pack.append(empty, hash: sha256Hex(empty), compressed: false, to: &pack)
        #expect(pack.prefix(8) == Pack.magic)
        #expect(e1.offset == 8 + Pack.headerSize && e1.length == 4)
        #expect(e2.offset == e1.offset + 4 + Pack.headerSize && e2.length == 0)
        #expect(try Pack.scan(pack, id: "x") == [e1, e2])
        #expect(try Pack.decodeIndex(Pack.encodeIndex([e1, e2]), id: "x") == [e1, e2])
    }
    @Test func truncatedPackAndDamagedIndexAreRefused() {
        var pack = Data()
        _ = Pack.append(Data("ciao".utf8), hash: sha256Hex(Data("ciao".utf8)), compressed: false, to: &pack)
        #expect(throws: RepositoryError.damagedPack("x")) { try Pack.scan(pack.dropLast(1), id: "x") }
        #expect(throws: RepositoryError.damagedPack("x")) { try Pack.scan(Data("altro".utf8), id: "x") }
        var index = Pack.encodeIndex([])
        index[index.count / 2] ^= 0xff
        #expect(throws: RepositoryError.damagedPack("x")) { try Pack.decodeIndex(index, id: "x") }
    }
    @Test func indexBytesMatchTheFormatDocument() throws {
        let h = String(repeating: "ab", count: 32)
        let text = String(decoding: try (Pack.encodeIndex([PackEntry(hash: h, offset: 45, length: 3, compressed: true)]) as NSData)
            .decompressed(using: .lzfse) as Data, as: UTF8.self)
        let body = "[[\"\(h)\",45,3,1]]"
        #expect(text == sha256Hex(Data(body.utf8)) + "\n" + body)
    }
}
