import InferPeerCore
import InferPeerProtocol
import InferPeerStorage
import Testing

@Suite("SQLite outbox store")
struct SQLiteOutboxStoreTests {
    @Test("Persists an enqueue and deduplicates an identical retry")
    func persistsAndDeduplicates() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let submission = try makeSubmission()
        let store = try testDatabase.makeOutboxStore()

        let first = try await store.enqueue(submission)
        let duplicate = try await store.enqueue(submission)
        try store.close()
        let reopenedStore = try testDatabase.makeOutboxStore()
        defer { try? reopenedStore.close() }
        let pending = try await reopenedStore.pending(callerID: submission.callerID, limit: 10)

        guard case .enqueued(let enqueued) = first,
            case .duplicate(let repeated) = duplicate
        else {
            Issue.record("Expected a new enqueue followed by a duplicate")
            return
        }
        #expect(enqueued == repeated)
        #expect(pending == [enqueued])
    }

    @Test("Rejects conflicting retries and cross-caller removal")
    func rejectsConflictsAndCrossCallerRemoval() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeOutboxStore()
        defer { try? store.close() }
        let submission = try makeSubmission()
        _ = try await store.enqueue(submission)

        await #expect(throws: RequestPersistenceError.requestConflict) {
            try await store.enqueue(makeSubmission(prompt: "Changed"))
        }
        let otherCaller = try #require(PeerID(rawValue: "caller-2"))
        await #expect(throws: RequestPersistenceError.accessDenied) {
            try await store.remove(requestID: submission.requestID, callerID: otherCaller)
        }
        await #expect(throws: SQLiteStorageError.invalidOutboxLimit) {
            try await store.pending(callerID: submission.callerID, limit: 101)
        }
    }

    @Test("Removes an accepted request idempotently")
    func removesIdempotently() async throws {
        let testDatabase = try StorageTestDatabase()
        defer { testDatabase.remove() }
        let store = try testDatabase.makeOutboxStore()
        defer { try? store.close() }
        let submission = try makeSubmission()
        _ = try await store.enqueue(submission)

        try await store.remove(
            requestID: submission.requestID,
            callerID: submission.callerID
        )
        try await store.remove(
            requestID: submission.requestID,
            callerID: submission.callerID
        )

        #expect(try await store.pending(callerID: submission.callerID, limit: 10).isEmpty)
    }
}
