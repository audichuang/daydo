import Foundation
import GRDB
import SQLite3
import Testing
@testable import DayDoCore

/// Suites that open file-backed app databases. GRDB suspension notifications are
/// process-wide, so these must not run concurrently with the suspension test.
@Suite(.serialized) enum FileBackedDatabaseTests {}

extension FileBackedDatabaseTests {
@Suite struct StorageTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-storage-tests-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    @Test func directoryResolutionUsesAppGroupOrFallsBackToApplicationSupport() {
        let group = URL(fileURLWithPath: "/tmp/app-group", isDirectory: true)
        let appSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)

        let withGroup = DayDoStorage.directory(groupContainerURL: group, applicationSupportURL: appSupport)
        #expect(withGroup == group.appendingPathComponent("DayDo", isDirectory: true))
        #expect(DayDoStorage.databaseURL(in: withGroup).lastPathComponent == "daydo.sqlite")
        #expect(DayDoStorage.attachmentsURL(in: withGroup).lastPathComponent == "Attachments")
        #expect(DayDoStorage.appGroup == "group.com.audichuang.daydo")

        let withoutGroup = DayDoStorage.directory(groupContainerURL: nil, applicationSupportURL: appSupport)
        #expect(withoutGroup == appSupport.appendingPathComponent("DayDo", isDirectory: true))
    }

    @Test func appOpenThenReadOnlyOpenSeesSameData() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = Clock.fixed(noon, timeZone: taipei)
        let createdId: String
        do {
            let store = try DayDoStorage.openForApp(in: dir, clock: clock)
            try await store.bootstrap()
            let task = try await store.api.createTask(CreateTaskInput(
                title: "Widget visible task",
                start: "2026-11-15T09:00:00+0800",
                timeZone: "Asia/Taipei"
            ))
            createdId = task.id

            // Concurrent read-only handle while app handle is still open.
            let concurrentReader = try DayDoStorage.openReadOnly(in: dir, clock: clock)
            let concurrentTasks = try await concurrentReader.listTasks(TaskQuery())
            #expect(concurrentTasks.map(\.id).contains(createdId))
            #expect(concurrentTasks.first(where: { $0.id == createdId })?.title == "Widget visible task")
        }

        // Re-open read-only after app handle closed (relies on persistent WAL).
        let readOnlyAPI = try DayDoStorage.openReadOnly(in: dir, clock: clock)
        let tasks = try await readOnlyAPI.listTasks(TaskQuery())
        #expect(tasks.map(\.id) == [createdId])
        #expect(tasks.first?.title == "Widget visible task")
    }

    @Test func writeThroughReadOnlyHandleThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try DayDoStorage.openForApp(in: dir, clock: .fixed(noon, timeZone: taipei))
        try await store.bootstrap()

        let readOnlyAPI = try DayDoStorage.openReadOnly(in: dir, clock: .fixed(noon, timeZone: taipei))
        await #expect(throws: Error.self) {
            _ = try await readOnlyAPI.createTask(CreateTaskInput(title: "Should fail"))
        }
        #expect(try await store.api.listTasks(TaskQuery()).isEmpty)
    }

    @Test func deviceStoreCountsUnsyncedChangesExcludingProjectInvites() async throws {
        let store = try DeviceStore.inMemory(clock: .fixed(noon, timeZone: taipei))
        #expect(store.today == LocalDay(year: 2026, month: 11, day: 15))
        try await store.bootstrap()
        let before = try await store.unsyncedChangeCount()
        #expect(before > 0)

        let project = try await store.api.createProject(CreateProjectInput(name: "Shared"))
        let afterProject = try await store.unsyncedChangeCount()
        #expect(afterProject == before + 2) // project + projectMember

        _ = try await store.api.inviteMember(projectId: project.id, email: "a@example.com", role: "editor")
        #expect(try await store.unsyncedChangeCount() == afterProject)
        #expect(try await store.hasPendingChange(entity: "projectInvite", entityId: project.id, op: "upsert") == false)
        #expect(try await store.hasPendingChange(entity: "project", entityId: project.id, op: "upsert") == true)
    }

    @Test func readOnlyOpenMissingFileThrowsWithoutCreatingIt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = DayDoStorage.databaseURL(in: dir)
        #expect(throws: StorageError.databaseNotFound(dbURL)) {
            _ = try DayDoStorage.openReadOnly(in: dir)
        }
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func readOnlyOpenUnmigratedFileThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = DayDoStorage.databaseURL(in: dir)
        // Create an empty SQLite database with no DayDo migrations applied.
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE placeholder (id INTEGER PRIMARY KEY)")
        }

        #expect(throws: StorageError.migrationsIncomplete(dbURL)) {
            _ = try DayDoStorage.openReadOnly(in: dir)
        }
    }

    @Test func readOnlyOpenPartiallyMigratedFileThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = DayDoStorage.databaseURL(in: dir)
        var partialMigrator = DatabaseMigrator()
        partialMigrator.registerMigration("v1") { db in
            try db.create(table: "member") { t in
                t.primaryKey("id", .text)
            }
        }
        let pool = try DatabasePool(path: dbURL.path)
        try partialMigrator.migrate(pool)

        // Ensure -wal/-shm aren't the only reason; keep pool alive while opening read-only.
        #expect(throws: StorageError.migrationsIncomplete(dbURL)) {
            _ = try DayDoStorage.openReadOnly(in: dir)
        }
        _ = pool
    }

    @Test func readOnlyOpenSupersededFileThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = DayDoStorage.databaseURL(in: dir)
        let appDB = try AppDatabase.open(at: dbURL)
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: ["v999"])
        }

        #expect(throws: StorageError.databaseSuperseded(dbURL)) {
            _ = try DayDoStorage.openReadOnly(in: dir)
        }
    }

    @Test func readOnlyOpenWaitsForExclusiveLockWithBusyTimeout() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = Clock.fixed(noon, timeZone: taipei)
        do {
            let store = try DayDoStorage.openForApp(in: dir, clock: clock)
            try await store.bootstrap()
            _ = try await store.api.createTask(CreateTaskInput(title: "Locked task"))
        }

        let dbPath = DayDoStorage.databaseURL(in: dir).path
        var rawDB: OpaquePointer?
        #expect(sqlite3_open_v2(dbPath, &rawDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer {
            if let rawDB { sqlite3_close(rawDB) }
        }
        #expect(sqlite3_exec(rawDB, "PRAGMA locking_mode = EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(
            rawDB,
            "BEGIN IMMEDIATE; INSERT OR REPLACE INTO meta (key, value) VALUES ('__lock_test__', '1'); COMMIT;",
            nil, nil, nil
        ) == SQLITE_OK)

        let (startedStream, startedCont) = AsyncStream<Void>.makeStream()
        let openTask = Task.detached {
            startedCont.yield()
            startedCont.finish()
            return try DayDoStorage.openReadOnly(in: dir, clock: clock)
        }

        for await _ in startedStream {}
        try await Task.sleep(for: .milliseconds(600))
        #expect(sqlite3_close(rawDB) == SQLITE_OK)
        rawDB = nil

        let readOnlyAPI = try await openTask.value
        let tasks = try await readOnlyAPI.listTasks(TaskQuery())
        #expect(tasks.map(\.title) == ["Locked task"])
    }

    @Test func appDatabaseSuspendsWritesAndResumes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = Clock.fixed(noon, timeZone: taipei)
        let dbURL = DayDoStorage.databaseURL(in: dir)
        let appDB = try AppDatabase.open(at: dbURL)
        #expect(appDB.writer.configuration.observesSuspensionNotifications)
        if case .timeout(let seconds) = appDB.writer.configuration.busyMode {
            #expect(seconds == 5)
        } else {
            Issue.record("Expected .timeout(5) busyMode on AppDatabase.open")
        }

        let readOnlyDB = try AppDatabase.openReadOnly(at: dbURL)
        #expect(!readOnlyDB.writer.configuration.observesSuspensionNotifications)
        if case .timeout(let seconds) = readOnlyDB.writer.configuration.busyMode {
            #expect(seconds == 5)
        } else {
            Issue.record("Expected .timeout(5) busyMode on AppDatabase.openReadOnly")
        }

        let store = try DayDoStorage.openForApp(in: dir, clock: clock)
        try await store.bootstrap()

        DayDoStorage.suspendDatabaseAccess()
        defer { DayDoStorage.resumeDatabaseAccess() }

        do {
            _ = try await store.api.createTask(CreateTaskInput(title: "Blocked while suspended"))
            Issue.record("Expected write while suspended to throw DatabaseError")
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_ABORT || error.resultCode == .SQLITE_INTERRUPT)
        }

        DayDoStorage.resumeDatabaseAccess()

        let created = try await store.api.createTask(CreateTaskInput(title: "Allowed after resume"))
        let tasks = try await store.api.listTasks(TaskQuery())
        #expect(tasks.map(\.id) == [created.id])
        #expect(tasks.first?.title == "Allowed after resume")
    }
}
}
