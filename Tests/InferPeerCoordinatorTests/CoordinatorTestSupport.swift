import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import Testing

final class TestCoordinatorListener: CoordinatorTransportListener, @unchecked Sendable {
    private let pair = InboundPeerSessionStream.makeStream()

    func sessions(bufferingLimit: Int) -> InboundPeerSessionStream {
        pair.stream
    }

    func emit(_ session: InboundPeerSession) {
        pair.continuation.yield(session)
    }

    func close() {
        pair.continuation.finish()
    }
}

final class TestCoordinatorCallerSession: CoordinatorCallerSession, @unchecked Sendable {
    let authenticatedPeerID: PeerID
    private let requestPair = CallerRequestStream.makeStream()
    private let responsePair = CallerResponseStream.makeStream()

    init(peerID: PeerID) {
        authenticatedPeerID = peerID
    }

    func requests(bufferingLimit: Int) -> CallerRequestStream {
        requestPair.stream
    }

    func send(_ response: InferPeer_V1_ClientSessionResponse) throws {
        responsePair.continuation.yield(response)
    }

    func close() {
        requestPair.continuation.finish()
        responsePair.continuation.finish()
    }

    func emit(_ request: InferPeer_V1_ClientSessionRequest) {
        requestPair.continuation.yield(request)
    }

    func responses() -> CallerResponseStream {
        responsePair.stream
    }
}

final class TestCoordinatorWorkerSession: CoordinatorWorkerSession, @unchecked Sendable {
    let authenticatedPeerID: PeerID
    private let requestPair = WorkerRequestStream.makeStream()
    private let responsePair = WorkerResponseStream.makeStream()

    init(peerID: PeerID) {
        authenticatedPeerID = peerID
    }

    func requests(bufferingLimit: Int) -> WorkerRequestStream {
        requestPair.stream
    }

    func send(_ response: InferPeer_V1_WorkerSessionResponse) throws {
        responsePair.continuation.yield(response)
    }

    func close() {
        requestPair.continuation.finish()
        responsePair.continuation.finish()
    }

    func emit(_ request: InferPeer_V1_WorkerSessionRequest) {
        requestPair.continuation.yield(request)
    }

    func disconnect() {
        requestPair.continuation.finish()
    }

    func responses() -> WorkerResponseStream {
        responsePair.stream
    }

    func clientSend(_ request: InferPeer_V1_WorkerSessionRequest) {
        requestPair.continuation.yield(request)
    }

    func clientResponses() -> WorkerResponseStream {
        responsePair.stream
    }
}

struct TestWorkerClientSession: WorkerTransportSession {
    let coordinatorSession: TestCoordinatorWorkerSession

    func send(_ request: InferPeer_V1_WorkerSessionRequest) throws {
        coordinatorSession.clientSend(request)
    }

    func responses(bufferingLimit: Int) -> WorkerResponseStream {
        coordinatorSession.clientResponses()
    }

    func close() {
        coordinatorSession.close()
    }
}

struct FixedWorkerStatusProvider: StatusProvider {
    let value: LocalWorkerStatus

    func currentStatus() -> LocalWorkerStatus {
        value
    }

    func updates(bufferingLimit: Int) -> WorkerStatusStream {
        WorkerStatusStream { $0.finish() }
    }
}

actor CompletingInferenceBackend: InferenceBackend {
    private let output: String

    init(output: String) {
        self.output = output
    }

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate()
    }

    func loadModel(_ model: LocalModelArtifact) {}

    func unloadModel(_ reference: ModelReference) {}

    func generate(_ execution: InferenceExecution) throws -> GenerationEventStream {
        let delta = try TextDelta(output)
        let result = GenerationResult(
            fullText: output,
            modelUsed: execution.model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 1, outputTokens: 1)
        )
        return GenerationEventStream { continuation in
            continuation.yield(.textDelta(delta))
            continuation.yield(.completed(result))
            continuation.finish()
        }
    }

    func cancel(attemptID: AttemptID) {}
}

actor TestLocalWorker: CoordinatorLocalWorker {
    nonisolated let peerID: PeerID
    private let model: ModelReference
    private let output: String
    private let modelSnapshot: WorkerModelSnapshot
    private let delta: TextDelta
    private var participation = WorkerParticipationState.available
    private(set) var startedAttemptIDs: [AttemptID] = []

    init(peerID: PeerID, model: ModelReference, output: String = "local") throws {
        self.peerID = peerID
        self.model = model
        self.output = output
        modelSnapshot = try WorkerModelSnapshot(
            model: model,
            isLoaded: true,
            measuredMemoryBytes: 1_000,
            estimatedLoadDuration: .zero
        )
        delta = try TextDelta(output)
    }

    func status() -> LocalWorkerStatus {
        LocalWorkerStatus(
            condition: WorkerCondition(
                participation: participation,
                thermalState: .nominal,
                lowPowerModeEnabled: false
            ),
            load: WorkerLoad(
                activeGenerations: 0,
                generationCapacity: 1,
                availableAppMemoryBytes: 4_000_000_000
            ),
            models: [modelSnapshot]
        )
    }

    func start(_ assignment: WorkerExecutionAssignment) -> GenerationEventStream {
        startedAttemptIDs.append(assignment.execution.attemptID)
        let model = model
        let output = output
        let delta = delta
        return GenerationEventStream { continuation in
            continuation.yield(.textDelta(delta))
            continuation.yield(
                .completed(
                    GenerationResult(
                        fullText: output,
                        modelUsed: model,
                        finishReason: .stop,
                        usage: TokenUsage(promptTokens: 1, outputTokens: 1)
                    )))
            continuation.finish()
        }
    }

    func renewLease(
        attemptID: AttemptID,
        until deadline: MonotonicInstant,
        coordinatorIncarnationID: CoordinatorIncarnationID
    ) {}

    func cancel(attemptID: AttemptID) {}

    func complete(attemptID: AttemptID) {}

    func setParticipation(_ participation: WorkerParticipationState) {
        self.participation = participation
    }
}

final class CoordinatorTestClock: CoreClock, CoreWallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = MonotonicInstant(nanoseconds: 1_000_000_000)
    private var date = Date(timeIntervalSince1970: 10_000)

    func now() -> MonotonicInstant {
        lock.withLock { instant }
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by seconds: UInt64) {
        lock.withLock {
            instant = MonotonicInstant(
                nanoseconds: instant.nanoseconds + seconds * 1_000_000_000
            )
            date = date.addingTimeInterval(TimeInterval(seconds))
        }
    }
}

struct CoordinatorStoreFixture {
    let directory: URL
    let store: SQLiteJobStore

    init(configuration: SQLiteStorageConfiguration = .standard) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferpeer-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = try SQLiteJobStore(
            databaseURL: directory.appendingPathComponent("jobs.sqlite"),
            configuration: configuration
        )
    }

    func remove() {
        try? store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

func makeCoordinatorConfiguration(
    coordinator: String = "coordinator",
    incarnation: String = "incarnation-new"
) throws -> CoordinatorConfiguration {
    try CoordinatorConfiguration(
        clusterID: #require(ClusterID(rawValue: "cluster-1")),
        coordinatorID: #require(PeerID(rawValue: coordinator)),
        incarnationID: #require(CoordinatorIncarnationID(rawValue: incarnation)),
        maintenanceInterval: .seconds(30)
    )
}

func makeCoordinatorModel() throws -> ModelReference {
    try ModelReference(
        modelID: #require(ModelID(rawValue: "model-1")),
        revision: "revision-1"
    )
}

func makeSubmitCommand(
    requestID: RequestID,
    callerID: PeerID,
    model: ModelReference
) throws -> InferPeer_V1_ClientSessionRequest {
    let context = try ConversationContext(
        conversationID: #require(ConversationID(rawValue: "conversation-1")),
        revision: 1,
        messages: [try TextMessage(role: .user, text: "Hello")]
    )
    let request = TextGenerationRequest(
        context: context,
        options: try GenerationOptions(modelRequirement: .exact(model), maximumOutputTokens: 8)
    )
    return InferPeer_V1_ClientSessionRequest.with {
        $0.metadata.requestID = requestID.rawValue
        $0.submit.request = request.wireValue
        $0.submit.immutableInputSha256 = Data(repeating: 0xA5, count: 32)
    }
}

func makeWorkerStatus(
    workerID: PeerID,
    model: ModelReference
) -> InferPeer_V1_WorkerSessionRequest {
    InferPeer_V1_WorkerSessionRequest.with {
        $0.metadata.authenticatedSenderID = workerID.rawValue
        $0.status.participation = .available
        $0.status.thermalState = .nominal
        $0.status.activeGenerations = 0
        $0.status.generationCapacity = 1
        $0.status.models = [
            InferPeer_V1_ModelStatus.with {
                $0.model = model.wireValue
                $0.loaded = true
                $0.measuredMemoryBytes = 1_000
            }
        ]
    }
}

func collectUntilCompleted(
    _ stream: CallerResponseStream
) async throws -> [InferPeer_V1_ClientSessionResponse] {
    try await withThrowingTaskGroup(of: [InferPeer_V1_ClientSessionResponse].self) { group in
        group.addTask {
            var responses: [InferPeer_V1_ClientSessionResponse] = []
            for try await response in stream {
                responses.append(response)
                if case .requestStateChanged(let changed) = response.payload,
                    changed.state == .completed
                {
                    return responses
                }
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

enum CoordinatorTestError: Error {
    case streamEnded
    case completionTimeout
    case assignmentTimeout
}
