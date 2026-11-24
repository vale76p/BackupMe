import BackupCore
import Foundation

/// One backup as the timeline lists it.
public struct TimelineItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    /// From this Mac's history, or from the index once read; nil when neither knows.
    public var newBytes: Int64?
    public var warnings: Int?

    public init(id: String, date: Date, newBytes: Int64? = nil, warnings: Int? = nil) {
        self.id = id; self.date = date; self.newBytes = newBytes; self.warnings = warnings
    }
}

/// A day of the last week, or a month.
public struct TimelineSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Newest first.
    public var items: [TimelineItem]

    /// The new bytes of the backups whose data is known; nil when none is.
    public var newBytes: Int64? {
        let known = items.compactMap(\.newBytes)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    init(id: String, title: String, items: [TimelineItem]) { self.id = id; self.title = title; self.items = items }
}

extension Date {
    /// The ways the rules write a date: "22 nov", "30 ott 2025", "domenica", "9 novembre", "10 dicembre 2025", "lunedì 23 novembre 2026", "novembre".
    enum RuleStyle { case day, dayMonth, dayMonthYear, weekday, dayMonthLong, dayMonthLongYear, weekdayDayMonthLongYear, month }

    /// In a calendar and a locale given once: the rules must read the same on every Mac, and in the tests.
    func rule(_ style: RuleStyle, calendar: Calendar, locale: Locale) -> String {
        let s = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return switch style {
        case .day: formatted(s.day())
        case .dayMonth: formatted(s.day().month(.abbreviated))
        case .dayMonthYear: formatted(s.day().month(.abbreviated).year())
        case .weekday: formatted(s.weekday(.wide))
        case .dayMonthLong: formatted(s.day().month(.wide))
        case .dayMonthLongYear: formatted(s.day().month(.wide).year())
        case .weekdayDayMonthLongYear: formatted(s.weekday(.wide).day().month(.wide).year())
        case .month: formatted(s.month(.wide))
        }
    }
}

extension String {
    /// "Domenica" from "domenica": the first letter only, so a day number stays as it is.
    var firstUp: String { prefix(1).uppercased() + String(dropFirst()) }
}

extension Calendar {
    /// The first of the seven days the timeline lists one by one: six days before today, at midnight.
    func timelineWeekStart(now: Date) -> Date { date(byAdding: .day, value: -6, to: startOfDay(for: now)) ?? now }

    /// Whether `date` falls on the day before `now`.
    func isYesterday(_ date: Date, now: Date) -> Bool {
        self.date(byAdding: .day, value: -1, to: now).map { isDate(date, inSameDayAs: $0) } ?? false
    }

    /// Whether `date` falls in another year than `now`.
    func isAnotherYear(_ date: Date, now: Date) -> Bool { component(.year, from: date) != component(.year, from: now) }
}

extension Date {
    /// "Oggi" or "Ieri" when the day is one of those two; nil for every other day.
    func todayOrYesterday(now: Date, calendar: Calendar) -> String? {
        if calendar.isDate(self, inSameDayAs: now) { return "Oggi" }
        if calendar.isYesterday(self, now: now) { return "Ieri" }
        return nil
    }
}

public enum BackupTimeline {
    /// New bytes and warnings of the backups the app's history holds (its last 50 runs); a run with no changes reused an older backup, so only the run that wrote an index counts.
    /// For warnings the history is the record even once its index is in memory: «Cancella avvisi» empties it for the last backup, and the timeline follows.
    public static func info(from history: [BackupReport]) -> [String: (newBytes: Int64, warnings: Int)] {
        var known: [String: (newBytes: Int64, warnings: Int)] = [:]
        for r in history {
            guard let id = r.snapshotID, let made = Snapshot.date(fromID: id), abs(made.timeIntervalSince(r.date)) < 2 else { continue }
            // a partial backup (a folder unreadable, no room for some files) is marked too
            known[id] = (r.newBytes, Restorer.boundedCount(r.warnings) + Restorer.boundedCount(r.error?.split(separator: "\n").map(String.init) ?? []))
        }
        return known
    }

    /// Every backup with what is known about it; `indexWarnings` answers only for a backup the history says nothing about.
    public static func items(snapshots: [(id: String, date: Date)], history: [BackupReport],
                             indexWarnings: (String) -> Int?) -> [TimelineItem] {
        let known = info(from: history)
        return snapshots.map {
            TimelineItem(id: $0.id, date: $0.date, newBytes: known[$0.id]?.newBytes,
                         warnings: known[$0.id]?.warnings ?? indexWarnings($0.id))
        }
    }

    /// One section per day of the last week (today included), then one per month. Newest first.
    public static func sections(_ items: [TimelineItem], now: Date = Date(), calendar: Calendar = .current,
                                locale: Locale = Locale(identifier: "it_IT")) -> [TimelineSection] {
        let weekStart = calendar.timelineWeekStart(now: now)
        var result: [TimelineSection] = []
        for item in items.sorted(by: { $0.date > $1.date }) {
            let key: String, title: String
            if item.date >= weekStart {
                key = "d" + String(calendar.startOfDay(for: item.date).timeIntervalSinceReferenceDate)
                title = dayTitle(item.date, now: now, calendar: calendar, locale: locale)
            } else {
                key = "m\(calendar.component(.year, from: item.date))-\(calendar.component(.month, from: item.date))"
                title = monthTitle(item.date, now: now, calendar: calendar, locale: locale)
            }
            if let last = result.indices.last, result[last].id == key { result[last].items.append(item) }
            else { result.append(TimelineSection(id: key, title: title, items: [item])) }
        }
        return result
    }

    /// "Oggi · 24 nov", "Ieri · 23 nov", "Domenica 22 nov".
    public static func dayTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let day = date.rule(.dayMonth, calendar: calendar, locale: locale)
        if let named = date.todayOrYesterday(now: now, calendar: calendar) { return named + " · " + day }
        return date.rule(.weekday, calendar: calendar, locale: locale).firstUp + " " + day
    }

    /// "Novembre", with the year when it isn't the current one: "Dicembre 2025".
    public static func monthTitle(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let month = date.rule(.month, calendar: calendar, locale: locale).firstUp
        return calendar.isAnotherYear(date, now: now) ? month + " " + String(calendar.component(.year, from: date)) : month
    }

    /// Width of an item's bar, 0...1, against the largest of `items`; nil when its data is unknown.
    public static func barWidth(_ item: TimelineItem, in items: [TimelineItem]) -> Double? {
        guard let bytes = item.newBytes else { return nil }
        let largest = items.compactMap(\.newBytes).max() ?? 0
        return largest > 0 ? Double(bytes) / Double(largest) : 0
    }

    /// "15:00"
    public static func hourLabel(_ date: Date, calendar: Calendar = .current,
                                 locale: Locale = Locale(identifier: "it_IT")) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                        timeZone: calendar.timeZone))
    }

    public static func bytesText(_ bytes: Int64, locale: Locale = Locale(identifier: "it_IT")) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    public static func warningsText(_ warnings: Int) -> String { warnings == 1 ? "1 avviso" : "\(warnings) avvisi" }

    /// "+210 MB" under a bar; "" with nothing saved or nothing known.
    public static func barLabel(_ item: TimelineItem, locale: Locale = Locale(identifier: "it_IT")) -> String {
        guard let bytes = item.newBytes, bytes > 0 else { return "" }
        return "+" + bytesText(bytes, locale: locale)
    }

    /// What the tooltip and VoiceOver read: "lunedì 23 novembre 2026 alle ore 15:00 · +210 MB nuovi · 1 avviso".
    public static func detail(_ item: TimelineItem, calendar: Calendar = .current,
                              locale: Locale = Locale(identifier: "it_IT")) -> String {
        var text = item.date.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar,
                                                        timeZone: calendar.timeZone))
        if let bytes = item.newBytes, bytes > 0 { text += " · +" + bytesText(bytes, locale: locale) + " nuovi" }
        if let warnings = item.warnings, warnings > 0 { text += " · " + warningsText(warnings) }
        return text
    }
}
