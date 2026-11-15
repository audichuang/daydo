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
    /// Server account userId for sharing role/removal calls, when known.
    public var userId: String?
    public var avatarUrl: String?

    public init(id: String, name: String, initial: String, color: String, isMe: Bool, userId: String? = nil, avatarUrl: String? = nil) {
        self.id = id
        self.name = name
        self.initial = initial
        self.color = color
        self.isMe = isMe
        self.userId = userId
        self.avatarUrl = avatarUrl
    }

    public static let legacyDefaultColor = "#9BB8FF"

    public static let avatarColors: [String] = [
        "#6FA8FF",
        "#4FC3A1",
        "#E98A5B",
        "#E8C14E",
        "#C77DDB",
        "#F27474",
        "#4AA8E8",
        "#8CD17D",
    ]

    /// Stable FNV-1a hash mapping a member id to one of `avatarColors`.
    public static func defaultColor(for id: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return avatarColors[Int(hash % UInt64(avatarColors.count))]
    }

    /// First extended grapheme cluster of the trimmed name, uppercased for Latin.
    public static func makeInitial(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return String(first).uppercased()
    }
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
    public var myRole: String
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis

    public var isShared: Bool { memberIds.count > 1 }

    public init(
        id: String,
        name: String,
        color: String? = nil,
        icon: String? = nil,
        folderId: String? = nil,
        viewMode: String,
        kind: String,
        isInbox: Bool,
        ownerId: String,
        sortKey: String,
        showInSmart: String,
        notifyMode: String,
        archived: Bool,
        memberIds: [String],
        activeCount: Int,
        myRole: String = "owner",
        createdAt: EpochMillis,
        updatedAt: EpochMillis
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.folderId = folderId
        self.viewMode = viewMode
        self.kind = kind
        self.isInbox = isInbox
        self.ownerId = ownerId
        self.sortKey = sortKey
        self.showInSmart = showInSmart
        self.notifyMode = notifyMode
        self.archived = archived
        self.memberIds = memberIds
        self.activeCount = activeCount
        self.myRole = myRole
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        viewMode = try c.decode(String.self, forKey: .viewMode)
        kind = try c.decode(String.self, forKey: .kind)
        isInbox = try c.decode(Bool.self, forKey: .isInbox)
        ownerId = try c.decode(String.self, forKey: .ownerId)
        sortKey = try c.decode(String.self, forKey: .sortKey)
        showInSmart = try c.decode(String.self, forKey: .showInSmart)
        notifyMode = try c.decode(String.self, forKey: .notifyMode)
        archived = try c.decode(Bool.self, forKey: .archived)
        memberIds = try c.decode([String].self, forKey: .memberIds)
        activeCount = try c.decode(Int.self, forKey: .activeCount)
        myRole = try c.decodeIfPresent(String.self, forKey: .myRole) ?? "owner"
        createdAt = try c.decode(EpochMillis.self, forKey: .createdAt)
        updatedAt = try c.decode(EpochMillis.self, forKey: .updatedAt)
    }
}

public struct ProjectMemberInfo: Codable, Hashable, Sendable, Identifiable {
    public var memberId: String
    public var name: String
    public var initial: String
    public var color: String
    public var isMe: Bool
    /// owner | editor | viewer
    public var role: String
    /// Server account userId for sharing role/removal calls, when known.
    public var userId: String?
    public var avatarUrl: String?

    public var id: String { memberId }

    public var asMember: Member {
        Member(id: memberId, name: name, initial: initial, color: color, isMe: isMe, userId: userId, avatarUrl: avatarUrl)
    }

    public init(memberId: String, name: String, initial: String, color: String, isMe: Bool, role: String, userId: String? = nil, avatarUrl: String? = nil) {
        self.memberId = memberId
        self.name = name
        self.initial = initial
        self.color = color
        self.isMe = isMe
        self.role = role
        self.userId = userId
        self.avatarUrl = avatarUrl
    }
}

public struct ProjectInvite: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var projectId: String
    public var email: String
    /// editor | viewer
    public var role: String
    /// pending | accepted | declined | expired
    public var status: String
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
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

    /// JSON uses `timezone` like ticktick-mcp.
    enum CodingKeys: String, CodingKey {
        case id, projectId, title, content, priority, status, schedule, start, due, allDay, reminders, `repeat`, tags, items
        case assigneeId, sortKey, completedAt, createdAt, updatedAt, deletedAt, attachments, commentCount, sourceRaw, importNote
        case timeZone = "timezone"
    }

    public var isCompleted: Bool { status == 2 }
    public var completedItemCount: Int { items.filter(\.isDone).count }
}

public struct TaskSection: Codable, Hashable, Sendable, Identifiable {
    /// overdue | today | tomorrow | later | nodate | completed | day:YYYY-MM-DD
    public var id: String
    public var title: String
    public var tasks: [TodoTask]
    public var hasMore: Bool

    public init(id: String, title: String, tasks: [TodoTask], hasMore: Bool = false) {
        self.id = id
        self.title = title
        self.tasks = tasks
        self.hasMore = hasMore
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        tasks = try c.decode([TodoTask].self, forKey: .tasks)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

public struct SmartCounts: Codable, Hashable, Sendable {
    public var today: Int
    public var tomorrow: Int
    public var next7Days: Int
    public var inbox: Int
    public var assignedToMe: Int
    public var completed: Int
    public var trash: Int

    public init(today: Int, tomorrow: Int, next7Days: Int, inbox: Int, assignedToMe: Int, completed: Int, trash: Int) {
        self.today = today; self.tomorrow = tomorrow; self.next7Days = next7Days; self.inbox = inbox
        self.assignedToMe = assignedToMe; self.completed = completed; self.trash = trash
    }
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
