import Foundation
import GRDB
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

@Suite("SQLite job store")
struct SQLiteJobStoreTests {
    @Test("Persists acceptance and deduplicates an identical retry")
    func persistsAcceptanceAndDeduplicates() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let submission = try makeSubmission()
        let store = try testDatabase.makeStore()

        let accepted = try acceptedRequest(from: await store.accept(submission))
        let duplicate = try await store.accept(submission)
        try store.close()
        let reopenedStore = try testDatabase.makeStore()
        defer { try? reopenedStore.close() }
        let restored = try await reopenedStore.request(
            requestID: submission.requestID,
            callerID: submission.callerID
        )

        #expect(accepted.lifecycle.state == .queued)
        #expect(accepted.revision == 0)
        guard case .duplicate(let duplicateRequest) = duplicate else {
            Issue.record("Expected an identical submission to be deduplicated")
            return
        }
        #expect(duplicateRequest.revision == 0)
        #expect(restored?.submission.request == submission.request)
    }

    @Test("Rejects identifier conflicts and cross-caller access")
    func rejectsConflictsAndCrossCallerAccess() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeStore()
        defer { try? store.close() }
        let submission = try makeSubmission()
        _ = try await store.accept(submission)

        await #expect(throws: RequestPersistenceError.requestConflict) {
            try await store.accept(makeSubmission(prompt: "Different input"))
        }
        await #expect(throws: RequestPersistenceError.accessDenied) {
            try await store.accept(makeSubmission(caller: "caller-2"))
        }
        let otherCaller = try #require(PeerID(rawValue: "caller-2"))
        await #expect(throws: RequestPersistenceError.accessDenied) {
            try await store.request(
                requestID: submission.requestID,
                callerID: otherCaller
            )
        }
    }

    @Test("Commits lifecycle and replay events in one revision")
    func commitsLifecycleAndReplay() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeStore()
        let submission = try makeSubmission()
        let accepted = try acceptedRequest(from: await store.accept(submission))
        let mutation = try makeRunningMutation(from: accepted)

        let committed = try await store.commit(mutation)
        let firstPage = try await store.replay(
            requestID: submission.requestID,
            callerID: submission.callerID,
            after: nil,
            limit: 2
        )
        let secondPage = try await store.replay(
            requestID: submission.requestID,
            callerID: submission.callerID,
            after: firstPage.last?.cursor,
            limit: 2
        )
        try await store.acknowledge(
            requestID: submission.requestID,
            callerID: submission.callerID,
            through: try #require(secondPage.last?.cursor)
        )

        #expect(committed.revision == 1)
        #expect(committed.lifecycle.state == .running)
        #expect(firstPage.count == 2)
        #expect(secondPage.count == 2)
        try assertReplayPayloads(firstPage + secondPage)
        await #expect(throws: RequestPersistenceError.staleRevision) {
            try await store.commit(mutation)
        }

        try store.close()
        try await assertRestoredLifecycle(
            committed.lifecycle,
            submission: submission,
            database: testDatabase
        )
        try assertAcknowledgementPersisted(in: testDatabase.databaseURL)
    }

    @Test("Rejects malformed persisted lifecycle state")
    func rejectsCorruptLifecycle() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let submission = try makeSubmission()
        let store = try testDatabase.makeStore()
        _ = try await store.accept(submission)
        try store.close()
        try corruptRequestState(in: testDatabase.databaseURL)
        let reopenedStore = try testDatabase.makeStore()
        defer { try? reopenedStore.close() }

        await #expect(throws: SQLiteStorageError.corruptData) {
            try await reopenedStore.request(
                requestID: submission.requestID,
                callerID: submission.callerID
            )
        }
    }

    @Test("Prunes terminal payloads but preserves an expiry tombstone")
    func preservesTombstoneAfterPruning() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeStore(date: timestamp)
        defer { try? store.close() }
        let submission = try makeSubmission()
        let accepted = try acceptedRequest(from: await store.accept(submission))
        var lifecycle = accepted.lifecycle
        lifecycle.requestCancellation()
        let mutation = RequestMutation(
            requestID: submission.requestID,
            callerID: submission.callerID,
            expectedRevision: accepted.revision,
            lifecycle: lifecycle,
            events: [PendingRequestEvent(payload: .cancellation(.confirmed))]
        )
        _ = try await store.commit(mutation)

        try await store.pruneTerminalRequests(before: timestamp.addingTimeInterval(1))

        #expect(
            try await store.request(
                requestID: submission.requestID,
                callerID: submission.callerID
            ) == nil
        )
        await #expect(throws: RequestPersistenceError.replayExpired) {
            try await store.replay(
                requestID: submission.requestID,
                callerID: submission.callerID,
                after: nil,
                limit: 10
            )
        }
        await #expect(throws: RequestPersistenceError.replayExpired) {
            try await store.accept(submission)
        }
    }

    @Test("Rolls back admission when the content quota is exhausted")
    func rollsBackQuotaExhaustion() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let configuration = try SQLiteStorageConfiguration(
            maximumDatabaseBytes: 1,
            maximumReplayPageSize: 10,
            busyTimeout: 1,
            maximumReaderCount: 1
        )
        let store = try testDatabase.makeStore(configuration: configuration)
        defer { try? store.close() }
        let submission = try makeSubmission()

        await #expect(throws: RequestPersistenceError.resourceExhausted) {
            try await store.accept(submission)
        }
        #expect(
            try await store.request(
                requestID: submission.requestID,
                callerID: submission.callerID
            ) == nil
        )
        await #expect(throws: SQLiteStorageError.invalidReplayLimit) {
            try await store.replay(
                requestID: submission.requestID,
                callerID: submission.callerID,
                after: nil,
                limit: 11
            )
        }
    }
}

private extension SQLiteJobStoreTests {
    private func makeRunningMutation(
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

    private func assertReplayPayloads(_ events: [PersistedRequestEvent]) throws {
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

    private func assertRestoredLifecycle(
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

    private func assertAcknowledgementPersisted(in databaseURL: URL) throws {
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
        #expect(migrations == ["v1_request_store"])
    }

    private func corruptRequestState(in databaseURL: URL) throws {
        let database = try DatabaseQueue(path: databaseURL.path)
        try database.write { database in
            try database.execute(
                sql: "UPDATE request SET state = ? WHERE requestID = ?",
                arguments: ["unknown-state", "request-1"]
            )
        }
    }
}
