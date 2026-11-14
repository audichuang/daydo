import Foundation
import GRDB

// Row types. Column names equal property names. Every syncable row carries
// createdAt/updatedAt (epoch ms) and a soft-delete `deletedAt`, so the
// future Cloudflare D1 schema can mirror these tables 1:1.

public struct MemberRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "member"
    public var id: String
    public var name: String
    public var initial: String
    public var color: String
    public var isMe: Bool
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

public struct FolderRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folder"
    public var id: String
    public var name: String
    public var sortKey: String
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

public struct ProjectRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"
    public var id: String
    public var name: String
    public var color: String?
    public var icon: String?
    public var folderId: String?
    /// list | kanban | timeline
    public var viewMode: String
    /// TASK | NOTE
    public var kind: String
    public var isInbox: Bool
    public var ownerId: String
    public var sortKey: String
    /// all | none — whether tasks appear in 今天／明天／未來 7 天.
    public var showInSmart: String
    /// all | none — change notifications for shared lists.
    public var notifyMode: String
    public var archivedAt: EpochMillis?
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

public struct ProjectMemberRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "projectMember"
    public var projectId: String
    public var memberId: String
    /// owner | editor | viewer
    public var role: String
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

public struct TaskRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task"
    public var id: String
    public var projectId: String
    public var title: String
    public var content: String
    /// 0 none, 1 low, 3 medium, 5 high (TickTick values).
    public var priority: Int
    /// 0 active, 2 completed.
    public var status: Int
    public var startDay: String?
    public var startMinute: Int?
    public var endDay: String?
    public var endMinute: Int?
    public var timeZone: String?
    public var reminders: [String]
    public var repeatRule: String?
    public var tags: [String]
    public var assigneeId: String?
    public var sortKey: String
    public var completedAt: EpochMillis?
    /// Original text when the task was imported (mail, share sheet).
    public var sourceRaw: String?
    /// Human note describing what the import cleaned up.
    public var importNote: String?
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?

    public var schedule: Schedule? {
        get {
            guard let s = startDay.flatMap(LocalDay.init) else { return nil }
            return Schedule(startDay: s, startMinute: startMinute, endDay: endDay.flatMap(LocalDay.init), endMinute: endMinute, timeZone: timeZone)
        }
        set {
            startDay = newValue?.startDay.description
            startMinute = newValue?.startMinute
            endDay = newValue?.endDay?.description
            endMinute = newValue?.endMinute
            timeZone = newValue?.timeZone
        }
    }
}

public struct ChecklistItemRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "checklistItem"
    public var id: String
    public var taskId: String
    public var title: String
    /// 0 open, 1 done (TickTick uses 0/1 for items).
    public var status: Int
    public var sortKey: String
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

public struct TagRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tag"
    /// Lowercased label is the key (TickTick semantics).
    public var name: String
    public var label: String
    public var color: String?
    public var sortKey: String
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

public struct AttachmentRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"
    public var id: String
    public var taskId: String
    public var fileName: String
    public var size: Int64
    public var mimeType: String
    /// Path relative to the attachments directory; nil once uploaded-only.
    public var localPath: String?
    /// Where the file originally came from (shown shortened in the UI).
    public var originalPath: String?
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

public struct CommentRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "comment"
    public var id: String
    public var taskId: String
    public var authorId: String
    public var body: String
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var deletedAt: EpochMillis?
}

/// Outbox: one row per local write, in the same transaction as the write.
/// The sync engine (phase 2) pushes these to the Worker and deletes them on ack.
public struct ChangeRecord: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "change"
    public var seq: Int64?
    public var entity: String
    public var entityId: String
    /// upsert | delete
    public var op: String
    /// Names of the fields this write changed (field-level merge on the server).
    public var fields: [String]
    /// Full row snapshot as JSON after the write.
    public var row: String
    public var at: EpochMillis

    public mutating func didInsert(_ inserted: InsertionSuccess) { seq = inserted.rowID }
}
