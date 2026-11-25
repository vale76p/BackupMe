import Foundation

/// The words that say when: the title above the list, and the line of the bar.
public enum WhenText {
    /// "Ieri alle 15:00", "Domenica 22 alle 20:00", "9 novembre alle 20:00".
    public static func title(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = Locale(identifier: "it_IT")) -> String {
        let time = BackupTimeline.hourLabel(date, calendar: calendar, locale: locale)
        if let named = date.todayOrYesterday(now: now, calendar: calendar) { return named + " alle " + time }
        // the days of the last week keep the weekday of the timeline; older ones read better with the month in full
        let day = date >= calendar.timelineWeekStart(now: now)
            ? date.rule(.weekday, calendar: calendar, locale: locale).firstUp + " " + date.rule(.day, calendar: calendar, locale: locale)
            : date.rule(calendar.isAnotherYear(date, now: now) ? .dayMonthLongYear : .dayMonthLong, calendar: calendar, locale: locale)
        return day + " alle " + time
    }

    /// "dal backup di ieri alle 15:00", "dal backup del 9 novembre alle 20:00": the same words, lower case, for the line of the bar.
    public static func from(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                            locale: Locale = Locale(identifier: "it_IT")) -> String {
        let text = title(date, now: now, calendar: calendar, locale: locale)
        // a day written as a date takes the article, as «versione del 30 ott» does; a day with its name does not
        let article = text.first?.isNumber == true ? "del" : "di"
        return "dal backup " + article + " " + text.prefix(1).lowercased() + String(text.dropFirst())
    }

    /// "lunedì 23 novembre 2026 · +210 MB salvati · 1 avviso": the third line of the title.
    public static func subtitle(_ item: TimelineItem, calendar: Calendar = .current,
                                locale: Locale = Locale(identifier: "it_IT")) -> String {
        var text = item.date.rule(.weekdayDayMonthLongYear, calendar: calendar, locale: locale)
        if let bytes = item.newBytes, bytes > 0 { text += " · +" + BackupTimeline.bytesText(bytes, locale: locale) + " salvati" }
        if let warnings = item.warnings, warnings > 0 { text += " · " + BackupTimeline.warningsText(warnings) }
        return text
    }

    /// "versione del 30 ott, 20:00", "versione di oggi, 20:00".
    public static func version(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                               locale: Locale = Locale(identifier: "it_IT")) -> String {
        let time = BackupTimeline.hourLabel(date, calendar: calendar, locale: locale)
        if let named = date.todayOrYesterday(now: now, calendar: calendar) { return "versione di " + named.lowercased() + ", " + time }
        return "versione del " + date.rule(calendar.isAnotherYear(date, now: now) ? .dayMonthYear : .dayMonth, calendar: calendar, locale: locale) + ", " + time
    }
}
