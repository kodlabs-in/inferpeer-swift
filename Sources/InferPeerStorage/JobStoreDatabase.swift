import Foundation
import GRDB
import InferPeerCore
import InferPeerProtocol
import SwiftProtobuf

enum JobStoreDatabase {
    static func accept(
        _ submission: RequestSubmission,
        at timestamp: Date,
        maximumDatabaseBytes: UInt64,
        in database: Database
    ) throws -> RequestAcceptance {
        if let tombstone = try TombstoneRecord.fetchOne(
            database, key: submission.requestID.rawValue)
        {
            try requireOwner(submission.callerID, storedCallerID: tombstone.callerID)
            throw RequestPersistenceError.replayExpired
        }
        if let existing = try RequestRecord.fetchOne(database, key: submission.requestID.rawValue) {
            return try duplicateAcceptance(for: submission, existing: existing)
        }

        var record = try RequestRecord(submission: submission, timestamp: timestamp)
        try record.insert(database)
        try insertEvent(
            PendingRequestEvent(payload: .accepted(.queued)),
            requestID: submission.requestID,
            timestamp: timestamp,
            in: database
        )
        try DatabaseQuota.enforce(maximumDatabaseBytes, in: database)
        return .accepted(try record.storedRequest())
    }

    static func request(
        requestID: RequestID,
        callerID: PeerID,
        in database: Database
    ) throws -> StoredRequest? {
        guard let record = try RequestRecord.fetchOne(database, key: requestID.rawValue) else {
            return nil
        }
        try requireOwner(callerID, storedCallerID: record.callerID)
        return try record.storedRequest()
    }

    static func commit(
        _ mutation: RequestMutation,
        at timestamp: Date,
        maximumDatabaseBytes: UInt64,
        in database: Database
    ) throws -> StoredRequest {
        guard var record = try RequestRecord.fetchOne(database, key: mutation.requestID.rawValue)
        else {
            throw RequestPersistenceError.requestNotFound
        }
        try requireOwner(mutation.callerID, storedCallerID: record.callerID)
        let storedRequest = try record.storedRequest()
        guard storedRequest.revision == mutation.expectedRevision else {
            throw RequestPersistenceError.staleRevision
        }
        guard storedRequest.revision < UInt64(Int64.max) else {
            throw SQLiteStorageError.revisionExhausted
        }

        try record.apply(
            lifecycle: mutation.lifecycle,
            revision: storedRequest.revision + 1,
            timestamp: timestamp
        )
        try record.update(database)
        for event in mutation.events {
            try insertEvent(
                event,
                requestID: mutation.requestID,
                timestamp: timestamp,
                in: database
            )
        }
        try DatabaseQuota.enforce(maximumDatabaseBytes, in: database)
        return try record.storedRequest()
    }

    static func replay(
        requestID: RequestID,
        callerID: PeerID,
        after cursor: UInt64?,
        limit: Int,
        in database: Database
    ) throws -> [PersistedRequestEvent] {
        try requireReplayAccess(requestID: requestID, callerID: callerID, in: database)
        let storedCursor = cursor.flatMap(Int64.init(exactly:)) ?? -1
        if cursor != nil, storedCursor < 0 {
            return []
        }
        let records = try EventRecord.fetchAll(
            database,
            sql: """
                SELECT * FROM requestEvent
                WHERE requestID = ? AND cursor > ?
                ORDER BY cursor
                LIMIT ?
                """,
            arguments: [requestID.rawValue, storedCursor, limit]
        )
        return try records.map { try $0.persistedEvent() }
    }

    static func acknowledge(
        requestID: RequestID,
        callerID: PeerID,
        through cursor: UInt64,
        in database: Database
    ) throws {
        guard var record = try RequestRecord.fetchOne(database, key: requestID.rawValue) else {
            throw RequestPersistenceError.requestNotFound
        }
        try requireOwner(callerID, storedCallerID: record.callerID)
        guard let storedCursor = Int64(exactly: cursor) else {
            throw SQLiteStorageError.cursorOutOfRange
        }
        let eventExists =
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM requestEvent WHERE requestID = ? AND cursor = ?)",
                arguments: [requestID.rawValue, storedCursor]
            ) ?? false
        guard eventExists else {
            throw SQLiteStorageError.cursorOutOfRange
        }
        record.acknowledgedCursor = max(record.acknowledgedCursor ?? -1, storedCursor)
        try record.update(database, columns: ["acknowledgedCursor"])
    }

    static func pruneTerminalRequests(
        before cutoff: Date,
        prunedAt timestamp: Date,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT OR IGNORE INTO requestTombstone (requestID, callerID, prunedAt)
                SELECT requestID, callerID, ? FROM request
                WHERE terminalAt IS NOT NULL AND terminalAt < ?
                """,
            arguments: [timestamp, cutoff]
        )
        try database.execute(
            sql: "DELETE FROM request WHERE terminalAt IS NOT NULL AND terminalAt < ?",
            arguments: [cutoff]
        )
    }

    private static func duplicateAcceptance(
        for submission: RequestSubmission,
        existing: RequestRecord
    ) throws -> RequestAcceptance {
        try requireOwner(submission.callerID, storedCallerID: existing.callerID)
        let requestData = try submission.request.wireValue.serializedData()
        guard existing.contentDigest == submission.contentDigest.bytes,
            existing.requestData == requestData
        else {
            throw RequestPersistenceError.requestConflict
        }
        return .duplicate(try existing.storedRequest())
    }

    private static func requireReplayAccess(
        requestID: RequestID,
        callerID: PeerID,
        in database: Database
    ) throws {
        if let record = try RequestRecord.fetchOne(database, key: requestID.rawValue) {
            try requireOwner(callerID, storedCallerID: record.callerID)
            return
        }
        if let tombstone = try TombstoneRecord.fetchOne(database, key: requestID.rawValue) {
            try requireOwner(callerID, storedCallerID: tombstone.callerID)
            throw RequestPersistenceError.replayExpired
        }
        throw RequestPersistenceError.requestNotFound
    }

    private static func requireOwner(_ callerID: PeerID, storedCallerID: String) throws {
        guard callerID.rawValue == storedCallerID else {
            throw RequestPersistenceError.accessDenied
        }
    }

    private static func insertEvent(
        _ event: PendingRequestEvent,
        requestID: RequestID,
        timestamp: Date,
        in database: Database
    ) throws {
        let encoded = try RequestEventCodec.encode(event.payload)
        var record = EventRecord(
            cursor: nil,
            requestID: requestID.rawValue,
            attemptID: event.attemptID?.rawValue,
            kind: encoded.kind.rawValue,
            payloadData: encoded.data,
            committedAt: timestamp
        )
        try record.insert(database)
    }
}
