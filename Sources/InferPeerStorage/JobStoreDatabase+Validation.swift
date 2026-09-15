import Foundation
import GRDB
import InferPeerCore
import InferPeerProtocol
import SwiftProtobuf

extension JobStoreDatabase {
    static func duplicateAcceptance(
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

    static func advanceConversationRevision(
        for submission: RequestSubmission,
        in database: Database
    ) throws {
        let context = submission.request.context
        guard let revision = Int64(exactly: context.revision) else {
            throw RequestPersistenceError.conversationRevisionNotIncreasing
        }
        let key: [String: (any DatabaseValueConvertible)?] = [
            "callerID": submission.callerID.rawValue,
            "conversationID": context.conversationID.rawValue,
        ]
        if let existing = try ConversationRevisionRecord.fetchOne(database, key: key) {
            guard revision > existing.latestRevision else {
                throw RequestPersistenceError.conversationRevisionNotIncreasing
            }
        }
        let record = ConversationRevisionRecord(
            callerID: submission.callerID.rawValue,
            conversationID: context.conversationID.rawValue,
            latestRevision: revision
        )
        try record.save(database)
    }

    static func requireAdmissionCapacity(
        callerID: PeerID,
        maximumPendingRequests: Int,
        maximumPendingRequestsPerCaller: Int,
        in database: Database
    ) throws {
        let clusterCount =
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM request WHERE terminalAt IS NULL"
            ) ?? 0
        let callerCount =
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM request WHERE terminalAt IS NULL AND callerID = ?",
                arguments: [callerID.rawValue]
            ) ?? 0
        guard clusterCount < maximumPendingRequests,
            callerCount < maximumPendingRequestsPerCaller
        else {
            throw RequestPersistenceError.resourceExhausted
        }
    }

    static func requireReplayAccess(
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
            throw RequestPersistenceError.replayExpired(try tombstone.retainedTerminalResult())
        }
        throw RequestPersistenceError.requestNotFound
    }

    static func requireOwner(_ callerID: PeerID, storedCallerID: String) throws {
        guard callerID.rawValue == storedCallerID else {
            throw RequestPersistenceError.accessDenied
        }
    }

    static func insertEvent(
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
