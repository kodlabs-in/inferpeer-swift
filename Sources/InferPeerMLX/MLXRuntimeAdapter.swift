import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import InferPeerProtocol

/// Model-store adapter for verified, package-managed MLX text artifacts.
public struct MLXRuntimeAdapter: InferPeerRuntimeAdapter, Sendable {
    /// Stable model-manifest runtime identity.
    public let runtimeID = RuntimeID(rawValue: "mlx")

    /// InferPeer adapter contract version, independent of the linked MLX package version.
    public let runtimeVersion = "0.2.0"

    private let backendFactory: @Sendable () -> MLXInferenceBackend

    /// Creates an adapter that never downloads model files outside `InferPeerModelStore`.
    public init() {
        backendFactory = { MLXInferenceBackend() }
    }

    init(backendFactory: @escaping @Sendable () -> MLXInferenceBackend) {
        self.backendFactory = backendFactory
    }

    // Protocol requirement is async so adapters can probe hardware when needed.
    // swiftlint:disable async_without_await
    /// Validates the manifest shape supported by the current MLX text adapter.
    public func support(
        for model: ModelManifest,
        on _: ModelStoreDeviceProfile
    ) async -> ModelSupport {
        guard
            model.runtime.runtimeIdentifier.caseInsensitiveCompare(runtimeID.rawValue)
                == .orderedSame
        else {
            return .unsupported(reasons: [.adapterRejected("runtime identifier is not mlx")])
        }
        guard model.runtime.format.caseInsensitiveCompare("MLX") == .orderedSame else {
            return .unsupported(reasons: [.adapterRejected("model format is not MLX")])
        }
        let tasks = Set(model.capabilities.map(\.task))
        guard tasks == [.textGeneration] else {
            return .unsupported(
                reasons: [.adapterRejected("this adapter currently supports MLX text models")]
            )
        }
        return .supported
    }
    // swiftlint:enable async_without_await

    /// Loads a verified installation without consulting Hugging Face or another network source.
    public func load(
        model: InstalledModel,
        configuration _: ModelLoadConfiguration
    ) async throws -> any InferPeerModelSession {
        let artifact = try Self.artifact(from: model)
        let backend = backendFactory()
        try await backend.loadModel(artifact)
        return MLXModelStoreSession(modelKey: model.key, backend: backend)
    }
}

private extension MLXRuntimeAdapter {
    static func artifact(from model: InstalledModel) throws -> LocalModelArtifact {
        let manifest = model.manifest
        guard let capability = manifest.capabilities.first(where: { $0.task == .textGeneration }),
            let contextLimit = capability.contextTokenLimit,
            let tokenizer = manifest.files.first(where: { $0.role == .tokenizer }),
            let template = manifest.files.first(where: { $0.role == .chatTemplate }),
            let weights = manifest.files.first(where: { $0.role == .weights })
        else {
            throw MLXModelStoreAdapterError.invalidManifest
        }
        let metadata = try ModelMetadata(
            quantization: manifest.runtime.quantization,
            tokenizer: tokenizer.relativePath,
            chatTemplate: template.relativePath,
            license: manifest.license
        )
        let measuredMemory = manifest.deviceProfiles.map(\.peakMemoryBytes).max()
        let descriptor = try ModelDescriptor(
            reference: model.key,
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: contextLimit,
            contentDigest: weights.sha256,
            measuredMemoryBytes: measuredMemory
        )
        return try LocalModelArtifact(
            descriptor: descriptor,
            directoryURL: model.directoryURL
        )
    }
}

/// Stable adapter failures surfaced through the model-store lifecycle.
public enum MLXModelStoreAdapterError: Error, Equatable, Sendable {
    case invalidManifest
    case sessionUnavailable
    case outputBackpressure
}

private final class MLXModelStoreSession: InferPeerModelSession, @unchecked Sendable {
    let modelKey: ModelKey
    let capabilities: Set<InferenceTask> = [.textGeneration]

    private let backend: MLXInferenceBackend
    private let state = MLXModelStoreSessionState()

    init(modelKey: ModelKey, backend: MLXInferenceBackend) {
        self.modelKey = modelKey
        self.backend = backend
    }

    func run(_ request: InferenceQuery) -> DirectRuntimeEventStream {
        let pair = DirectRuntimeEventStream.makeStream(bufferingPolicy: .bufferingOldest(64))
        let attemptID = Self.identifier(AttemptID.self, prefix: "mlx-attempt")
        let task = Task { [backend, modelKey, state] in
            do {
                try state.begin(attemptID)
                defer { state.finish(attemptID) }
                let execution = try Self.execution(
                    request: request,
                    modelKey: modelKey,
                    attemptID: attemptID
                )
                let source = try await backend.generate(execution)
                try await Self.forward(source, to: pair.continuation)
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { [backend, state] _ in
            task.cancel()
            state.finish(attemptID)
            Task { await backend.cancel(attemptID: attemptID) }
        }
        return pair.stream
    }

    func unload() async {
        let attemptID = state.markUnloaded()
        if let attemptID {
            await backend.cancel(attemptID: attemptID)
        }
        try? await backend.unloadModel(modelKey)
    }
}

private extension MLXModelStoreSession {
    static func execution(
        request: InferenceQuery,
        modelKey: ModelKey,
        attemptID: AttemptID
    ) throws -> InferenceExecution {
        guard case .text(let query) = request else {
            throw MLXModelStoreAdapterError.invalidManifest
        }
        try request.validate()
        let messages = try query.messages.map { try TextMessage(role: $0.role, text: $0.text) }
        let context = try ConversationContext(
            conversationID: identifier(ConversationID.self, prefix: "mlx-conversation"),
            revision: 1,
            messages: messages
        )
        let sampling = try SamplingOptions(
            temperature: query.generation.temperature,
            topP: query.generation.topP,
            seed: query.generation.seed
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(modelKey),
            maximumOutputTokens: query.generation.maxOutputTokens,
            sampling: sampling
        )
        return InferenceExecution(
            requestID: identifier(RequestID.self, prefix: "mlx-request"),
            attemptID: attemptID,
            model: modelKey,
            request: TextGenerationRequest(context: context, options: options)
        )
    }

    static func forward(
        _ source: GenerationEventStream,
        to continuation: DirectRuntimeEventStream.Continuation
    ) async throws {
        for try await event in source {
            let mapped = map(event)
            guard case .dropped = continuation.yield(mapped) else { continue }
            throw MLXModelStoreAdapterError.outputBackpressure
        }
    }

    static func map(_ event: GenerationEvent) -> DirectRuntimeEvent {
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

    static func identifier<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        prefix: String
    ) -> ProtocolIdentifier<Domain> {
        guard
            let identifier = ProtocolIdentifier<Domain>(
                rawValue: "\(prefix)-\(UUID().uuidString.lowercased())"
            )
        else {
            preconditionFailure("Generated InferPeer identifier must be valid")
        }
        return identifier
    }
}

private final class MLXModelStoreSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeAttemptID: AttemptID?
    private var isUnloaded = false

    func begin(_ attemptID: AttemptID) throws {
        try lock.withLock {
            guard !isUnloaded, activeAttemptID == nil else {
                throw MLXModelStoreAdapterError.sessionUnavailable
            }
            activeAttemptID = attemptID
        }
    }

    func finish(_ attemptID: AttemptID) {
        lock.withLock {
            guard activeAttemptID == attemptID else { return }
            activeAttemptID = nil
        }
    }

    func markUnloaded() -> AttemptID? {
        lock.withLock {
            isUnloaded = true
            return activeAttemptID
        }
    }
}
