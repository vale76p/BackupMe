import Foundation

public struct PackEntry: Equatable, Sendable {
    public var hash: String      // SHA-256 of the original content
    public var offset: Int       // of the stored bytes, after the record header
    public var length: Int       // of the stored bytes
    public var compressed: Bool  // LZFSE, as a `.lzfse` object; false as a `.raw` one
}

/// A container: many small objects in one file. `BMPACK1\n`, then records of a 37-byte header and the object's bytes.
enum Pack {
    static let magic = Data("BMPACK1\n".utf8)
    static let headerSize = 37   // 32 hash bytes, 1 encoding byte (0 raw, 1 lzfse), 4 length bytes big-endian

    static func append(_ body: Data, hash: String, compressed: Bool, to pack: inout Data) -> PackEntry {
        if pack.isEmpty { pack.append(magic) }
        pack.append(contentsOf: stride(from: 0, to: 64, by: 2).map { i in
            let s = hash.utf8.index(hash.utf8.startIndex, offsetBy: i)
            return UInt8(String(hash[s..<hash.index(s, offsetBy: 2)]), radix: 16)!
        })
        pack.append(compressed ? 1 : 0)
        pack.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: body.count >> (8 * (3 - $0))) })
        pack.append(body)
        return PackEntry(hash: hash, offset: pack.count - body.count, length: body.count, compressed: compressed)
    }

    static func scan(_ pack: Data, id: String) throws -> [PackEntry] {
        let p = Data(pack), damaged = RepositoryError.damagedPack(id)
        guard p.starts(with: magic) else { throw damaged }
        var entries: [PackEntry] = [], at = magic.count
        while at < p.count {
            guard p.count - at >= headerSize, p[at + 32] <= 1 else { throw damaged }
            let length = p[(at + 33)..<(at + 37)].reduce(0) { $0 << 8 | Int($1) }
            let offset = at + headerSize
            guard length <= p.count - offset else { throw damaged }
            entries.append(PackEntry(hash: p[at..<(at + 32)].map { String(format: "%02x", $0) }.joined(),
                                     offset: offset, length: length, compressed: p[at + 32] == 1))
            at = offset + length
        }
        return entries
    }

    static func encodeIndex(_ entries: [PackEntry]) -> Data {
        let body = "[" + entries.sorted { $0.offset < $1.offset }
            .map { "[\"\($0.hash)\",\($0.offset),\($0.length),\($0.compressed ? 1 : 0)]" }.joined(separator: ",") + "]"
        // in-memory LZFSE doesn't fail on valid input
        return try! (Data((sha256Hex(Data(body.utf8)) + "\n" + body).utf8) as NSData).compressed(using: .lzfse) as Data
    }

    static func decodeIndex(_ data: Data, id: String) throws -> [PackEntry] {
        let damaged = RepositoryError.damagedPack(id)
        guard let raw = try? (data as NSData).decompressed(using: .lzfse) as Data, raw.count > 65,
              raw[raw.startIndex + 64] == 10 else { throw damaged }
        let body = raw.dropFirst(65)
        guard String(decoding: raw.prefix(64), as: UTF8.self) == sha256Hex(Data(body)),
              let rows = try? JSONSerialization.jsonObject(with: body) as? [[Any]] else { throw damaged }
        return try rows.map { r in
            guard r.count == 4, let h = r[0] as? String, Repository.isHash(h), let o = r[1] as? Int, let l = r[2] as? Int,
                  o >= 0, l >= 0, let c = r[3] as? Int, c == 0 || c == 1 else { throw damaged }
            return PackEntry(hash: h, offset: o, length: l, compressed: c == 1)
        }
    }
}
