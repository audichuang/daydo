import Foundation

/// Three-state field for partial updates: key absent (leave alone), JSON
/// `null` (clear), or a value (set).
public enum Patch<Value: Codable & Sendable & Hashable>: Hashable, Sendable {
    case unset
    case clear
    case set(Value)

    public var isUnset: Bool { if case .unset = self { return true } else { return false } }
    public var value: Value? { if case let .set(v) = self { return v } else { return nil } }
}

extension Patch: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .clear : .set(try c.decode(Value.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .unset, .clear: try c.encodeNil()
        case let .set(v): try c.encode(v)
        }
    }
}

extension KeyedDecodingContainer {
    public func decode<V>(_ type: Patch<V>.Type, forKey key: Key) throws -> Patch<V> {
        guard contains(key) else { return .unset }
        return try decodeNil(forKey: key) ? .clear : .set(try decode(V.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<V>(_ value: Patch<V>, forKey key: Key) throws {
        switch value {
        case .unset: break
        case .clear: try encodeNil(forKey: key)
        case let .set(v): try encode(v, forKey: key)
        }
    }
}

public struct CreateTaskInput: Codable, Hashable, Sendable {
    /// Defaults to the inbox.
    public var projectId: String?
    public var title: String
    public var content: String?
    public var priority: Priority?
    /// TickTick-style schedule: ISO 8601 date-times (with or without offset)
    /// or plain dates for all-day; `due` is the end (inclusive day for all-day).
    public var start: String?
    public var due: String?
    public var allDay: Bool?
    public var timeZone: String?
    /// Precise alternative to start/due used by the app UI; wins if present.
    public var schedule: Schedule?
    /// Trigger strings, e.g. ["TRIGGER:-PT15M"]. `reminder` accepts the
    /// comma-separated form used by ticktick-mcp.
    public var reminders: [String]?
    public var reminder: String?
    public var `repeat`: String?
    public var subtasks: [String]?
    public var tags: [String]?
    public var assigneeId: String?
    public var sourceRaw: String?
    public var importNote: String?

    /// JSON uses `timezone` like ticktick-mcp.
    enum CodingKeys: String, CodingKey {
        case projectId, title, content, priority, start, due, allDay, schedule, reminders, reminder, `repeat`
        case subtasks, tags, assigneeId, sourceRaw, importNote
        case timeZone = "timezone"
    }

    public init(projectId: String? = nil, title: String, content: String? = nil, priority: Priority? = nil,
                start: String? = nil, due: String? = nil, allDay: Bool? = nil, timeZone: String? = nil,
                schedule: Schedule? = nil, reminders: [String]? = nil, reminder: String? = nil, repeat: String? = nil,
                subtasks: [String]? = nil, tags: [String]? = nil, assigneeId: String? = nil,
                sourceRaw: String? = nil, importNote: String? = nil) {
        self.projectId = projectId; self.title = title; self.content = content; self.priority = priority
        self.start = start; self.due = due; self.allDay = allDay; self.timeZone = timeZone; self.schedule = schedule
        self.reminders = reminders; self.reminder = reminder; self.repeat = `repeat`; self.subtasks = subtasks
        self.tags = tags; self.assigneeId = assigneeId; self.sourceRaw = sourceRaw; self.importNote = importNote
    }
}

public struct UpdateTaskInput: Codable, Hashable, Sendable {
    public var taskId: String
    public var projectId: String?
    public var title: String?
    public var content: String?
    public var priority: Priority?
    /// Setting `start` rebuilds the schedule from start/due/all_day/time_zone;
    /// `null` or "" clears the date. `due` alone only moves the end.
    public var start: Patch<String> = .unset
    public var due: Patch<String> = .unset
    public var allDay: Bool?
    public var timeZone: String?
    /// Precise alternative used by the UI; wins over start/due.
    public var schedule: Patch<Schedule> = .unset
    public var reminders: [String]?
    public var reminder: String?
    /// RRULE; null or "" clears.
    public var `repeat`: Patch<String> = .unset
    /// Replaces the whole checklist when present.
    public var subtasks: [String]?
    public var tags: [String]?
    public var assigneeId: Patch<String> = .unset

    public init(taskId: String) { self.taskId = taskId }

    enum CodingKeys: String, CodingKey {
        case taskId, projectId, title, content, priority, start, due, allDay, schedule
        case timeZone = "timezone"
        case reminders, reminder, `repeat`, subtasks, tags, assigneeId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority)
        start = try c.decode(Patch<String>.self, forKey: .start)
        due = try c.decode(Patch<String>.self, forKey: .due)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        schedule = try c.decode(Patch<Schedule>.self, forKey: .schedule)
        reminders = try c.decodeIfPresent([String].self, forKey: .reminders)
        reminder = try c.decodeIfPresent(String.self, forKey: .reminder)
        `repeat` = try c.decode(Patch<String>.self, forKey: .repeat)
        subtasks = try c.decodeIfPresent([String].self, forKey: .subtasks)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        assigneeId = try c.decode(Patch<String>.self, forKey: .assigneeId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskId, forKey: .taskId)
        try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encode(start, forKey: .start)
        try c.encode(due, forKey: .due)
        try c.encodeIfPresent(allDay, forKey: .allDay)
        try c.encodeIfPresent(timeZone, forKey: .timeZone)
        try c.encode(schedule, forKey: .schedule)
        try c.encodeIfPresent(reminders, forKey: .reminders)
        try c.encodeIfPresent(reminder, forKey: .reminder)
        try c.encode(`repeat`, forKey: .repeat)
        try c.encodeIfPresent(subtasks, forKey: .subtasks)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encode(assigneeId, forKey: .assigneeId)
    }
}

public struct CreateProjectInput: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?
    public var icon: String?
    public var folderId: String?
    public var viewMode: String?
    public var kind: String?

    public init(name: String, color: String? = nil, icon: String? = nil, folderId: String? = nil, viewMode: String? = nil, kind: String? = nil) {
        self.name = name; self.color = color; self.icon = icon; self.folderId = folderId; self.viewMode = viewMode; self.kind = kind
    }
}

public struct UpdateProjectInput: Codable, Hashable, Sendable {
    public var projectId: String
    public var name: String?
    public var color: Patch<String> = .unset
    public var icon: Patch<String> = .unset
    public var folderId: Patch<String> = .unset
    public var viewMode: String?
    public var kind: String?
    public var showInSmart: String?
    public var notifyMode: String?
    public var archived: Bool?

    public init(projectId: String) { self.projectId = projectId }

    enum CodingKeys: String, CodingKey { case projectId, name, color, icon, folderId, viewMode, kind, showInSmart, notifyMode, archived }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decode(String.self, forKey: .projectId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        color = try c.decode(Patch<String>.self, forKey: .color)
        icon = try c.decode(Patch<String>.self, forKey: .icon)
        folderId = try c.decode(Patch<String>.self, forKey: .folderId)
        viewMode = try c.decodeIfPresent(String.self, forKey: .viewMode)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        showInSmart = try c.decodeIfPresent(String.self, forKey: .showInSmart)
        notifyMode = try c.decodeIfPresent(String.self, forKey: .notifyMode)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(icon, forKey: .icon)
        try c.encode(folderId, forKey: .folderId)
        try c.encodeIfPresent(viewMode, forKey: .viewMode)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(showInSmart, forKey: .showInSmart)
        try c.encodeIfPresent(notifyMode, forKey: .notifyMode)
        try c.encodeIfPresent(archived, forKey: .archived)
    }
}

public struct TaskQuery: Codable, Hashable, Sendable {
    public var projectId: String?
    public var tag: String?
    /// Inclusive day range; tasks whose schedule overlaps it.
    public var from: LocalDay?
    public var to: LocalDay?
    public var includeCompleted: Bool
    /// Only tasks belonging to this member (assignee, or list owner when unassigned).
    public var memberId: String?

    public init(projectId: String? = nil, tag: String? = nil, from: LocalDay? = nil, to: LocalDay? = nil, includeCompleted: Bool = false, memberId: String? = nil) {
        self.projectId = projectId; self.tag = tag; self.from = from; self.to = to
        self.includeCompleted = includeCompleted; self.memberId = memberId
    }
}
