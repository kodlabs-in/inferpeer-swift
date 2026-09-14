import GRDB
import InferPeerCore

enum DatabaseQuota {
    static func enforce(_ maximumBytes: UInt64, in database: Database) throws {
        let pageCount = try requiredPragma("page_count", in: database)
        let freePageCount = try requiredPragma("freelist_count", in: database)
        let pageSize = try requiredPragma("page_size", in: database)
        guard pageCount >= freePageCount else {
            throw SQLiteStorageError.databaseFailure
        }
        let usedPageCount = UInt64(pageCount - freePageCount)
        let byteCount = usedPageCount.multipliedReportingOverflow(by: UInt64(pageSize))
        guard !byteCount.overflow, byteCount.partialValue <= maximumBytes else {
            throw RequestPersistenceError.resourceExhausted
        }
    }

    private static func requiredPragma(
        _ name: String,
        in database: Database
    ) throws -> Int64 {
        guard let value = try Int64.fetchOne(database, sql: "PRAGMA \(name)") else {
            throw SQLiteStorageError.databaseFailure
        }
        return value
    }
}
