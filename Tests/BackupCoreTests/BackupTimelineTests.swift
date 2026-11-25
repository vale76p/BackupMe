import Foundation
import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct BackupTimelineTests {
    /// A Tuesday afternoon.
    var now: Date { Rules.d(2026, 11, 24, 20, 15) }

    func sections(_ items: [TimelineItem], now: Date) -> [TimelineSection] {
        BackupTimeline.sections(items, now: now, calendar: Rules.cal, locale: Rules.it)
    }
    func titles(_ items: [TimelineItem], now: Date) -> [String] { sections(items, now: now).map(\.title) }

    @Test func oneSectionPerDayOfTheLastWeekThenPerMonth() {
        let s = sections([
            Rules.item(Rules.d(2026, 11, 17)), Rules.item(Rules.d(2026, 10, 30)), Rules.item(Rules.d(2026, 11, 24, 15)),
            Rules.item(Rules.d(2026, 11, 22)), Rules.item(Rules.d(2025, 12, 10)), Rules.item(Rules.d(2026, 11, 23, 23)),
            Rules.item(Rules.d(2026, 11, 24, 20)), Rules.item(Rules.d(2026, 11, 18)), Rules.item(Rules.d(2026, 11, 23, 15)),
        ], now: now)
        #expect(s.map(\.title) == ["Oggi · 24 nov", "Ieri · 23 nov", "Domenica 22 nov", "Mercoledì 18 nov",
                                   "Novembre", "Ottobre", "Dicembre 2025"])
        #expect(s.map { $0.items.count } == [2, 2, 1, 1, 1, 1, 1])
        // whatever the order they come in, the newest is first
        #expect(s[0].items.map(\.date) == [Rules.d(2026, 11, 24, 20), Rules.d(2026, 11, 24, 15)])
    }

    @Test func theWeekStartsSixDaysAgoAtMidnight() {
        #expect(titles([Rules.item(Rules.d(2026, 11, 18, 0, 0)), Rules.item(Rules.d(2026, 11, 17, 23, 59))], now: now)
                == ["Mercoledì 18 nov", "Novembre"])
    }

    @Test func midnightPartsOneDayFromTheNext() {
        #expect(titles([Rules.item(Rules.d(2026, 11, 24, 0, 0)), Rules.item(Rules.d(2026, 11, 23, 23, 59))], now: Rules.d(2026, 11, 24, 0, 30))
                == ["Oggi · 24 nov", "Ieri · 23 nov"])
    }

    @Test func theDaysTheClockChanges() {
        // 29 March 2026 has 23 hours in Rome and 25 October has 25: the week still starts six days back at midnight
        #expect(titles([Rules.item(Rules.d(2026, 3, 23, 0, 30)), Rules.item(Rules.d(2026, 3, 22, 23, 30)),
                        Rules.item(Rules.d(2026, 3, 29, 0, 30)), Rules.item(Rules.d(2026, 3, 29, 3, 30))], now: Rules.d(2026, 3, 29, 12))
                == ["Oggi · 29 mar", "Lunedì 23 mar", "Marzo"])
        #expect(titles([Rules.item(Rules.d(2026, 10, 19, 3, 30)), Rules.item(Rules.d(2026, 10, 18, 23, 30))], now: Rules.d(2026, 10, 25, 12))
                == ["Lunedì 19 ott", "Ottobre"])
    }

    @Test func monthAndYearEnds() {
        // December the 1st: the 26th is still in the week, the 24th isn't
        #expect(titles([Rules.item(Rules.d(2026, 12, 1, 8)), Rules.item(Rules.d(2026, 11, 30)), Rules.item(Rules.d(2026, 11, 26)),
                        Rules.item(Rules.d(2026, 11, 24))], now: Rules.d(2026, 12, 1, 9))
                == ["Oggi · 1 dic", "Ieri · 30 nov", "Giovedì 26 nov", "Novembre"])
        // a new year: December keeps its year
        #expect(titles([Rules.item(Rules.d(2026, 12, 31)), Rules.item(Rules.d(2026, 12, 20))], now: Rules.d(2027, 1, 1, 9))
                == ["Ieri · 31 dic", "Dicembre 2026"])
    }

    @Test func twoBackupsInTheSameHourStayBoth() {
        let a = Rules.item(Rules.d(2026, 11, 24, 15, 0)), b = Rules.item(Rules.d(2026, 11, 24, 15, 40))
        let s = sections([a, b], now: now)
        #expect(s.count == 1)
        #expect(s[0].items.map(\.date) == [b.date, a.date])
        #expect(s[0].items.map { BackupTimeline.hourLabel($0.date, calendar: Rules.cal, locale: Rules.it) } == ["15:40", "15:00"])
    }

    @Test func aSectionSumsWhatItKnows() {
        let a = Rules.item(Rules.d(2026, 11, 24, 20), 12), b = Rules.item(Rules.d(2026, 11, 24, 15), 38), c = Rules.item(Rules.d(2026, 11, 24, 8))
        #expect(sections([a, b, c], now: now)[0].newBytes == 50_000_000)
        #expect(sections([c], now: now)[0].newBytes == nil)
    }

    @Test func anEmptyArchiveHasNoSections() {
        #expect(sections([], now: now).isEmpty)
    }

    @Test func onlyTheRunThatWroteTheIndexCounts() {
        let made = Rules.d(2026, 11, 23, 15), id = Snapshot.id(for: made)
        let history = [
            BackupReport(snapshotID: id, date: made, duration: 3, fileCount: 10, newBytes: 210_000_000, warnings: [], error: nil),
            // two hours later nothing changed: the run names the same index, and it isn't its own
            BackupReport(snapshotID: id, date: made.addingTimeInterval(7200), duration: 1, fileCount: 10, newBytes: 0, warnings: [], error: nil),
            BackupReport(snapshotID: nil, date: made, duration: 1, fileCount: 0, newBytes: 0, warnings: ["a"], error: nil),
        ]
        let known = BackupTimeline.info(from: history)
        #expect(known.count == 1)
        #expect(known[id]?.newBytes == 210_000_000)
        #expect(known[id]?.warnings == 0)
    }

    @Test func aFailedRunCountsItsErrorsAsWarnings() {
        let made = Rules.d(2026, 11, 22, 20), id = Snapshot.id(for: made)
        let history = [BackupReport(snapshotID: id, date: made, duration: 1, fileCount: 1, newBytes: 5_000_000,
                                    warnings: ["w1", "w2"], error: "e1\ne2\ne3")]
        let known = BackupTimeline.info(from: history)
        #expect(known[id]?.newBytes == 5_000_000)
        #expect(known[id]?.warnings == 5)
    }

    @Test func theHistoryWinsOverTheIndex() {
        // «Cancella avvisi» empties the last run's warnings in the app's history: the timeline follows it, index or not
        let a = Rules.d(2026, 11, 23, 15), b = Rules.d(2026, 11, 20, 20), c = Rules.d(2026, 11, 18, 20)
        let id = Snapshot.id(for: a)
        let index = { (id: String) -> Int? in id == Snapshot.id(for: b) ? 2 : id == Snapshot.id(for: a) ? 9 : nil }
        let report = BackupReport(snapshotID: id, date: a, duration: 1, fileCount: 1, newBytes: 1_000_000, warnings: ["w"], error: nil)
        let items = BackupTimeline.items(snapshots: [a, b, c].map { (id: Snapshot.id(for: $0), date: $0) }, history: [report], indexWarnings: index)
        #expect(items.map(\.newBytes) == [1_000_000, nil, nil])
        // what the history knows stands, even where an index in memory says otherwise
        #expect(items.map(\.warnings) == [1, 2, nil])
        // and once the warnings are cleared nothing brings them back
        let cleared = BackupReport(snapshotID: id, date: a, duration: 1, fileCount: 1, newBytes: 1_000_000, warnings: [], error: nil)
        #expect(BackupTimeline.items(snapshots: [(id: id, date: a)], history: [cleared], indexWarnings: index).first?.warnings == 0)
    }

    @Test func barsAreProportionalToTheLargest() {
        let items = [Rules.item(Rules.d(2026, 11, 24, 20), 210), Rules.item(Rules.d(2026, 11, 24, 15), 105),
                     Rules.item(Rules.d(2026, 11, 24, 8), 0), TimelineItem(id: "x", date: Rules.d(2026, 11, 24, 7))]
        #expect(BackupTimeline.barWidth(items[0], in: items) == 1)
        #expect(BackupTimeline.barWidth(items[1], in: items) == 0.5)
        #expect(BackupTimeline.barWidth(items[2], in: items) == 0)
        #expect(BackupTimeline.barWidth(items[3], in: items) == nil)
        #expect(BackupTimeline.barLabel(items[0], locale: Rules.it) == "+210 MB")
        #expect(BackupTimeline.barLabel(items[2], locale: Rules.it) == "")
        #expect(BackupTimeline.barLabel(items[3], locale: Rules.it) == "")
    }

    @Test func withNothingButZerosTheBarIsEmpty() {
        let items = [Rules.item(Rules.d(2026, 11, 24, 20), 0)]
        #expect(BackupTimeline.barWidth(items[0], in: items) == 0)
    }

    @Test func theTooltipSaysEverything() {
        let date = Rules.d(2026, 11, 23, 15)
        func detail(_ item: TimelineItem) -> String { BackupTimeline.detail(item, calendar: Rules.cal, locale: Rules.it) }
        #expect(detail(Rules.item(date, 210, warnings: 1)) == "lunedì 23 novembre 2026 alle ore 15:00 · +210 MB nuovi · 1 avviso")
        #expect(detail(Rules.item(date, warnings: 3)) == "lunedì 23 novembre 2026 alle ore 15:00 · 3 avvisi")
        #expect(detail(Rules.item(date)) == "lunedì 23 novembre 2026 alle ore 15:00")
    }
}
