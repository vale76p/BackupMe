import Foundation

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var days = 14
    public var weeks = 8
    public var months = 12
    public init() {}

    // missing keys keep their defaults, so adding a field never wipes saved settings
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? days
        weeks = try c.decodeIfPresent(Int.self, forKey: .weeks) ?? weeks
        months = try c.decodeIfPresent(Int.self, forKey: .months) ?? months
    }
}

extension Calendar {
    /// Gregorian, weeks Monday–Sunday, current time zone: the calendar retention periods are counted in.
    public static var backup: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        return c
    }
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
    // a lastSuccess in the future means the clock was wrong: back up now rather than wait for it
    guard let last = lastSuccess, last <= now else { return true }
    return now.timeIntervalSince(last) >= Double(intervalHours) * 3600
}
