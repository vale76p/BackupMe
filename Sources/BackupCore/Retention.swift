import Foundation

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var days = 14
    public var weeks = 8
    public var months = 12
    public init() {}
}

/// Keeps: the newest, everything from the last 24h, and the last snapshot of each of the
/// last N days / weeks / months (periods counted in `calendar`, starting from the one containing `now`).
public func snapshotsToKeep(_ snapshots: [(id: String, date: Date)], policy: RetentionPolicy,
                            now: Date, calendar: Calendar) -> Set<String> {
    var keep = Set<String>()
    if let newest = snapshots.max(by: { $0.date < $1.date }) { keep.insert(newest.id) }
    for s in snapshots where now.timeIntervalSince(s.date) < 24 * 3600 { keep.insert(s.id) }
    for (component, count) in [(Calendar.Component.day, policy.days), (.weekOfYear, policy.weeks), (.month, policy.months)] {
        var anchor = now
        for _ in 0..<max(count, 0) {
            guard let period = calendar.dateInterval(of: component, for: anchor) else { break }
            if let last = snapshots.filter({ $0.date >= period.start && $0.date < period.end })
                .max(by: { $0.date < $1.date }) {
                keep.insert(last.id)
            }
            anchor = period.start.addingTimeInterval(-1)
        }
    }
    return keep
}

public func isBackupDue(lastSuccess: Date?, intervalHours: Int, now: Date) -> Bool {
    guard let last = lastSuccess else { return true }
    return now.timeIntervalSince(last) >= Double(intervalHours) * 3600
}
