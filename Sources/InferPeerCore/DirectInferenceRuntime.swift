import InferPeerInference
import InferPeerProtocol

/// One validated direct-resource execution owned by a single local runtime.
public struct DirectRuntimeExecution: Sendable {
    /// Stable logical request identity.
    public let requestID: RequestID
    /// Unique local execution attempt.
    public let attemptID: AttemptID
    /// Host-owned conversation identity used by text adapters.
    public let conversationID: ConversationID
    /// Exact selected model artifact.
    public let model: ModelKey
    /// Immutable typed request.
    public let query: InferenceQuery

    /// Creates an execution after facade and resource validation.
    public init(
        requestID: RequestID,
        attemptID: AttemptID,
        conversationID: ConversationID,
        model: ModelKey,
        query: InferenceQuery
    ) {
        self.requestID = requestID
        self.attemptID = attemptID
        self.conversationID = conversationID
        self.model = model
        self.query = query
    }
}

/// Runtime-owned progress and output before the resource commits a terminal state.
public enum DirectRuntimeEvent: Sendable {
    case preprocessing(PreprocessingStage)
    case textDelta(String)
    case transcriptSegment(TranscriptSegment)
    case audioChunk(AudioChunk)
    case completed(RunResult)
}

/// Bounded event sequence produced by a direct inference runtime.
public typealias DirectRuntimeEventStream = AsyncThrowingStream<DirectRuntimeEvent, any Error>

/// Adapter-neutral runtime contract for every v2 inference modality.
public protocol DirectInferenceRuntime: Sendable {
    /// Estimates the peak resources for one exact query and registered artifact.
    func estimateResources(
        for query: InferenceQuery,
        using model: ModelDescriptor
    ) async throws -> InferenceResourceEstimate

    /// Loads one verified artifact without downloading hidden dependencies.
    func loadModel(_ model: LocalModelArtifact) async throws

    /// Safely releases one exact model and its disposable caches.
    func unloadModel(_ reference: ModelKey) async throws

    /// Executes one complete typed request and produces one terminal result.
    func execute(_ execution: DirectRuntimeExecution) async throws -> DirectRuntimeEventStream

    /// Cooperatively cancels one attempt at a runtime-safe boundary.
    func cancel(attemptID: AttemptID) async
}
