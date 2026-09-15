@testable import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

struct SeededCoordinatorRequest {
    let requestID: RequestID
    let callerID: PeerID
}

func submit(
    _ requestID: RequestID,
    callerID: PeerID,
    model: ModelReference,
    to engine: CoordinatorEngine
) async throws {
    let command = try makeSubmitCommand(
        requestID: requestID,
        callerID: callerID,
        model: model
    )
    try await engine.submit(command.submit, requestID: requestID, callerID: callerID)
}

func registerRemoteWorker(
    _ remote: TestCoordinatorWorkerSession,
    model: ModelReference,
    engine: CoordinatorEngine
) async throws {
    let workerID = remote.authenticatedPeerID
    await engine.acceptWorker(remote)
    try await engine.updateWorker(
        peerID: workerID,
        status: LocalWorkerStatus(
            wireValue: makeWorkerStatus(workerID: workerID, model: model).status
        )
    )
}

func acceptRemoteAssignment(
    _ assignment: InferPeer_V1_WorkerSessionResponse,
    requestID: RequestID,
    workerID: PeerID,
    engine: CoordinatorEngine
) async throws {
    try await engine.acceptAttempt(
        AttemptContext(
            requestID: requestID,
            attemptID: try #require(AttemptID(rawValue: assignment.metadata.attemptID)),
            workerID: workerID
        )
    )
}

func assertRetryResponses(
    _ responses: [InferPeer_V1_ClientSessionResponse],
    assignment: InferPeer_V1_AttemptAssignment,
    localWorker: TestLocalWorker
) async {
    let deltas = responses.compactMap { response -> (String, String)? in
        guard case .textDelta(let delta) = response.generationEvent.payload else { return nil }
        return (response.metadata.attemptID, delta.text)
    }
    let interruptions = responses.compactMap { response -> InferPeer_V1_GenerationInterrupted? in
        guard case .interrupted(let event) = response.generationEvent.payload else { return nil }
        return event
    }

    #expect(assignment.attemptNumber == 1)
    #expect(deltas.map(\.1) == ["old", "local"])
    #expect(Set(deltas.map(\.0)).count == 2)
    #expect(interruptions.contains { $0.willRetry })
    #expect(responses.last?.requestStateChanged.attemptNumber == 2)
    #expect(await localWorker.startedAttemptIDs.count == 1)
}

func seedOldActiveRequest(in store: SQLiteJobStore) async throws -> SeededCoordinatorRequest {
    let callerID = try #require(PeerID(rawValue: "caller-1"))
    let workerID = try #require(PeerID(rawValue: "worker-1"))
    let requestID = try #require(RequestID(rawValue: "request-recovery"))
    let submission = try storedSubmission(
        requestID: requestID,
        callerID: callerID,
        model: makeCoordinatorModel()
    )
    let accepted = try accepted(try await store.accept(submission))
    var lifecycle = accepted.lifecycle
    let attemptID = try #require(AttemptID(rawValue: "attempt-old"))
    _ = try lifecycle.assign(
        attemptID: attemptID,
        workerID: workerID,
        coordinatorIncarnationID: #require(
            CoordinatorIncarnationID(rawValue: "incarnation-old")
        ),
        leaseDeadline: MonotonicInstant(nanoseconds: .max)
    )
    try lifecycle.accept(attemptID: attemptID)
    _ = try await store.commit(
        RequestMutation(
            requestID: requestID,
            callerID: callerID,
            expectedRevision: accepted.revision,
            lifecycle: lifecycle,
            events: []
        )
    )
    return SeededCoordinatorRequest(requestID: requestID, callerID: callerID)
}
