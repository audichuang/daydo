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

    /// Midnight UTC of this day; only used for day arithmetic.
    var utcDate: Date {
        LocalDay.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> LocalDay {
        LocalDay(date: LocalDay.calendar.date(byAdding: .day, value: days, to: utcDate)!, in: TimeZone(identifier: "UTC")!)
    }

    public func adding(months: Int) -> LocalDay {
        LocalDay(date: LocalDay.calendar.date(byAdding: .month, value: months, to: utcDate)!, in: TimeZone(identifier: "UTC")!)
    }

    public func days(until other: LocalDay) -> Int {
        LocalDay.calendar.dateComponents([.day], from: utcDate, to: other.utcDate).day!
    }

    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int { LocalDay.calendar.component(.weekday, from: utcDate) - 1 }

    public var firstOfMonth: LocalDay { LocalDay(year: year, month: month, day: 1) }

    public var daysInMonth: Int {
        LocalDay.calendar.range(of: .day, in: .month, for: utcDate)!.count
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
