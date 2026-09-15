import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Worker session service")
struct WorkerSessionServiceTests {
    @Test("Becoming unavailable cancels active inference and reports interruption")
    func cancelsActiveAssignmentWhenUnavailable() async throws {
        let model = try makeCoordinatorModel()
        let workerID = try #require(PeerID(rawValue: "worker-1"))
        let provider = MutableWorkerStatusProvider(value: try makeStatus(model: model))
        let backend = CancellationRecordingBackend()
        let session = TestCoordinatorWorkerSession(peerID: workerID)
        let service = WorkerSessionService(
            configuration: try WorkerSessionConfiguration(
                clusterID: #require(ClusterID(rawValue: "cluster-1")),
                workerID: workerID
            ),
            statusProvider: provider,
            backend: backend
        )
        let interrupted = Task { try await nextInterruption(session.requests(bufferingLimit: 4)) }
        try await service.start(session: TestWorkerClientSession(coordinatorSession: session))
        try session.send(makeAssignmentResponse(model: model))
        await backend.waitUntilStarted()

        provider.send(try makeStatus(model: model, participation: .unavailable))
        let response = try await interrupted.value

        #expect(response.generationEvent.interrupted.error.code == .workerUnavailable)
        #expect(response.generationEvent.interrupted.willRetry)
        #expect(await backend.cancellationCount == 1)
        await service.stop()
    }

    @Test("Worker rechecks resource, thermal, model, and peer policy before acceptance")
    func rejectsIneligibleAssignments() async throws {
        let model = try makeCoordinatorModel()
        try await assertRejection(
            status: makeStatus(model: model, availableMemory: 500),
            model: model,
            expectedCode: .resourceExhausted
        )
        try await assertRejection(
            status: makeStatus(model: model, thermalState: .serious),
            model: model,
            expectedCode: .workerUnavailable
        )
        try await assertRejection(
            status: makeStatus(model: model, isLoaded: false),
            model: model,
            expectedCode: .modelUnavailable
        )
        try await assertRejection(
            status: makeStatus(model: model),
            model: model,
            allowedWorkerID: "different-worker",
            expectedCode: .permissionDenied
        )
    }

    private func assertRejection(
        status: LocalWorkerStatus,
        model: ModelReference,
        allowedWorkerID: String? = nil,
        expectedCode: InferPeerErrorCode
    ) async throws {
        let workerID = try #require(PeerID(rawValue: "worker-1"))
        let session = TestCoordinatorWorkerSession(peerID: workerID)
        let backend = AdmissionRecordingBackend()
        let service = WorkerSessionService(
            configuration: try WorkerSessionConfiguration(
                clusterID: #require(ClusterID(rawValue: "cluster-1")),
                workerID: workerID
            ),
            statusProvider: FixedWorkerStatusProvider(value: status),
            backend: backend
        )
        let rejection = Task { try await nextAttemptRejection(session.requests(bufferingLimit: 4)) }
        try await service.start(session: TestWorkerClientSession(coordinatorSession: session))
        var assignment = try makeAssignmentResponse(model: model)
        if let allowedWorkerID {
            assignment.assignment.request.allowedWorkerIds = [allowedWorkerID]
        }

        try session.send(assignment)
        let response = try await rejection.value

        #expect(response.attemptRejected.error.code.rawValue == expectedCode.rawValue)
        #expect(await backend.generationCount == 0)
        await service.stop()
    }

    private func makeStatus(
        model: ModelReference,
        participation: WorkerParticipationState = .available,
        thermalState: WorkerThermalState = .nominal,
        availableMemory: UInt64 = 4_000,
        isLoaded: Bool = true
    ) throws -> LocalWorkerStatus {
        LocalWorkerStatus(
            condition: WorkerCondition(
                participation: participation,
                thermalState: thermalState,
                lowPowerModeEnabled: false
            ),
            load: WorkerLoad(
                activeGenerations: 0,
                generationCapacity: 1,
                availableAppMemoryBytes: availableMemory
            ),
            models: [
                try WorkerModelSnapshot(
                    model: model,
                    isLoaded: isLoaded,
                    measuredMemoryBytes: 1_000,
                    estimatedLoadDuration: .zero
                )
            ]
        )
    }

    private func makeAssignmentResponse(
        model: ModelReference
    ) throws -> InferPeer_V1_WorkerSessionResponse {
        let requestID = try #require(RequestID(rawValue: "request-1"))
        let callerID = try #require(PeerID(rawValue: "caller-1"))
        let request = try makeSubmitCommand(
            requestID: requestID,
            callerID: callerID,
            model: model
        ).submit.request
        return InferPeer_V1_WorkerSessionResponse.with {
            $0.metadata.requestID = requestID.rawValue
            $0.metadata.attemptID = "attempt-1"
            $0.assignment.request = request
            $0.assignment.attemptNumber = 1
            $0.assignment.leaseDurationMilliseconds = 20_000
            $0.assignment.coordinatorIncarnationID = "incarnation-1"
            $0.assignment.selectedModel = model.wireValue
        }
    }
}

private final class MutableWorkerStatusProvider: StatusProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalWorkerStatus
    private let pair = WorkerStatusStream.makeStream(bufferingPolicy: .bufferingNewest(1))

    init(value: LocalWorkerStatus) {
        self.value = value
    }

    func currentStatus() -> LocalWorkerStatus {
        lock.withLock { value }
    }

    func updates(bufferingLimit: Int) -> WorkerStatusStream {
        pair.stream
    }

    func send(_ value: LocalWorkerStatus) {
        lock.withLock { self.value = value }
        pair.continuation.yield(value)
    }
}

private actor CancellationRecordingBackend: InferenceBackend {
    private(set) var cancellationCount = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var streamContinuation: GenerationEventStream.Continuation?

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate()
    }

    func loadModel(_ model: LocalModelArtifact) {}

    func unloadModel(_ reference: ModelReference) {}

    func generate(_ execution: InferenceExecution) -> GenerationEventStream {
        let pair = GenerationEventStream.makeStream()
        streamContinuation = pair.continuation
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return pair.stream
    }

    func cancel(attemptID: AttemptID) {
        cancellationCount += 1
        streamContinuation?.finish()
        streamContinuation = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor AdmissionRecordingBackend: InferenceBackend {
    private(set) var generationCount = 0

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate()
    }

    func loadModel(_ model: LocalModelArtifact) {}

    func unloadModel(_ reference: ModelReference) {}

    func generate(_ execution: InferenceExecution) -> GenerationEventStream {
        generationCount += 1
        return GenerationEventStream { $0.finish() }
    }

    func cancel(attemptID: AttemptID) {}
}

private func nextAttemptRejection(
    _ stream: WorkerRequestStream
) async throws -> InferPeer_V1_WorkerSessionRequest {
    try await withThrowingTaskGroup(of: InferPeer_V1_WorkerSessionRequest.self) { group in
        group.addTask {
            for try await request in stream {
                if case .attemptRejected = request.payload { return request }
            }
            throw CoordinatorTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw CoordinatorTestError.assignmentTimeout
        }
        defer { group.cancelAll() }
        guard let response = try await group.next() else { throw CoordinatorTestError.streamEnded }
        return response
    }
}

private func nextInterruption(
    _ stream: WorkerRequestStream
) async throws -> InferPeer_V1_WorkerSessionRequest {
    try await withThrowingTaskGroup(of: InferPeer_V1_WorkerSessionRequest.self) { group in
        group.addTask {
            for try await request in stream {
                if case .interrupted = request.generationEvent.payload { return request }
            }
            throw CoordinatorTestError.streamEnded
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw CoordinatorTestError.assignmentTimeout
        }
        defer { group.cancelAll() }
        return try #require(await group.next())
    }
}
