import Foundation

/// The RRULE subset DayDo creates and understands (stored verbatim, so
/// rules written by other clients survive even if we cannot expand them).
public struct Recurrence: Hashable, Sendable {
    public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    public var frequency: Frequency
    public var interval: Int = 1
    /// 0 = Sunday … 6 = Saturday (BYDAY).
    public var byWeekday: [Int] = []
    public var byMonthDay: Int?

    static let dayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    public init(frequency: Frequency, interval: Int = 1, byWeekday: [Int] = [], byMonthDay: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.byWeekday = byWeekday
        self.byMonthDay = byMonthDay
    }

    public init?(rrule: String) {
        var s = rrule
        if s.uppercased().hasPrefix("RRULE:") { s.removeFirst(6) }
        var freq: Frequency?
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).uppercased() }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "FREQ": freq = Frequency(rawValue: kv[1])
            case "INTERVAL": interval = max(1, Int(kv[1]) ?? 1)
            case "BYDAY": byWeekday = kv[1].split(separator: ",").compactMap { Recurrence.dayCodes.firstIndex(of: String($0.suffix(2))) }.sorted()
            case "BYMONTHDAY": byMonthDay = Int(kv[1])
            default: break
            }
        }
        guard let freq else { return nil }
        frequency = freq
    }

    public var rrule: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if !byWeekday.isEmpty { parts.append("BYDAY=" + byWeekday.map { Recurrence.dayCodes[$0] }.joined(separator: ",")) }
        if let byMonthDay { parts.append("BYMONTHDAY=\(byMonthDay)") }
        return "RRULE:" + parts.joined(separator: ";")
    }

    /// First occurrence strictly after `day`.
    public func next(after day: LocalDay) -> LocalDay {
        switch frequency {
        case .daily:
            return day.adding(days: interval)
        case .weekly:
            guard !byWeekday.isEmpty else { return day.adding(days: 7 * interval) }
            var d = day.adding(days: 1)
            for _ in 0..<(7 * interval + 7) {
                // Weeks are anchored on the Sunday of `day`'s week.
                let weeksApart = day.startOfWeek.days(until: d.startOfWeek) / 7
                if byWeekday.contains(d.weekday) && weeksApart % interval == 0 { return d }
                d = d.adding(days: 1)
            }
            return day.adding(days: 7 * interval)
        case .monthly:
            let target = byMonthDay ?? day.day
            var m = day.firstOfMonth
            for _ in 0..<48 {
                m = m.adding(months: interval)
                if target <= m.daysInMonth { return LocalDay(year: m.year, month: m.month, day: target) }
            }
            return day.adding(months: interval)
        case .yearly:
            var y = day.year
            for _ in 0..<8 {
                y += interval
                let first = LocalDay(year: y, month: day.month, day: 1)
                if day.day <= first.daysInMonth { return LocalDay(year: y, month: day.month, day: day.day) }
            }
            return day.adding(months: 12 * interval)
        }
    }

    /// Short Chinese label used by the date panel.
    public func label(anchor: LocalDay) -> String {
        let every = interval > 1 ? "每 \(interval) " : "每"
        switch frequency {
        case .daily: return interval > 1 ? "每 \(interval) 天" : "每天"
        case .weekly:
            if byWeekday == [1, 2, 3, 4, 5] && interval == 1 { return "平日" }
            let days = (byWeekday.isEmpty ? [anchor.weekday] : byWeekday).map { "週" + LocalDay.weekdaySymbols[$0] }.joined(separator: "、")
            return interval > 1 ? "每 \(interval) 週的\(days)" : "每" + days
        case .monthly: return "\(every)月 \(byMonthDay ?? anchor.day) 日"
        case .yearly: return "\(every)年 \(anchor.month) 月 \(anchor.day) 日"
        }
    }

    public static func presets(anchor: LocalDay) -> [Recurrence] {
        [
            Recurrence(frequency: .daily),
            Recurrence(frequency: .weekly, byWeekday: [1, 2, 3, 4, 5]),
            Recurrence(frequency: .weekly, byWeekday: [anchor.weekday]),
            Recurrence(frequency: .monthly, byMonthDay: anchor.day),
            Recurrence(frequency: .yearly),
        ]
    }
}
