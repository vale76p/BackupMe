import BackupCore
import Foundation
@testable import RestoreRules

/// One calendar, one time zone, one locale: the rules read the same wherever the tests run.
enum Rules {
    static let it = Locale(identifier: "it_IT")
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    static func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 20, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: minute))!
    }

    /// A backup with its new bytes in MB.
    static func item(_ date: Date, _ mb: Int64? = nil, warnings: Int? = nil) -> TimelineItem {
        TimelineItem(id: Snapshot.id(for: date), date: date, newBytes: mb.map { $0 * 1_000_000 }, warnings: warnings)
    }

    static let source = "/Users/x/Progetti"

    /// A file of a saved folder; `path` is relative to it.
    static func entry(_ path: String, kind: EntryKind = .file, source: String = Rules.source, size: Int64 = 10) -> Entry {
        Entry(source: source, path: path, kind: kind, hash: kind == .file ? String(repeating: "a", count: 64) : nil, size: size,
              mtime: d(2026, 11, 23, 14, 2), mode: 0o644, linkTarget: nil)
    }
}
