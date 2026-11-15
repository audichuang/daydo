import Foundation
import GRDB

/// On-device implementation of `DayDoAPI` backed by SQLite. Every write
/// appends to the `change` outbox in the same transaction.
public final class LocalDayDoAPI: DayDoAPI {
    public let database: AppDatabase
    public let clock: Clock
    public let attachmentsDirectory: URL

    public init(database: AppDatabase, clock: Clock = .system, attachmentsDirectory: URL) {
        self.database = database
        self.clock = clock
        self.attachmentsDirectory = attachmentsDirectory
    }

    var writer: any DatabaseWriter { database.writer }
    func now() -> EpochMillis { clock.now().epochMillis }
    var today: LocalDay { clock.today }

    // MARK: Bootstrap

    public static let defaultLists: [(String, String)] = [("工作", "#4AA8E8"), ("個人", "#E98A5B"), ("購物", "#C77DDB")]

    /// Creates the local user, the inbox and starter lists on first launch.
    public func bootstrap(meName: String = "我") async throws {
        let now = now()
        try await writer.write { db in
            try Self.bootstrap(meName: meName, in: db, now: now)
        }
    }

    static func bootstrap(meName: String = "我", in db: Database, now: EpochMillis) throws {
        if try MemberRecord.filter(Column("isMe") == true).fetchOne(db) != nil { return }
        let me = MemberRecord(id: ID.make(), name: meName, initial: String(meName.prefix(1)), color: "#9BB8FF", isMe: true, createdAt: now, updatedAt: now)
        try Outbox.save(me, entity: "member", id: me.id, in: db, now: now)
        var key: String? = nil
        func project(_ name: String, _ color: String?, inbox: Bool) throws {
            key = SortKey.after(key)
            let p = ProjectRecord(id: ID.make(), name: name, color: color, icon: inbox ? "inbox" : nil, folderId: nil, viewMode: "list", kind: "TASK",
                                  isInbox: inbox, ownerId: me.id, sortKey: key!, showInSmart: "all", notifyMode: "all",
                                  archivedAt: nil, createdAt: now, updatedAt: now)
            try Outbox.save(p, entity: "project", id: p.id, in: db, now: now)
            let pm = ProjectMemberRecord(projectId: p.id, memberId: me.id, role: "owner", createdAt: now, updatedAt: now)
            try Outbox.save(pm, entity: "projectMember", id: "\(p.id):\(me.id)", key: ["projectId": p.id, "memberId": me.id], in: db, now: now)
        }
        try project("收件匣", nil, inbox: true)
        for (n, c) in Self.defaultLists { try project(n, c, inbox: false) }
    }

    // MARK: Helpers (run inside a transaction)

    func me(_ db: Database) throws -> MemberRecord {
        guard let m = try MemberRecord.filter(Column("isMe") == true).fetchOne(db) else {
            throw DayDoError.invalid("Database not bootstrapped")
        }
        return m
    }

    func inbox(_ db: Database) throws -> ProjectRecord {
        guard let p = try ProjectRecord.filter(Column("isInbox") == true && Column("deletedAt") == nil).fetchOne(db) else {
            throw DayDoError.invalid("Inbox missing")
        }
        return p
    }

    func projectRecord(_ db: Database, _ id: String) throws -> ProjectRecord {
        guard let p = try ProjectRecord.fetchOne(db, key: id), p.deletedAt == nil else { throw DayDoError.notFound("project", id) }
        return p
    }

    func taskRecord(_ db: Database, _ id: String, includeDeleted: Bool = false) throws -> TaskRecord {
        guard let t = try TaskRecord.fetchOne(db, key: id), includeDeleted || t.deletedAt == nil else { throw DayDoError.notFound("task", id) }
        return t
    }

    func saveTask(_ db: Database, _ t: TaskRecord) throws {
        try Outbox.save(t, entity: "task", id: t.id, in: db, now: now())
    }

    func recordDelete(_ db: Database, entity: String, id: String) throws {
        let now = now()
        let hlc = try HLC.tick(in: db, now: now)
        var c = ChangeRecord(
            seq: nil, entity: entity, entityId: id, op: "delete", fields: [], row: "{}", at: now,
            opId: ID.make(), hlc: hlc.description, ackedAt: nil, result: nil)
        try c.insert(db)
    }

    func tasks(_ db: Database, _ records: [TaskRecord]) throws -> [TodoTask] {
        guard !records.isEmpty else { return [] }
        let ids = records.map(\.id)
        let items = try ChecklistItemRecord.filter(ids.contains(Column("taskId")) && Column("deletedAt") == nil).fetchAll(db)
        let atts = try AttachmentRecord.filter(ids.contains(Column("taskId")) && Column("deletedAt") == nil).fetchAll(db)
        let comments = try Row.fetchAll(db, sql: "SELECT taskId, COUNT(*) AS n FROM comment WHERE deletedAt IS NULL AND taskId IN (\(ids.map { _ in "?" }.joined(separator: ","))) GROUP BY taskId", arguments: StatementArguments(ids))
        let itemsBy = Dictionary(grouping: items, by: \.taskId)
        let attsBy = Dictionary(grouping: atts, by: \.taskId)
        var counts: [String: Int] = [:]
        for r in comments { counts[r["taskId"]] = r["n"] }
        let tz = clock.timeZone()
        return records.map { r in
            let sched = r.schedule?.localized(to: tz)
            return TodoTask(
                id: r.id, projectId: r.projectId, title: r.title, content: r.content,
                priority: Priority(rawValue: r.priority) ?? .none, status: r.status,
                schedule: sched, start: sched?.apiStart, due: sched?.apiDue, allDay: sched?.isAllDay ?? false,
                timeZone: r.timeZone, reminders: r.reminders, repeat: r.repeatRule, tags: r.tags,
                items: (itemsBy[r.id] ?? []).sorted { $0.sortKey < $1.sortKey }.map { ChecklistItem(id: $0.id, title: $0.title, status: $0.status, sortKey: $0.sortKey) },
                assigneeId: r.assigneeId, sortKey: r.sortKey, completedAt: r.completedAt,
                createdAt: r.createdAt, updatedAt: r.updatedAt, deletedAt: r.deletedAt,
                attachments: (attsBy[r.id] ?? []).sorted { $0.createdAt < $1.createdAt }.map {
                    Attachment(id: $0.id, fileName: $0.fileName, size: $0.size, mimeType: $0.mimeType, localPath: $0.localPath, originalPath: $0.originalPath, createdAt: $0.createdAt)
                },
                commentCount: counts[r.id] ?? 0, sourceRaw: r.sourceRaw, importNote: r.importNote)
        }
    }

    func task(_ db: Database, _ r: TaskRecord) throws -> TodoTask { try tasks(db, [r])[0] }

    func project(_ db: Database, _ p: ProjectRecord) throws -> Project {
        let members = try String.fetchAll(db, sql: "SELECT memberId FROM projectMember WHERE projectId = ? AND deletedAt IS NULL ORDER BY createdAt", arguments: [p.id])
        let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE projectId = ? AND deletedAt IS NULL AND status = 0", arguments: [p.id]) ?? 0
        return Project(id: p.id, name: p.name, color: p.color, icon: p.icon, folderId: p.folderId, viewMode: p.viewMode, kind: p.kind,
                       isInbox: p.isInbox, ownerId: p.ownerId, sortKey: p.sortKey, showInSmart: p.showInSmart, notifyMode: p.notifyMode,
                       archived: p.archivedAt != nil, memberIds: members, activeCount: active, createdAt: p.createdAt, updatedAt: p.updatedAt)
    }

    /// Live (not deleted, not archived) project ids, optionally only those
    /// that feed smart lists.
    func liveProjectIds(_ db: Database, smartOnly: Bool) throws -> Set<String> {
        var sql = "SELECT id FROM project WHERE deletedAt IS NULL AND archivedAt IS NULL"
        if smartOnly { sql += " AND showInSmart = 'all'" }
        return Set(try String.fetchAll(db, sql: sql))
    }

    func normalizeTags(_ db: Database, _ labels: [String], now: EpochMillis) throws -> [String] {
        var out: [String] = []
        for raw in labels {
            let label = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !label.isEmpty else { continue }
            let name = label.lowercased()
            if out.contains(name) { continue }
            out.append(name)
            if let existing = try TagRecord.fetchOne(db, key: name) {
                if existing.deletedAt != nil {
                    var t = existing
                    t.deletedAt = nil
                    t.updatedAt = now
                    try Outbox.save(t, entity: "tag", id: name, key: ["name": name], in: db, now: now)
                }
            } else {
                let last = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM tag")
                let t = TagRecord(name: name, label: label, color: nil, sortKey: SortKey.after(last), createdAt: now, updatedAt: now)
                try Outbox.save(t, entity: "tag", id: name, key: ["name": name], in: db, now: now)
            }
        }
        return out
    }

    static func reminderList(_ list: [String]?, _ csv: String?) throws -> [String]? {
        var raw = list
        if raw == nil, let csv { raw = csv.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        guard let raw else { return nil }
        return try raw.map { s in
            guard let r = Reminder(trigger: s) else { throw DayDoError.invalid("Invalid reminder trigger: \(s)") }
            return r.trigger
        }
    }

    static func validateRepeat(_ s: String) throws -> String {
        guard let r = Recurrence(rrule: s) else { throw DayDoError.invalid("Unsupported repeat rule: \(s)") }
        return s.uppercased().hasPrefix("RRULE:") ? s : r.rrule
    }
}

// MARK: - Members & folders

extension LocalDayDoAPI {
    public func listMembers() async throws -> [Member] {
        try await writer.read { db in
            try MemberRecord.filter(Column("deletedAt") == nil).order(Column("createdAt")).fetchAll(db)
                .map { Member(id: $0.id, name: $0.name, initial: $0.initial, color: $0.color, isMe: $0.isMe) }
        }
    }

    public func listFolders() async throws -> [Folder] {
        try await writer.read { db in
            try FolderRecord.filter(Column("deletedAt") == nil).order(Column("sortKey")).fetchAll(db)
                .map { Folder(id: $0.id, name: $0.name, sortKey: $0.sortKey) }
        }
    }

    public func createFolder(name: String) async throws -> Folder {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DayDoError.invalid("Folder name is required") }
        let now = now()
        return try await writer.write { db in
            let last = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM folder")
            let f = FolderRecord(id: ID.make(), name: name, sortKey: SortKey.after(last), createdAt: now, updatedAt: now)
            try Outbox.save(f, entity: "folder", id: f.id, in: db, now: now)
            return Folder(id: f.id, name: f.name, sortKey: f.sortKey)
        }
    }

    public func updateFolder(id: String, name: String) async throws -> Folder {
        let now = now()
        return try await writer.write { db in
            guard var f = try FolderRecord.fetchOne(db, key: id), f.deletedAt == nil else { throw DayDoError.notFound("folder", id) }
            f.name = name
            f.updatedAt = now
            try Outbox.save(f, entity: "folder", id: f.id, in: db, now: now)
            return Folder(id: f.id, name: f.name, sortKey: f.sortKey)
        }
    }

    public func deleteFolder(id: String) async throws {
        let now = now()
        try await writer.write { db in
            guard var f = try FolderRecord.fetchOne(db, key: id), f.deletedAt == nil else { throw DayDoError.notFound("folder", id) }
            for var p in try ProjectRecord.filter(Column("folderId") == id).fetchAll(db) {
                p.folderId = nil
                p.updatedAt = now
                try Outbox.save(p, entity: "project", id: p.id, in: db, now: now)
            }
            f.deletedAt = now
            f.updatedAt = now
            try Outbox.save(f, entity: "folder", id: f.id, in: db, now: now)
        }
    }
}

// MARK: - Projects

extension LocalDayDoAPI {
    public func listProjects(includeArchived: Bool = false) async throws -> [Project] {
        try await writer.read { db in
            var req = ProjectRecord.filter(Column("deletedAt") == nil)
            if !includeArchived { req = req.filter(Column("archivedAt") == nil) }
            return try req.order(Column("isInbox").desc, Column("sortKey")).fetchAll(db).map { try self.project(db, $0) }
        }
    }

    public func getProject(id: String) async throws -> Project {
        try await writer.read { db in try self.project(db, try self.projectRecord(db, id)) }
    }

    public func getProjectData(id: String) async throws -> ProjectData {
        try await writer.read { db in
            let p = try self.projectRecord(db, id)
            let recs = try TaskRecord.filter(Column("projectId") == id && Column("deletedAt") == nil && Column("status") == 0).order(Column("sortKey")).fetchAll(db)
            return ProjectData(project: try self.project(db, p), tasks: try self.tasks(db, recs))
        }
    }

    public func createProject(_ input: CreateProjectInput) async throws -> Project {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DayDoError.invalid("Project name is required") }
        let now = now()
        return try await writer.write { db in
            let me = try self.me(db)
            if let fid = input.folderId, try FolderRecord.fetchOne(db, key: fid)?.deletedAt != nil || FolderRecord.fetchOne(db, key: fid) == nil {
                throw DayDoError.notFound("folder", fid)
            }
            let last = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM project")
            let p = ProjectRecord(id: ID.make(), name: name, color: input.color, icon: input.icon, folderId: input.folderId,
                                  viewMode: input.viewMode ?? "list", kind: input.kind ?? "TASK", isInbox: false, ownerId: me.id,
                                  sortKey: SortKey.after(last), showInSmart: "all", notifyMode: "all", archivedAt: nil, createdAt: now, updatedAt: now)
            try Outbox.save(p, entity: "project", id: p.id, in: db, now: now)
            let pm = ProjectMemberRecord(projectId: p.id, memberId: me.id, role: "owner", createdAt: now, updatedAt: now)
            try Outbox.save(pm, entity: "projectMember", id: "\(p.id):\(me.id)", key: ["projectId": p.id, "memberId": me.id], in: db, now: now)
            return try self.project(db, p)
        }
    }

    public func updateProject(_ input: UpdateProjectInput) async throws -> Project {
        let now = now()
        return try await writer.write { db in
            var p = try self.projectRecord(db, input.projectId)
            if let name = input.name {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { throw DayDoError.invalid("Project name is required") }
                p.name = n
            }
            switch input.color { case .unset: break; case .clear: p.color = nil; case let .set(v): p.color = v }
            switch input.icon { case .unset: break; case .clear: p.icon = nil; case let .set(v): p.icon = v }
            switch input.folderId {
            case .unset: break
            case .clear: p.folderId = nil
            case let .set(v):
                guard let f = try FolderRecord.fetchOne(db, key: v), f.deletedAt == nil else { throw DayDoError.notFound("folder", v) }
                p.folderId = v
            }
            if let v = input.viewMode {
                guard ["list", "kanban", "timeline"].contains(v) else { throw DayDoError.invalid("view_mode must be list, kanban or timeline") }
                p.viewMode = v
            }
            if let v = input.kind { p.kind = v }
            if let v = input.showInSmart { p.showInSmart = v }
            if let v = input.notifyMode { p.notifyMode = v }
            if let v = input.archived {
                if p.isInbox && v { throw DayDoError.invalid("The inbox cannot be archived") }
                p.archivedAt = v ? (p.archivedAt ?? now) : nil
            }
            p.updatedAt = now
            try Outbox.save(p, entity: "project", id: p.id, in: db, now: now)
            return try self.project(db, p)
        }
    }

    public func moveProject(id: String, beforeProjectId: String?) async throws -> Project {
        let now = now()
        return try await writer.write { db in
            var p = try self.projectRecord(db, id)
            if p.isInbox { throw DayDoError.invalid("The inbox cannot be reordered") }
            let siblings = try ProjectRecord
                .filter(Column("deletedAt") == nil && Column("archivedAt") == nil && Column("isInbox") == false && Column("folderId") == p.folderId && Column("id") != p.id)
                .order(Column("sortKey"))
                .fetchAll(db)
            let newKey: String
            if let targetId = beforeProjectId {
                if targetId == id { return try self.project(db, p) }
                let target = try self.projectRecord(db, targetId)
                guard !target.isInbox, target.folderId == p.folderId else {
                    throw DayDoError.invalid("Target list must be in the same group")
                }
                guard let idx = siblings.firstIndex(where: { $0.id == targetId }) else {
                    throw DayDoError.invalid("Target list is archived")
                }
                let prevKey = idx > 0 ? siblings[idx - 1].sortKey : nil
                let nextKey = siblings[idx].sortKey
                if (prevKey == nil || prevKey! < p.sortKey) && p.sortKey < nextKey {
                    return try self.project(db, p)
                }
                newKey = SortKey.between(prevKey, nextKey)
            } else {
                let lastKey = siblings.last?.sortKey
                if lastKey.map({ p.sortKey > $0 }) ?? true {
                    return try self.project(db, p)
                }
                newKey = SortKey.after(lastKey)
            }
            p.sortKey = newKey
            p.updatedAt = now
            try Outbox.save(p, entity: "project", id: p.id, in: db, now: now)
            return try self.project(db, p)
        }
    }

    public func deleteProject(id: String) async throws {
        let now = now()
        try await writer.write { db in
            var p = try self.projectRecord(db, id)
            if p.isInbox { throw DayDoError.invalid("The inbox cannot be deleted") }
            for var t in try TaskRecord.filter(Column("projectId") == id && Column("deletedAt") == nil).fetchAll(db) {
                t.deletedAt = now
                t.updatedAt = now
                try self.saveTask(db, t)
            }
            p.deletedAt = now
            p.updatedAt = now
            try Outbox.save(p, entity: "project", id: p.id, in: db, now: now)
        }
    }

    public func duplicateProject(id: String) async throws -> Project {
        let now = now()
        return try await writer.write { db in
            let src = try self.projectRecord(db, id)
            if src.isInbox { throw DayDoError.invalid("The inbox cannot be duplicated") }
            let me = try self.me(db)
            let nextSortKey = try ProjectRecord
                .filter(Column("deletedAt") == nil && Column("archivedAt") == nil && Column("isInbox") == false && Column("folderId") == src.folderId && Column("sortKey") > src.sortKey)
                .order(Column("sortKey"))
                .fetchOne(db)?
                .sortKey
            let copy = ProjectRecord(
                id: ID.make(),
                name: "\(src.name) 副本",
                color: src.color,
                icon: src.icon,
                folderId: src.folderId,
                viewMode: src.viewMode,
                kind: src.kind,
                isInbox: false,
                ownerId: me.id,
                sortKey: SortKey.between(src.sortKey, nextSortKey),
                showInSmart: src.showInSmart,
                notifyMode: src.notifyMode,
                archivedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            try Outbox.save(copy, entity: "project", id: copy.id, in: db, now: now)
            let pm = ProjectMemberRecord(projectId: copy.id, memberId: me.id, role: "owner", createdAt: now, updatedAt: now)
            try Outbox.save(pm, entity: "projectMember", id: "\(copy.id):\(me.id)", key: ["projectId": copy.id, "memberId": me.id], in: db, now: now)

            let tasks = try TaskRecord
                .filter(Column("projectId") == id && Column("deletedAt") == nil && Column("status") == 0)
                .order(Column("sortKey"))
                .fetchAll(db)
            for t in tasks {
                var tc = t
                tc.id = ID.make()
                tc.projectId = copy.id
                tc.assigneeId = nil
                tc.createdAt = now
                tc.updatedAt = now
                try self.saveTask(db, tc)
                let items = try ChecklistItemRecord
                    .filter(Column("taskId") == t.id && Column("deletedAt") == nil)
                    .order(Column("sortKey"))
                    .fetchAll(db)
                for item in items {
                    let ic = ChecklistItemRecord(id: ID.make(), taskId: tc.id, title: item.title, status: item.status, sortKey: item.sortKey, createdAt: now, updatedAt: now)
                    try Outbox.save(ic, entity: "checklistItem", id: ic.id, in: db, now: now)
                }
                let atts = try AttachmentRecord
                    .filter(Column("taskId") == t.id && Column("deletedAt") == nil)
                    .order(Column("createdAt"))
                    .fetchAll(db)
                for att in atts {
                    let newAttId = ID.make()
                    var newRel: String?
                    if let oldRel = att.localPath {
                        let srcURL = self.attachmentsDirectory.appendingPathComponent(oldRel)
                        if FileManager.default.fileExists(atPath: srcURL.path) {
                            let safeName = att.fileName.replacingOccurrences(of: "/", with: "_")
                            let rel = "\(newAttId)/\(safeName)"
                            let dstURL = self.attachmentsDirectory.appendingPathComponent(rel)
                            try FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            // Remove the copy if the transaction rolls back, including a failed COMMIT.
                            let dir = dstURL.deletingLastPathComponent()
                            db.afterNextTransaction(onCommit: { _ in }, onRollback: { _ in try? FileManager.default.removeItem(at: dir) })
                            try FileManager.default.copyItem(at: srcURL, to: dstURL)
                            newRel = rel
                        }
                    }
                    let ac = AttachmentRecord(
                        id: newAttId,
                        taskId: tc.id,
                        fileName: att.fileName,
                        size: att.size,
                        mimeType: att.mimeType,
                        localPath: newRel,
                        originalPath: att.originalPath,
                        createdAt: now,
                        updatedAt: now
                    )
                    try Outbox.save(ac, entity: "attachment", id: ac.id, in: db, now: now)
                }
            }
            return try self.project(db, copy)
        }
    }

    public func transferProjectOwner(projectId: String, toMemberId: String) async throws -> Project {
        let now = now()
        return try await writer.write { db in
            var p = try self.projectRecord(db, projectId)
            if p.isInbox { throw DayDoError.invalid("The inbox owner cannot be transferred") }
            guard var targetPM = try ProjectMemberRecord
                .filter(Column("projectId") == projectId && Column("memberId") == toMemberId && Column("deletedAt") == nil)
                .fetchOne(db) else {
                throw DayDoError.invalid("Target must be a member of this project")
            }
            if p.ownerId != toMemberId {
                if var oldPM = try ProjectMemberRecord
                    .filter(Column("projectId") == projectId && Column("memberId") == p.ownerId && Column("deletedAt") == nil)
                    .fetchOne(db) {
                    oldPM.role = "editor"
                    oldPM.updatedAt = now
                    try Outbox.save(oldPM, entity: "projectMember", id: "\(projectId):\(p.ownerId)", key: ["projectId": projectId, "memberId": p.ownerId], in: db, now: now)
                }
                targetPM.role = "owner"
                targetPM.updatedAt = now
                try Outbox.save(targetPM, entity: "projectMember", id: "\(projectId):\(toMemberId)", key: ["projectId": projectId, "memberId": toMemberId], in: db, now: now)
                p.ownerId = toMemberId
                p.updatedAt = now
                try Outbox.save(p, entity: "project", id: p.id, in: db, now: now)
            }
            return try self.project(db, p)
        }
    }

    public func listProjectMembers(projectId: String) async throws -> [ProjectMemberInfo] {
        try await writer.read { db in
            _ = try self.projectRecord(db, projectId)
            let pms = try ProjectMemberRecord
                .filter(Column("projectId") == projectId && Column("deletedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll(db)
            var out: [ProjectMemberInfo] = []
            for pm in pms {
                if let m = try MemberRecord.fetchOne(db, key: pm.memberId), m.deletedAt == nil {
                    out.append(ProjectMemberInfo(
                        memberId: m.id,
                        name: m.name,
                        initial: m.initial,
                        color: m.color,
                        isMe: m.isMe,
                        role: pm.role
                    ))
                }
            }
            return out
        }
    }

    public func updateMemberRole(projectId: String, memberId: String, role: String) async throws {
        guard role == "editor" || role == "viewer" else {
            throw DayDoError.invalid("role must be editor or viewer")
        }
        let now = now()
        try await writer.write { db in
            let p = try self.projectRecord(db, projectId)
            if p.isInbox { throw DayDoError.invalid("The inbox has no shared members") }
            if memberId == p.ownerId { throw DayDoError.invalid("Cannot change the project owner's role") }
            guard var pm = try ProjectMemberRecord
                .filter(Column("projectId") == projectId && Column("memberId") == memberId && Column("deletedAt") == nil)
                .fetchOne(db) else {
                throw DayDoError.notFound("project_member", "\(projectId):\(memberId)")
            }
            pm.role = role
            pm.updatedAt = now
            try Outbox.save(pm, entity: "projectMember", id: "\(projectId):\(memberId)", key: ["projectId": projectId, "memberId": memberId], in: db, now: now)
        }
    }

    public func removeMember(projectId: String, memberId: String) async throws {
        let now = now()
        try await writer.write { db in
            let p = try self.projectRecord(db, projectId)
            if p.isInbox { throw DayDoError.invalid("The inbox has no shared members") }
            if memberId == p.ownerId { throw DayDoError.invalid("Cannot remove the project owner") }
            guard var pm = try ProjectMemberRecord
                .filter(Column("projectId") == projectId && Column("memberId") == memberId && Column("deletedAt") == nil)
                .fetchOne(db) else {
                throw DayDoError.notFound("project_member", "\(projectId):\(memberId)")
            }
            pm.deletedAt = now
            pm.updatedAt = now
            try Outbox.save(pm, entity: "projectMember", id: "\(projectId):\(memberId)", key: ["projectId": projectId, "memberId": memberId], in: db, now: now)
        }
    }

    public func listInvites(projectId: String) async throws -> [ProjectInvite] {
        try await writer.read { db in
            _ = try self.projectRecord(db, projectId)
            return try ProjectInviteRecord
                .filter(Column("projectId") == projectId && Column("deletedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll(db)
                .map(Self.invite)
        }
    }

    public func inviteMember(projectId: String, email: String, role: String) async throws -> ProjectInvite {
        guard role == "editor" || role == "viewer" else {
            throw DayDoError.invalid("role must be editor or viewer")
        }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidInviteEmail(normalized) else {
            throw DayDoError.invalid("Invalid email address")
        }
        let now = now()
        return try await writer.write { db in
            let p = try self.projectRecord(db, projectId)
            if p.isInbox { throw DayDoError.invalid("The inbox cannot be shared") }
            let dup = try ProjectInviteRecord
                .filter(Column("projectId") == projectId && Column("email") == normalized && Column("status") == "pending" && Column("deletedAt") == nil)
                .fetchOne(db)
            if dup != nil {
                throw DayDoError.invalid("An invite for this email is already pending")
            }
            let rec = ProjectInviteRecord(
                id: ID.make(),
                projectId: projectId,
                email: normalized,
                role: role,
                status: "pending",
                createdAt: now,
                updatedAt: now,
                deletedAt: nil
            )
            try Outbox.save(rec, entity: "projectInvite", id: rec.id, in: db, now: now)
            return Self.invite(rec)
        }
    }

    public func cancelInvite(id: String) async throws {
        let now = now()
        try await writer.write { db in
            guard var rec = try ProjectInviteRecord.fetchOne(db, key: id), rec.deletedAt == nil else {
                throw DayDoError.notFound("project_invite", id)
            }
            rec.deletedAt = now
            rec.updatedAt = now
            try Outbox.save(rec, entity: "projectInvite", id: rec.id, in: db, now: now)
        }
    }

    public func updateInviteRole(id: String, role: String) async throws -> ProjectInvite {
        guard role == "editor" || role == "viewer" else {
            throw DayDoError.invalid("role must be editor or viewer")
        }
        let now = now()
        return try await writer.write { db in
            guard var rec = try ProjectInviteRecord.fetchOne(db, key: id), rec.deletedAt == nil else {
                throw DayDoError.notFound("project_invite", id)
            }
            rec.role = role
            rec.updatedAt = now
            try Outbox.save(rec, entity: "projectInvite", id: rec.id, in: db, now: now)
            return Self.invite(rec)
        }
    }

    private static func invite(_ r: ProjectInviteRecord) -> ProjectInvite {
        ProjectInvite(
            id: r.id,
            projectId: r.projectId,
            email: r.email,
            role: r.role,
            status: r.status,
            createdAt: r.createdAt,
            updatedAt: r.updatedAt
        )
    }

    private static func isValidInviteEmail(_ email: String) -> Bool {
        guard !email.isEmpty, !email.contains(where: { $0.isWhitespace }) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domainParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domainParts.count >= 2 && domainParts.allSatisfy { !$0.isEmpty }
    }
}

// MARK: - Task queries

extension LocalDayDoAPI {
    func fetchActive(_ db: Database, query: TaskQuery, smartOnly: Bool) throws -> [TodoTask] {
        let live = try liveProjectIds(db, smartOnly: smartOnly)
        var req = TaskRecord.filter(Column("deletedAt") == nil)
        if !query.includeCompleted { req = req.filter(Column("status") == 0) }
        if let pid = query.projectId { req = req.filter(Column("projectId") == pid) }
        var recs = try req.order(Column("sortKey")).fetchAll(db).filter { live.contains($0.projectId) || $0.projectId == query.projectId }
        if let tag = query.tag?.lowercased() { recs = recs.filter { $0.tags.contains(tag) } }
        if let mid = query.memberId {
            let rows = try Row.fetchAll(db, sql: "SELECT projectId, memberId FROM projectMember WHERE deletedAt IS NULL")
            var members: [String: Set<String>] = [:]
            for r in rows { members[r["projectId"], default: []].insert(r["memberId"]) }
            let meId = try me(db).id
            recs = recs.filter { t in
                let m = members[t.projectId] ?? []
                if m.count <= 1 { return mid == meId }
                return m.contains(mid)
            }
        }
        var out = try tasks(db, recs)
        if let from = query.from {
            let to = query.to ?? from
            out = out.filter { $0.schedule?.overlaps(from, to) ?? false }
        }
        return out
    }

    func completedToday(_ db: Database) throws -> [TodoTask] {
        let tz = clock.timeZone()
        let start = today.date(minute: 0, in: tz).epochMillis
        let live = try liveProjectIds(db, smartOnly: true)
        let recs = try TaskRecord.filter(Column("deletedAt") == nil && Column("status") == 2 && Column("completedAt") >= start)
            .order(Column("completedAt").desc).fetchAll(db).filter { live.contains($0.projectId) }
        return try tasks(db, recs)
    }

    public func listTasks(_ query: TaskQuery) async throws -> [TodoTask] {
        try await writer.read { db in try self.fetchActive(db, query: query, smartOnly: false) }
    }

    public func listSections(_ scope: TaskScope, limit: Int?) async throws -> [TaskSection] {
        let today = today
        return try await writer.read { db in
            let meId = try self.me(db).id
            switch scope {
            case .smart(let v):
                switch v {
                case .today, .tomorrow, .next7:
                    let active = try self.fetchActive(db, query: TaskQuery(), smartOnly: true).filter { $0.schedule != nil }
                    let done = v == .next7 ? [] : try self.completedToday(db)
                    return TaskGrouping.sections(for: scope, tasks: active, completed: v == .tomorrow ? [] : done, today: today)
                case .inbox:
                    let pid = try self.inbox(db).id
                    let active = try self.fetchActive(db, query: TaskQuery(projectId: pid), smartOnly: false)
                    let pageLimit = limit ?? 30
                    let fetched = try self.completed(db, projectId: pid, limit: pageLimit + 1)
                    let sections = TaskGrouping.sections(for: scope, tasks: active, completed: Array(fetched.prefix(pageLimit)), today: today)
                    return self.markingHasMore(sections, sectionId: "completed", hasMore: fetched.count > pageLimit)
                case .assigned:
                    let active = try self.fetchActive(db, query: TaskQuery(), smartOnly: false).filter { $0.assigneeId == meId }
                    return TaskGrouping.sections(for: scope, tasks: active, completed: [], today: today)
                case .completed:
                    let pageLimit = limit ?? 300
                    let fetched = try self.completed(db, projectId: nil, limit: pageLimit + 1)
                    let sections = TaskGrouping.sections(for: scope, tasks: [], completed: Array(fetched.prefix(pageLimit)), today: today)
                    return self.markingHasMore(sections, sectionId: "completed", hasMore: fetched.count > pageLimit)
                case .trash:
                    let pageLimit = limit ?? 300
                    let recs = try TaskRecord.filter(Column("deletedAt") != nil).order(Column("deletedAt").desc).limit(pageLimit + 1).fetchAll(db)
                    let sections = TaskGrouping.sections(for: scope, tasks: try self.tasks(db, Array(recs.prefix(pageLimit))), completed: [], today: today)
                    return self.markingHasMore(sections, sectionId: "trash", hasMore: recs.count > pageLimit)
                }
            case .project(let pid):
                _ = try self.projectRecord(db, pid)
                let active = try self.fetchActive(db, query: TaskQuery(projectId: pid), smartOnly: false)
                let pageLimit = limit ?? 30
                let fetched = try self.completed(db, projectId: pid, limit: pageLimit + 1)
                let sections = TaskGrouping.sections(for: scope, tasks: active, completed: Array(fetched.prefix(pageLimit)), today: today)
                return self.markingHasMore(sections, sectionId: "completed", hasMore: fetched.count > pageLimit)
            case .tag(let name):
                let active = try self.fetchActive(db, query: TaskQuery(tag: name), smartOnly: false)
                return TaskGrouping.sections(for: scope, tasks: active, completed: [], today: today)
            }
        }
    }

    private func markingHasMore(_ sections: [TaskSection], sectionId: String, hasMore: Bool) -> [TaskSection] {
        guard hasMore else { return sections }
        return sections.map { sec in
            guard sec.id == sectionId else { return sec }
            var copy = sec
            copy.hasMore = true
            return copy
        }
    }

    func completed(_ db: Database, projectId: String?, limit: Int) throws -> [TodoTask] {
        let live = try liveProjectIds(db, smartOnly: false)
        var req = TaskRecord.filter(Column("deletedAt") == nil && Column("status") == 2 && live.contains(Column("projectId")))
        if let projectId { req = req.filter(Column("projectId") == projectId) }
        let recs = try req.order(Column("completedAt").desc).limit(limit).fetchAll(db)
        return try tasks(db, recs)
    }

    public func getCompletedTasks(projectId: String?, limit: Int = 100) async throws -> [TodoTask] {
        try await writer.read { db in try self.completed(db, projectId: projectId, limit: limit) }
    }

    public func searchTasks(text: String, activeOnly: Bool = false) async throws -> [TodoTask] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return try await writer.read { db in
            let live = try self.liveProjectIds(db, smartOnly: false)
            let pattern = "%\(q)%"
            var sql = """
                SELECT DISTINCT task.* FROM task
                LEFT JOIN checklistItem ci ON ci.taskId = task.id AND ci.deletedAt IS NULL
                WHERE task.deletedAt IS NULL AND (LOWER(task.title) LIKE ? OR LOWER(task.content) LIKE ? OR LOWER(task.tags) LIKE ? OR LOWER(ci.title) LIKE ?)
                """
            if activeOnly { sql += " AND task.status = 0" }
            sql += " ORDER BY task.status, task.updatedAt DESC LIMIT 200"
            let recs = try TaskRecord.fetchAll(db, sql: sql, arguments: [pattern, pattern, pattern, pattern]).filter { live.contains($0.projectId) }
            return try self.tasks(db, recs)
        }
    }

    public func getTask(id: String) async throws -> TodoTask {
        try await writer.read { db in try self.task(db, try self.taskRecord(db, id, includeDeleted: true)) }
    }

    public func smartCounts() async throws -> SmartCounts {
        let today = today
        return try await writer.read { db in
            let meId = try self.me(db).id
            let smart = try self.fetchActive(db, query: TaskQuery(), smartOnly: true)
            let all = try self.fetchActive(db, query: TaskQuery(), smartOnly: false)
            let inboxId = try self.inbox(db).id
            func count(_ f: (Schedule) -> Bool) -> Int { smart.filter { $0.schedule.map(f) ?? false }.count }
            let overdue = count { $0.lastDay < today }
            let completed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE deletedAt IS NULL AND status = 2") ?? 0
            let trash = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE deletedAt IS NOT NULL") ?? 0
            return SmartCounts(
                today: overdue + count { $0.occurs(on: today) },
                tomorrow: count { $0.occurs(on: today.adding(days: 1)) && $0.lastDay >= today },
                next7Days: overdue + count { $0.overlaps(today, today.adding(days: 6)) },
                inbox: all.filter { $0.projectId == inboxId }.count,
                assignedToMe: all.filter { $0.assigneeId == meId }.count,
                completed: completed, trash: trash)
        }
    }
}

// MARK: - Task commands

extension LocalDayDoAPI {
    public func createTask(_ input: CreateTaskInput) async throws -> TodoTask {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DayDoError.invalid("title is required") }
        let schedule = try input.schedule ?? Schedule.fromAPI(start: input.start, due: input.due, allDay: input.allDay, timeZone: input.timeZone)
        let reminders = try Self.reminderList(input.reminders, input.reminder) ?? []
        if !reminders.isEmpty && schedule == nil {
            throw DayDoError.invalid("reminders need a start/due date in the same call")
        }
        let rrule: String? = try {
            guard let r = input.repeat, !r.isEmpty else { return nil }
            guard schedule != nil else { throw DayDoError.invalid("repeat needs a start/due date") }
            return try Self.validateRepeat(r)
        }()
        let now = now()
        return try await writer.write { db in
            let pid = try input.projectId ?? self.inbox(db).id
            _ = try self.projectRecord(db, pid)
            if let a = input.assigneeId, try MemberRecord.fetchOne(db, key: a) == nil { throw DayDoError.notFound("member", a) }
            let first = try String.fetchOne(db, sql: "SELECT MIN(sortKey) FROM task WHERE projectId = ?", arguments: [pid])
            let tags = try self.normalizeTags(db, input.tags ?? [], now: now)
            var t = TaskRecord(id: ID.make(), projectId: pid, title: title, content: input.content ?? "",
                               priority: (input.priority ?? .none).rawValue, status: 0,
                               reminders: reminders, repeatRule: rrule, tags: tags, assigneeId: input.assigneeId,
                               sortKey: SortKey.before(first), completedAt: nil,
                               sourceRaw: input.sourceRaw, importNote: input.importNote,
                               createdAt: now, updatedAt: now)
            t.schedule = schedule
            try self.saveTask(db, t)
            var key: String?
            for s in input.subtasks ?? [] where !s.trimmingCharacters(in: .whitespaces).isEmpty {
                key = SortKey.after(key)
                let item = ChecklistItemRecord(id: ID.make(), taskId: t.id, title: s, status: 0, sortKey: key!, createdAt: now, updatedAt: now)
                try Outbox.save(item, entity: "checklistItem", id: item.id, in: db, now: now)
            }
            return try self.task(db, t)
        }
    }

    public func updateTask(_ input: UpdateTaskInput) async throws -> TodoTask {
        let now = now()
        return try await writer.write { db in
            var t = try self.taskRecord(db, input.taskId)
            if let pid = input.projectId { _ = try self.projectRecord(db, pid); t.projectId = pid }
            if let title = input.title {
                let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { throw DayDoError.invalid("title cannot be empty") }
                t.title = s
            }
            if let c = input.content { t.content = c }
            if let p = input.priority { t.priority = p.rawValue }

            // Schedule
            switch input.schedule {
            case let .set(s): t.schedule = s
            case .clear: t.schedule = nil
            case .unset:
                switch input.start {
                case .clear: t.schedule = nil
                case let .set(s) where s.isEmpty: t.schedule = nil
                case let .set(s):
                    t.schedule = try Schedule.fromAPI(start: s, due: input.due.value.flatMap { $0.isEmpty ? nil : $0 }, allDay: input.allDay, timeZone: input.timeZone ?? t.timeZone)
                case .unset:
                    if let due = input.due.value, !due.isEmpty, let cur = t.schedule {
                        let startStr = cur.isAllDay ? cur.startDay.description : cur.apiStart
                        t.schedule = try Schedule.fromAPI(start: startStr, due: due, allDay: input.allDay ?? cur.isAllDay, timeZone: input.timeZone ?? cur.timeZone)
                    } else if case .clear = input.due, var cur = t.schedule {
                        cur.endDay = nil
                        cur.endMinute = nil
                        t.schedule = cur
                    } else if let tz = input.timeZone, var cur = t.schedule {
                        guard TimeZone(identifier: tz) != nil else { throw ScheduleError.unknownTimeZone(tz) }
                        cur.timeZone = tz
                        t.schedule = cur
                    }
                }
            }
            let explicitReminders = try Self.reminderList(input.reminders, input.reminder)
            if let r = explicitReminders { t.reminders = r }
            switch input.repeat {
            case .unset: break
            case .clear: t.repeatRule = nil
            case let .set(s): t.repeatRule = s.isEmpty ? nil : try Self.validateRepeat(s)
            }
            if t.schedule == nil {
                if let r = explicitReminders, !r.isEmpty {
                    throw DayDoError.invalid("reminders need a start/due date")
                }
                t.reminders = []
                t.repeatRule = nil
            }
            if let tags = input.tags { t.tags = try self.normalizeTags(db, tags, now: now) }
            switch input.assigneeId {
            case .unset: break
            case .clear: t.assigneeId = nil
            case let .set(a):
                guard try MemberRecord.fetchOne(db, key: a) != nil else { throw DayDoError.notFound("member", a) }
                t.assigneeId = a
            }
            t.updatedAt = now
            try self.saveTask(db, t)
            if let subs = input.subtasks {
                for var item in try ChecklistItemRecord.filter(Column("taskId") == t.id && Column("deletedAt") == nil).fetchAll(db) {
                    item.deletedAt = now
                    item.updatedAt = now
                    try Outbox.save(item, entity: "checklistItem", id: item.id, in: db, now: now)
                }
                var key: String?
                for s in subs where !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    key = SortKey.after(key)
                    let item = ChecklistItemRecord(id: ID.make(), taskId: t.id, title: s, status: 0, sortKey: key!, createdAt: now, updatedAt: now)
                    try Outbox.save(item, entity: "checklistItem", id: item.id, in: db, now: now)
                }
            }
            return try self.task(db, t)
        }
    }

    /// Completing a repeating task records a completed copy and moves the
    /// original to its next occurrence (TickTick behaviour). When
    /// `ifUpdatedAt` is provided and no longer matches the stored `updatedAt`,
    /// returns the task unchanged (optimistic-concurrency guard).
    public func completeTask(id: String, ifUpdatedAt: EpochMillis?) async throws -> TodoTask {
        let now = now()
        return try await writer.write { db in
            var t = try self.taskRecord(db, id)
            if t.status == 2 { return try self.task(db, t) }
            if let expected = ifUpdatedAt, t.updatedAt != expected {
                return try self.task(db, t)
            }
            if let rule = t.repeatRule.flatMap(Recurrence.init(rrule:)), let s = t.schedule {
                let minutePart = s.startMinute.map(String.init) ?? ""
                let deterministicId = ID.v5(name: "\(t.id)|\(s.startDay.description)|\(minutePart)")
                let cloneId = try PurgedId.contains(entity: "task", id: deterministicId, in: db) ? ID.make() : deterministicId
                let existingClone = try TaskRecord.fetchOne(db, key: cloneId)
                let done: TaskRecord
                if var existing = existingClone, existing.deletedAt == nil {
                    if existing.status == 2 {
                        done = existing
                    } else {
                        existing.status = 2
                        existing.completedAt = now
                        existing.updatedAt = now
                        try self.saveTask(db, existing)
                        done = existing
                    }
                } else {
                    var copy = t
                    copy.id = cloneId
                    copy.status = 2
                    copy.completedAt = now
                    copy.repeatRule = nil
                    copy.createdAt = existingClone?.createdAt ?? now
                    copy.updatedAt = now
                    try self.saveTask(db, copy)
                    done = copy
                }
                let items = try ChecklistItemRecord.filter(Column("taskId") == t.id && Column("deletedAt") == nil).fetchAll(db)
                for var item in items {
                    let copyId = ID.v5(name: "\(cloneId)|\(item.id)")
                    let existingItem = try ChecklistItemRecord.fetchOne(db, key: copyId)
                    if existingItem == nil || existingItem?.deletedAt != nil {
                        let copy = ChecklistItemRecord(id: copyId, taskId: cloneId, title: item.title, status: item.status, sortKey: item.sortKey, createdAt: existingItem?.createdAt ?? now, updatedAt: now)
                        try Outbox.save(copy, entity: "checklistItem", id: copy.id, in: db, now: now)
                    }
                    if item.status != 0 {
                        item.status = 0
                        item.updatedAt = now
                        try Outbox.save(item, entity: "checklistItem", id: item.id, in: db, now: now)
                    }
                }
                var next = rule.next(after: s.startDay)
                // Skip occurrences already in the past when catching up.
                var guardCount = 0
                while next < self.today && guardCount < 1000 { next = rule.next(after: next); guardCount += 1 }
                t.schedule = s.moved(to: next)
                t.updatedAt = max(now, t.updatedAt + 1)
                try self.saveTask(db, t)
                return try self.task(db, done)
            }
            t.status = 2
            t.completedAt = now
            t.updatedAt = now
            try self.saveTask(db, t)
            return try self.task(db, t)
        }
    }

    public func uncompleteTask(id: String) async throws -> TodoTask {
        let now = now()
        return try await writer.write { db in
            var t = try self.taskRecord(db, id)
            t.status = 0
            t.completedAt = nil
            t.updatedAt = now
            try self.saveTask(db, t)
            return try self.task(db, t)
        }
    }

    public func deleteTask(id: String) async throws {
        let now = now()
        try await writer.write { db in
            var t = try self.taskRecord(db, id)
            t.deletedAt = now
            t.updatedAt = now
            try self.saveTask(db, t)
        }
    }

    public func restoreTask(id: String) async throws -> TodoTask {
        let now = now()
        return try await writer.write { db in
            var t = try self.taskRecord(db, id, includeDeleted: true)
            if try ProjectRecord.fetchOne(db, key: t.projectId)?.deletedAt != nil { t.projectId = try self.inbox(db).id }
            t.deletedAt = nil
            t.updatedAt = now
            try self.saveTask(db, t)
            return try self.task(db, t)
        }
    }

    public func purgeTask(id: String) async throws {
        let now = now()
        try await writer.write { db in
            let t = try self.taskRecord(db, id, includeDeleted: true)
            _ = try t.delete(db)
            try self.recordDelete(db, entity: "task", id: id)
            try PurgedId.record(entity: "task", id: id, purgedAt: now, in: db)
        }
    }

    public func moveTask(id: String, toProjectId: String) async throws -> TodoTask {
        var u = UpdateTaskInput(taskId: id)
        u.projectId = toProjectId
        return try await updateTask(u)
    }

    public func postponeOverdue(taskIds: [String]) async throws -> Int {
        guard !taskIds.isEmpty else { return 0 }
        let idSet = Set(taskIds)
        let now = now()
        let today = today
        return try await writer.write { db in
            var n = 0
            for var t in try TaskRecord.filter(Column("deletedAt") == nil && Column("status") == 0 && idSet.contains(Column("id"))).fetchAll(db) {
                guard let s = t.schedule?.localized(to: self.clock.timeZone()), s.lastDay < today else { continue }
                // Keep the shape; land the last day on today.
                t.schedule = s.moved(to: today.adding(days: -s.startDay.days(until: s.lastDay)))
                t.updatedAt = now
                try self.saveTask(db, t)
                n += 1
            }
            return n
        }
    }
}

// MARK: - Checklist, tags, attachments

extension LocalDayDoAPI {
    public func addChecklistItem(taskId: String, title: String) async throws -> ChecklistItem {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DayDoError.invalid("title is required") }
        let now = now()
        return try await writer.write { db in
            _ = try self.taskRecord(db, taskId)
            let last = try String.fetchOne(db, sql: "SELECT MAX(sortKey) FROM checklistItem WHERE taskId = ?", arguments: [taskId])
            let item = ChecklistItemRecord(id: ID.make(), taskId: taskId, title: title, status: 0, sortKey: SortKey.after(last), createdAt: now, updatedAt: now)
            try Outbox.save(item, entity: "checklistItem", id: item.id, in: db, now: now)
            return ChecklistItem(id: item.id, title: item.title, status: item.status, sortKey: item.sortKey)
        }
    }

    public func updateChecklistItem(id: String, title: String?, done: Bool?) async throws -> ChecklistItem {
        let now = now()
        return try await writer.write { db in
            guard var item = try ChecklistItemRecord.fetchOne(db, key: id), item.deletedAt == nil else { throw DayDoError.notFound("checklist_item", id) }
            if let title { item.title = title }
            if let done { item.status = done ? 1 : 0 }
            item.updatedAt = now
            try Outbox.save(item, entity: "checklistItem", id: item.id, in: db, now: now)
            return ChecklistItem(id: item.id, title: item.title, status: item.status, sortKey: item.sortKey)
        }
    }

    public func deleteChecklistItem(id: String) async throws {
        let now = now()
        try await writer.write { db in
            guard var item = try ChecklistItemRecord.fetchOne(db, key: id), item.deletedAt == nil else { throw DayDoError.notFound("checklist_item", id) }
            item.deletedAt = now
            item.updatedAt = now
            try Outbox.save(item, entity: "checklistItem", id: item.id, in: db, now: now)
        }
    }

    public func listTags() async throws -> [Tag] {
        try await writer.read { db in
            let recs = try TagRecord.filter(Column("deletedAt") == nil).order(Column("sortKey")).fetchAll(db)
            let tasks = try TaskRecord.filter(Column("deletedAt") == nil && Column("status") == 0).fetchAll(db)
            var counts: [String: Int] = [:]
            for t in tasks { for tag in t.tags { counts[tag, default: 0] += 1 } }
            return recs.map { Tag(name: $0.name, label: $0.label, color: $0.color, activeCount: counts[$0.name] ?? 0) }
        }
    }

    public func createTag(label: String, color: String?) async throws -> Tag {
        let now = now()
        return try await writer.write { db in
            guard let name = try self.normalizeTags(db, [label], now: now).first, var rec = try TagRecord.fetchOne(db, key: name) else {
                throw DayDoError.invalid("Tag label is required")
            }
            if let color {
                rec.color = color
                rec.updatedAt = now
                try Outbox.save(rec, entity: "tag", id: name, key: ["name": name], in: db, now: now)
            }
            return Tag(name: rec.name, label: rec.label, color: rec.color, activeCount: 0)
        }
    }

    public func updateTag(name: String, label: String?, color: String?) async throws -> Tag {
        let now = now()
        return try await writer.write { db in
            guard var rec = try TagRecord.fetchOne(db, key: name.lowercased()), rec.deletedAt == nil else { throw DayDoError.notFound("tag", name) }
            if let label { rec.label = label }
            if let color { rec.color = color }
            rec.updatedAt = now
            try Outbox.save(rec, entity: "tag", id: rec.name, key: ["name": rec.name], in: db, now: now)
            return Tag(name: rec.name, label: rec.label, color: rec.color, activeCount: 0)
        }
    }

    public func deleteTag(name: String) async throws {
        let now = now()
        let key = name.lowercased()
        try await writer.write { db in
            guard var rec = try TagRecord.fetchOne(db, key: key), rec.deletedAt == nil else { throw DayDoError.notFound("tag", name) }
            for var t in try TaskRecord.fetchAll(db) where t.tags.contains(key) {
                t.tags.removeAll { $0 == key }
                t.updatedAt = now
                try self.saveTask(db, t)
            }
            rec.deletedAt = now
            rec.updatedAt = now
            try Outbox.save(rec, entity: "tag", id: key, key: ["name": key], in: db, now: now)
        }
    }

    public func uploadAttachment(taskId: String, fileName: String, data: Data, mimeType: String, originalPath: String?) async throws -> Attachment {
        let id = ID.make()
        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
        let rel = "\(id)/\(safeName)"
        let url = attachmentsDirectory.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let now = now()
        do {
            return try await writer.write { db in
                _ = try self.taskRecord(db, taskId)
                let a = AttachmentRecord(id: id, taskId: taskId, fileName: safeName, size: Int64(data.count), mimeType: mimeType,
                                         localPath: rel, originalPath: originalPath, createdAt: now, updatedAt: now)
                try Outbox.save(a, entity: "attachment", id: id, in: db, now: now)
                return Attachment(id: id, fileName: safeName, size: a.size, mimeType: mimeType, localPath: rel, originalPath: originalPath, createdAt: now)
            }
        } catch {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
    }

    public func deleteAttachment(id: String) async throws {
        let now = now()
        let rel: String? = try await writer.write { db in
            guard var a = try AttachmentRecord.fetchOne(db, key: id), a.deletedAt == nil else { throw DayDoError.notFound("attachment", id) }
            a.deletedAt = now
            a.updatedAt = now
            try Outbox.save(a, entity: "attachment", id: id, in: db, now: now)
            return a.localPath
        }
        if let rel { try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(rel).deletingLastPathComponent()) }
    }

    public func attachmentURL(_ attachment: Attachment) -> URL? {
        attachment.localPath.map { attachmentsDirectory.appendingPathComponent($0) }
    }

    public func upcomingReminders(limit: Int = 60) async throws -> [ScheduledReminder] {
        let now = clock.now()
        return try await writer.read { db in
            let live = try self.liveProjectIds(db, smartOnly: false)
            let recs = try TaskRecord.filter(Column("deletedAt") == nil && Column("status") == 0 && Column("startDay") != nil).fetchAll(db)
            var out: [ScheduledReminder] = []
            for t in recs where live.contains(t.projectId) && !t.reminders.isEmpty {
                guard let s = t.schedule else { continue }
                for trig in t.reminders {
                    guard let r = Reminder(trigger: trig) else { continue }
                    let fire = r.fireDate(for: s)
                    guard fire > now else { continue }
                    let body = s.isAllDay ? "全天" : DateText.range(s)
                    out.append(ScheduledReminder(id: "\(t.id)|\(trig)", taskId: t.id, title: t.title, body: body, fireDate: fire))
                }
            }
            return Array(out.sorted { $0.fireDate < $1.fireDate }.prefix(limit))
        }
    }

    /// Outbox entries not yet pushed (phase 2 sync).
    public func pendingChanges(limit: Int = 500) async throws -> [ChangeRecord] {
        try await writer.read { db in
            try ChangeRecord.filter(Column("ackedAt") == nil).order(Column("seq")).limit(limit).fetchAll(db)
        }
    }
}
