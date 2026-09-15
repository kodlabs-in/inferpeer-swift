import Foundation
import InferPeerInference
@testable import InferPeerMLX
import InferPeerProtocol
import Testing

@Suite("MLX inference backend")
struct MLXInferenceBackendTests {
    @Test("Loads a local model and maps generated text and usage")
    func loadsAndGenerates() async throws {
        let completion = MLXRuntimeCompletion(
            promptTokens: 4,
            outputTokens: 2,
            promptDuration: .milliseconds(20),
            generationDuration: .milliseconds(100),
            finishReason: .stop
        )
        let session = FakeMLXSession(
            promptTokens: 4,
            behavior: .immediate([.text("Hel"), .text("lo"), .completed(completion)])
        )
        let runtime = FakeMLXRuntime(session: session)
        let backend = MLXInferenceBackend(configuration: .standard, runtime: runtime)
        let artifact = try makeArtifact()
        try await backend.loadModel(artifact)

        let events = try await collect(backend.generate(try makeExecution()))

        #expect(events.count == 3)
        #expect(events[0] == .textDelta(try TextDelta("Hel")))
        #expect(events[1] == .textDelta(try TextDelta("lo")))
        let expected = GenerationResult(
            fullText: "Hello",
            modelUsed: artifact.descriptor.reference,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 4, outputTokens: 2)
        )
        #expect(events[2] == .completed(expected))
    }

    @Test("Measured execution updates later resource estimates")
    func updatesResourceEstimates() async throws {
        let completion = MLXRuntimeCompletion(
            promptTokens: 3,
            outputTokens: 2,
            promptDuration: .milliseconds(25),
            generationDuration: .milliseconds(100),
            finishReason: .maximumTokens
        )
        let session = FakeMLXSession(
            promptTokens: 3,
            behavior: .immediate([.completed(completion)])
        )
        let backend = MLXInferenceBackend(
            configuration: .standard,
            runtime: FakeMLXRuntime(session: session)
        )
        let artifact = try makeArtifact(measuredMemoryBytes: 2_048)
        let execution = try makeExecution()
        try await backend.loadModel(artifact)
        _ = try await collect(backend.generate(execution))

        let estimate = try await backend.estimateResources(
            for: execution.request,
            using: artifact.descriptor
        )

        #expect(estimate.peakMemoryBytes == 2_048)
        #expect(estimate.modelLoadDuration != nil)
        #expect(estimate.promptProcessingDuration == .milliseconds(25))
        #expect(estimate.generationTokensPerSecond == 20)
    }

    @Test("Only one generation can be active")
    func serializesGeneration() async throws {
        let session = FakeMLXSession(promptTokens: 2, behavior: .pending)
        let backend = MLXInferenceBackend(
            configuration: .standard,
            runtime: FakeMLXRuntime(session: session)
        )
        try await backend.loadModel(makeArtifact())
        let first = try makeExecution(attempt: "attempt-1")
        let second = try makeExecution(attempt: "attempt-2")
        _ = try await backend.generate(first)

        await #expect(throws: InferenceBackendError.resourceExhausted) {
            _ = try await backend.generate(second)
        }

        await backend.cancel(attemptID: first.attemptID)
    }

    @Test("Cancellation terminates the matching stream")
    func cancelsGeneration() async throws {
        let session = FakeMLXSession(promptTokens: 2, behavior: .pending)
        let backend = MLXInferenceBackend(
            configuration: .standard,
            runtime: FakeMLXRuntime(session: session)
        )
        try await backend.loadModel(makeArtifact())
        let execution = try makeExecution()
        let stream = try await backend.generate(execution)

        await backend.cancel(attemptID: execution.attemptID)

        await #expect(throws: InferenceBackendError.cancelled) {
            for try await _ in stream {}
        }
    }

    @Test("Overflow never publishes terminal success after text continuity is lost")
    func overflowCannotPublishCompletion() async throws {
        let completion = MLXRuntimeCompletion(
            promptTokens: 1,
            outputTokens: 1,
            promptDuration: .milliseconds(1),
            generationDuration: .milliseconds(1),
            finishReason: .stop
        )
        let runtime = FakeMLXRuntime(
            session: FakeMLXSession(
                promptTokens: 1,
                behavior: .immediate([.text("A"), .completed(completion)])
            )
        )
        let backend = MLXInferenceBackend(
            configuration: try MLXBackendConfiguration(eventBufferingLimit: 1),
            runtime: runtime
        )
        try await backend.loadModel(makeArtifact())
        let stream = try await backend.generate(makeExecution())
        while runtime.clearCount < 2 {
            await Task.yield()
        }

        var received: [GenerationEvent] = []
        do {
            for try await event in stream {
                received.append(event)
            }
            Issue.record("Expected overflow")
        } catch {
            #expect(error as? InferenceBackendError == .resourceExhausted)
        }
        #expect(received == [.textDelta(try TextDelta("A"))])
    }

    @Test("Context limit includes requested output tokens")
    func enforcesContextLimit() async throws {
        let session = FakeMLXSession(promptTokens: 9, behavior: .immediate([]))
        let backend = MLXInferenceBackend(
            configuration: .standard,
            runtime: FakeMLXRuntime(session: session)
        )
        try await backend.loadModel(makeArtifact(contextLimit: 10))

        await #expect(throws: InferenceBackendError.contextTooLarge(limit: 10)) {
            _ = try await backend.generate(makeExecution(maximumOutputTokens: 2))
        }
    }

    @Test("A missing local directory never triggers runtime loading")
    func rejectsMissingDirectory() async throws {
        let runtime = FakeMLXRuntime(
            session: FakeMLXSession(promptTokens: 1, behavior: .immediate([]))
        )
        let backend = MLXInferenceBackend(configuration: .standard, runtime: runtime)
        let missing = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let artifact = try makeArtifact(directoryURL: missing)

        await #expect(throws: InferenceBackendError.modelLoadFailed(retryable: false)) {
            try await backend.loadModel(artifact)
        }
        #expect(runtime.loadCount == 0)
    }

    private func collect(_ stream: GenerationEventStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private func makeExecution(
        attempt: String = "attempt-1",
        maximumOutputTokens: UInt32 = 8
    ) throws -> InferenceExecution {
        let reference = try makeReference()
        let context = try ConversationContext(
            conversationID: try #require(ConversationID(rawValue: "conversation-1")),
            revision: 1,
            messages: [try TextMessage(role: .user, text: "Hello")]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(reference),
            maximumOutputTokens: maximumOutputTokens
        )
        return InferenceExecution(
            requestID: try #require(RequestID(rawValue: "request-1")),
            attemptID: try #require(AttemptID(rawValue: attempt)),
            model: reference,
            request: TextGenerationRequest(context: context, options: options)
        )
    }

    private func makeArtifact(
        contextLimit: UInt32 = 128,
        measuredMemoryBytes: UInt64? = nil,
        directoryURL: URL? = nil
    ) throws -> LocalModelArtifact {
        let directory = try directoryURL ?? temporaryDirectory()
        let metadata = try ModelMetadata(
            quantization: "4-bit",
            tokenizer: "tokenizer.json",
            chatTemplate: "tokenizer_config.json",
            license: "Apache-2.0"
        )
        let descriptor = try ModelDescriptor(
            reference: makeReference(),
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: contextLimit,
            contentDigest: ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32)),
            measuredMemoryBytes: measuredMemoryBytes
        )
        return try LocalModelArtifact(descriptor: descriptor, directoryURL: directory)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeReference() throws -> ModelReference {
        try ModelReference(
            modelID: #require(ModelID(rawValue: "test-model")),
            revision: "revision-1"
        )
    }
}

private enum FakeMLXBehavior: Sendable {
    case immediate([MLXRuntimeEvent])
    case pending
}

private actor FakeMLXSession: MLXModelSession {
    let promptTokens: Int
    let behavior: FakeMLXBehavior

    init(promptTokens: Int, behavior: FakeMLXBehavior) {
        self.promptTokens = promptTokens
        self.behavior = behavior
    }

    func tokenCount(messages: [TextMessage]) -> Int {
        promptTokens
    }

    func generate(
        messages: [TextMessage],
        sampling: SamplingOptions,
        maximumOutputTokens: UInt32
    ) -> MLXRuntimeEventStream {
        switch behavior {
        case .immediate(let events):
            return MLXRuntimeEventStream { continuation in
                events.forEach { continuation.yield($0) }
                continuation.finish()
            }
        case .pending:
            return MLXRuntimeEventStream { _ in }
        }
    }
}

private final class FakeMLXRuntime: MLXRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let session: any MLXModelSession
    private var storedLoadCount = 0
    private var storedClearCount = 0

    init(session: any MLXModelSession) {
        self.session = session
    }

    var loadCount: Int {
        lock.withLock { storedLoadCount }
    }

    var clearCount: Int {
        lock.withLock { storedClearCount }
    }

    // swiftlint:disable:next async_without_await
    func loadModel(at directoryURL: URL) async throws -> any MLXModelSession {
        lock.withLock { storedLoadCount += 1 }
        return session
    }

    func clearCache() {
        lock.withLock { storedClearCount += 1 }
    }
}
