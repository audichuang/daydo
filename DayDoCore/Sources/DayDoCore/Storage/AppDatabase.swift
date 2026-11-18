import Foundation
import GRDB
import SQLite3

/// Owns the SQLite file and its schema.
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private init(unchecked writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// File-backed read-write database with persistent WAL mode and file
    /// coordination so extension processes can safely open read-only readers.
    static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<AppDatabase, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinatorError) { coordinatedURL in
            result = Result {
                var config = Configuration()
                config.foreignKeysEnabled = true
                config.busyMode = .timeout(5)
                config.observesSuspensionNotifications = true
                config.prepareDatabase { db in
                    // Keep -wal and -shm files around on close so read-only
                    // extension processes can always attach to the WAL database.
                    if db.configuration.readonly == false {
                        var flag: CInt = 1
                        let code = withUnsafeMutablePointer(to: &flag) { flagP in
                            sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagP)
                        }
                        guard code == SQLITE_OK else {
                            throw DatabaseError(resultCode: ResultCode(rawValue: code))
                        }
                    }
                }
                let pool = try DatabasePool(path: coordinatedURL.path, configuration: config)
                return try AppDatabase(pool)
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try result!.get()
    }

    /// Opens an existing, fully migrated database in read-only mode without
    /// creating files or running migrations.
    static func openReadOnly(at url: URL) throws -> AppDatabase {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.databaseNotFound(url)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<AppDatabase, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            result = Result {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                    throw StorageError.databaseNotFound(coordinatedURL)
                }
                var config = Configuration()
                config.readonly = true
                config.foreignKeysEnabled = true
                config.busyMode = .timeout(5)
                let pool = try DatabasePool(path: coordinatedURL.path, configuration: config)
                try pool.read { db in
                    if try Self.migrator.hasBeenSuperseded(db) {
                        throw StorageError.databaseSuperseded(coordinatedURL)
                    }
                    guard try Self.migrator.hasCompletedMigrations(db) else {
                        throw StorageError.migrationsIncomplete(coordinatedURL)
                    }
                }
                return AppDatabase(unchecked: pool)
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try result!.get()
    }

    static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(try DatabaseQueue(configuration: config))
    }

    static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            func stamps(_ t: TableDefinition) {
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deletedAt", .integer)
            }
            try db.create(table: "member") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("initial", .text).notNull()
                t.column("color", .text).notNull()
                t.column("isMe", .boolean).notNull().defaults(to: false)
                stamps(t)
            }
            try db.create(table: "folder") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sortKey", .text).notNull()
                stamps(t)
            }
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("icon", .text)
                t.column("folderId", .text).references("folder", onDelete: .setNull)
                t.column("viewMode", .text).notNull().defaults(to: "list")
                t.column("kind", .text).notNull().defaults(to: "TASK")
                t.column("isInbox", .boolean).notNull().defaults(to: false)
                t.column("ownerId", .text).notNull()
                t.column("sortKey", .text).notNull()
                t.column("showInSmart", .text).notNull().defaults(to: "all")
                t.column("notifyMode", .text).notNull().defaults(to: "all")
                t.column("archivedAt", .integer)
                stamps(t)
            }
            try db.create(table: "projectMember") { t in
                t.column("projectId", .text).notNull().references("project", onDelete: .cascade)
                t.column("memberId", .text).notNull().references("member", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.primaryKey(["projectId", "memberId"])
                stamps(t)
            }
            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull().references("project", onDelete: .cascade).indexed()
                t.column("title", .text).notNull()
                t.column("content", .text).notNull().defaults(to: "")
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("status", .integer).notNull().defaults(to: 0)
                t.column("startDay", .text).indexed()
                t.column("startMinute", .integer)
                t.column("endDay", .text)
                t.column("endMinute", .integer)
                t.column("timeZone", .text)
                t.column("reminders", .jsonText).notNull().defaults(to: "[]")
                t.column("repeatRule", .text)
                t.column("tags", .jsonText).notNull().defaults(to: "[]")
                t.column("assigneeId", .text)
                t.column("sortKey", .text).notNull()
                t.column("completedAt", .integer)
                t.column("sourceRaw", .text)
                t.column("importNote", .text)
                stamps(t)
            }
            try db.create(table: "checklistItem") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().references("task", onDelete: .cascade).indexed()
                t.column("title", .text).notNull()
                t.column("status", .integer).notNull().defaults(to: 0)
                t.column("sortKey", .text).notNull()
                stamps(t)
            }
            try db.create(table: "tag") { t in
                t.primaryKey("name", .text)
                t.column("label", .text).notNull()
                t.column("color", .text)
                t.column("sortKey", .text).notNull()
                stamps(t)
            }
            try db.create(table: "attachment") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().references("task", onDelete: .cascade).indexed()
                t.column("fileName", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mimeType", .text).notNull()
                t.column("localPath", .text)
                t.column("originalPath", .text)
                stamps(t)
            }
            try db.create(table: "comment") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().references("task", onDelete: .cascade).indexed()
                t.column("authorId", .text).notNull()
                t.column("body", .text).notNull()
                stamps(t)
            }
            try db.create(table: "change") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("entity", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("op", .text).notNull()
                t.column("fields", .jsonText).notNull()
                t.column("row", .jsonText).notNull()
                t.column("at", .integer).notNull()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.create(table: "projectInvite") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull().references("project", onDelete: .cascade).indexed()
                t.column("email", .text).notNull()
                t.column("role", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deletedAt", .integer)
            }
        }
        m.registerMigration("v3") { db in
            try db.alter(table: "change") { t in
                t.add(column: "opId", .text)
                t.add(column: "hlc", .text)
                t.add(column: "ackedAt", .integer)
                t.add(column: "result", .text)
            }
            try db.create(index: "change_opId_unique", on: "change", columns: ["opId"], unique: true)

            let deviceId = try HLC.ensureDeviceId(in: db)
            var lastHLC = try HLC.loadLast(in: db)
            let rows = try Row.fetchAll(db, sql: "SELECT seq, at FROM change ORDER BY seq ASC")
            for row in rows {
                let seq: Int64 = row["seq"]
                let at: EpochMillis = row["at"]
                let hlc = HLC.next(now: at, last: lastHLC, deviceId: deviceId)
                lastHLC = hlc
                try db.execute(
                    sql: "UPDATE change SET opId = ?, hlc = ? WHERE seq = ?",
                    arguments: [ID.make(), hlc.description, seq]
                )
            }
            if let lastHLC {
                try HLC.saveLast(lastHLC, in: db)
            }
        }
        m.registerMigration("v4") { db in
            try db.create(table: "purgedId") { t in
                t.column("entity", .text).notNull()
                t.column("id", .text).notNull()
                t.column("purgedAt", .integer).notNull()
                t.primaryKey(["entity", "id"])
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO purgedId (entity, id, purgedAt)
                SELECT entity, entityId, MAX(at)
                FROM change
                WHERE op = 'delete'
                GROUP BY entity, entityId
                """)
        }
        m.registerMigration("v5") { db in
            try db.create(table: "syncStaging") { t in
                t.column("entity", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("row", .jsonText).notNull()
                t.column("clocks", .jsonText).notNull()
                t.column("serverSeq", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.primaryKey(["entity", "entityId"])
            }
        }
        m.registerMigration("v6") { db in
            try db.create(table: "projectMembership") { t in
                t.column("projectId", .text).primaryKey()
                t.column("scope", .text).notNull()
                t.column("role", .text).notNull()
                t.column("needsBackfill", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "memberUser") { t in
                t.column("memberId", .text).primaryKey()
                t.column("userId", .text).notNull()
            }
        }
        m.registerMigration("v7") { db in
            try db.alter(table: "memberUser") { t in
                t.add(column: "avatarUrl", .text)
            }
        }
        m.registerMigration("v8") { db in
            try db.alter(table: "attachment") { t in
                t.add(column: "fileUploadedAt", .integer)
                t.add(column: "fileUploadFailed", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v9") { db in
            try db.alter(table: "task") { t in
                t.add(column: "countdown", .boolean).notNull().defaults(to: false)
            }
        }
        return m
    }
}

// MARK: - Change tracking

enum Outbox {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Inserts or updates `record` and appends an outbox entry listing the
    /// fields that actually changed. No-op writes produce no outbox entry.
    @discardableResult
    static func save<R: PersistableRecord & FetchableRecord & Encodable & Equatable>(
        _ record: R, entity: String, id: String, key: [String: any DatabaseValueConvertible]? = nil,
        in db: Database, now: EpochMillis
    ) throws -> Bool {
        let before = try R.fetchOne(db, key: key ?? ["id": id])
        if let before, before == record { return false }
        try record.save(db)
        let newDict = try dict(record)
        let changed: [String]
        if let before {
            let oldDict = try dict(before)
            changed = Set(oldDict.keys).union(newDict.keys).filter { !jsonEqual(oldDict[$0], newDict[$0]) }.sorted()
        } else {
            changed = newDict.keys.sorted()
        }
        let hlc = try HLC.tick(in: db, now: now)
        var change = ChangeRecord(
            seq: nil, entity: entity, entityId: id,
            op: "upsert", fields: changed,
            row: String(data: try encoder.encode(record), encoding: .utf8)!, at: now,
            opId: ID.make(), hlc: hlc.description, ackedAt: nil, result: nil)
        try change.insert(db)
        return true
    }

    private static func dict<R: Encodable>(_ r: R) throws -> [String: Any] {
        let data = try encoder.encode(r)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }
}

// MARK: - Local purge bookkeeping

enum PurgedId {
    /// Records a permanently deleted entity id in `purgedId` without writing to
    /// the `change` outbox. Called locally by `purgeTask` and by the sync engine
    /// when it applies a server tombstone (a row with `purgedAt`).
    static func record(entity: String, id: String, purgedAt: EpochMillis, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO purgedId (entity, id, purgedAt) VALUES (?, ?, ?)
            ON CONFLICT(entity, id) DO UPDATE SET purgedAt = excluded.purgedAt
            """,
            arguments: [entity, id, purgedAt]
        )
    }

    static func contains(entity: String, id: String, in db: Database) throws -> Bool {
        try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM purgedId WHERE entity = ? AND id = ?",
            arguments: [entity, id]
        ) != nil
    }
}
