import Foundation
@testable import InferPeerCore
import InferPeerProtocol
import Testing

@Suite("Coordinator reliability")
struct CoordinatorReliabilityTests {
    @Test("A missed remote heartbeat retries on the eligible local worker")
    func retriesAfterHeartbeatExpiry() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let clock = CoordinatorTestClock()
        let model = try makeCoordinatorModel()
        let localID = try #require(PeerID(rawValue: "z-local"))
        let remoteID = try #require(PeerID(rawValue: "a-remote"))
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let localWorker = try TestLocalWorker(peerID: localID, model: model)
        let remote = TestCoordinatorWorkerSession(peerID: remoteID)
        let caller = TestCoordinatorCallerSession(peerID: callerID)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard),
            clock: clock,
            wallClock: clock,
            localWorker: localWorker
        )
        try await engine.start(listener: TestCoordinatorListener())
        try await registerRemoteWorker(remote, model: model, engine: engine)
        await engine.acceptCaller(caller)
        let completed = Task { try await collectUntilCompleted(caller.responses()) }
        let assignment = Task { try await nextAssignment(remote.responses()) }
        let requestID = try #require(RequestID(rawValue: "request-heartbeat"))

        try await submit(requestID, callerID: callerID, model: model, to: engine)
        let assigned = try await assignment.value
        try await acceptRemoteAssignment(
            assigned,
            requestID: requestID,
            workerID: remoteID,
            engine: engine
        )
        clock.advance(by: 16)
        await engine.performMaintenance()
        let responses = try await completed.value

        #expect(responses.contains { $0.generationEvent.interrupted.willRetry })
        #expect(responses.last?.requestStateChanged.state == .completed)
        #expect(await localWorker.startedAttemptIDs.count == 1)
        await engine.stop()
    }

    @Test("A queued request with no eligible worker expires at its original deadline")
    func expiresQueuedRequest() async throws {
        let fixture = try CoordinatorStoreFixture()
        defer { fixture.remove() }
        let clock = CoordinatorTestClock()
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let caller = TestCoordinatorCallerSession(peerID: callerID)
        let engine = CoordinatorEngine(
            configuration: try makeCoordinatorConfiguration(),
            store: fixture.store,
            scheduler: DefaultSchedulerPolicy(configuration: .standard),
            clock: clock
        )
        try await engine.start(listener: TestCoordinatorListener())
        await engine.acceptCaller(caller)
        let expired = Task { try await collectUntilState(.expired, from: caller.responses()) }
        let requestID = try #require(RequestID(rawValue: "request-timeout"))
        let command = try makeSubmitCommand(
            requestID: requestID,
            callerID: callerID,
            model: makeCoordinatorModel()
        )

        try await engine.submit(command.submit, requestID: requestID, callerID: callerID)
        clock.advance(by: 121)
        await engine.performMaintenance()
        let responses = try await expired.value
        let stored = try await fixture.store.request(requestID: requestID, callerID: callerID)

        #expect(stored?.lifecycle.state == .expired)
        #expect(responses.contains { $0.requestFailed.error.code == .deadlineExceeded })
        await engine.stop()
    }
}

private func nextAssignment(
    _ stream: WorkerResponseStream
) async throws -> InferPeer_V1_WorkerSessionResponse {
    for try await response in stream {
        if case .assignment = response.payload { return response }
    }
    throw CoordinatorTestError.streamEnded
}

private func collectUntilState(
    _ state: InferPeer_V1_RequestState,
    from stream: CallerResponseStream
) async throws -> [InferPeer_V1_ClientSessionResponse] {
    try await withThrowingTaskGroup(of: [InferPeer_V1_ClientSessionResponse].self) { group in
        group.addTask {
            var responses: [InferPeer_V1_ClientSessionResponse] = []
            var observedState = false
            for try await response in stream {
                responses.append(response)
                if response.requestStateChanged.state == state { observedState = true }
                if observedState, case .requestFailed = response.payload { return responses }
            }
            throw CoordinatorTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw CoordinatorTestError.completionTimeout
        }
        defer { group.cancelAll() }
        return try await group.next() ?? []
    }
}
