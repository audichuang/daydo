import Foundation
import GRDB

/// Hybrid logical clock timestamp used to order outbox operations and resolve
/// field-level LWW conflicts during sync.
///
/// Format: `<13-digit zero-padded epoch ms>:<4-digit zero-padded counter>:<lowercase deviceId>`.
/// Fixed width up to year 2286 so lexicographical string comparison matches causal order.
public struct HLC: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let deviceIdMetaKey = "deviceId"
    public static let hlcMetaKey = "hlc"

    public let ms: EpochMillis
    public let counter: Int
    public let deviceId: String

    public init(ms: EpochMillis, counter: Int, deviceId: String) {
        var adjustedMs = max(0, ms)
        var adjustedCounter = max(0, counter)
        if adjustedCounter > 9999 {
            adjustedMs += EpochMillis(adjustedCounter / 10000)
            adjustedCounter %= 10000
        }
        self.ms = adjustedMs
        self.counter = adjustedCounter
        self.deviceId = deviceId.lowercased()
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 13, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].count == 4, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              !parts[2].isEmpty,
              let ms = EpochMillis(parts[0]),
              let counter = Int(parts[1]),
              (0...9999).contains(counter)
        else { return nil }
        self.ms = ms
        self.counter = counter
        self.deviceId = String(parts[2]).lowercased()
    }

    public var description: String {
        String(format: "%013lld:%04d:%@", ms, counter, deviceId)
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        lhs.description < rhs.description
    }

    /// Generates the next local HLC from wall-clock `now` and optional `last` HLC.
    public static func next(now: EpochMillis, last: HLC?, deviceId: String) -> HLC {
        let wall = max(0, now)
        let dev = deviceId.lowercased()
        guard let last else {
            return HLC(ms: wall, counter: 0, deviceId: dev)
        }
        if wall > last.ms {
            return HLC(ms: wall, counter: 0, deviceId: dev)
        }
        return HLC(ms: last.ms, counter: last.counter + 1, deviceId: dev)
    }

    /// Advances the local clock past a newer `remote` HLC while respecting wall-clock `now`.
    public static func receive(remote: HLC, now: EpochMillis, last: HLC?, deviceId: String) -> HLC {
        let wall = max(0, now)
        let dev = deviceId.lowercased()
        if let last, remote <= last {
            if wall > last.ms {
                return HLC(ms: wall, counter: 0, deviceId: dev)
            }
            return last
        }
        if wall > remote.ms {
            return HLC(ms: wall, counter: 0, deviceId: dev)
        }
        return HLC(ms: remote.ms, counter: remote.counter + 1, deviceId: dev)
    }

    // MARK: - SQLite meta state

    /// Returns the persisted `deviceId` in `meta`, creating one if absent.
    static func ensureDeviceId(in db: Database) throws -> String {
        if let existing = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [deviceIdMetaKey]) {
            return existing.lowercased()
        }
        let id = ID.make().lowercased()
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?)", arguments: [deviceIdMetaKey, id])
        return id
    }

    static func loadLast(in db: Database) throws -> HLC? {
        guard let raw = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [hlcMetaKey]) else {
            return nil
        }
        return HLC(raw)
    }

    static func saveLast(_ hlc: HLC, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [hlcMetaKey, hlc.description]
        )
    }

    /// Generates the next HLC for a local write and persists it (plus `deviceId` if absent)
    /// into `meta` in the current transaction.
    static func tick(in db: Database, now: EpochMillis) throws -> HLC {
        let deviceId = try ensureDeviceId(in: db)
        let last = try loadLast(in: db)
        let next = Self.next(now: now, last: last, deviceId: deviceId)
        try saveLast(next, in: db)
        return next
    }

    /// Advances the persisted HLC past a newer `remote` HLC in the current transaction.
    @discardableResult
    static func receive(_ remote: HLC, in db: Database, now: EpochMillis) throws -> HLC {
        let deviceId = try ensureDeviceId(in: db)
        let last = try loadLast(in: db)
        let updated = Self.receive(remote: remote, now: now, last: last, deviceId: deviceId)
        if updated != last {
            try saveLast(updated, in: db)
        }
        return updated
    }
}
