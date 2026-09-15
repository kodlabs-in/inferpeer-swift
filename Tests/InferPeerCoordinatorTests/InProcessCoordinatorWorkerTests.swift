import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("In-process coordinator worker")
struct InProcessCoordinatorWorkerTests {
    @Test("Default adapter executes, renews, completes, and cancels serialized work")
    func executesLifecycle() async throws {
        let workerID = try #require(PeerID(rawValue: "local-worker"))
        let model = try makeCoordinatorModel()
        let status = try makeLocalStatus(model: model)
        let backend = LocalAdapterBackend()
        let clock = CoordinatorTestClock()
        let worker = InProcessCoordinatorWorker(
            peerID: workerID,
            statusProvider: FixedWorkerStatusProvider(value: status),
            backend: backend,
            clock: clock
        )
        let first = try makeLocalAssignment(model: model, attemptID: "attempt-1")

        #expect(await worker.status().models == status.models)
        let stream = try await worker.start(first)
        for try await _ in stream {}
        try await worker.renewLease(
            attemptID: first.execution.attemptID,
            until: MonotonicInstant(nanoseconds: 1_000_000_200),
            coordinatorIncarnationID: first.coordinatorIncarnationID
        )
        try await worker.complete(attemptID: first.execution.attemptID)

        let second = try makeLocalAssignment(model: model, attemptID: "attempt-2")
        _ = try await worker.start(second)
        await worker.cancel(attemptID: second.execution.attemptID)

        #expect(await backend.executions == [first.execution, second.execution])
        #expect(await backend.cancellations == [second.execution.attemptID])
    }

    private func makeLocalStatus(model: ModelReference) throws -> LocalWorkerStatus {
        LocalWorkerStatus(
            condition: WorkerCondition(
                participation: .available,
                thermalState: .nominal,
                lowPowerModeEnabled: false
            ),
            load: WorkerLoad(
                activeGenerations: 0,
                generationCapacity: 1,
                availableAppMemoryBytes: 4_000
            ),
            models: [
                try WorkerModelSnapshot(
                    model: model,
                    isLoaded: true,
                    measuredMemoryBytes: 1_000,
                    estimatedLoadDuration: .zero
                )
            ]
        )
    }

    private func makeLocalAssignment(
        model: ModelReference,
        attemptID: String
    ) throws -> WorkerExecutionAssignment {
        let requestID = try #require(RequestID(rawValue: "request-\(attemptID)"))
        let attemptID = try #require(AttemptID(rawValue: attemptID))
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
        let incarnationID = try #require(
            CoordinatorIncarnationID(rawValue: "incarnation-1")
        )
        let context = try ConversationContext(
            conversationID: conversationID,
            revision: 1,
            messages: [try TextMessage(role: .user, text: "Hello")]
        )
        let request = TextGenerationRequest(
            context: context,
            options: try GenerationOptions(
                modelRequirement: .exact(model),
                maximumOutputTokens: 32
            )
        )
        return WorkerExecutionAssignment(
            execution: InferenceExecution(
                requestID: requestID,
                attemptID: attemptID,
                model: model,
                request: request
            ),
            coordinatorIncarnationID: incarnationID,
            leaseDeadline: MonotonicInstant(nanoseconds: 1_000_000_100)
        )
    }
}

private actor LocalAdapterBackend: InferenceBackend {
    private(set) var executions: [InferenceExecution] = []
    private(set) var cancellations: [AttemptID] = []

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate()
    }

    func loadModel(_ model: LocalModelArtifact) {}

    func unloadModel(_ reference: ModelReference) {}

    func generate(_ execution: InferenceExecution) -> GenerationEventStream {
        executions.append(execution)
        return GenerationEventStream { $0.finish() }
    }

    func cancel(attemptID: AttemptID) {
        cancellations.append(attemptID)
    }
}
