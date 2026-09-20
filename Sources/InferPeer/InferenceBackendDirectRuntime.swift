import InferPeerCore
import InferPeerInference
import InferPeerProtocol

struct InferenceBackendDirectRuntime: DirectInferenceRuntime {
    private let backend: any InferenceBackend

    init(backend: any InferenceBackend) {
        self.backend = backend
    }

    func estimateResources(
        for query: InferenceQuery,
        using model: ModelDescriptor
    ) async throws -> InferenceResourceEstimate {
        let text = try query.textQuery()
        let request = try text.legacyRequest(
            conversationID: Self.estimationConversationID,
            model: model.reference
        )
        return try await backend.estimateResources(for: request, using: model)
    }

    func loadModel(_ model: LocalModelArtifact) async throws {
        try await backend.loadModel(model)
    }

    func unloadModel(_ reference: ModelKey) async throws {
        try await backend.unloadModel(reference)
    }

    func execute(_ execution: DirectRuntimeExecution) async throws -> DirectRuntimeEventStream {
        let query = try execution.query.textQuery()
        let request = try query.legacyRequest(
            conversationID: execution.conversationID,
            model: execution.model
        )
        let legacyExecution = InferenceExecution(
            requestID: execution.requestID,
            attemptID: execution.attemptID,
            model: execution.model,
            request: request
        )
        let source = try await backend.generate(legacyExecution)
        let pair = DirectRuntimeEventStream.makeStream(bufferingPolicy: .bufferingOldest(64))
        let bridge = Task {
            do {
                for try await event in source {
                    let mapped = Self.map(event)
                    switch pair.continuation.yield(mapped) {
                    case .enqueued:
                        continue
                    case .dropped:
                        throw InferPeerError(
                            code: .outputBackpressure,
                            message: "The text runtime exceeded its bounded adapter buffer",
                            isRetryable: false
                        )
                    case .terminated:
                        return
                    @unknown default:
                        return
                    }
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { _ in bridge.cancel() }
        return pair.stream
    }

    func cancel(attemptID: AttemptID) async {
        await backend.cancel(attemptID: attemptID)
    }

    private static func map(_ event: GenerationEvent) -> DirectRuntimeEvent {
        switch event {
        case .textDelta(let delta):
            .textDelta(delta.text)
        case .completed(let result):
            .completed(
                RunResult(
                    text: result.fullText,
                    model: result.modelUsed,
                    finishReason: result.finishReason,
                    usage: result.usage
                )
            )
        }
    }

    private static let estimationConversationID: ConversationID = {
        guard let identifier = ConversationID(rawValue: "direct-runtime-estimate") else {
            preconditionFailure("Static estimation conversation identity must be valid")
        }
        return identifier
    }()
}
