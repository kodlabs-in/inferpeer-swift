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
        migrator.registerMigration("v2_caller_replay_state") { database in
            try createCallerReplayState(in: database)
        }
        migrator.registerMigration("v3_retained_terminal_result") { database in
            try database.alter(table: RequestRecord.databaseTableName) { table in
                table.add(column: "terminalResultData", .blob)
                table.add(column: "terminalAttemptID", .text)
            }
            try database.alter(table: TombstoneRecord.databaseTableName) { table in
                table.add(column: "terminalResultData", .blob)
                table.add(column: "terminalAttemptID", .text)
            }
        }
        migrator.registerMigration("v4_conversation_revisions") { database in
            try createConversationRevisions(in: database)
            try populateConversationRevisions(in: database)
        }
        migrator.registerMigration("v5_direct_request_metadata") { database in
            try createDirectRequestMetadata(in: database)
        }
        migrator.registerMigration("v6_direct_asset_records") { database in
            try createDirectAssetRecords(in: database)
        }
        migrator.registerMigration("v7_verified_model_manifests") { database in
            try createVerifiedModelManifests(in: database)
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

    private static func createCallerReplayState(in database: Database) throws {
        try database.create(table: CallerReplayRecord.databaseTableName) { table in
            table.column("requestID", .text).primaryKey()
            table.column("callerID", .text).notNull()
            table.column("latestCursor", .integer).notNull()
            table.column("acknowledgedCursor", .integer)
        }
    }

    private static func createConversationRevisions(in database: Database) throws {
        try database.create(table: ConversationRevisionRecord.databaseTableName) { table in
            table.column("callerID", .text).notNull()
            table.column("conversationID", .text).notNull()
            table.column("latestRevision", .integer).notNull()
            table.primaryKey(["callerID", "conversationID"])
        }
    }

    private static func populateConversationRevisions(in database: Database) throws {
        let requests = try RequestRecord.fetchAll(database)
        for request in requests {
            let stored = try request.storedRequest()
            let context = stored.submission.request.context
            guard let revision = Int64(exactly: context.revision) else {
                throw SQLiteStorageError.corruptData
            }
            try database.execute(
                sql: """
                    INSERT INTO conversationRevision (callerID, conversationID, latestRevision)
                    VALUES (?, ?, ?)
                    ON CONFLICT(callerID, conversationID) DO UPDATE
                    SET latestRevision = MAX(latestRevision, excluded.latestRevision)
                    """,
                arguments: [request.callerID, context.conversationID.rawValue, revision]
            )
        }
    }

    private static func createDirectRequestMetadata(in database: Database) throws {
        try database.create(table: "directRequestMetadata") { table in
            table.column("requestID", .text).primaryKey()
            table.column("principalID", .text).notNull()
            table.column("resourceID", .text).notNull()
            table.column("specificationDigest", .blob).notNull()
            table.column("modelID", .text).notNull()
            table.column("modelRevision", .text).notNull()
            table.column("state", .text).notNull()
            table.column("processIncarnation", .text).notNull()
            table.column("originalTimeoutMilliseconds", .text).notNull()
            table.column("acceptedAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
            table.column("terminalAt", .datetime)
        }
        try database.create(
            index: "directRequestsByPrincipalAndState",
            on: "directRequestMetadata",
            columns: ["principalID", "state", "acceptedAt"]
        )
    }

    private static func createDirectAssetRecords(in database: Database) throws {
        try database.create(table: "directAssetRecord") { table in
            table.column("ticket", .text).primaryKey()
            table.column("ownerID", .text).notNull()
            table.column("expectedByteCount", .text).notNull()
            table.column("expectedSHA256", .blob).notNull()
            table.column("mediaType", .text).notNull()
            table.column("expiresAt", .datetime).notNull()
            table.column("durableOffset", .text).notNull()
            table.column("fileName", .text).notNull()
            table.column("receipt", .text).unique()
            table.column("isComplete", .boolean).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
        }
        try database.create(
            index: "directAssetsByOwnerAndExpiry",
            on: "directAssetRecord",
            columns: ["ownerID", "expiresAt"]
        )
    }

    private static func createVerifiedModelManifests(in database: Database) throws {
        try database.create(table: VerifiedModelManifestRecord.databaseTableName) { table in
            table.column("modelID", .text).notNull()
            table.column("revision", .text).notNull()
            table.column("manifestDigest", .blob).notNull()
            table.column("manifestData", .blob).notNull()
            table.column("directoryPath", .text).notNull()
            table.column("registeredAt", .datetime).notNull()
            table.primaryKey(["modelID", "revision"])
        }
    }
}
