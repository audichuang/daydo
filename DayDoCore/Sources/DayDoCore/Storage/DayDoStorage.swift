import Foundation

/// Errors thrown when opening DayDo storage.
public enum StorageError: Error, LocalizedError, Sendable, Equatable {
    case databaseNotFound(URL)
    case migrationsIncomplete(URL)
    case databaseSuperseded(URL)

    public var errorDescription: String? {
        switch self {
        case let .databaseNotFound(url):
            return "Database file does not exist at \(url.path)"
        case let .migrationsIncomplete(url):
            return "Database at \(url.path) has not completed all required migrations"
        case let .databaseSuperseded(url):
            return "Database at \(url.path) was created by a newer schema version"
        }
    }
}

/// On-device store returned by `DayDoStorage.openForApp(...)`. Exposes the
/// `DayDoAPI` command/query contract along with device-local lifecycle
/// operations (bootstrap, clock, outbox status, and `SyncEngine` creation).
public struct DeviceStore: Sendable {
    private let localAPI: LocalDayDoAPI

    init(localAPI: LocalDayDoAPI) {
        self.localAPI = localAPI
    }

    public var api: any DayDoAPI { localAPI }

    public var today: LocalDay { localAPI.clock.today }

    public func bootstrap(meName: String = "我") async throws {
        try await localAPI.bootstrap(meName: meName)
    }

    public func unsyncedChangeCount() async throws -> Int {
        try await localAPI.unsyncedChangeCount()
    }

    public func hasPendingChange(entity: String, entityId: String, op: String) async throws -> Bool {
        try await localAPI.hasPendingChange(entity: entity, entityId: entityId, op: op)
    }

    public func makeSyncEngine(
        transport: any SyncTransport,
        tokenStore: any SyncTokenStore
    ) -> SyncEngine {
        SyncEngine(
            database: localAPI.database,
            transport: transport,
            tokenStore: tokenStore,
            clock: localAPI.clock
        )
    }

    public func makeLocalSharing() -> any ListSharing {
        LocalListSharing(api: localAPI, clock: localAPI.clock)
    }

    /// Creates an isolated in-memory store for tests.
    public static func inMemory(
        clock: Clock = .system,
        attachmentsDirectory: URL? = nil
    ) throws -> DeviceStore {
        let dir = attachmentsDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("daydo-tests-\(UUID().uuidString)", isDirectory: true)
        let db = try AppDatabase.inMemory()
        let api = LocalDayDoAPI(database: db, clock: clock, attachmentsDirectory: dir)
        return DeviceStore(localAPI: api)
    }
}

/// Owns where DayDo's on-device files live and how processes open them.
public enum DayDoStorage {
    public static let appGroup = "group.com.audichuang.daydo"
    public static let directoryName = "DayDo"
    public static let databaseFileName = "daydo.sqlite"
    public static let attachmentsDirectoryName = "Attachments"

    /// Resolves the storage directory from an optional App Group container URL,
    /// falling back to Application Support when the group is not provisioned
    /// (e.g. unsigned simulator builds).
    public static func directory(
        groupContainerURL: URL?,
        applicationSupportURL: URL
    ) -> URL {
        let base = groupContainerURL ?? applicationSupportURL
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Storage directory for the current process.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return directory(
            groupContainerURL: groupURL,
            applicationSupportURL: URL.applicationSupportDirectory
        )
    }

    public static func databaseURL(in directory: URL) -> URL {
        directory.appendingPathComponent(databaseFileName)
    }

    public static func attachmentsURL(in directory: URL) -> URL {
        directory.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
    }

    /// Opens the database read-write, running pending migrations, for the main app.
    public static func openForApp(
        in directory: URL = defaultDirectory(),
        clock: Clock = .system
    ) throws -> DeviceStore {
        let db = try AppDatabase.open(at: databaseURL(in: directory))
        let api = LocalDayDoAPI(
            database: db,
            clock: clock,
            attachmentsDirectory: attachmentsURL(in: directory)
        )
        return DeviceStore(localAPI: api)
    }

    /// Opens an existing, migrated database read-only for extension processes
    /// (such as widgets). Never creates the database file or runs migrations.
    public static func openReadOnly(
        in directory: URL = defaultDirectory(),
        clock: Clock = .system
    ) throws -> any DayDoAPI {
        let db = try AppDatabase.openReadOnly(at: databaseURL(in: directory))
        return LocalDayDoAPI(
            database: db,
            clock: clock,
            attachmentsDirectory: attachmentsURL(in: directory)
        )
    }
}
