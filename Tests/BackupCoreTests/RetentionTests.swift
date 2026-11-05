import Foundation
import Testing
@testable import BackupCore

@Suite struct RetentionTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        c.firstWeekday = 2
        return c
    }()

    func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!
    }
    var now: Date { d(2026, 11, 5, 12) }

    func policy(_ days: Int, _ weeks: Int, _ months: Int) -> RetentionPolicy {
        var p = RetentionPolicy(); p.days = days; p.weeks = weeks; p.months = months; return p
    }

    func snaps(_ dates: [Date]) -> [(id: String, date: Date)] { dates.map { (Snapshot.id(for: $0), $0) } }
    func ids(_ dates: [Date]) -> Set<String> { Set(dates.map { Snapshot.id(for: $0) }) }

    @Test func keepsAllWithin24h() {
        let dates = (0..<24).map { now.addingTimeInterval(-Double($0) * 3600) }
        #expect(snapshotsToKeep(snaps(dates), policy: policy(0, 0, 0), now: now, calendar: cal) == ids(dates))
    }

    @Test func keepsLastPerDay() {
        let dates = [d(2026, 11, 1, 9), d(2026, 11, 1, 13), d(2026, 11, 1, 18), now]
        #expect(snapshotsToKeep(snaps(dates), policy: policy(14, 0, 0), now: now, calendar: cal)
            == ids([d(2026, 11, 1, 18), now]))
    }

    @Test func dropsDailyBeyondNDays() {
        let dates = [d(2026, 11, 1, 18), d(2026, 11, 4, 18), d(2026, 11, 5, 11)]
        #expect(snapshotsToKeep(snaps(dates), policy: policy(2, 0, 0), now: now, calendar: cal)
            == ids([d(2026, 11, 4, 18), d(2026, 11, 5, 11)]))
    }

    @Test func keepsLastPerWeek() {
        // newest is in the current week so the "always keep newest" rule does not interfere
        let dates = [d(2026, 10, 26), d(2026, 10, 30), d(2026, 11, 2)]
        #expect(snapshotsToKeep(snaps(dates), policy: policy(0, 2, 0), now: now, calendar: cal)
            == ids([d(2026, 10, 30), d(2026, 11, 2)]))
    }

    @Test func keepsLastPerMonth() {
        let dates = [d(2026, 7, 10), d(2026, 8, 15), d(2026, 9, 1), d(2026, 9, 20), d(2026, 11, 1)]
        #expect(snapshotsToKeep(snaps(dates), policy: policy(0, 0, 3), now: now, calendar: cal)
            == ids([d(2026, 9, 20), d(2026, 11, 1)]))
    }

    @Test func alwaysKeepsNewest() {
        let old = d(2025, 11, 5)
        #expect(snapshotsToKeep(snaps([old]), policy: policy(0, 0, 0), now: now, calendar: cal) == ids([old]))
    }

    @Test func dueLogic() {
        #expect(isBackupDue(lastSuccess: nil, intervalHours: 1, now: now))
        #expect(!isBackupDue(lastSuccess: now.addingTimeInterval(-1800), intervalHours: 1, now: now))
        #expect(isBackupDue(lastSuccess: now.addingTimeInterval(-3600), intervalHours: 1, now: now))
    }
}
