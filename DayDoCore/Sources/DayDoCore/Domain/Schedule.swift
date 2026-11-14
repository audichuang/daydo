import Foundation

/// When a task happens, stored as wall-clock values.
///
/// - all-day:   `startMinute == nil`; `endDay` (inclusive) makes it multi-day.
/// - timed:     `startMinute` set; `endDay`/`endMinute` set for a block (may
///              end on the next day, e.g. 23:30 – 隔日 00:30), or both nil for
///              a single point in time (a deadline such as 17:00).
/// - `timeZone == nil` means floating: the wall-clock follows the device.
public struct Schedule: Codable, Hashable, Sendable {
    public var startDay: LocalDay
    public var startMinute: Int?
    public var endDay: LocalDay?
    public var endMinute: Int?
    public var timeZone: String?

    public init(startDay: LocalDay, startMinute: Int? = nil, endDay: LocalDay? = nil, endMinute: Int? = nil, timeZone: String? = nil) {
        self.startDay = startDay
        self.startMinute = startMinute
        self.endDay = endDay
        self.endMinute = endMinute
        self.timeZone = timeZone
    }

    public static func allDay(_ day: LocalDay, through end: LocalDay? = nil) -> Schedule {
        Schedule(startDay: day, endDay: (end.map { $0 > day ? $0 : nil }) ?? nil)
    }

    /// A timed block; an `end` at or before `start` wraps to the next day.
    public static func timed(_ day: LocalDay, start: Int, end: Int?, timeZone: String? = nil) -> Schedule {
        guard let end else { return Schedule(startDay: day, startMinute: start, timeZone: timeZone) }
        let endAbs = end <= start ? end + 1440 : end
        return Schedule(startDay: day, startMinute: start, endDay: day.adding(days: endAbs / 1440), endMinute: endAbs % 1440, timeZone: timeZone)
    }

    public var isAllDay: Bool { startMinute == nil }

    /// Minutes from `startDay` 00:00 to the end (may exceed 1440).
    public var endOffsetMinutes: Int? {
        guard let endDay, let endMinute else { return nil }
        return startDay.days(until: endDay) * 1440 + endMinute
    }

    public var durationMinutes: Int? {
        guard let s = startMinute, let e = endOffsetMinutes else { return nil }
        return e - s
    }

    public var crossesMidnight: Bool { !isAllDay && (endOffsetMinutes ?? 0) > 1440 }

    /// Last day the task occupies. A block ending exactly at 00:00 does not
    /// spill into that day.
    public var lastDay: LocalDay {
        guard let endDay else { return startDay }
        if isAllDay { return max(endDay, startDay) }
        if endMinute == 0 && endDay > startDay { return endDay.adding(days: -1) }
        return max(endDay, startDay)
    }

    public var isMultiDay: Bool { lastDay > startDay }

    public func occurs(on day: LocalDay) -> Bool { day >= startDay && day <= lastDay }

    public func overlaps(_ from: LocalDay, _ to: LocalDay) -> Bool { startDay <= to && lastDay >= from }

    /// (index, total) for multi-day items, 1-based: 第 3/4 天.
    public func dayPosition(on day: LocalDay) -> (Int, Int)? {
        guard isMultiDay, occurs(on: day) else { return nil }
        return (startDay.days(until: day) + 1, startDay.days(until: lastDay) + 1)
    }

    public var startInstant: Date? {
        guard let startMinute else { return nil }
        return startDay.date(minute: startMinute, in: zone)
    }

    public var zone: TimeZone { timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// Re-expresses a zoned timed schedule in `target`'s wall clock. Floating
    /// and all-day schedules are returned unchanged.
    public func localized(to target: TimeZone) -> Schedule {
        guard let tzId = timeZone, let tz = TimeZone(identifier: tzId), tz.identifier != target.identifier,
              let s = startMinute else { return self }
        let startDate = startDay.date(minute: s, in: tz)
        var out = Schedule(startDay: LocalDay(date: startDate, in: target), startMinute: minuteOfDay(startDate, target), timeZone: target.identifier)
        if let endDay, let endMinute {
            let endDate = endDay.date(minute: endMinute, in: tz)
            out.endDay = LocalDay(date: endDate, in: target)
            out.endMinute = minuteOfDay(endDate, target)
        }
        return out
    }

    /// Moves the schedule to a new start day keeping its shape.
    public func moved(to day: LocalDay) -> Schedule {
        let delta = startDay.days(until: day)
        var out = self
        out.startDay = day
        out.endDay = endDay?.adding(days: delta)
        return out
    }
}

func minuteOfDay(_ date: Date, _ tz: TimeZone) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.hour, .minute], from: date)
    return c.hour! * 60 + c.minute!
}

// MARK: - ISO 8601 bridge (API / MCP surface)

public enum ScheduleError: Error, Equatable, LocalizedError {
    case invalidDateTime(String)
    case endBeforeStart
    case unknownTimeZone(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDateTime(let s): return "Invalid ISO 8601 date/time: \(s)"
        case .endBeforeStart: return "due must not be before start"
        case .unknownTimeZone(let s): return "Unknown IANA time zone: \(s)"
        }
    }
}

extension Schedule {
    struct ParsedTime {
        var day: LocalDay
        var minute: Int?
        var offsetSeconds: Int?
    }

    /// Accepts `2026-11-15`, `2026-11-15T18:00`, `2026-11-15T18:00:00`,
    /// optionally followed by `Z`, `+08:00` or `+0800`.
    static func parse(_ raw: String) throws -> ParsedTime {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let day = LocalDay(s) else { throw ScheduleError.invalidDateTime(raw) }
        if s.count == 10 { return ParsedTime(day: day, minute: nil, offsetSeconds: nil) }
        let rest = Array(s.dropFirst(10))
        guard rest.first == "T" || rest.first == " " else { throw ScheduleError.invalidDateTime(raw) }
        var body = String(rest.dropFirst())
        var offset: Int?
        if body.hasSuffix("Z") {
            offset = 0
            body.removeLast()
        } else if let idx = body.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let tz = body[idx...]
            body = String(body[..<idx])
            let sign = tz.first == "-" ? -1 : 1
            let digits = tz.dropFirst().replacingOccurrences(of: ":", with: "")
            guard digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)) else {
                throw ScheduleError.invalidDateTime(raw)
            }
            offset = sign * (hh * 3600 + mm * 60)
        }
        let hms = body.split(separator: ":")
        guard hms.count >= 2, let h = Int(hms[0]), let m = Int(hms[1]), (0...23).contains(h), (0...59).contains(m) else {
            throw ScheduleError.invalidDateTime(raw)
        }
        return ParsedTime(day: day, minute: h * 60 + m, offsetSeconds: offset)
    }

    /// Builds a schedule from the TickTick-style fields used by the API.
    /// - `start`/`due` without an offset are wall-clock in `timeZone`
    ///   (floating when `timeZone` is nil).
    /// - With an offset they are converted into `timeZone`; when no zone is
    ///   given, a matching zone is inferred from the offset (Asia/Taipei for
    ///   +08:00 etc.).
    /// - All-day: dates only, `due` is the inclusive last day.
    public static func fromAPI(start: String?, due: String?, allDay: Bool?, timeZone: String?) throws -> Schedule? {
        guard start != nil || due != nil else { return nil }
        if let timeZone, TimeZone(identifier: timeZone) == nil { throw ScheduleError.unknownTimeZone(timeZone) }
        let ps = try start.map(parse)
        let pd = try due.map(parse)
        let first = ps ?? pd!
        let isAllDay = allDay ?? (first.minute == nil)
        if isAllDay {
            let s = first.day
            let e = (ps != nil ? pd?.day : nil) ?? s
            guard e >= s else { throw ScheduleError.endBeforeStart }
            return .allDay(s, through: e)
        }
        let zoneId = timeZone ?? first.offsetSeconds.flatMap(inferZone)
        let zone = zoneId.flatMap(TimeZone.init(identifier:))
        func wall(_ p: ParsedTime) -> (LocalDay, Int) {
            let minute = p.minute ?? 0
            guard let off = p.offsetSeconds, let zone else { return (p.day, minute) }
            let utc = p.day.date(minute: minute, in: TimeZone(identifier: "UTC")!).addingTimeInterval(TimeInterval(-off))
            return (LocalDay(date: utc, in: zone), minuteOfDay(utc, zone))
        }
        let (sd, sm) = wall(first)
        var sched = Schedule(startDay: sd, startMinute: sm, timeZone: zoneId)
        if let pd, ps != nil {
            let (ed, em) = wall(pd)
            let offset = sd.days(until: ed) * 1440 + em
            guard offset >= sm else { throw ScheduleError.endBeforeStart }
            if offset > sm {
                sched.endDay = ed
                sched.endMinute = em
            }
        }
        return sched
    }

    static func inferZone(_ offset: Int) -> String? {
        let known = ["Asia/Taipei", "Asia/Tokyo", "Europe/London", "America/New_York", "America/Los_Angeles", "Europe/Paris", "Australia/Sydney", "Asia/Singapore"]
        let now = Date()
        if TimeZone.current.secondsFromGMT(for: now) == offset { return TimeZone.current.identifier }
        return known.first { TimeZone(identifier: $0)?.secondsFromGMT(for: now) == offset } ?? "UTC"
    }

    /// TickTick-style rendering: dates for all-day, otherwise ISO with offset
    /// (floating schedules are rendered in the device zone).
    public var apiStart: String {
        if isAllDay { return startDay.description }
        return Schedule.iso(startDay, startMinute!, zone)
    }

    public var apiDue: String? {
        if isAllDay { return endDay.map(\.description) }
        guard let endDay, let endMinute else { return nil }
        return Schedule.iso(endDay, endMinute, zone)
    }

    static func iso(_ day: LocalDay, _ minute: Int, _ tz: TimeZone) -> String {
        let date = day.date(minute: minute, in: tz)
        let f = ISO8601DateFormatter()
        f.timeZone = tz
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
