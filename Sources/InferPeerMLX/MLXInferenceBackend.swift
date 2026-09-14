import Foundation
import InferPeerInference
import InferPeerProtocol

/// Invalid adapter configuration rejected during initialization.
public enum MLXBackendConfigurationError: Error, Equatable, Sendable {
    /// The public event stream capacity was zero or negative.
    case invalidEventBufferingLimit
}

/// Configuration for local MLX generation and public stream backpressure.
public struct MLXBackendConfiguration: Equatable, Sendable {
    /// Default bounded-stream configuration.
    public static let standard = MLXBackendConfiguration(validatedEventBufferingLimit: 32)

    /// Maximum pending generation events retained for a slow consumer.
    public let eventBufferingLimit: Int

    /// Creates validated backend configuration.
    public init(eventBufferingLimit: Int = 32) throws {
        guard eventBufferingLimit > 0 else {
            throw MLXBackendConfigurationError.invalidEventBufferingLimit
        }
        self.eventBufferingLimit = eventBufferingLimit
    }

    private init(validatedEventBufferingLimit: Int) {
        eventBufferingLimit = validatedEventBufferingLimit
    }
}

/// Text-only MLX backend that loads verified local model directories without downloading.
public actor MLXInferenceBackend: InferenceBackend {
    private struct LoadedModel {
        let artifact: LocalModelArtifact
        let session: any MLXModelSession
    }

    private struct PerformanceProfile {
        var loadDuration: Duration?
        var promptDuration: Duration?
        var generationTokensPerSecond: Double?

        init(
            loadDuration: Duration? = nil,
            promptDuration: Duration? = nil,
            generationTokensPerSecond: Double? = nil
        ) {
            self.loadDuration = loadDuration
            self.promptDuration = promptDuration
            self.generationTokensPerSecond = generationTokensPerSecond
        }
    }

    private let configuration: MLXBackendConfiguration
    private let runtime: any MLXRuntime
    private var loadedModel: LoadedModel?
    private var profiles: [ModelReference: PerformanceProfile] = [:]
    private var isLoadingModel = false
    private var activeAttemptID: AttemptID?
    private var generationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var generationContinuation: GenerationEventStream.Continuation?

    /// Creates a production backend backed by MLX Swift and local tokenizer files.
    public init(configuration: MLXBackendConfiguration = .standard) {
        self.configuration = configuration
        runtime = AppleMLXRuntime()
    }

    init(configuration: MLXBackendConfiguration, runtime: any MLXRuntime) {
        self.configuration = configuration
        self.runtime = runtime
    }

    // swiftlint:disable async_without_await
    /// Reports descriptor memory and locally measured timing history when available.
    public func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) async throws -> InferenceResourceEstimate {
        let profile = profiles[model.reference]
        return try InferenceResourceEstimate(
            peakMemoryBytes: model.measuredMemoryBytes,
            modelLoadDuration: profile?.loadDuration,
            promptProcessingDuration: profile?.promptDuration,
            generationTokensPerSecond: profile?.generationTokensPerSecond
        )
    }

    /// Loads one verified local MLX model and records its measured loading duration.
    public func loadModel(_ model: LocalModelArtifact) async throws {
        guard activeAttemptID == nil, !isLoadingModel else {
            throw InferenceBackendError.resourceExhausted
        }
        if loadedModel?.artifact == model { return }
        guard Self.isDirectory(model.directoryURL) else {
            throw InferenceBackendError.modelLoadFailed(retryable: false)
        }

        isLoadingModel = true
        defer { isLoadingModel = false }
        runtime.clearCache()
        let stopwatch = ContinuousClock().now
        do {
            let session = try await runtime.loadModel(at: model.directoryURL)
            loadedModel = LoadedModel(artifact: model, session: session)
            let duration = stopwatch.duration(to: ContinuousClock().now)
            updateLoadDuration(duration, for: model.descriptor.reference)
        } catch {
            runtime.clearCache()
            throw InferenceBackendError.modelLoadFailed(retryable: false)
        }
    }

    /// Unloads the matching model and clears disposable MLX caches.
    public func unloadModel(_ reference: ModelReference) async throws {
        guard activeAttemptID == nil, !isLoadingModel else {
            throw InferenceBackendError.resourceExhausted
        }
        guard loadedModel?.artifact.descriptor.reference == reference else {
            throw InferenceBackendError.modelUnavailable(reference)
        }
        loadedModel = nil
        runtime.clearCache()
    }

    /// Starts one serialized attempt and returns a bounded ordered event stream.
    public func generate(_ execution: InferenceExecution) async throws -> GenerationEventStream {
        guard activeAttemptID == nil, !isLoadingModel else {
            throw InferenceBackendError.resourceExhausted
        }
        guard let loadedModel, loadedModel.artifact.descriptor.reference == execution.model else {
            throw InferenceBackendError.modelUnavailable(execution.model)
        }
        try validate(execution, descriptor: loadedModel.artifact.descriptor)
        activeAttemptID = execution.attemptID

        do {
            let promptTokens = try await loadedModel.session.tokenCount(
                messages: execution.request.context.messages
            )
            guard activeAttemptID == execution.attemptID else {
                throw InferenceBackendError.cancelled
            }
            try validateDeadline(execution.request.options.deadline)
            try validateContext(promptTokens: promptTokens, execution: execution)
            return startGeneration(execution, session: loadedModel.session)
        } catch {
            clearActiveAttempt(execution.attemptID)
            throw mapExecutionError(error)
        }
    }

    /// Cooperatively cancels the matching active attempt and releases disposable caches.
    public func cancel(attemptID: AttemptID) async {
        guard activeAttemptID == attemptID else { return }
        generationTask?.cancel()
        generationContinuation?.finish(throwing: InferenceBackendError.cancelled)
        clearActiveAttempt(attemptID)
    }
    // swiftlint:enable async_without_await
}

extension MLXInferenceBackend {
    private func validate(_ execution: InferenceExecution, descriptor: ModelDescriptor) throws {
        guard execution.model == descriptor.reference else {
            throw InferenceBackendError.modelUnavailable(execution.model)
        }
        guard request(execution.request, permits: execution.model) else {
            throw InferenceBackendError.invalidRequest
        }
        try validateDeadline(execution.request.options.deadline)
    }

    private func validateDeadline(_ deadline: Date?) throws {
        guard let deadline else { return }
        guard deadline > Date() else { throw InferenceBackendError.deadlineExceeded }
    }

    private func request(_ request: TextGenerationRequest, permits model: ModelReference) -> Bool {
        switch request.options.modelRequirement.selection {
        case .exact(let required):
            required == model
        case .permittedModels(let permitted):
            permitted.contains(model)
        }
    }

    private func validateContext(promptTokens: Int, execution: InferenceExecution) throws {
        guard promptTokens >= 0 else { throw InferenceBackendError.invalidRequest }
        guard let promptTokens = UInt64(exactly: promptTokens) else {
            throw InferenceBackendError.invalidRequest
        }
        let requested = promptTokens + UInt64(execution.request.options.maximumOutputTokens)
        let limit = loadedModel?.artifact.descriptor.contextTokenLimit ?? 0
        guard requested <= UInt64(limit) else {
            throw InferenceBackendError.contextTooLarge(limit: limit)
        }
    }

    private func startGeneration(
        _ execution: InferenceExecution,
        session: any MLXModelSession
    ) -> GenerationEventStream {
        let pair = GenerationEventStream.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.eventBufferingLimit)
        )
        generationContinuation = pair.continuation
        pair.continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel(attemptID: execution.attemptID) }
        }
        generationTask = Task { [weak self] in
            await self?.runGeneration(execution, session: session)
        }
        scheduleDeadline(for: execution)
        return pair.stream
    }

    private func runGeneration(
        _ execution: InferenceExecution,
        session: any MLXModelSession
    ) async {
        do {
            let events = try await session.generate(
                messages: execution.request.context.messages,
                sampling: execution.request.options.sampling,
                maximumOutputTokens: execution.request.options.maximumOutputTokens
            )
            try await consume(events, execution: execution)
        } catch {
            finish(execution.attemptID, throwing: mapExecutionError(error))
        }
    }

    private func consume(
        _ events: MLXRuntimeEventStream,
        execution: InferenceExecution
    ) async throws {
        var fullText = ""
        for try await event in events {
            try Task.checkCancellation()
            guard activeAttemptID == execution.attemptID else { throw CancellationError() }
            try validateDeadline(execution.request.options.deadline)
            switch event {
            case .text(let text):
                guard !text.isEmpty else { continue }
                fullText += text
                try yield(.textDelta(try TextDelta(text)))
            case .completed(let completion):
                try finish(execution, fullText: fullText, completion: completion)
                return
            }
        }
        throw InferenceBackendError.executionFailed(retryable: false)
    }

    private func finish(
        _ execution: InferenceExecution,
        fullText: String,
        completion: MLXRuntimeCompletion
    ) throws {
        let result = GenerationResult(
            fullText: fullText,
            modelUsed: execution.model,
            finishReason: finishReason(completion.finishReason),
            usage: TokenUsage(
                promptTokens: completion.promptTokens,
                outputTokens: completion.outputTokens
            )
        )
        updateProfile(completion, for: execution.model)
        try yield(.completed(result))
        generationContinuation?.finish()
        clearActiveAttempt(execution.attemptID)
    }

    private func finishReason(_ reason: MLXRuntimeFinishReason) -> GenerationFinishReason {
        switch reason {
        case .stop:
            .stop
        case .maximumTokens:
            .maximumTokens
        }
    }

    private func yield(_ event: GenerationEvent) throws {
        guard case .dropped = generationContinuation?.yield(event) else { return }
        throw InferenceBackendError.resourceExhausted
    }

    private func finish(_ attemptID: AttemptID, throwing error: InferenceBackendError) {
        guard activeAttemptID == attemptID else { return }
        generationContinuation?.finish(throwing: error)
        clearActiveAttempt(attemptID)
    }

    private func clearActiveAttempt(_ attemptID: AttemptID) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        generationTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        generationContinuation = nil
        runtime.clearCache()
    }

    private func scheduleDeadline(for execution: InferenceExecution) {
        guard let deadline = execution.request.options.deadline else { return }
        let delay = Duration.seconds(max(0, deadline.timeIntervalSinceNow))
        deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.reachDeadline(for: execution.attemptID)
        }
    }

    private func reachDeadline(for attemptID: AttemptID) {
        guard activeAttemptID == attemptID else { return }
        generationTask?.cancel()
        generationContinuation?.finish(throwing: InferenceBackendError.deadlineExceeded)
        clearActiveAttempt(attemptID)
    }

    private func updateLoadDuration(_ duration: Duration, for model: ModelReference) {
        var profile = profiles[model] ?? PerformanceProfile()
        profile.loadDuration = duration
        profiles[model] = profile
    }

    private func updateProfile(_ completion: MLXRuntimeCompletion, for model: ModelReference) {
        var profile = profiles[model] ?? PerformanceProfile()
        profile.promptDuration = completion.promptDuration
        if completion.outputTokens > 0, completion.generationDuration > .zero {
            let seconds = Self.seconds(completion.generationDuration)
            profile.generationTokensPerSecond = Double(completion.outputTokens) / seconds
        }
        profiles[model] = profile
    }

    private func mapExecutionError(_ error: any Error) -> InferenceBackendError {
        if let backendError = error as? InferenceBackendError { return backendError }
        if error is CancellationError { return .cancelled }
        if error is MLXRuntimeAdapterError { return .invalidRequest }
        return .executionFailed(retryable: false)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
