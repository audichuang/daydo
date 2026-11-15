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
    ) throws -> LocalDayDoAPI {
        let db = try AppDatabase.open(at: databaseURL(in: directory))
        return LocalDayDoAPI(
            database: db,
            clock: clock,
            attachmentsDirectory: attachmentsURL(in: directory)
        )
    }

    /// Opens an existing, migrated database read-only for extension processes
    /// (such as widgets). Never creates the database file or runs migrations.
    public static func openReadOnly(
        in directory: URL = defaultDirectory(),
        clock: Clock = .system
    ) throws -> LocalDayDoAPI {
        let db = try AppDatabase.openReadOnly(at: databaseURL(in: directory))
        return LocalDayDoAPI(
            database: db,
            clock: clock,
            attachmentsDirectory: attachmentsURL(in: directory)
        )
    }
}
