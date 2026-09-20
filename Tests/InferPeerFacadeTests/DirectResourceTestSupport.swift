import Foundation
@testable import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

struct DirectResourceFixture {
    let backend: DirectFakeBackend
    let model: LocalModelArtifact
    let models: [LocalModelArtifact]
    let facade: InferPeer

    init(
        autoComplete: Bool = true,
        discovery: (any ResourceDiscovery)? = nil,
        exposure: (any ResourceExposure)? = nil,
        modelIDs: [String] = ["direct-test-model"],
        failModelLoads: Bool = false,
        modelIdleTimeout: Duration = .seconds(300),
        peakMemoryBytes: UInt64 = 1,
        memoryAvailability: (any MemoryAvailabilityProvider)? = nil,
        runEventBufferLimit: Int = 64,
        maximumPendingLocalRuns: Int = 4,
        sessionManager: (any ResourceSessionManaging)? = nil
    ) throws {
        backend = DirectFakeBackend(
            autoComplete: autoComplete,
            failModelLoads: failModelLoads,
            peakMemoryBytes: peakMemoryBytes
        )
        models = try modelIDs.map {
            try Self.makeModel(id: $0, measuredMemoryBytes: peakMemoryBytes)
        }
        model = models[0]
        facade = try InferPeer(
            configuration: InferPeerConfiguration(
                localResource: LocalResourceConfiguration(
                    displayName: "Test Mac",
                    platform: PlatformDescriptor(
                        operatingSystem: .macOS,
                        operatingSystemVersion: "test"
                    )
                ),
                localRuntime: backend,
                localModels: models,
                defaultTextModel: model.descriptor.reference,
                maximumPendingLocalRuns: maximumPendingLocalRuns,
                runEventBufferLimit: runEventBufferLimit,
                localModelIdleTimeout: modelIdleTimeout,
                memoryAvailability: memoryAvailability,
                discovery: discovery,
                exposure: exposure,
                sessionManager: sessionManager
            )
        )
    }

    func query(text: String = "Keep this run on the selected resource") -> InferenceQuery {
        .text(
            model: .exact(model.descriptor.reference),
            messages: [.user(text)],
            generation: .init(maxOutputTokens: 16, temperature: 0)
        )
    }

    private static func makeModel(
        id: String,
        measuredMemoryBytes: UInt64
    ) throws -> LocalModelArtifact {
        let reference = try ModelReference(
            modelID: requiredID(ModelID.self, value: id),
            revision: "1"
        )
        let descriptor = try ModelDescriptor(
            reference: reference,
            runtimeFormat: .mlx,
            metadata: try ModelMetadata(
                quantization: "test",
                tokenizer: "test",
                chatTemplate: "test",
                license: "test"
            ),
            contextTokenLimit: 128,
            contentDigest: try ModelContentDigest(bytes: Data(repeating: 0xAB, count: 32)),
            measuredMemoryBytes: measuredMemoryBytes
        )
        return try LocalModelArtifact(
            descriptor: descriptor,
            directoryURL: URL(fileURLWithPath: "/tmp/direct-test-model")
        )
    }

    private static func requiredID<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        value: String
    ) -> ProtocolIdentifier<Domain> {
        guard let identifier = ProtocolIdentifier<Domain>(rawValue: value) else {
            preconditionFailure("Test identifier must be valid")
        }
        return identifier
    }
}

struct DirectFixedMemoryAvailability: MemoryAvailabilityProvider {
    let bytes: UInt64?

    func safeAdditionalMemoryBytes() async -> UInt64? {
        await Task.yield()
        return bytes
    }
}

actor DirectFakeExposure: ResourceExposure {
    nonisolated let endpoint: PeerEndpoint
    private let startDelay: Duration
    private var starts = 0
    private var stops = 0

    init(startDelay: Duration = .zero) {
        guard let endpoint = try? PeerEndpoint(host: "127.0.0.1", port: 9443) else {
            preconditionFailure("The fixed fake exposure endpoint must be valid")
        }
        self.endpoint = endpoint
        self.startDelay = startDelay
    }

    func start(configuration: ExposureConfiguration) async throws -> ExposureHandle {
        starts += 1
        if startDelay > .zero { try await Task.sleep(for: startDelay) }
        return ExposureHandle(endpoint: endpoint) { [weak self] in
            await self?.recordStop()
        }
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }

    private func recordStop() {
        stops += 1
    }
}

actor DirectFakeSessionManager: ResourceSessionManaging {
    static let output = "Direct remote execution"

    private var forgotten: [ResourceID] = []
    private var runDestinations: [ResourceID] = []
    private var pairs = 0
    private var reconnectSnapshots: [ResourceSnapshot] = []

    func pair(_ invitation: ResourcePairingInvitation) throws -> ResourceSnapshot {
        pairs += 1
        return ResourceSnapshot(
            id: invitation.resourceID,
            displayName: "Remote Mac",
            platform: PlatformDescriptor(
                operatingSystem: .macOS,
                operatingSystemVersion: "test"
            ),
            connection: .connected,
            execution: .available,
            capabilities: CapabilitySnapshot(supportedTasks: [.textGeneration]),
            models: [],
            revision: 1
        )
    }

    func disconnect(_ resourceID: ResourceID) {}

    func reconnectPairedResources() -> [ResourceSnapshot] { reconnectSnapshots }

    func forget(_ resourceID: ResourceID) {
        forgotten.append(resourceID)
    }

    func prepareModel(_ model: ModelKey, on resourceID: ResourceID) async throws {
        await Task.yield()
    }

    func run(
        _ query: InferenceQuery,
        resourceID: ResourceID,
        options: RunOptions
    ) throws -> RemoteRunExecution {
        runDestinations.append(resourceID)
        guard let requestID = options.requestID ?? RequestID(rawValue: "fake-remote-request") else {
            preconditionFailure("The fixed fake request ID must be valid")
        }
        let model = exactModel(in: query)
        let result = RunResult(
            text: Self.output,
            model: model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 4, outputTokens: 3)
        )
        let pair = RunEventStream.makeStream()
        pair.continuation.yield(.accepted(model: model))
        pair.continuation.yield(.completed(result))
        pair.continuation.finish()
        return RemoteRunExecution(
            requestID: requestID,
            resourceID: resourceID,
            events: pair.stream,
            result: { result },
            cancel: {},
            status: { .completed }
        )
    }

    func stop() {}

    func forgottenResources() -> [ResourceID] { forgotten }
    func runResources() -> [ResourceID] { runDestinations }
    func pairCount() -> Int { pairs }

    func setReconnectSnapshots(_ snapshots: [ResourceSnapshot]) {
        reconnectSnapshots = snapshots
    }

    private func exactModel(in query: InferenceQuery) -> ModelKey {
        guard case .exact(let model) = query.modelSelection else {
            preconditionFailure("This fixture always selects an exact model")
        }
        return model
    }
}

actor DirectFakeDiscovery: ResourceDiscovery {
    private var starts = 0
    private var stops = 0
    private var continuation: DiscoveryEventStream.Continuation?

    func start(options: DiscoveryOptions) throws -> DiscoveryEventStream {
        starts += 1
        let pair = DiscoveryEventStream.makeStream(
            bufferingPolicy: .bufferingNewest(options.eventBufferLimit)
        )
        continuation = pair.continuation
        return pair.stream
    }

    func stop() {
        stops += 1
        continuation?.finish()
        continuation = nil
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

actor DirectFakeBackend: InferenceBackend {
    static let output = "Direct local execution"

    private struct ActiveGeneration {
        let execution: InferenceExecution
        let continuation: GenerationEventStream.Continuation
    }

    private let autoComplete: Bool
    private let failModelLoads: Bool
    private let peakMemoryBytes: UInt64
    private var loadedReferences: [ModelReference] = []
    private var active: [AttemptID: ActiveGeneration] = [:]
    private var startedCount = 0
    private var maximumActiveCount = 0
    private var cancellationCount = 0
    private var unloadedReferences: [ModelReference] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        autoComplete: Bool,
        failModelLoads: Bool = false,
        peakMemoryBytes: UInt64 = 1
    ) {
        self.autoComplete = autoComplete
        self.failModelLoads = failModelLoads
        self.peakMemoryBytes = peakMemoryBytes
    }

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate(peakMemoryBytes: peakMemoryBytes)
    }

    func loadModel(_ model: LocalModelArtifact) throws {
        if failModelLoads {
            throw InferenceBackendError.modelLoadFailed(retryable: false)
        }
        loadedReferences.append(model.descriptor.reference)
    }

    func unloadModel(_ reference: ModelReference) {
        unloadedReferences.append(reference)
    }

    func generate(_ execution: InferenceExecution) throws -> GenerationEventStream {
        let pair = GenerationEventStream.makeStream()
        active[execution.attemptID] = ActiveGeneration(
            execution: execution,
            continuation: pair.continuation
        )
        startedCount += 1
        maximumActiveCount = max(maximumActiveCount, active.count)
        resumeSatisfiedWaiters()
        if autoComplete {
            complete(execution.attemptID)
        }
        return pair.stream
    }

    func cancel(attemptID: AttemptID) {
        guard let generation = active.removeValue(forKey: attemptID) else { return }
        cancellationCount += 1
        generation.continuation.finish(throwing: InferenceBackendError.cancelled)
    }

    func completeAll() {
        for attemptID in Array(active.keys) {
            complete(attemptID)
        }
    }

    func waitUntilGenerationStarts(count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func loadedModels() -> [ModelReference] { loadedReferences }
    func generationCount() -> Int { startedCount }
    func maximumConcurrentGenerations() -> Int { maximumActiveCount }
    func cancelCount() -> Int { cancellationCount }
    func unloadedModels() -> [ModelReference] { unloadedReferences }

    private func complete(_ attemptID: AttemptID) {
        guard let generation = active.removeValue(forKey: attemptID) else { return }
        guard let delta = try? TextDelta(Self.output) else {
            preconditionFailure("The fixed test output must create a valid text delta")
        }
        let usage = TokenUsage(promptTokens: 4, outputTokens: 3)
        let result = GenerationResult(
            fullText: Self.output,
            modelUsed: generation.execution.model,
            finishReason: .stop,
            usage: usage
        )
        generation.continuation.yield(.textDelta(delta))
        generation.continuation.yield(.completed(result))
        generation.continuation.finish()
    }

    private func resumeSatisfiedWaiters() {
        let ready = startWaiters.filter { $0.count <= startedCount }
        startWaiters.removeAll { $0.count <= startedCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

extension RunEvent {
    var kind: String {
        switch self {
        case .accepted: "accepted"
        case .queued: "queued"
        case .loadingModel: "loadingModel"
        case .started: "started"
        case .textDelta: "textDelta"
        case .usage: "usage"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .preprocessing: "preprocessing"
        case .transcriptSegment: "transcriptSegment"
        case .audioChunk: "audioChunk"
        case .expired: "expired"
        case .interrupted: "interrupted"
        }
    }
}
