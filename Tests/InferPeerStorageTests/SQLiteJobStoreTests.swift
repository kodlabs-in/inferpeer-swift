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

    @Test("Concurrent lifecycle commits preserve one atomic winner")
    func serializesConcurrentLifecycleCommits() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeStore()
        defer { try? store.close() }
        let submission = try makeSubmission()
        let accepted = try acceptedRequest(from: await store.accept(submission))
        let running = try makeRunningMutation(from: accepted)
        let cancelled = makeQueuedCancellationMutation(from: accepted)

        async let runningOutcome = commitOutcome(running, to: store)
        async let cancellationOutcome = commitOutcome(cancelled, to: store)
        let outcomes = await [runningOutcome, cancellationOutcome]
        let restored = try await store.request(
            requestID: submission.requestID,
            callerID: submission.callerID
        )

        #expect(outcomes.filter(\.succeeded).count == 1)
        #expect(outcomes.filter(\.lostRevisionRace).count == 1)
        #expect(restored?.revision == 1)
        #expect(restored?.lifecycle.state == .running || restored?.lifecycle.state == .cancelled)
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
        await #expect(throws: RequestPersistenceError.self) {
            try await store.replay(
                requestID: submission.requestID,
                callerID: submission.callerID,
                after: nil,
                limit: 10
            )
        }
        await #expect(throws: RequestPersistenceError.self) {
            try await store.accept(submission)
        }
    }
}

extension SQLiteJobStoreTests {
    @Test("An expired replay retains its successful terminal result")
    func retainsTerminalResultAfterPruning() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeStore(date: timestamp)
        defer { try? store.close() }
        let submission = try makeSubmission()
        let accepted = try acceptedRequest(from: await store.accept(submission))
        let completion = try makeStoredCompletion(from: accepted)
        _ = try await store.commit(completion.mutation)
        try await store.pruneTerminalRequests(before: timestamp.addingTimeInterval(1))

        do {
            _ = try await store.replay(
                requestID: submission.requestID,
                callerID: submission.callerID,
                after: nil,
                limit: 10
            )
            Issue.record("Expected replay expiry")
        } catch RequestPersistenceError.replayExpired(let retained) {
            #expect(retained?.attemptID == completion.attemptID)
            #expect(retained?.result == completion.result)
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

    @Test("Enforces pending queue limits without rejecting duplicates")
    func enforcesPendingQueueLimits() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let configuration = try SQLiteStorageConfiguration(
            maximumDatabaseBytes: 256 * 1_024 * 1_024,
            maximumReplayPageSize: 10,
            maximumPendingRequests: 1,
            maximumPendingRequestsPerCaller: 1,
            busyTimeout: 1,
            maximumReaderCount: 1
        )
        let store = try testDatabase.makeStore(configuration: configuration)
        defer { try? store.close() }
        let first = try makeSubmission()
        _ = try await store.accept(first)

        guard case .duplicate = try await store.accept(first) else {
            Issue.record("Expected a duplicate while the queue is full")
            return
        }
        await #expect(throws: RequestPersistenceError.resourceExhausted) {
            try await store.accept(makeSubmission(request: "request-2", revision: 2))
        }
    }

    @Test("Lists nonterminal requests deterministically for recovery")
    func listsNonterminalRequests() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeStore()
        defer { try? store.close() }
        let first = try makeSubmission()
        let second = try makeSubmission(request: "request-2", revision: 2)
        _ = try await store.accept(first)
        _ = try await store.accept(second)

        let recovered = try await store.nonterminalRequests(limit: 10)

        #expect(recovered.map(\.submission.requestID) == [first.requestID, second.requestID])
        #expect(recovered.allSatisfy { $0.acceptedAt.timeIntervalSince1970 > 0 })
    }

    @Test("Conversation revisions advance per caller across coordinator restarts")
    func enforcesConversationRevisions() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        var store = try testDatabase.makeStore()
        _ = try await store.accept(makeSubmission(revision: 2))
        try store.close()
        store = try testDatabase.makeStore()
        defer { try? store.close() }

        await #expect(throws: RequestPersistenceError.conversationRevisionNotIncreasing) {
            try await store.accept(makeSubmission(request: "request-regressed", revision: 1))
        }
        await #expect(throws: Never.self) {
            try await store.accept(
                makeSubmission(request: "request-other-caller", caller: "caller-2", revision: 1)
            )
        }
    }
}
