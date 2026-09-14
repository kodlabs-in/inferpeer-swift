import InferPeerProtocol

/// A validated metric in a backend resource estimate.
public enum InferenceResourceMetric: String, Equatable, Sendable {
    /// Estimated peak memory needed by the host app.
    case peakMemory

    /// Estimated time required to load the model.
    case modelLoadDuration

    /// Estimated time required to process the prompt.
    case promptProcessingDuration

    /// Estimated generated tokens per second.
    case generationTokensPerSecond
}

/// Request-specific resource and latency estimates reported by an inference backend.
public struct InferenceResourceEstimate: Equatable, Sendable {
    /// Estimated peak memory required by the app, when known.
    public let peakMemoryBytes: UInt64?

    /// Estimated model loading time, when known.
    public let modelLoadDuration: Duration?

    /// Estimated prompt processing time, when known.
    public let promptProcessingDuration: Duration?

    /// Estimated steady-state generation throughput, when known.
    public let generationTokensPerSecond: Double?

    /// Creates a resource estimate, preserving unavailable metrics as `nil`.
    public init(
        peakMemoryBytes: UInt64? = nil,
        modelLoadDuration: Duration? = nil,
        promptProcessingDuration: Duration? = nil,
        generationTokensPerSecond: Double? = nil
    ) throws {
        if let peakMemoryBytes, peakMemoryBytes == 0 {
            throw InferenceValidationError.invalidResourceEstimate(metric: .peakMemory)
        }
        try Self.validate(modelLoadDuration, metric: .modelLoadDuration)
        try Self.validate(promptProcessingDuration, metric: .promptProcessingDuration)
        if let generationTokensPerSecond,
            !generationTokensPerSecond.isFinite || generationTokensPerSecond <= 0
        {
            throw InferenceValidationError.invalidResourceEstimate(
                metric: .generationTokensPerSecond
            )
        }

        self.peakMemoryBytes = peakMemoryBytes
        self.modelLoadDuration = modelLoadDuration
        self.promptProcessingDuration = promptProcessingDuration
        self.generationTokensPerSecond = generationTokensPerSecond
    }

    private static func validate(
        _ duration: Duration?,
        metric: InferenceResourceMetric
    ) throws {
        guard let duration else { return }
        guard duration >= .zero else {
            throw InferenceValidationError.invalidResourceEstimate(metric: metric)
        }
    }
}

/// A selected logical request and attempt ready for one backend execution.
public struct InferenceExecution: Hashable, Sendable {
    /// The stable logical request identifier.
    public let requestID: RequestID

    /// The unique execution-attempt identifier.
    public let attemptID: AttemptID

    /// The exact model selected for this attempt.
    public let model: ModelReference

    /// The immutable input and generation options.
    public let request: TextGenerationRequest

    /// Creates a backend execution assignment.
    public init(
        requestID: RequestID,
        attemptID: AttemptID,
        model: ModelReference,
        request: TextGenerationRequest
    ) {
        self.requestID = requestID
        self.attemptID = attemptID
        self.model = model
        self.request = request
    }
}

/// The bounded event stream returned by an inference backend.
public typealias GenerationEventStream = AsyncThrowingStream<GenerationEvent, any Error>

/// Backend-neutral lifecycle and text-generation operations implemented by inference adapters.
public protocol InferenceBackend: Sendable {
    /// Estimates resources for one request using a specific registered model.
    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) async throws -> InferenceResourceEstimate

    /// Loads a verified local model artifact for future executions.
    func loadModel(_ model: LocalModelArtifact) async throws

    /// Unloads the matching model and releases its disposable caches.
    func unloadModel(_ reference: ModelReference) async throws

    /// Starts one selected attempt and returns its ordered output stream.
    func generate(_ execution: InferenceExecution) async throws -> GenerationEventStream

    /// Cooperatively cancels one active attempt at the next backend boundary.
    func cancel(attemptID: AttemptID) async
}
