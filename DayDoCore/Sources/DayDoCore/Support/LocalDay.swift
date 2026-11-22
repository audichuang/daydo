import Foundation

/// A calendar day without a time zone ("2026-11-15"). Task schedules are
/// stored as wall-clock values (day + minute of day) so that all-day and
/// floating-time tasks keep their meaning when the device changes zone.
public struct LocalDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ string: String) {
        let parts = string.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public init(date: Date, in timeZone: TimeZone) {
        var cal = LocalDay.calendar
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = LocalDay(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid day \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }()

    /// Proleptic Gregorian matches Foundation's `Calendar(identifier: .gregorian)`
    /// for all dates after the 1582 Julian-to-Gregorian cutover; guard at 1600.
    private static let fastPathMinYear = 1600
    private static let fastPathMinEpochDay = -135_140 // 1600-01-01

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    private var epochDay: Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func fromEpochDay(_ z: Int) -> LocalDay {
        let shifted = z + 719468
        let era = (shifted >= 0 ? shifted : shifted - 146096) / 146097
        let doe = shifted - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return LocalDay(year: y + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    /// Midnight UTC of this day; used for month arithmetic and pre-1600 fallback.
    var utcDate: Date {
        LocalDay.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> LocalDay {
        if days == 0 { return self }
        if year >= Self.fastPathMinYear {
            let (target, overflow) = epochDay.addingReportingOverflow(days)
            if !overflow && target >= Self.fastPathMinEpochDay {
                return LocalDay.fromEpochDay(target)
            }
        }
        return LocalDay(date: LocalDay.calendar.date(byAdding: .day, value: days, to: utcDate)!, in: TimeZone(identifier: "UTC")!)
    }

    public func adding(months: Int) -> LocalDay {
        LocalDay(date: LocalDay.calendar.date(byAdding: .month, value: months, to: utcDate)!, in: TimeZone(identifier: "UTC")!)
    }

    public func days(until other: LocalDay) -> Int {
        if year >= Self.fastPathMinYear && other.year >= Self.fastPathMinYear {
            return other.epochDay - epochDay
        }
        return LocalDay.calendar.dateComponents([.day], from: utcDate, to: other.utcDate).day!
    }

    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int {
        if year >= Self.fastPathMinYear {
            let r = (epochDay + 4) % 7
            return r >= 0 ? r : r + 7
        }
        return LocalDay.calendar.component(.weekday, from: utcDate) - 1
    }

    /// Sunday starting this day's week.
    public var startOfWeek: LocalDay { adding(days: -self.weekday) }

    public var firstOfMonth: LocalDay { LocalDay(year: year, month: month, day: 1) }

    public var daysInMonth: Int {
        if year >= Self.fastPathMinYear {
            switch month {
            case 1, 3, 5, 7, 8, 10, 12: return 31
            case 4, 6, 9, 11: return 30
            case 2:
                let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
                return isLeap ? 29 : 28
            default: break
            }
        }
        return LocalDay.calendar.range(of: .day, in: .month, for: utcDate)!.count
    }

    /// Absolute instant of `minute` on this day in `timeZone`.
    public func date(minute: Int, in timeZone: TimeZone) -> Date {
        var cal = LocalDay.calendar
        cal.timeZone = timeZone
        let dayOffset = minute >= 0 ? minute / 1440 : (minute - 1439) / 1440
        let m = minute - dayOffset * 1440
        let d = dayOffset == 0 ? self : adding(days: dayOffset)
        return cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: m / 60, minute: m % 60))!
    }

    public static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
}
