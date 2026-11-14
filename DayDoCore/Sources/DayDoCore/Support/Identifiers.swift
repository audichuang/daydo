import Foundation

/// Client-generated identifiers. UUIDv7 keeps ids globally unique (so offline
/// clients never collide when they later sync) and roughly time-ordered.
public enum ID {
    public static func make(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        var rng = SystemRandomNumberGenerator()
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70 // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let p = Array(hex)
        return String(p[0..<8]) + "-" + String(p[8..<12]) + "-" + String(p[12..<16]) + "-" + String(p[16..<20]) + "-" + String(p[20..<32])
    }
}

/// Milliseconds since the Unix epoch; every row stores timestamps this way so
/// they map 1:1 onto D1 INTEGER columns later.
public typealias EpochMillis = Int64

public extension Date {
    var epochMillis: EpochMillis { EpochMillis((timeIntervalSince1970 * 1000).rounded()) }
    init(epochMillis: EpochMillis) { self.init(timeIntervalSince1970: Double(epochMillis) / 1000) }
}

/// Injectable clock so tests can pin "today".
public struct Clock: Sendable {
    public var now: @Sendable () -> Date
    public var timeZone: @Sendable () -> TimeZone
    public init(now: @escaping @Sendable () -> Date, timeZone: @escaping @Sendable () -> TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }
    public static let system = Clock(now: { Date() }, timeZone: { TimeZone.current })
    public static func fixed(_ date: Date, timeZone: TimeZone) -> Clock {
        Clock(now: { date }, timeZone: { timeZone })
    }
    public var today: LocalDay { LocalDay(date: now(), in: timeZone()) }
}
