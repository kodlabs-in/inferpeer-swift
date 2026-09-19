import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Direct run replay store")
struct DirectRunReplayStoreTests {
    @Test("Sequences, acknowledges, and rejects an expired replay cursor")
    func sequencesAndAcknowledgesEvents() async throws {
        let fixture = try ReplayFixture()
        let store = fixture.store
        _ = try await store.register(
            requestID: fixture.requestID,
            immutableRequestDigest: Data([0x01])
        )

        let accepted = try await store.append(
            .accepted(model: fixture.model),
            retainedByteCount: 4,
            to: fixture.requestID
        )
        let text = try await store.append(
            .textDelta("hello"),
            retainedByteCount: 5,
            to: fixture.requestID
        )

        #expect(accepted.sequence == 1)
        #expect(text.sequence == 2)
        #expect(try await store.replay(after: 0, for: fixture.requestID).map(\.sequence) == [1, 2])

        try await store.acknowledge(through: 1, for: fixture.requestID)
        let snapshot = try await store.snapshot(for: fixture.requestID)

        #expect(snapshot.replayRange == RunReplayRange(first: 2, last: 2))
        #expect(snapshot.acknowledgedThrough == 1)
        #expect(snapshot.retainedByteCount == 5)
        await #expect(throws: DirectRunReplayError.replayExpired(earliestAvailable: 2)) {
            try await store.replay(after: 0, for: fixture.requestID)
        }
    }

    @Test("Never exceeds per-run or resource-wide byte budgets")
    func enforcesByteBudgets() async throws {
        let fixture = try ReplayFixture(perRunBytes: 10, resourceWideBytes: 15)
        let secondRequestID = try #require(RequestID(rawValue: "request-2"))
        _ = try await fixture.store.register(
            requestID: fixture.requestID,
            immutableRequestDigest: Data([0x01])
        )
        _ = try await fixture.store.register(
            requestID: secondRequestID,
            immutableRequestDigest: Data([0x02])
        )
        _ = try await fixture.store.append(
            .textDelta("12345678"),
            retainedByteCount: 8,
            to: fixture.requestID
        )

        let perRun = try await fixture.store.offer(
            .textDelta("abc"),
            retainedByteCount: 3,
            to: fixture.requestID
        )
        let global = try await fixture.store.offer(
            .textDelta("abcdefgh"),
            retainedByteCount: 8,
            to: secondRequestID
        )

        #expect(perRun == .backpressured(.perRun))
        #expect(global == .backpressured(.resourceWide))
        #expect(await fixture.store.usage().retainedByteCount == 8)
    }

    @Test("A disconnected producer requests cancellation at budget or grace limits")
    func disconnectCancellationBoundaries() async throws {
        let fixture = try ReplayFixture(perRunBytes: 10, disconnectGrace: .seconds(30))
        _ = try await fixture.store.register(
            requestID: fixture.requestID,
            immutableRequestDigest: Data([0x01])
        )
        _ = try await fixture.store.append(
            .textDelta("12345678"),
            retainedByteCount: 8,
            to: fixture.requestID
        )
        try await fixture.store.markDisconnected(fixture.requestID)

        let budget = try await fixture.store.offer(
            .textDelta("abc"),
            retainedByteCount: 3,
            to: fixture.requestID
        )

        #expect(budget == .cancellationRequired(.outputBackpressure))

        let graceFixture = try ReplayFixture(disconnectGrace: .seconds(30))
        _ = try await graceFixture.store.register(
            requestID: graceFixture.requestID,
            immutableRequestDigest: Data([0x02])
        )
        try await graceFixture.store.markDisconnected(graceFixture.requestID)
        graceFixture.clock.advance(by: .seconds(29))
        #expect(await graceFixture.store.cancellationsRequired().isEmpty)
        graceFixture.clock.advance(by: .seconds(1))

        let cancellations = await graceFixture.store.cancellationsRequired()
        #expect(cancellations.map(\.requestID) == [graceFixture.requestID])
        #expect(cancellations.first?.reason == .connectionLost)
    }

    @Test("Reconnect before grace expiry preserves replay without cancellation")
    func reconnectWithinGrace() async throws {
        let fixture = try ReplayFixture(disconnectGrace: .seconds(30))
        _ = try await fixture.store.register(
            requestID: fixture.requestID,
            immutableRequestDigest: Data([0x01])
        )
        try await fixture.store.markDisconnected(fixture.requestID)
        fixture.clock.advance(by: .seconds(29))
        try await fixture.store.markConnected(fixture.requestID)
        fixture.clock.advance(by: .seconds(2))

        #expect(await fixture.store.cancellationsRequired().isEmpty)
        #expect(try await fixture.store.snapshot(for: fixture.requestID).connection == .connected)
    }

    @Test("First terminal wins and retained content expires only after acknowledgement")
    func firstTerminalWinsAndExpiresRetainedContent() async throws {
        let fixture = try ReplayFixture(terminalRetention: .seconds(60))
        _ = try await fixture.store.register(
            requestID: fixture.requestID,
            immutableRequestDigest: Data([0x01])
        )
        let result = RunResult(
            text: "done",
            model: fixture.model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 1, outputTokens: 1)
        )

        let completed = try await fixture.store.offer(
            .completed(result),
            retainedByteCount: 6,
            to: fixture.requestID
        )
        let cancelled = try await fixture.store.offer(
            .cancelled,
            retainedByteCount: 1,
            to: fixture.requestID
        )

        #expect(completed.sequence == 1)
        #expect(cancelled == .alreadyTerminal(.completed))
        fixture.clock.advance(by: .seconds(60))
        _ = await fixture.store.expireRetainedTerminalContent()
        #expect(
            try await fixture.store.snapshot(for: fixture.requestID).terminal?.contentAvailable
                == true)

        try await fixture.store.acknowledge(through: 1, for: fixture.requestID)
        let expired = await fixture.store.expireRetainedTerminalContent()
        let snapshot = try await fixture.store.snapshot(for: fixture.requestID)

        #expect(expired == [fixture.requestID])
        #expect(snapshot.terminal?.kind == .completed)
        #expect(snapshot.terminal?.contentAvailable == false)
        #expect(snapshot.retainedByteCount == 0)
    }

    @Test("Registration deduplicates immutable requests and rejects conflicting reuse")
    func immutableRequestDeduplication() async throws {
        let fixture = try ReplayFixture()
        let first = try await fixture.store.register(
            requestID: fixture.requestID,
            immutableRequestDigest: Data([0x01])
        )
        let duplicate = try await fixture.store.register(
            requestID: fixture.requestID,
            immutableRequestDigest: Data([0x01])
        )

        #expect(first == .accepted)
        #expect(duplicate == .duplicate)
        await #expect(throws: DirectRunReplayError.requestConflict) {
            try await fixture.store.register(
                requestID: fixture.requestID,
                immutableRequestDigest: Data([0x02])
            )
        }
    }

    @Test("Consumer cursor ignores duplicates and detects gaps")
    func consumerCursorDetectsGaps() throws {
        var cursor = DirectRunEventCursor(lastAppliedSequence: 4)

        #expect(try cursor.observe(sequence: 4) == .duplicate)
        #expect(try cursor.observe(sequence: 5) == .applied)
        #expect(throws: DirectRunReplayError.sequenceGap(expected: 6, received: 7)) {
            try cursor.observe(sequence: 7)
        }
        #expect(cursor.lastAppliedSequence == 5)
    }
}

private struct ReplayFixture {
    let clock = ReplayTestClock()
    let requestID: RequestID
    let model: ModelKey
    let store: DirectRunReplayStore

    init(
        perRunBytes: UInt64 = 8 * 1_024 * 1_024,
        resourceWideBytes: UInt64 = 64 * 1_024 * 1_024,
        disconnectGrace: Duration = .seconds(30),
        terminalRetention: Duration = .seconds(24 * 60 * 60)
    ) throws {
        requestID = try #require(RequestID(rawValue: "request-1"))
        model = try ModelReference(
            modelID: #require(ModelID(rawValue: "model")),
            revision: "1"
        )
        store = DirectRunReplayStore(
            configuration: ReplayBufferConfiguration(
                perRunByteLimit: perRunBytes,
                resourceWideByteLimit: resourceWideBytes,
                disconnectGrace: disconnectGrace,
                terminalRetention: terminalRetention
            ),
            clock: clock
        )
    }
}

private final class ReplayTestClock: CoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = MonotonicInstant(nanoseconds: 1_000_000_000)

    func now() -> MonotonicInstant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock {
            instant = instant.advanced(by: duration)
        }
    }
}
