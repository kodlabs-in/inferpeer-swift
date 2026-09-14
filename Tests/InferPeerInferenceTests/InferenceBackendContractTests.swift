import Foundation
import InferPeerInference
import InferPeerProtocol
import Testing

@Suite("Inference backend contract")
struct InferenceBackendContractTests {
    @Test("Classifies only explicitly transient backend failures as retryable")
    func classifiesRetryableFailures() {
        #expect(InferenceBackendError.executionFailed(retryable: true).isRetryable)
        #expect(InferenceBackendError.modelLoadFailed(retryable: true).isRetryable)
        #expect(!InferenceBackendError.executionFailed(retryable: false).isRetryable)
        #expect(!InferenceBackendError.cancelled.isRetryable)
        #expect(!InferenceBackendError.invalidRequest.isRetryable)
    }

    @Test("Supports the complete backend lifecycle through one async contract")
    func supportsBackendLifecycle() async throws {
        let estimate = try InferenceResourceEstimate(
            peakMemoryBytes: 2_000_000_000,
            modelLoadDuration: .seconds(2),
            promptProcessingDuration: .milliseconds(40),
            generationTokensPerSecond: 25
        )
        let result = GenerationResult(
            fullText: "Hello",
            modelUsed: try makeModelReference(),
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 4, outputTokens: 1)
        )
        let backend = RecordingBackend(estimate: estimate, events: [.completed(result)])
        let contract: any InferenceBackend = backend
        let artifact = try makeArtifact()
        let execution = try makeExecution()

        let reportedEstimate = try await contract.estimateResources(
            for: execution.request,
            using: artifact.descriptor
        )
        try await contract.loadModel(artifact)
        let stream = try await contract.generate(execution)
        var events: [GenerationEvent] = []
        for try await event in stream {
            events.append(event)
        }
        await contract.cancel(attemptID: execution.attemptID)
        try await contract.unloadModel(artifact.descriptor.reference)

        #expect(reportedEstimate == estimate)
        #expect(events == [.completed(result)])
        #expect(await backend.cancelledAttempts() == [execution.attemptID])
    }

    @Test("Rejects impossible resource estimates")
    func rejectsInvalidEstimate() {
        #expect(
            throws: InferenceValidationError.invalidResourceEstimate(metric: .peakMemory)
        ) {
            try InferenceResourceEstimate(peakMemoryBytes: 0)
        }
        #expect(
            throws: InferenceValidationError.invalidResourceEstimate(
                metric: .modelLoadDuration
            )
        ) {
            try InferenceResourceEstimate(modelLoadDuration: .seconds(-1))
        }
        #expect(
            throws: InferenceValidationError.invalidResourceEstimate(
                metric: .generationTokensPerSecond
            )
        ) {
            try InferenceResourceEstimate(generationTokensPerSecond: .infinity)
        }
    }

    private func makeExecution() throws -> InferenceExecution {
        let requestID = try #require(RequestID(rawValue: "request-1"))
        let attemptID = try #require(AttemptID(rawValue: "attempt-1"))
        let conversationID = try #require(ConversationID(rawValue: "conversation-1"))
        let context = try ConversationContext(
            conversationID: conversationID,
            revision: 1,
            messages: [try TextMessage(role: .user, text: "Hello")]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(try makeModelReference()),
            maximumOutputTokens: 64
        )
        let request = TextGenerationRequest(context: context, options: options)
        return InferenceExecution(
            requestID: requestID,
            attemptID: attemptID,
            model: try makeModelReference(),
            request: request
        )
    }

    private func makeArtifact() throws -> LocalModelArtifact {
        let metadata = try ModelMetadata(
            quantization: "Q4_K_M",
            tokenizer: "tokenizer.json",
            chatTemplate: "chat-template",
            license: "Apache-2.0"
        )
        let descriptor = try ModelDescriptor(
            reference: try makeModelReference(),
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: 4_096,
            contentDigest: try ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))
        )
        return try LocalModelArtifact(
            descriptor: descriptor,
            directoryURL: URL(fileURLWithPath: "/models/model-1", isDirectory: true)
        )
    }

    private func makeModelReference() throws -> ModelReference {
        let modelID = try #require(ModelID(rawValue: "model-1"))
        return try ModelReference(modelID: modelID, revision: "revision-1")
    }
}

private actor RecordingBackend: InferenceBackend {
    private let estimate: InferenceResourceEstimate
    private let events: [GenerationEvent]
    private var cancellations: Set<AttemptID> = []

    init(estimate: InferenceResourceEstimate, events: [GenerationEvent]) {
        self.estimate = estimate
        self.events = events
    }

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        estimate
    }

    func loadModel(_ model: LocalModelArtifact) throws {}

    func unloadModel(_ reference: ModelReference) throws {}

    func generate(_ execution: InferenceExecution) throws -> GenerationEventStream {
        let events = self.events
        return GenerationEventStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func cancel(attemptID: AttemptID) {
        cancellations.insert(attemptID)
    }

    func cancelledAttempts() -> Set<AttemptID> {
        cancellations
    }
}
