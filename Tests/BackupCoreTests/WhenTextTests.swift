import Foundation
import Testing
@testable import BackupCore
@testable import RestoreRules

@Suite struct WhenTextTests {
    /// A Tuesday afternoon.
    var now: Date { Rules.d(2026, 11, 24, 20, 15) }

    func title(_ date: Date) -> String { WhenText.title(date, now: now, calendar: Rules.cal, locale: Rules.it) }
    func from(_ date: Date) -> String { WhenText.from(date, now: now, calendar: Rules.cal, locale: Rules.it) }
    func subtitle(_ item: TimelineItem) -> String { WhenText.subtitle(item, calendar: Rules.cal, locale: Rules.it) }
    func version(_ date: Date) -> String { WhenText.version(date, now: now, calendar: Rules.cal, locale: Rules.it) }

    @Test func todayYesterdayTheWeekThenTheMonths() {
        #expect(title(Rules.d(2026, 11, 24, 14)) == "Oggi alle 14:00")
        #expect(title(Rules.d(2026, 11, 23, 23, 15)) == "Ieri alle 23:15")
        #expect(title(Rules.d(2026, 11, 22)) == "Domenica 22 alle 20:00")
        #expect(title(Rules.d(2026, 11, 18)) == "Mercoledì 18 alle 20:00")
        #expect(title(Rules.d(2026, 11, 9)) == "9 novembre alle 20:00")
        #expect(title(Rules.d(2025, 12, 10)) == "10 dicembre 2025 alle 20:00")
    }

    @Test func theBarSaysTheSameInLowerCase() {
        #expect(from(Rules.d(2026, 11, 24, 14)) == "dal backup di oggi alle 14:00")
        #expect(from(Rules.d(2026, 11, 23, 15)) == "dal backup di ieri alle 15:00")
        #expect(from(Rules.d(2026, 11, 22)) == "dal backup di domenica 22 alle 20:00")
        #expect(from(Rules.d(2026, 11, 9)) == "dal backup di 9 novembre alle 20:00")
    }

    @Test func theThirdLineTellsTheDataOfTheBackup() {
        let date = Rules.d(2026, 11, 23, 15)
        #expect(subtitle(Rules.item(date, 210, warnings: 1)) == "lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso")
        #expect(subtitle(Rules.item(date, 210)) == "lunedì 23 novembre 2026 · +210 MB salvati")
        #expect(subtitle(Rules.item(date)) == "lunedì 23 novembre 2026")
        #expect(subtitle(Rules.item(date, 0)) == "lunedì 23 novembre 2026")
    }

    @Test func aVersionIsNamedByItsDay() {
        #expect(version(Rules.d(2026, 11, 24, 19)) == "versione di oggi, 19:00")
        #expect(version(Rules.d(2026, 11, 23, 19)) == "versione di ieri, 19:00")
        #expect(version(Rules.d(2026, 10, 30)) == "versione del 30 ott, 20:00")
        #expect(version(Rules.d(2025, 12, 10)) == "versione del 10 dic 2025, 20:00")
    }
}
