import CryptoKit
import Foundation

public enum EntryKind: String, Codable, Sendable { case file, directory, symlink }

public struct Entry: Codable, Equatable, Hashable, Sendable {
    public var source: String      // absolute path of the source folder
    public var path: String        // relative to source; "" = the source itself
    public var kind: EntryKind
    public var hash: String?       // .file only
    public var size: Int64
    public var mtime: Date
    public var mode: UInt16        // POSIX permissions
    public var linkTarget: String? // .symlink only

    public init(source: String, path: String, kind: EntryKind, hash: String?, size: Int64,
                mtime: Date, mode: UInt16, linkTarget: String?) {
        self.source = source; self.path = path; self.kind = kind; self.hash = hash
        self.size = size; self.mtime = mtime; self.mode = mode; self.linkTarget = linkTarget
    }

    public var name: String { path.isEmpty ? (source as NSString).lastPathComponent : (path as NSString).lastPathComponent }
    public var url: URL { path.isEmpty ? URL(fileURLWithPath: source) : URL(fileURLWithPath: source).appending(path: path) }
}

public struct Snapshot: Codable, Sendable {
    public var id: String
    public var date: Date
    public var sources: [String]
    public var entries: [Entry]
    public var warnings: [String]

    public init(date: Date, sources: [String], entries: [Entry], warnings: [String]) {
        self.id = Snapshot.id(for: date); self.date = date
        self.sources = sources; self.entries = entries; self.warnings = warnings
    }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return f
    }

    public static func id(for date: Date) -> String { formatter().string(from: date) }
    public static func date(fromID id: String) -> Date? { formatter().date(from: id) }
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
