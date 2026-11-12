import Foundation
import Testing
@testable import BackupCore

@Suite struct DeletionLedgerTests {
    @Test func allowanceCountsTheLastHour() {
        var l = DeletionLedger()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        l.record(30, at: t); l.record(15, at: t.addingTimeInterval(900))
        #expect(l.allowance(limit: 50, now: t.addingTimeInterval(1800)) == 5)
        #expect(l.allowance(limit: 50, now: t.addingTimeInterval(3601)) == 35)
        #expect(l.allowance(limit: 50, now: t.addingTimeInterval(4600)) == 50)
        #expect(l.allowance(limit: 10, now: t.addingTimeInterval(60)) == 0)
    }

    @Test func clockSetBackDoesNotResetTheCount() {
        var l = DeletionLedger()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        l.record(50, at: t)
        #expect(l.allowance(limit: 50, now: t.addingTimeInterval(-7200)) == 0)
    }

    @Test func survivesEncoding() throws {
        var l = DeletionLedger()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        l.record(7, at: t); l.record(3, at: t.addingTimeInterval(120))
        let back = try JSONDecoder().decode(DeletionLedger.self, from: JSONEncoder().encode(l))
        #expect(back == l)
    }
}
