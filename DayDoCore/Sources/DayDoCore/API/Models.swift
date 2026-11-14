import Foundation

// Public data-transfer types. These are the shapes the app UI consumes and
// the shapes `spec/openapi.yaml` describes (JSON uses snake_case, see
// `DayDoJSON`). The Cloudflare Worker in phase 2 returns the same JSON, so
// an MCP server can sit on either side unchanged.

public struct Member: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var initial: String
    public var color: String
    public var isMe: Bool
}

public struct Folder: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sortKey: String
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var color: String?
    public var icon: String?
    public var folderId: String?
    public var viewMode: String
    public var kind: String
    public var isInbox: Bool
    public var ownerId: String
    public var sortKey: String
    public var showInSmart: String
    public var notifyMode: String
    public var archived: Bool
    public var memberIds: [String]
    public var activeCount: Int
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis

    public var isShared: Bool { memberIds.count > 1 }
}

public struct ChecklistItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// 0 open, 1 done.
    public var status: Int
    public var sortKey: String
    public var isDone: Bool { status != 0 }
}

public struct Attachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fileName: String
    public var size: Int64
    public var mimeType: String
    public var localPath: String?
    public var originalPath: String?
    public var createdAt: EpochMillis
}

public struct Tag: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var label: String
    public var color: String?
    public var activeCount: Int
    public var id: String { name }
}

public struct Comment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var authorId: String
    public var body: String
    public var createdAt: EpochMillis
}

public enum Priority: Int, Codable, Sendable, CaseIterable, Comparable {
    case none = 0, low = 1, medium = 3, high = 5

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

    /// Accepts 0/1/3/5 or "none"/"low"/"medium"/"high".
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self), let p = Priority(rawValue: n) { self = p; return }
        let s = try c.decode(String.self).lowercased()
        switch s {
        case "none", "0": self = .none
        case "low", "1": self = .low
        case "medium", "3": self = .medium
        case "high", "5": self = .high
        default: throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown priority \(s)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var label: String {
        switch self { case .none: "無"; case .low: "低"; case .medium: "中"; case .high: "高" }
    }
}

public struct TodoTask: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectId: String
    public var title: String
    public var content: String
    public var priority: Priority
    /// 0 active, 2 completed.
    public var status: Int
    /// Canonical wall-clock schedule.
    public var schedule: Schedule?
    /// TickTick-compatible renderings of `schedule` (ISO 8601 / dates).
    public var start: String?
    public var due: String?
    public var allDay: Bool
    public var timeZone: String?
    public var reminders: [String]
    public var `repeat`: String?
    public var tags: [String]
    public var items: [ChecklistItem]
    public var assigneeId: String?
    public var sortKey: String
    public var completedAt: EpochMillis?
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
    public var attachments: [Attachment]
    public var commentCount: Int
    public var sourceRaw: String?
    public var importNote: String?

    public var isCompleted: Bool { status == 2 }
    public var completedItemCount: Int { items.filter(\.isDone).count }
}

public struct TaskSection: Codable, Hashable, Sendable, Identifiable {
    /// overdue | today | tomorrow | later | nodate | completed | day:YYYY-MM-DD
    public var id: String
    public var title: String
    public var tasks: [TodoTask]
}

public struct SmartCounts: Codable, Hashable, Sendable {
    public var today: Int
    public var tomorrow: Int
    public var next7Days: Int
    public var inbox: Int
    public var assignedToMe: Int
    public var completed: Int
    public var trash: Int
}

public enum SmartView: String, Codable, Sendable, CaseIterable {
    case today, tomorrow, next7 = "next7", inbox, assigned, completed, trash
}

/// What a task list screen shows.
public enum TaskScope: Hashable, Sendable, Codable {
    case smart(SmartView)
    case project(String)
    case tag(String)
}

public struct ProjectData: Codable, Hashable, Sendable {
    public var project: Project
    public var tasks: [TodoTask]
}

public struct ScheduledReminder: Hashable, Sendable {
    public var id: String
    public var taskId: String
    public var title: String
    public var body: String
    public var fireDate: Date
}

public enum DayDoError: Error, LocalizedError, Equatable {
    case notFound(String, String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(entity, id): return "\(entity) not found: \(id)"
        case let .invalid(msg): return msg
        }
    }
}

/// JSON coding for the HTTP/MCP surface: snake_case keys.
public enum DayDoJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
