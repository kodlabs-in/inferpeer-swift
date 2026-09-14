import GRDB

enum StorageSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_request_store") { database in
            try createRequests(in: database)
            try createEvents(in: database)
            try createTombstones(in: database)
            try createOutbox(in: database)
            try createPeers(in: database)
            try createModels(in: database)
        }
        return migrator
    }

    private static func createRequests(in database: Database) throws {
        try database.create(table: RequestRecord.databaseTableName) { table in
            table.column("requestID", .text).primaryKey()
            table.column("callerID", .text).notNull()
            table.column("requestData", .blob).notNull()
            table.column("contentDigest", .blob).notNull()
            table.column("state", .text).notNull()
            table.column("attemptNumber", .integer).notNull()
            table.column("activeAttemptID", .text)
            table.column("workerID", .text)
            table.column("coordinatorIncarnationID", .text)
            table.column("leaseDeadlineNanoseconds", .text)
            table.column("cancellationState", .text).notNull()
            table.column("revision", .integer).notNull()
            table.column("acknowledgedCursor", .integer)
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
            table.column("terminalAt", .datetime)
        }
        try database.create(
            index: "requestsByTerminalAt",
            on: RequestRecord.databaseTableName,
            columns: ["terminalAt"]
        )
    }

    private static func createEvents(in database: Database) throws {
        try database.create(table: EventRecord.databaseTableName) { table in
            table.autoIncrementedPrimaryKey("cursor")
            table.column("requestID", .text).notNull().references(
                RequestRecord.databaseTableName,
                onDelete: .cascade
            )
            table.column("attemptID", .text)
            table.column("kind", .integer).notNull()
            table.column("payloadData", .blob).notNull()
            table.column("committedAt", .datetime).notNull()
        }
        try database.create(
            index: "eventsByRequestAndCursor",
            on: EventRecord.databaseTableName,
            columns: ["requestID", "cursor"]
        )
    }

    private static func createTombstones(in database: Database) throws {
        try database.create(table: TombstoneRecord.databaseTableName) { table in
            table.column("requestID", .text).primaryKey()
            table.column("callerID", .text).notNull()
            table.column("prunedAt", .datetime).notNull()
        }
    }

    private static func createOutbox(in database: Database) throws {
        try database.create(table: OutboxRecord.databaseTableName) { table in
            table.column("requestID", .text).primaryKey()
            table.column("callerID", .text).notNull()
            table.column("requestData", .blob).notNull()
            table.column("contentDigest", .blob).notNull()
            table.column("enqueuedAt", .datetime).notNull()
        }
        try database.create(
            index: "outboxByCallerAndDate",
            on: OutboxRecord.databaseTableName,
            columns: ["callerID", "enqueuedAt", "requestID"]
        )
    }

    private static func createPeers(in database: Database) throws {
        try database.create(table: PeerRecord.databaseTableName) { table in
            table.column("peerID", .text).primaryKey()
            table.column("certificateFingerprint", .blob).notNull()
            table.column("allowsCaller", .boolean).notNull()
            table.column("allowsCoordinator", .boolean).notNull()
            table.column("allowsWorker", .boolean).notNull()
            table.column("approvedAt", .datetime).notNull()
            table.column("revokedAt", .datetime)
        }
    }

    private static func createModels(in database: Database) throws {
        try database.create(table: ModelRecord.databaseTableName) { table in
            table.column("modelID", .text).notNull()
            table.column("revision", .text).notNull()
            table.column("descriptorData", .blob).notNull()
            table.column("directoryPath", .text).notNull()
            table.column("registeredAt", .datetime).notNull()
            table.primaryKey(["modelID", "revision"])
        }
    }
}
