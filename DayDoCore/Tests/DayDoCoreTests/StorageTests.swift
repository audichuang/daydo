import Foundation
import GRDB
import Testing
@testable import DayDoCore

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
            let appAPI = try DayDoStorage.openForApp(in: dir, clock: clock)
            try await appAPI.bootstrap()
            let task = try await appAPI.createTask(CreateTaskInput(
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

        let appAPI = try DayDoStorage.openForApp(in: dir, clock: .fixed(noon, timeZone: taipei))
        try await appAPI.bootstrap()

        let readOnlyAPI = try DayDoStorage.openReadOnly(in: dir, clock: .fixed(noon, timeZone: taipei))
        await #expect(throws: Error.self) {
            _ = try await readOnlyAPI.createTask(CreateTaskInput(title: "Should fail"))
        }
        #expect(try await appAPI.listTasks(TaskQuery()).isEmpty)
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
}
