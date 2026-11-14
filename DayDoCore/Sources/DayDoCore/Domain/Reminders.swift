import Foundation

/// Reminders use TickTick's trigger strings so the API/MCP layer can pass them
/// through unchanged: `TRIGGER:-PT15M` (15 min before), `TRIGGER:PT0S` (on
/// time), `TRIGGER:-P1D`, and for all-day tasks `TRIGGER:P0DT9H0M0S` (09:00).
public struct Reminder: Hashable, Sendable {
    /// Seconds relative to the anchor (start time, or 00:00 for all-day).
    public let offsetSeconds: Int

    public init(offsetSeconds: Int) { self.offsetSeconds = offsetSeconds }

    public init?(trigger: String) {
        var s = trigger.uppercased()
        if s.hasPrefix("TRIGGER:") { s.removeFirst(8) }
        var sign = 1
        if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        guard s.hasPrefix("P") else { return nil }
        s.removeFirst()
        var total = 0
        var number = ""
        var inTime = false
        for ch in s {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { number.append(ch); continue }
            guard let n = Int(number) else { return nil }
            number = ""
            switch (ch, inTime) {
            case ("W", false): total += n * 7 * 86400
            case ("D", false): total += n * 86400
            case ("H", true): total += n * 3600
            case ("M", true): total += n * 60
            case ("S", true): total += n
            default: return nil
            }
        }
        guard number.isEmpty else { return nil }
        offsetSeconds = sign * total
    }

    public var trigger: String {
        if offsetSeconds == 0 { return "TRIGGER:PT0S" }
        let sign = offsetSeconds < 0 ? "-" : ""
        var r = abs(offsetSeconds)
        let d = r / 86400; r %= 86400
        let h = r / 3600; r %= 3600
        let m = r / 60; let sec = r % 60
        var out = "TRIGGER:\(sign)P"
        if d > 0 { out += "\(d)D" }
        if h > 0 || m > 0 || sec > 0 {
            out += "T"
            if h > 0 { out += "\(h)H" }
            if m > 0 { out += "\(m)M" }
            if sec > 0 { out += "\(sec)S" }
        }
        return out
    }

    public func label(allDay: Bool) -> String {
        if allDay && offsetSeconds >= 0 {
            let m = offsetSeconds / 60
            return String(format: "當天 %02d:%02d", m / 60, m % 60)
        }
        if allDay && offsetSeconds < 0 {
            // e.g. -P0DT15H = 前一天 09:00
            let daysBefore = Int((Double(-offsetSeconds) / 86400).rounded(.up))
            let m = (daysBefore * 86400 + offsetSeconds) / 60
            return String(format: "提前 %d 天 %02d:%02d", daysBefore, m / 60, m % 60)
        }
        let before = -offsetSeconds
        if before == 0 { return "準時" }
        if before < 0 { return "延後 \(-before / 60) 分鐘" }
        if before % 86400 == 0 { return "提前 \(before / 86400) 天" }
        if before % 3600 == 0 { return "提前 \(before / 3600) 小時" }
        return "提前 \(before / 60) 分鐘"
    }

    public func fireDate(for schedule: Schedule) -> Date {
        let anchor = schedule.startDay.date(minute: schedule.startMinute ?? 0, in: schedule.zone)
        return anchor.addingTimeInterval(TimeInterval(offsetSeconds))
    }

    /// Presets shown in the date panel (4b).
    public static let timedPresets: [Reminder] = [0, -300, -900, -1800, -3600, -86400].map(Reminder.init(offsetSeconds:))
    public static let allDayPresets: [Reminder] = [9 * 3600, -15 * 3600, -2 * 86400 + 9 * 3600, -7 * 86400 + 9 * 3600].map(Reminder.init(offsetSeconds:))
}
