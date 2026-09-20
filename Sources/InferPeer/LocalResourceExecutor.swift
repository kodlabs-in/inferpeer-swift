import InferPeerCore
import InferPeerInference
import InferPeerProtocol
actor LocalResourceExecutor {
    private struct PendingRun {
        let attemptID: AttemptID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let runtime: any LocalExecutionRuntime
    private var models: [ModelKey: LocalExecutionModel]
    private var defaultModels: [InferenceTask: ModelKey]
    private let maximumPendingRuns: Int
    private let modelIdleTimeout: Duration
    private let memoryAvailability: (any MemoryAvailabilityProvider)?
    private let resourceStateChanged:
        @Sendable (ExecutionAvailability, ModelKey?, ModelReadiness?) async -> Void
    private var loadedModel: ModelKey?
    private var activeAttempt: AttemptID?
    private var pendingRuns: [PendingRun] = []
    private var idleUnloadTask: Task<Void, Never>?
    private var isStopped = false

    init(
        runtime: any LocalExecutionRuntime,
        models: [ModelKey: LocalExecutionModel],
        defaultModels: [InferenceTask: ModelKey],
        maximumPendingRuns: Int,
        modelIdleTimeout: Duration,
        memoryAvailability: (any MemoryAvailabilityProvider)?,
        resourceStateChanged:
            @escaping @Sendable (
                ExecutionAvailability,
                ModelKey?,
                ModelReadiness?
            ) async -> Void
    ) {
        self.runtime = runtime
        self.models = models
        self.defaultModels = defaultModels
        self.maximumPendingRuns = maximumPendingRuns
        self.modelIdleTimeout = modelIdleTimeout
        self.memoryAvailability = memoryAvailability
        self.resourceStateChanged = resourceStateChanged
    }
    func makeExecution(
        query: InferenceQuery,
        requestID: RequestID,
        attemptID: AttemptID,
        conversationID: ConversationID
    ) throws -> DirectRuntimeExecution {
        try requireRunning()
        let model = try resolveModel(query.modelSelection, task: query.task)
        guard models[model]?.tasks.contains(query.task) == true else {
            throw InferPeerError(
                code: .unsupportedTask,
                message: "The selected local model does not support this task",
                isRetryable: false
            )
        }
        return DirectRuntimeExecution(
            requestID: requestID,
            attemptID: attemptID,
            conversationID: conversationID,
            model: model,
            query: query
        )
    }

    func execute(
        _ execution: DirectRuntimeExecution,
        options: RunOptions,
        state: RunStateStore,
        emit: @escaping @Sendable (RunEvent) throws -> Void
    ) async throws -> RunResult {
        try await acquire(
            execution.attemptID, policy: options.queuePolicy, state: state, emit: emit)
        await resourceStateChanged(.busy, nil, nil)
        do {
            try Task.checkCancellation()
            try await validateMemory(for: execution)
            try await prepareModelIfNeeded(
                execution.model,
                policy: options.missingModelPolicy,
                state: state,
                emit: emit
            )
            await state.update(.running(execution.model))
            try emit(.started(model: execution.model))
            let result = try await consumeRuntimeEvents(execution, emit: emit)
            await finish(execution.attemptID)
            return result
        } catch {
            await finish(
                execution.attemptID,
                availability: Self.availability(after: error)
            )
            throw error
        }
    }

    func prepareModel(_ model: ModelKey, attemptID: AttemptID) async throws {
        try requireRunning()
        guard models[model] != nil else {
            throw InferPeerError(
                code: .modelUnavailable,
                message: "The selected model is not installed on this resource",
                isRetryable: false
            )
        }
        let state = RunStateStore()
        try await acquire(attemptID, policy: .bounded, state: state) { _ in }
        await resourceStateChanged(.busy, nil, nil)
        do {
            try await validateMemoryForPreparation(of: model)
            try await prepareModelIfNeeded(
                model,
                policy: .prepareIfEligible,
                state: state,
                emit: { _ in }
            )
            await finish(attemptID)
        } catch {
            await finish(attemptID, availability: Self.availability(after: error))
            throw error
        }
    }

    func cancel(_ attemptID: AttemptID) async {
        if activeAttempt == attemptID {
            await runtime.cancel(attemptID: attemptID)
            return
        }
        cancelPending(attemptID)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        cancelAllPending()
        if let activeAttempt {
            await runtime.cancel(attemptID: activeAttempt)
            return
        }
        await unloadForStop()
    }

    func replaceModels(
        _ models: [ModelKey: LocalExecutionModel],
        defaultModels: [InferenceTask: ModelKey]
    ) async throws {
        guard activeAttempt == nil, pendingRuns.isEmpty else {
            throw InferPeerError(code: .queueFull, isRetryable: true)
        }
        if let loadedModel, models[loadedModel] == nil {
            await unloadCurrentModel()
        }
        self.models = models
        self.defaultModels = defaultModels.filter { task, model in
            models[model]?.tasks.contains(task) == true
        }
    }
}

private extension LocalResourceExecutor {
    private func resolveModel(
        _ selection: InferenceModelSelection,
        task: InferenceTask
    ) throws -> ModelKey {
        let model: ModelKey?
        switch selection {
        case .exact(let exact):
            model = exact
        case .taskDefault:
            model = defaultModels[task]
        }
        guard let model, models[model] != nil else {
            throw InferPeerError(
                code: .modelUnavailable,
                message: "The selected model is not installed on this resource",
                isRetryable: false
            )
        }
        return model
    }

    private func acquire(
        _ attemptID: AttemptID,
        policy: RunQueuePolicy,
        state: RunStateStore,
        emit: @escaping @Sendable (RunEvent) throws -> Void
    ) async throws {
        guard activeAttempt != nil else {
            idleUnloadTask?.cancel()
            idleUnloadTask = nil
            activeAttempt = attemptID
            return
        }
        guard policy == .bounded, pendingRuns.count < maximumPendingRuns else {
            throw InferPeerError(
                code: .queueFull,
                message: "The selected resource queue is full",
                isRetryable: true
            )
        }
        let position = pendingRuns.count + 1
        await state.update(.queued(position: position))
        try emit(.queued(position: position))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRuns.append(PendingRun(attemptID: attemptID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelPending(attemptID) }
        }
    }

    private func release(_ attemptID: AttemptID) -> Bool {
        guard activeAttempt == attemptID else { return activeAttempt == nil }
        guard !pendingRuns.isEmpty else {
            activeAttempt = nil
            return true
        }
        let next = pendingRuns.removeFirst()
        activeAttempt = next.attemptID
        next.continuation.resume()
        return false
    }

    private func finish(
        _ attemptID: AttemptID,
        availability: ExecutionAvailability = .available
    ) async {
        guard release(attemptID) else { return }
        if isStopped {
            await unloadForStop()
            return
        }
        await resourceStateChanged(availability, nil, nil)
        scheduleIdleUnload()
    }

    private func requireRunning() throws {
        guard !isStopped else {
            throw InferPeerError(
                code: .workerUnavailable,
                message: "The local resource has stopped",
                isRetryable: false
            )
        }
    }

    private func validateMemory(for execution: DirectRuntimeExecution) async throws {
        guard let memoryAvailability,
            let safeAdditionalBytes = await memoryAvailability.safeAdditionalMemoryBytes(),
            models[execution.model] != nil
        else {
            return
        }
        let estimate = try await runtime.estimateResources(
            for: execution.query,
            using: execution.model
        )
        guard let neededBytes = estimate.peakMemoryBytes else { return }
        guard neededBytes <= safeAdditionalBytes else {
            throw InferPeerError(
                code: .insufficientMemory,
                message: "The selected resource cannot safely admit this operation",
                isRetryable: true
            )
        }
    }

    private func validateMemoryForPreparation(of model: ModelKey) async throws {
        guard loadedModel != model,
            let memoryAvailability,
            let safeAdditionalBytes = await memoryAvailability.safeAdditionalMemoryBytes(),
            let neededBytes = models[model]?.measuredMemoryBytes
        else {
            return
        }
        guard neededBytes <= safeAdditionalBytes else {
            throw InferPeerError(
                code: .insufficientMemory,
                message: "The selected resource cannot safely prepare this model",
                isRetryable: true
            )
        }
    }

    private static func availability(after error: any Error) -> ExecutionAvailability {
        guard let error = error as? InferPeerError, error.code == .insufficientMemory else {
            return .available
        }
        return .memoryLimited
    }

    private func cancelPending(_ attemptID: AttemptID) {
        guard let index = pendingRuns.firstIndex(where: { $0.attemptID == attemptID }) else {
            return
        }
        let pending = pendingRuns.remove(at: index)
        pending.continuation.resume(throwing: CancellationError())
    }

    private func cancelAllPending() {
        let pending = pendingRuns
        pendingRuns.removeAll(keepingCapacity: false)
        for run in pending {
            run.continuation.resume(throwing: CancellationError())
        }
    }

    private func prepareModelIfNeeded(
        _ model: ModelKey,
        policy: MissingModelPolicy,
        state: RunStateStore,
        emit: @escaping @Sendable (RunEvent) throws -> Void
    ) async throws {
        guard loadedModel != model else { return }
        guard policy == .prepareIfEligible else {
            throw InferPeerError(
                code: .modelUnavailable,
                message: "The selected model is registered but not ready",
                isRetryable: true
            )
        }
        if let loadedModel {
            await resourceStateChanged(.busy, loadedModel, .unloading)
            try await runtime.unloadModel(loadedModel)
            self.loadedModel = nil
            await resourceStateChanged(.busy, loadedModel, .registered)
        }
        guard models[model] != nil else {
            throw InferPeerError(
                code: .modelUnavailable,
                message: "The selected model is not installed on this resource",
                isRetryable: false
            )
        }
        await state.update(.loadingModel(model))
        try emit(.loadingModel(model))
        await resourceStateChanged(.busy, model, .preparing)
        do {
            try await runtime.loadModel(model)
        } catch {
            await resourceStateChanged(.busy, model, .failed)
            throw error
        }
        loadedModel = model
        await resourceStateChanged(.busy, model, .ready)
    }

    private func consumeRuntimeEvents(
        _ execution: DirectRuntimeExecution,
        emit: @escaping @Sendable (RunEvent) throws -> Void
    ) async throws -> RunResult {
        let events = try await runtime.execute(execution)
        return try await DirectRuntimeEventConsumer.consume(
            events,
            execution: execution,
            emit: emit
        )
    }

    private func unloadCurrentModel() async {
        guard let loadedModel else { return }
        try? await runtime.unloadModel(loadedModel)
        self.loadedModel = nil
    }

    private func unloadForStop() async {
        let unloadedModel = loadedModel
        await unloadCurrentModel()
        await resourceStateChanged(.unavailable, unloadedModel, .registered)
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard loadedModel != nil else { return }
        idleUnloadTask = Task { [weak self, modelIdleTimeout] in
            do {
                try await Task.sleep(for: modelIdleTimeout)
                await self?.unloadIfIdle()
            } catch {
                return
            }
        }
    }

    private func unloadIfIdle() async {
        guard !isStopped, activeAttempt == nil, let loadedModel else { return }
        idleUnloadTask = nil
        await unloadCurrentModel()
        await resourceStateChanged(.available, loadedModel, .registered)
    }
}
