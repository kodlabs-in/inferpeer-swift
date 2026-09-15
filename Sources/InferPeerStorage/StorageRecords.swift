import Foundation
import GRDB
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import SwiftProtobuf

struct RequestRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "request"

    var requestID: String
    var callerID: String
    var requestData: Data
    var contentDigest: Data
    var state: String
    var attemptNumber: Int64
    var activeAttemptID: String?
    var workerID: String?
    var coordinatorIncarnationID: String?
    var leaseDeadlineNanoseconds: String?
    var cancellationState: String
    var revision: Int64
    var acknowledgedCursor: Int64?
    var createdAt: Date
    var updatedAt: Date
    var terminalAt: Date?
    var terminalResultData: Data?
    var terminalAttemptID: String?

    init(submission: RequestSubmission, timestamp: Date) throws {
        requestID = submission.requestID.rawValue
        callerID = submission.callerID.rawValue
        requestData = try StoredSubmissionCodec.encodeRequest(submission.request)
        contentDigest = submission.contentDigest.bytes
        state = RequestState.queued.rawValue
        attemptNumber = 0
        activeAttemptID = nil
        workerID = nil
        coordinatorIncarnationID = nil
        leaseDeadlineNanoseconds = nil
        cancellationState = CancellationState.notRequested.rawValue
        revision = 0
        acknowledgedCursor = nil
        createdAt = timestamp
        updatedAt = timestamp
        terminalAt = nil
        terminalResultData = nil
        terminalAttemptID = nil
    }

    func storedRequest() throws -> StoredRequest {
        do {
            return try decodeStoredRequest()
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.corruptData
        }
    }

    private func decodeStoredRequest() throws -> StoredRequest {
        let submission = try decodedSubmission()
        let attemptNumber = try decodedAttemptNumber()
        let lifecycle = try RequestLifecycle(
            restoring: decodedState(),
            attemptNumber: attemptNumber,
            activeAttempt: decodedActiveAttempt(number: attemptNumber),
            cancellationState: decodedCancellationState()
        )
        guard let revision = UInt64(exactly: revision) else {
            throw SQLiteStorageError.corruptData
        }
        return StoredRequest(
            submission: submission,
            lifecycle: lifecycle,
            revision: revision,
            acceptedAt: createdAt
        )
    }

    mutating func apply(
        lifecycle: RequestLifecycle,
        revision: UInt64,
        timestamp: Date
    ) throws {
        guard let storedRevision = Int64(exactly: revision) else {
            throw SQLiteStorageError.revisionExhausted
        }
        state = lifecycle.state.rawValue
        attemptNumber = Int64(lifecycle.attemptNumber)
        cancellationState = lifecycle.cancellationState.rawValue
        self.revision = storedRevision
        updatedAt = timestamp
        terminalAt = lifecycle.state.isTerminal ? terminalAt ?? timestamp : nil
        apply(activeAttempt: lifecycle.activeAttempt)
    }

    mutating func retainTerminalResult(from events: [PendingRequestEvent]) throws {
        for event in events.reversed() {
            guard case .generation(.completed(let result)) = event.payload else { continue }
            terminalResultData = try result.wireValue.serializedData()
            terminalAttemptID = event.attemptID?.rawValue
            return
        }
    }

    private func decodedSubmission() throws -> RequestSubmission {
        try StoredSubmissionCodec.decode(
            requestID: requestID,
            callerID: callerID,
            requestData: requestData,
            contentDigest: contentDigest
        )
    }

    private func decodedState() throws -> RequestState {
        guard let state = RequestState(rawValue: state) else {
            throw SQLiteStorageError.corruptData
        }
        return state
    }

    private func decodedCancellationState() throws -> CancellationState {
        guard let cancellationState = CancellationState(rawValue: cancellationState) else {
            throw SQLiteStorageError.corruptData
        }
        return cancellationState
    }

    private func decodedAttemptNumber() throws -> UInt32 {
        guard let attemptNumber = UInt32(exactly: attemptNumber) else {
            throw SQLiteStorageError.corruptData
        }
        return attemptNumber
    }

    private func decodedActiveAttempt(number: UInt32) throws -> ActiveAttempt? {
        guard let activeAttemptID else { return nil }
        guard let attemptID = AttemptID(rawValue: activeAttemptID),
            let workerID,
            let worker = PeerID(rawValue: workerID),
            let coordinatorIncarnationID,
            let coordinator = CoordinatorIncarnationID(rawValue: coordinatorIncarnationID),
            let leaseDeadlineNanoseconds,
            let deadline = UInt64(leaseDeadlineNanoseconds)
        else {
            throw SQLiteStorageError.corruptData
        }
        return ActiveAttempt(
            attemptID: attemptID,
            workerID: worker,
            number: number,
            coordinatorIncarnationID: coordinator,
            leaseDeadline: MonotonicInstant(nanoseconds: deadline)
        )
    }

    private mutating func apply(activeAttempt: ActiveAttempt?) {
        activeAttemptID = activeAttempt?.attemptID.rawValue
        workerID = activeAttempt?.workerID.rawValue
        coordinatorIncarnationID = activeAttempt?.coordinatorIncarnationID.rawValue
        leaseDeadlineNanoseconds = activeAttempt.map { String($0.leaseDeadline.nanoseconds) }
    }
}

struct EventRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "requestEvent"

    var cursor: Int64?
    var requestID: String
    var attemptID: String?
    var kind: Int
    var payloadData: Data
    var committedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        cursor = inserted.rowID
    }

    func persistedEvent() throws -> PersistedRequestEvent {
        do {
            return try decodePersistedEvent()
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.corruptData
        }
    }

    private func decodePersistedEvent() throws -> PersistedRequestEvent {
        guard let cursor,
            let domainCursor = UInt64(exactly: cursor),
            let requestID = RequestID(rawValue: requestID)
        else {
            throw SQLiteStorageError.corruptData
        }
        let attemptID = try decodedAttemptID()
        return PersistedRequestEvent(
            cursor: domainCursor,
            requestID: requestID,
            attemptID: attemptID,
            payload: try RequestEventCodec.decode(kind: kind, data: payloadData),
            committedAt: committedAt
        )
    }

    private func decodedAttemptID() throws -> AttemptID? {
        guard let attemptID else { return nil }
        guard let identifier = AttemptID(rawValue: attemptID) else {
            throw SQLiteStorageError.corruptData
        }
        return identifier
    }
}

struct TombstoneRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "requestTombstone"

    let requestID: String
    let callerID: String
    let prunedAt: Date
    let terminalResultData: Data?
    let terminalAttemptID: String?

    func retainedTerminalResult() throws -> RetainedTerminalResult? {
        guard let terminalResultData else { return nil }
        let wire = try InferPeer_V1_GenerationCompleted(serializedBytes: terminalResultData)
        let attemptID = terminalAttemptID.flatMap(AttemptID.init(rawValue:))
        if terminalAttemptID != nil, attemptID == nil {
            throw SQLiteStorageError.corruptData
        }
        return RetainedTerminalResult(
            attemptID: attemptID,
            result: try GenerationResult(wireValue: wire)
        )
    }
}

struct ConversationRevisionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "conversationRevision"

    let callerID: String
    let conversationID: String
    var latestRevision: Int64
}
