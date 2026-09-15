import Foundation
import GRDB
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

struct StoredCompletion {
    let attemptID: AttemptID
    let result: GenerationResult
    let mutation: RequestMutation
}

enum ConcurrentCommitOutcome: Sendable {
    case succeeded
    case lostRevisionRace
    case failed

    var succeeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    var lostRevisionRace: Bool {
        if case .lostRevisionRace = self { return true }
        return false
    }
}

func commitOutcome(
    _ mutation: RequestMutation,
    to store: SQLiteJobStore
) async -> ConcurrentCommitOutcome {
    do {
        _ = try await store.commit(mutation)
        return .succeeded
    } catch RequestPersistenceError.staleRevision {
        return .lostRevisionRace
    } catch {
        return .failed
    }
}

extension SQLiteJobStoreTests {
    func makeRunningMutation(
        from accepted: StoredRequest
    ) throws -> RequestMutation {
        var lifecycle = accepted.lifecycle
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        let workerID = try #require(PeerID(rawValue: "worker-1"))
        let coordinatorID = try #require(
            CoordinatorIncarnationID(rawValue: "coordinator-1")
        )
        _ = try lifecycle.assign(
            attemptID: attemptID,
            workerID: workerID,
            coordinatorIncarnationID: coordinatorID,
            leaseDeadline: MonotonicInstant(nanoseconds: 20_000_000_000)
        )
        try lifecycle.accept(attemptID: attemptID)
        return RequestMutation(
            requestID: accepted.submission.requestID,
            callerID: accepted.submission.callerID,
            expectedRevision: accepted.revision,
            lifecycle: lifecycle,
            events: [
                PendingRequestEvent(
                    attemptID: attemptID,
                    payload: .stateChanged(state: .assigned, attemptNumber: 1)
                ),
                PendingRequestEvent(
                    attemptID: attemptID,
                    payload: .stateChanged(state: .running, attemptNumber: 1)
                ),
                PendingRequestEvent(
                    attemptID: attemptID,
                    payload: .generation(try .textDelta(TextDelta("Hi")))
                ),
            ]
        )
    }

    func makeQueuedCancellationMutation(from accepted: StoredRequest) -> RequestMutation {
        var lifecycle = accepted.lifecycle
        let cancellation = lifecycle.requestCancellation()
        return RequestMutation(
            requestID: accepted.submission.requestID,
            callerID: accepted.submission.callerID,
            expectedRevision: accepted.revision,
            lifecycle: lifecycle,
            events: [PendingRequestEvent(payload: .cancellation(cancellation))]
        )
    }

    func assertReplayPayloads(_ events: [PersistedRequestEvent]) throws {
        #expect(events.count == 4)
        guard case .accepted(.queued) = events[0].payload,
            case .stateChanged(.assigned, 1) = events[1].payload,
            case .stateChanged(.running, 1) = events[2].payload,
            case .generation(.textDelta(let delta)) = events[3].payload
        else {
            Issue.record("Replay payloads were not restored in committed order")
            return
        }
        #expect(delta.text == "Hi")
    }

    func assertRestoredLifecycle(
        _ expected: RequestLifecycle,
        submission: RequestSubmission,
        database: StorageTestDatabase
    ) async throws {
        let reopenedStore = try database.makeStore()
        let restored = try await reopenedStore.request(
            requestID: submission.requestID,
            callerID: submission.callerID
        )
        try reopenedStore.close()
        #expect(restored?.lifecycle == expected)
    }

    func assertAcknowledgementPersisted(in databaseURL: URL) throws {
        let database = try DatabaseQueue(path: databaseURL.path)
        let acknowledgedCursor = try database.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT acknowledgedCursor FROM request WHERE requestID = ?",
                arguments: ["request-1"]
            )
        }
        let journalMode = try database.read { database in
            try String.fetchOne(database, sql: "PRAGMA journal_mode")
        }
        let migrations = try database.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations")
        }

        #expect(acknowledgedCursor == 4)
        #expect(journalMode?.lowercased() == "wal")
        #expect(
            migrations == [
                "v1_request_store",
                "v2_caller_replay_state",
                "v3_retained_terminal_result",
                "v4_conversation_revisions",
            ]
        )
    }

    func corruptRequestState(in databaseURL: URL) throws {
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { database in
            try database.execute(
                sql: "UPDATE request SET state = ? WHERE requestID = ?",
                arguments: ["unknown-state", "request-1"]
            )
        }
    }
}

extension SQLiteJobStoreTests {
    func makeStoredCompletion(from accepted: StoredRequest) throws -> StoredCompletion {
        var lifecycle = accepted.lifecycle
        let attemptID = try #require(AttemptID(rawValue: "attempt-terminal"))
        _ = try lifecycle.assign(
            attemptID: attemptID,
            workerID: #require(PeerID(rawValue: "worker-1")),
            coordinatorIncarnationID: #require(
                CoordinatorIncarnationID(rawValue: "coordinator-1")
            ),
            leaseDeadline: MonotonicInstant(nanoseconds: 20_000_000_000)
        )
        try lifecycle.accept(attemptID: attemptID)
        _ = try lifecycle.complete(attemptID: attemptID)
        let result = GenerationResult(
            fullText: "Retained answer",
            modelUsed: try makeModelReference(),
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 2, outputTokens: 3)
        )
        let event = PendingRequestEvent(
            attemptID: attemptID,
            payload: .generation(.completed(result))
        )
        return StoredCompletion(
            attemptID: attemptID,
            result: result,
            mutation: RequestMutation(
                requestID: accepted.submission.requestID,
                callerID: accepted.submission.callerID,
                expectedRevision: accepted.revision,
                lifecycle: lifecycle,
                events: [event]
            )
        )
    }
}
