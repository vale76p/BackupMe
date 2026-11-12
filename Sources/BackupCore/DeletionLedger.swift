import Foundation

/// Counts deletions made in the last hour, so the destination never sees a burst that triggers cloud alerts.
public struct DeletionLedger: Codable, Equatable, Sendable {
    private var entries: [Entry] = []
    private struct Entry: Codable, Equatable, Sendable { var at: Date; var count: Int }

    public init() {}

    /// How many files may be deleted now: `limit` minus those recorded in the 60 minutes before `now`, never below 0.
    public func allowance(limit: Int, now: Date) -> Int {
        max(0, limit - entries.filter { now.timeIntervalSince($0.at) <= 3600 }.reduce(0) { $0 + $1.count })
    }

    /// Remembers `count` deletions at `now` and forgets those older than an hour. A count of 0 is not kept.
    public mutating func record(_ count: Int, at now: Date) {
        // Future-dated entries (clock set back) stay until they are an hour older than `now`.
        entries.removeAll { now.timeIntervalSince($0.at) > 3600 }
        if count > 0 { entries.append(Entry(at: now, count: count)) }
    }
}
