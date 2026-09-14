import Foundation
import GRDB

enum StorageConnection {
    static func open(
        databaseURL: URL,
        configuration: SQLiteStorageConfiguration
    ) throws -> DatabasePool {
        guard databaseURL.isFileURL else {
            throw SQLiteStorageError.invalidDatabaseURL
        }
        do {
            let pool = try makePool(path: databaseURL.path, configuration: configuration)
            try StorageSchema.migrator.migrate(pool)
            return pool
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.databaseFailure
        }
    }

    private static func makePool(
        path: String,
        configuration: SQLiteStorageConfiguration
    ) throws -> DatabasePool {
        var databaseConfiguration = Configuration()
        databaseConfiguration.busyMode = .timeout(configuration.busyTimeout)
        databaseConfiguration.maximumReaderCount = configuration.maximumReaderCount
        databaseConfiguration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: path, configuration: databaseConfiguration)
        try pool.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        return pool
    }
}
