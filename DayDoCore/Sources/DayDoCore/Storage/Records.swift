import Foundation
import GRDB

// Row types. Column names equal property names. Every syncable row carries
// createdAt/updatedAt (epoch ms) and a soft-delete `deletedAt`, so the
// future Cloudflare D1 schema can mirror these tables 1:1.

struct MemberRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "member"
    var id: String
    var name: String
    var initial: String
    var color: String
    var isMe: Bool
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

struct FolderRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "folder"
    var id: String
    var name: String
    var sortKey: String
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

struct ProjectRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"
    var id: String
    var name: String
    var color: String?
    var icon: String?
    var folderId: String?
    /// list | kanban | timeline
    var viewMode: String
    /// TASK | NOTE
    var kind: String
    var isInbox: Bool
    var ownerId: String
    var sortKey: String
    /// all | none — whether tasks appear in 今天／明天／未來 7 天.
    var showInSmart: String
    /// all | none — change notifications for shared lists.
    var notifyMode: String
    var archivedAt: EpochMillis?
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

struct ProjectMemberRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projectMember"
    var projectId: String
    var memberId: String
    /// owner | editor | viewer
    var role: String
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

struct ProjectInviteRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projectInvite"
    var id: String
    var projectId: String
    var email: String
    /// editor | viewer
    var role: String
    /// pending | accepted | declined | expired
    var status: String
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

struct TaskRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "task"
    var id: String
    var projectId: String
    var title: String
    var content: String
    /// 0 none, 1 low, 3 medium, 5 high (TickTick values).
    var priority: Int
    /// 0 active, 2 completed.
    var status: Int
    var startDay: String?
    var startMinute: Int?
    var endDay: String?
    var endMinute: Int?
    var timeZone: String?
    var reminders: [String]
    var repeatRule: String?
    var tags: [String]
    var assigneeId: String?
    var countdown: Bool = false
    var sortKey: String
    var completedAt: EpochMillis?
    /// Original text when the task was imported (mail, share sheet).
    var sourceRaw: String?
    /// Human note describing what the import cleaned up.
    var importNote: String?
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?

    var schedule: Schedule? {
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

struct ChecklistItemRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "checklistItem"
    var id: String
    var taskId: String
    var title: String
    /// 0 open, 1 done (TickTick uses 0/1 for items).
    var status: Int
    var sortKey: String
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

struct TagRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tag"
    /// Lowercased label is the key (TickTick semantics).
    var name: String
    var label: String
    var color: String?
    var sortKey: String
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

struct AttachmentRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attachment"

    /// SQL WHERE predicate for local attachment files that exist only on this device
    /// (never confirmed uploaded), including permanently failed or rejected rows so
    /// sign-out / account-switch warnings do not undercount unbacked local files.
    static let localOnlyFileWhereClause = """
        deletedAt IS NULL
        AND localPath IS NOT NULL
        AND localPath != ''
        AND fileUploadedAt IS NULL
        AND NOT EXISTS (
            SELECT 1 FROM "change"
            WHERE entity = 'attachment'
              AND entityId = attachment.id
              AND ackedAt IS NULL
        )
        """

    /// SQL WHERE predicate for local attachment files waiting to be uploaded.
    static let pendingUploadWhereClause = """
        \(localOnlyFileWhereClause)
        AND fileUploadFailed = 0
        AND NOT EXISTS (
            SELECT 1 FROM "change"
            WHERE entity = 'attachment'
              AND entityId = attachment.id
              AND op = 'upsert'
              AND result = 'rejected'
              AND EXISTS (SELECT 1 FROM json_each(fields) WHERE value = 'id')
        )
        """

    var id: String
    var taskId: String
    var fileName: String
    var size: Int64
    var mimeType: String
    /// Path relative to the attachments directory; nil once uploaded-only.
    var localPath: String?
    /// Where the file originally came from (shown shortened in the UI).
    var originalPath: String?
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
    /// Local-only: epoch ms when file content was confirmed stored on the server.
    var fileUploadedAt: EpochMillis? = nil
    /// Local-only: true when file upload hit a permanent error (400/403/410/413).
    var fileUploadFailed: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, taskId, fileName, size, mimeType, localPath, originalPath, createdAt, updatedAt, deletedAt
    }

    init(
        id: String,
        taskId: String,
        fileName: String,
        size: Int64,
        mimeType: String,
        localPath: String? = nil,
        originalPath: String? = nil,
        createdAt: EpochMillis,
        updatedAt: EpochMillis,
        deletedAt: EpochMillis? = nil,
        fileUploadedAt: EpochMillis? = nil,
        fileUploadFailed: Bool = false
    ) {
        self.id = id
        self.taskId = taskId
        self.fileName = fileName
        self.size = size
        self.mimeType = mimeType
        self.localPath = localPath
        self.originalPath = originalPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.fileUploadedAt = fileUploadedAt
        self.fileUploadFailed = fileUploadFailed
    }

    init(row: Row) throws {
        id = row["id"]
        taskId = row["taskId"]
        fileName = row["fileName"]
        size = row["size"]
        mimeType = row["mimeType"]
        localPath = row["localPath"]
        originalPath = row["originalPath"]
        createdAt = row["createdAt"]
        updatedAt = row["updatedAt"]
        deletedAt = row["deletedAt"]
        fileUploadedAt = row["fileUploadedAt"]
        fileUploadFailed = row["fileUploadFailed"] ?? false
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["taskId"] = taskId
        container["fileName"] = fileName
        container["size"] = size
        container["mimeType"] = mimeType
        container["localPath"] = localPath
        container["originalPath"] = originalPath
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
        container["deletedAt"] = deletedAt
        container["fileUploadedAt"] = fileUploadedAt
        container["fileUploadFailed"] = fileUploadFailed
    }
}

struct CommentRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "comment"
    var id: String
    var taskId: String
    var authorId: String
    var body: String
    var createdAt: EpochMillis
    var updatedAt: EpochMillis
    var deletedAt: EpochMillis?
}

/// Outbox: one row per local write, in the same transaction as the write.
/// The sync engine (phase 2) pushes these to the Worker and deletes them on ack.
struct ChangeRecord: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "change"
    var seq: Int64?
    var entity: String
    var entityId: String
    /// upsert | delete
    var op: String
    /// Names of the fields this write changed (field-level merge on the server).
    var fields: [String]
    /// Full row snapshot as JSON after the write.
    var row: String
    var at: EpochMillis
    var opId: String?
    var hlc: String?
    var ackedAt: EpochMillis?
    /// null | applied | rejected
    var result: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { seq = inserted.rowID }
}
