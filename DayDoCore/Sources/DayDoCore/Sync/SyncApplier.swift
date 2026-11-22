import Foundation
import GRDB

/// Staged remote row waiting for a missing foreign-key parent.
struct SyncStagingRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "syncStaging"
    var entity: String
    var entityId: String
    var row: String
    var clocks: String
    var serverSeq: Int64
    var updatedAt: EpochMillis
}

/// Result of applying a single remote row or batch.
struct ApplyOutcome: Sendable {
    var didChangeLocalData: Bool
    var staged: Bool

    static let unchanged = ApplyOutcome(didChangeLocalData: false, staged: false)
    static let changed = ApplyOutcome(didChangeLocalData: true, staged: false)
    static let deferred = ApplyOutcome(didChangeLocalData: false, staged: true)
}

/// Pure SQLite applier for remote sync rows (both pull and push results).
/// Never writes to `change` (never uses `Outbox.save`).
enum SyncApplier {
    static let scheduleFields: Set<String> = [
        "startDay", "startMinute", "endDay", "endMinute", "timeZone",
    ]
    static let scheduleClockKey = "schedule"

    private struct FieldSpec {
        let name: String
        let nonSynced: Bool
        let defaultValue: SyncJSONValue?

        init(_ name: String, nonSynced: Bool = false, default defaultValue: SyncJSONValue? = nil) {
            self.name = name
            self.nonSynced = nonSynced
            self.defaultValue = defaultValue
        }
    }

    private struct EntitySpec {
        let name: String
        let fields: [FieldSpec]
        let nonSyncedSet: Set<String>

        init(_ name: String, _ fields: [FieldSpec]) {
            self.name = name
            self.fields = fields
            self.nonSyncedSet = Set(fields.filter(\.nonSynced).map(\.name))
        }
    }

    private static let specs: [String: EntitySpec] = {
        let list: [EntitySpec] = [
            EntitySpec("member", [
                FieldSpec("id"),
                FieldSpec("name", default: .string("")),
                FieldSpec("initial", default: .string("")),
                FieldSpec("color", default: .string("")),
                FieldSpec("isMe", nonSynced: true, default: .bool(false)),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("folder", [
                FieldSpec("id"),
                FieldSpec("name", default: .string("")),
                FieldSpec("sortKey", default: .string("")),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("project", [
                FieldSpec("id"),
                FieldSpec("name", default: .string("")),
                FieldSpec("color"),
                FieldSpec("icon"),
                FieldSpec("folderId"),
                FieldSpec("viewMode", default: .string("list")),
                FieldSpec("kind", default: .string("TASK")),
                FieldSpec("isInbox", default: .bool(false)),
                FieldSpec("ownerId", default: .string("")),
                FieldSpec("sortKey", default: .string("")),
                FieldSpec("showInSmart", default: .string("all")),
                FieldSpec("notifyMode", default: .string("all")),
                FieldSpec("archivedAt"),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("projectMember", [
                FieldSpec("projectId"),
                FieldSpec("memberId"),
                FieldSpec("role", default: .string("viewer")),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("projectInvite", [
                FieldSpec("id"),
                FieldSpec("projectId", default: .string("")),
                FieldSpec("email", default: .string("")),
                FieldSpec("role", default: .string("viewer")),
                FieldSpec("status", default: .string("pending")),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("task", [
                FieldSpec("id"),
                FieldSpec("projectId", default: .string("")),
                FieldSpec("title", default: .string("")),
                FieldSpec("content", default: .string("")),
                FieldSpec("priority", default: .int(0)),
                FieldSpec("status", default: .int(0)),
                FieldSpec("startDay"),
                FieldSpec("startMinute"),
                FieldSpec("endDay"),
                FieldSpec("endMinute"),
                FieldSpec("timeZone"),
                FieldSpec("reminders", default: .array([])),
                FieldSpec("repeatRule"),
                FieldSpec("tags", default: .array([])),
                FieldSpec("assigneeId"),
                FieldSpec("countdown", default: .bool(false)),
                FieldSpec("sortKey", default: .string("")),
                FieldSpec("completedAt"),
                FieldSpec("sourceRaw"),
                FieldSpec("importNote"),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("checklistItem", [
                FieldSpec("id"),
                FieldSpec("taskId", default: .string("")),
                FieldSpec("title", default: .string("")),
                FieldSpec("status", default: .int(0)),
                FieldSpec("sortKey", default: .string("")),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("tag", [
                FieldSpec("name"),
                FieldSpec("label", default: .string("")),
                FieldSpec("color"),
                FieldSpec("sortKey", default: .string("")),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("attachment", [
                FieldSpec("id"),
                FieldSpec("taskId", default: .string("")),
                FieldSpec("fileName", default: .string("")),
                FieldSpec("size", default: .int(0)),
                FieldSpec("mimeType", default: .string("")),
                FieldSpec("localPath", nonSynced: true),
                FieldSpec("originalPath", nonSynced: true),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
            EntitySpec("comment", [
                FieldSpec("id"),
                FieldSpec("taskId", default: .string("")),
                FieldSpec("authorId", default: .string("")),
                FieldSpec("body", default: .string("")),
                FieldSpec("createdAt", default: .int(0)),
                FieldSpec("updatedAt", default: .int(0)),
                FieldSpec("deletedAt"),
            ]),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()

    static func isKnownEntity(_ entity: String) -> Bool {
        specs[entity] != nil
    }

    /// Configured `FieldSpec` names per synced entity (exposed internally for schema guard tests).
    static var specFieldNamesByEntity: [String: [String]] {
        specs.mapValues { $0.fields.map(\.name) }
    }

    static func entityId(for entity: String, row: [String: SyncJSONValue]) -> String? {
        switch entity {
        case "projectMember":
            guard let pid = row["projectId"]?.stringValue,
                  let mid = row["memberId"]?.stringValue,
                  !pid.isEmpty, !mid.isEmpty else { return nil }
            return "\(pid):\(mid)"
        case "tag":
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            return name
        default:
            guard let id = row["id"]?.stringValue, !id.isEmpty else { return nil }
            return id
        }
    }

    /// Applies a single upsert or tombstone row. Returns `.deferred` if a required FK parent is missing.
    static func applyRow(
        entity: String,
        entityId: String,
        row: [String: SyncJSONValue],
        clocks: [String: String],
        in db: Database
    ) throws -> ApplyOutcome {
        guard let spec = specs[entity] else {
            return .unchanged
        }

        if let purgedAt = row["purgedAt"]?.int64Value {
            let deleted = try applyTombstone(entity: entity, entityId: entityId, purgedAt: purgedAt, in: db)
            return deleted ? .changed : .unchanged
        }

        let unackedOps = try ChangeRecord
            .filter(Column("entity") == entity && Column("entityId") == entityId && Column("ackedAt") == nil)
            .order(Column("seq"))
            .fetchAll(db)

        // Do not resurrect a row that has a pending local hard delete.
        if unackedOps.contains(where: { $0.op == "delete" }) {
            return .unchanged
        }

        let existingDict = try fetchLocalDict(entity: entity, entityId: entityId, in: db)
        let meMemberId: String? = (entity == "project")
            ? try String.fetchOne(db, sql: "SELECT id FROM member WHERE isMe = 1 AND deletedAt IS NULL")
            : nil
        let mergedDict = mergeRowFields(
            spec: spec,
            existingDict: existingDict,
            serverRow: row,
            clocks: clocks,
            unackedOps: unackedOps,
            meMemberId: meMemberId
        )

        if try hasMissingParent(entity: entity, row: mergedDict, in: db) {
            return .deferred
        }

        let changed = try saveMergedDict(entity: entity, existingDict: existingDict, mergedDict: mergedDict, in: db)
        return changed ? .changed : .unchanged
    }

    /// Hard-deletes an entity locally and records `purgedId` without writing to `change`.
    static func applyTombstone(
        entity: String,
        entityId: String,
        purgedAt: EpochMillis,
        in db: Database
    ) throws -> Bool {
        try deleteStagedSubtree(entity: entity, entityId: entityId, in: db)
        let deleted = try deleteEntityRow(entity: entity, entityId: entityId, in: db)
        try PurgedId.record(entity: entity, id: entityId, purgedAt: purgedAt, in: db)
        return deleted
    }

    /// Hard-deletes an entity locally with children, drops unacked ops, and does NOT record `purgedId`.
    static func applyGone(
        entity: String,
        entityId: String,
        in db: Database
    ) throws -> Bool {
        try deleteStagedSubtree(entity: entity, entityId: entityId, in: db)

        var cascadeTargets: [(String, String)] = [(entity, entityId)]
        if entity == "task" {
            cascadeTargets.append(contentsOf: try taskChildTargets(taskId: entityId, in: db))
        } else if entity == "project" {
            cascadeTargets.append(contentsOf: try projectChildTargets(projectId: entityId, in: db))
        }

        let deleted = try deleteEntityRow(entity: entity, entityId: entityId, in: db)
        for (targetEntity, targetId) in cascadeTargets {
            try db.execute(
                sql: "DELETE FROM change WHERE entity = ? AND entityId = ? AND ackedAt IS NULL",
                arguments: [targetEntity, targetId]
            )
        }
        return deleted
    }

    static func stageRow(
        entity: String,
        entityId: String,
        row: [String: SyncJSONValue],
        clocks: [String: String],
        serverSeq: Int64,
        now: EpochMillis,
        in db: Database
    ) throws {
        let rowData = try Outbox.encoder.encode(row)
        let clocksData = try Outbox.encoder.encode(clocks)
        let record = SyncStagingRecord(
            entity: entity,
            entityId: entityId,
            row: String(data: rowData, encoding: .utf8)!,
            clocks: String(data: clocksData, encoding: .utf8)!,
            serverSeq: serverSeq,
            updatedAt: now
        )
        try record.save(db)
    }

    static func deleteStagedRow(entity: String, entityId: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM syncStaging WHERE entity = ? AND entityId = ?",
            arguments: [entity, entityId]
        )
    }

    static func fetchStagedRows(in db: Database) throws -> [SyncStagingRecord] {
        try SyncStagingRecord.order(Column("serverSeq"), Column("updatedAt")).fetchAll(db)
    }

    /// Retries any previously staged rows whose parents may now exist.
    static func retryStagedRows(in db: Database) throws -> Bool {
        var didChange = false
        let decoder = JSONDecoder()
        while true {
            let staged = try fetchStagedRows(in: db)
            if staged.isEmpty { break }
            var appliedInPass = 0
            for item in staged {
                let row = try decoder.decode([String: SyncJSONValue].self, from: Data(item.row.utf8))
                let clocks = try decoder.decode([String: String].self, from: Data(item.clocks.utf8))
                let outcome = try applyRow(
                    entity: item.entity,
                    entityId: item.entityId,
                    row: row,
                    clocks: clocks,
                    in: db
                )
                if !outcome.staged {
                    try deleteStagedRow(entity: item.entity, entityId: item.entityId, in: db)
                    appliedInPass += 1
                    if outcome.didChangeLocalData {
                        didChange = true
                    }
                }
            }
            if appliedInPass == 0 {
                break
            }
        }
        return didChange
    }

    // MARK: - Field Merging

    private static func mergeRowFields(
        spec: EntitySpec,
        existingDict: [String: SyncJSONValue]?,
        serverRow: [String: SyncJSONValue],
        clocks: [String: String],
        unackedOps: [ChangeRecord],
        meMemberId: String? = nil
    ) -> [String: SyncJSONValue] {
        var maxLocalHLCByField: [String: HLC] = [:]
        for op in unackedOps where op.op == "upsert" {
            guard let hlcStr = op.hlc, let hlc = HLC(hlcStr) else { continue }
            for field in op.fields {
                if let prev = maxLocalHLCByField[field] {
                    if hlc > prev { maxLocalHLCByField[field] = hlc }
                } else {
                    maxLocalHLCByField[field] = hlc
                }
            }
        }

        var keepLocalSchedule = false
        if spec.name == "task", existingDict != nil {
            let maxScheduleLocal = scheduleFields.compactMap { maxLocalHLCByField[$0] }.max()
            let serverScheduleClock = clocks[scheduleClockKey].flatMap(HLC.init)
            keepLocalSchedule = shouldKeepLocal(localHLC: maxScheduleLocal, serverClock: serverScheduleClock)
        }

        var keepLocalFolderId = false
        if spec.name == "project" {
            let rowOwnerId = serverRow["ownerId"]?.stringValue ?? existingDict?["ownerId"]?.stringValue
            keepLocalFolderId = (meMemberId == nil || rowOwnerId != meMemberId)
        }

        var merged: [String: SyncJSONValue] = [:]
        for fieldSpec in spec.fields {
            let name = fieldSpec.name
            let chosen: SyncJSONValue?

            if fieldSpec.nonSynced {
                if let existingDict {
                    chosen = existingDict[name]
                } else if spec.name == "member", name == "isMe" {
                    chosen = serverRow[name] ?? .bool(false)
                } else {
                    chosen = nil
                }
            } else if spec.name == "project", name == "folderId", keepLocalFolderId {
                chosen = existingDict?[name]
            } else if spec.name == "task", scheduleFields.contains(name) {
                if keepLocalSchedule {
                    chosen = existingDict?[name]
                } else {
                    chosen = nonNullValue(serverRow[name])
                }
            } else {
                let localHLC = maxLocalHLCByField[name]
                let serverClock = clocks[name].flatMap(HLC.init)
                if existingDict != nil && shouldKeepLocal(localHLC: localHLC, serverClock: serverClock) {
                    chosen = existingDict?[name]
                } else if let serverVal = nonNullValue(serverRow[name]) {
                    chosen = serverVal
                } else if existingDict == nil {
                    chosen = fieldSpec.defaultValue
                } else if serverRow[name] == nil, let defaultValue = fieldSpec.defaultValue {
                    chosen = existingDict?[name] ?? defaultValue
                } else {
                    chosen = nil
                }
            }

            if let chosen, chosen != .null {
                merged[name] = chosen
            }
        }
        return merged
    }

    private static func shouldKeepLocal(localHLC: HLC?, serverClock: HLC?) -> Bool {
        guard let localHLC else { return false }
        guard let serverClock else { return true }
        return localHLC > serverClock
    }

    private static func nonNullValue(_ value: SyncJSONValue?) -> SyncJSONValue? {
        guard let value, value != .null else { return nil }
        return value
    }

    // MARK: - FK Parent Checks

    private static func hasMissingParent(
        entity: String,
        row: [String: SyncJSONValue],
        in db: Database
    ) throws -> Bool {
        switch entity {
        case "project":
            if let folderId = row["folderId"]?.stringValue {
                return !(try rowExists(table: "folder", column: "id", value: folderId, in: db))
            }
            return false
        case "projectMember":
            guard let projectId = row["projectId"]?.stringValue,
                  let memberId = row["memberId"]?.stringValue else { return true }
            let hasProject = try rowExists(table: "project", column: "id", value: projectId, in: db)
            let hasMember = try rowExists(table: "member", column: "id", value: memberId, in: db)
            return !hasProject || !hasMember
        case "projectInvite", "task":
            guard let projectId = row["projectId"]?.stringValue else { return true }
            return !(try rowExists(table: "project", column: "id", value: projectId, in: db))
        case "checklistItem", "attachment", "comment":
            guard let taskId = row["taskId"]?.stringValue else { return true }
            return !(try rowExists(table: "task", column: "id", value: taskId, in: db))
        default:
            return false
        }
    }

    private static func rowExists(table: String, column: String, value: String, in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM \"\(table)\" WHERE \"\(column)\" = ? LIMIT 1", arguments: [value]) != nil
    }

    // MARK: - Typed GRDB Persistence

    private static func fetchLocalDict(entity: String, entityId: String, in db: Database) throws -> [String: SyncJSONValue]? {
        switch entity {
        case "member": return try encodeRecord(MemberRecord.fetchOne(db, key: entityId))
        case "folder": return try encodeRecord(FolderRecord.fetchOne(db, key: entityId))
        case "project": return try encodeRecord(ProjectRecord.fetchOne(db, key: entityId))
        case "projectMember":
            guard let (pid, mid) = parseProjectMemberId(entityId) else { return nil }
            return try encodeRecord(ProjectMemberRecord.fetchOne(db, key: ["projectId": pid, "memberId": mid]))
        case "projectInvite": return try encodeRecord(ProjectInviteRecord.fetchOne(db, key: entityId))
        case "task": return try encodeRecord(TaskRecord.fetchOne(db, key: entityId))
        case "checklistItem": return try encodeRecord(ChecklistItemRecord.fetchOne(db, key: entityId))
        case "tag": return try encodeRecord(TagRecord.fetchOne(db, key: ["name": entityId]))
        case "attachment": return try encodeRecord(AttachmentRecord.fetchOne(db, key: entityId))
        case "comment": return try encodeRecord(CommentRecord.fetchOne(db, key: entityId))
        default: return nil
        }
    }

    private static func saveMergedDict(
        entity: String,
        existingDict: [String: SyncJSONValue]?,
        mergedDict: [String: SyncJSONValue],
        in db: Database
    ) throws -> Bool {
        if let existingDict, existingDict == mergedDict {
            return false
        }
        let data = try Outbox.encoder.encode(mergedDict)
        let decoder = JSONDecoder()

        switch entity {
        case "member":
            let rec = try decoder.decode(MemberRecord.self, from: data)
            try rec.save(db)
        case "folder":
            let rec = try decoder.decode(FolderRecord.self, from: data)
            try rec.save(db)
        case "project":
            let rec = try decoder.decode(ProjectRecord.self, from: data)
            try rec.save(db)
        case "projectMember":
            let rec = try decoder.decode(ProjectMemberRecord.self, from: data)
            try rec.save(db)
        case "projectInvite":
            let rec = try decoder.decode(ProjectInviteRecord.self, from: data)
            try rec.save(db)
        case "task":
            let rec = try decoder.decode(TaskRecord.self, from: data)
            try rec.save(db)
        case "checklistItem":
            let rec = try decoder.decode(ChecklistItemRecord.self, from: data)
            try rec.save(db)
        case "tag":
            let rec = try decoder.decode(TagRecord.self, from: data)
            try rec.save(db)
        case "attachment":
            var rec = try decoder.decode(AttachmentRecord.self, from: data)
            if let existing = try AttachmentRecord.fetchOne(db, key: rec.id) {
                rec.fileUploadedAt = existing.fileUploadedAt
                rec.fileUploadFailed = existing.fileUploadFailed
            }
            try rec.save(db)
        case "comment":
            let rec = try decoder.decode(CommentRecord.self, from: data)
            try rec.save(db)
        default:
            return false
        }
        return true
    }

    private static func encodeRecord<R: Encodable>(_ record: R?) throws -> [String: SyncJSONValue]? {
        guard let record else { return nil }
        let data = try Outbox.encoder.encode(record)
        return try JSONDecoder().decode([String: SyncJSONValue].self, from: data)
    }

    private static func deleteEntityRow(entity: String, entityId: String, in db: Database) throws -> Bool {
        switch entity {
        case "projectMember":
            guard let (pid, mid) = parseProjectMemberId(entityId) else { return false }
            try db.execute(
                sql: "DELETE FROM projectMember WHERE projectId = ? AND memberId = ?",
                arguments: [pid, mid]
            )
        case "tag":
            try db.execute(sql: "DELETE FROM tag WHERE name = ?", arguments: [entityId])
        case "member", "folder", "project", "projectInvite", "task", "checklistItem", "attachment", "comment":
            try db.execute(sql: "DELETE FROM \"\(entity)\" WHERE id = ?", arguments: [entityId])
        default:
            return false
        }
        return db.changesCount > 0
    }

    private static func parseProjectMemberId(_ entityId: String) -> (String, String)? {
        let parts = entityId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func taskChildTargets(taskId: String, in db: Database) throws -> [(String, String)] {
        var targets: [(String, String)] = []
        for childEntity in ["checklistItem", "attachment", "comment"] {
            let ids = try String.fetchAll(db, sql: "SELECT id FROM \"\(childEntity)\" WHERE taskId = ?", arguments: [taskId])
            targets.append(contentsOf: ids.map { (childEntity, $0) })
        }
        return targets
    }

    private static func projectChildTargets(projectId: String, in db: Database) throws -> [(String, String)] {
        var targets: [(String, String)] = []
        let taskIds = try String.fetchAll(db, sql: "SELECT id FROM task WHERE projectId = ?", arguments: [projectId])
        for tid in taskIds {
            targets.append(("task", tid))
            targets.append(contentsOf: try taskChildTargets(taskId: tid, in: db))
        }
        let memberIds = try String.fetchAll(db, sql: "SELECT memberId FROM projectMember WHERE projectId = ?", arguments: [projectId])
        targets.append(contentsOf: memberIds.map { ("projectMember", "\(projectId):\($0)") })
        let inviteIds = try String.fetchAll(db, sql: "SELECT id FROM projectInvite WHERE projectId = ?", arguments: [projectId])
        targets.append(contentsOf: inviteIds.map { ("projectInvite", $0) })
        return targets
    }

    private static func deleteStagedSubtree(entity: String, entityId: String, in db: Database) throws {
        try deleteStagedRow(entity: entity, entityId: entityId, in: db)
        if entity == "task" {
            try db.execute(
                sql: "DELETE FROM syncStaging WHERE entity IN ('checklistItem', 'attachment', 'comment') AND json_extract(row, '$.taskId') = ?",
                arguments: [entityId]
            )
        } else if entity == "project" {
            let stagedTaskIds = try String.fetchAll(
                db,
                sql: "SELECT entityId FROM syncStaging WHERE entity = 'task' AND json_extract(row, '$.projectId') = ?",
                arguments: [entityId]
            )
            for tid in stagedTaskIds {
                try db.execute(
                    sql: "DELETE FROM syncStaging WHERE entity IN ('checklistItem', 'attachment', 'comment') AND json_extract(row, '$.taskId') = ?",
                    arguments: [tid]
                )
            }
            try db.execute(
                sql: "DELETE FROM syncStaging WHERE entity IN ('task', 'projectMember', 'projectInvite') AND json_extract(row, '$.projectId') = ?",
                arguments: [entityId]
            )
        } else if entity == "member" {
            try db.execute(
                sql: "DELETE FROM syncStaging WHERE entity = 'projectMember' AND json_extract(row, '$.memberId') = ?",
                arguments: [entityId]
            )
        }
    }
}
