import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Worker controller")
struct WorkerControllerTests {
    @Test("Runs a backend attempt and records completion")
    func runsAndCompletesAttempt() async throws {
        let backend = RecordingCoreBackend()
        let assignment = try makeAssignment(leaseDeadline: 20)
        let controller = WorkerController(
            backend: backend,
            clock: FixedClock(nanoseconds: 10)
        )

        let stream = try await controller.start(assignment)
        for try await _ in stream {}
        try await controller.complete(assignment.execution.attemptID)

        #expect(await backend.executions() == [assignment.execution])
        #expect(await controller.lifecycle()?.state == .completed)
    }

    @Test("Forwards cooperative cancellation to the active backend attempt")
    func cancelsActiveAttempt() async throws {
        let backend = RecordingCoreBackend()
        let assignment = try makeAssignment(leaseDeadline: 20)
        let controller = WorkerController(
            backend: backend,
            clock: FixedClock(nanoseconds: 10)
        )

        _ = try await controller.start(assignment)
        try await controller.requestCancellation(for: assignment.execution.attemptID)
        try await controller.confirmCancellation(for: assignment.execution.attemptID)

        #expect(await backend.cancellations() == [assignment.execution.attemptID])
        #expect(await controller.lifecycle()?.state == .cancelled)
    }

    @Test("Expires a lease using only monotonic time")
    func expiresLease() async throws {
        let backend = RecordingCoreBackend()
        let assignment = try makeAssignment(leaseDeadline: 10)
        let controller = WorkerController(
            backend: backend,
            clock: FixedClock(nanoseconds: 10)
        )

        await #expect(throws: WorkerAttemptTransitionError.leaseExpired) {
            _ = try await controller.start(assignment)
        }
        #expect(await backend.executions().isEmpty)
    }

    private func makeAssignment(leaseDeadline: UInt64) throws -> WorkerExecutionAssignment {
        let requestID = try #require(RequestID(rawValue: "request-1"))
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
        let coordinatorID = try #require(
            CoordinatorIncarnationID(rawValue: "coordinator-1")
        )
        let modelID = try #require(ModelID(rawValue: "model-1"))
        let model = try ModelReference(modelID: modelID, revision: "revision-1")
        let context = try ConversationContext(
            conversationID: conversationID,
            revision: 1,
            messages: [try TextMessage(role: .user, text: "Hello")]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(model),
            maximumOutputTokens: 32
        )
        let execution = InferenceExecution(
            requestID: requestID,
            attemptID: attemptID,
            model: model,
            request: TextGenerationRequest(context: context, options: options)
        )
        return WorkerExecutionAssignment(
            execution: execution,
            coordinatorIncarnationID: coordinatorID,
            leaseDeadline: MonotonicInstant(nanoseconds: leaseDeadline)
        )
    }
}

private struct FixedClock: CoreClock {
    let instant: MonotonicInstant

    init(nanoseconds: UInt64) {
        instant = MonotonicInstant(nanoseconds: nanoseconds)
    }

    func now() -> MonotonicInstant {
        instant
    }
}

private actor RecordingCoreBackend: InferenceBackend {
    private var recordedExecutions: [InferenceExecution] = []
    private var cancelledAttempts: [AttemptID] = []

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate()
    }

    func loadModel(_ model: LocalModelArtifact) throws {}

    func unloadModel(_ reference: ModelReference) throws {}

    func generate(_ execution: InferenceExecution) throws -> GenerationEventStream {
        recordedExecutions.append(execution)
        return GenerationEventStream { continuation in
            continuation.finish()
        }
    }

    func cancel(attemptID: AttemptID) {
        cancelledAttempts.append(attemptID)
    }

    func executions() -> [InferenceExecution] {
        recordedExecutions
    }

    func cancellations() -> [AttemptID] {
        cancelledAttempts
    }
}
