import Foundation
import InferPeerProtocol
import InferPeerStorage
import Testing

@Suite("SQLite direct request metadata store")
struct SQLiteDirectRequestStoreTests {
    @Test("Persists deduplication metadata without request or output payloads")
    func persistsAndDeduplicatesMetadata() async throws {
        let database = try StorageTestDatabase()
        defer { database.remove() }
        let requestID = try #require(RequestID(rawValue: "direct-request-1"))
        let firstStore = try database.makeDirectRequestStore()
        let admission = try DirectRequestAdmission(
            principalID: "principal-1",
            requestID: requestID,
            resourceID: "resource-1",
            specificationDigest: Data(repeating: 0xA5, count: 32),
            modelID: "model-1",
            modelRevision: "revision-1",
            processIncarnation: "process-1",
            originalTimeoutMilliseconds: 120_000
        )

        guard case .accepted = try await firstStore.accept(admission) else {
            Issue.record("Expected a new direct request admission")
            return
        }
        try firstStore.close()

        let reopened = try database.makeDirectRequestStore()
        defer { try? reopened.close() }
        guard case .duplicate(let restored) = try await reopened.accept(admission) else {
            Issue.record("Expected durable deduplication")
            return
        }

        #expect(restored.state == .accepted)
        #expect(restored.specificationDigest == admission.specificationDigest)
        #expect(restored.processIncarnation == "process-1")
    }

    @Test("A new process marks accepted nonterminal requests interrupted")
    func restartMarksNonterminalRequestsInterrupted() async throws {
        let database = try StorageTestDatabase()
        defer { database.remove() }
        let store = try database.makeDirectRequestStore()
        defer { try? store.close() }
        let requestID = try #require(RequestID(rawValue: "direct-request-2"))
        let admission = try DirectRequestAdmission(
            principalID: "principal-1",
            requestID: requestID,
            resourceID: "resource-1",
            specificationDigest: Data(repeating: 0xB6, count: 32),
            modelID: "model-1",
            modelRevision: "revision-1",
            processIncarnation: "process-1",
            originalTimeoutMilliseconds: 120_000
        )
        _ = try await store.accept(admission)

        let interrupted = try await store.interruptNonterminalRequests(
            preceding: "process-2"
        )
        let restored = try await store.request(
            principalID: admission.principalID,
            requestID: requestID
        )

        #expect(interrupted == 1)
        #expect(restored?.state == .interrupted)
        #expect(restored?.processIncarnation == "process-1")
    }

    @Test("Cancellation and completion obey the first committed terminal outcome")
    func terminalTransitionRacesAreSerialized() async throws {
        let database = try StorageTestDatabase()
        defer { database.remove() }
        let store = try database.makeDirectRequestStore()
        defer { try? store.close() }
        let requestID = try #require(RequestID(rawValue: "direct-request-race"))
        let admission = try makeDirectAdmission(requestID: requestID, digestByte: 0xC7)
        _ = try await store.accept(admission)
        _ = try await store.transition(
            principalID: admission.principalID,
            requestID: requestID,
            to: .running
        )
        _ = try await store.transition(
            principalID: admission.principalID,
            requestID: requestID,
            to: .cancelRequested
        )

        await #expect(throws: DirectRequestStoreError.invalidTransition) {
            _ = try await store.transition(
                principalID: admission.principalID,
                requestID: requestID,
                to: .completed
            )
        }
        let cancelled = try await store.transition(
            principalID: admission.principalID,
            requestID: requestID,
            to: .cancelled
        )
        let lateCompletion = try await store.transition(
            principalID: admission.principalID,
            requestID: requestID,
            to: .completed
        )

        #expect(cancelled.state == .cancelled)
        #expect(lateCompletion.state == .cancelled)
    }
}

private func makeDirectAdmission(
    requestID: RequestID,
    digestByte: UInt8
) throws -> DirectRequestAdmission {
    try DirectRequestAdmission(
        principalID: "principal-1",
        requestID: requestID,
        resourceID: "resource-1",
        specificationDigest: Data(repeating: digestByte, count: 32),
        modelID: "model-1",
        modelRevision: "revision-1",
        processIncarnation: "process-1",
        originalTimeoutMilliseconds: 120_000
    )
}
