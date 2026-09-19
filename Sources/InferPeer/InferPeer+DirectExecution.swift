import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension InferPeer {
    /// Runs a validated query only on the exact resource selected by the host.
    public func run(
        _ query: InferenceQuery,
        resourceId: ResourceID,
        options: RunOptions = .default
    ) async throws -> RunHandle {
        try Self.validate(options)
        try validate(query)
        let requestID = options.requestID ?? Self.makeID(RequestID.self, prefix: "request")
        let specification = Self.specification(query, resourceID: resourceId, options: options)
        if let accepted = try acceptedRun(requestID, specification: specification) {
            return accepted
        }
        let acceptedOptions = Self.acceptedOptions(options, requestID: requestID)
        let handle = try await startRun(query, resourceID: resourceId, options: acceptedOptions)
        acceptedRuns[requestID] = AcceptedRun(specification: specification, handle: handle)
        return handle
    }

    /// Prepares one exact model on the selected resource without starting inference.
    public func prepareModel(_ model: ModelKey, on resourceID: ResourceID) async throws {
        if resourceID != .local {
            try await prepareRemoteModel(model, resourceID: resourceID)
            return
        }
        try await prepareLocalModel(model, resourceID: resourceID)
    }

    private func startRun(
        _ query: InferenceQuery,
        resourceID: ResourceID,
        options: RunOptions
    ) async throws -> RunHandle {
        if resourceID == .local {
            return try await startLocalRun(query, resourceID: resourceID, options: options)
        }
        return try await startRemoteRun(query, resourceID: resourceID, options: options)
    }

    private func startLocalRun(
        _ query: InferenceQuery,
        resourceID: ResourceID,
        options: RunOptions
    ) async throws -> RunHandle {
        let localExecutor = try requireLocalExecutor(resourceID)
        guard let requestID = options.requestID else {
            preconditionFailure("Accepted run options must have a request ID")
        }
        let execution: DirectRuntimeExecution
        do {
            execution = try await localExecutor.makeExecution(
                query: query,
                requestID: requestID,
                attemptID: Self.makeID(AttemptID.self, prefix: "attempt"),
                conversationID: Self.makeID(ConversationID.self, prefix: "conversation")
            )
        } catch {
            throw Self.publicError(error)
        }
        return makeRunHandle(
            execution: execution,
            resourceID: resourceID,
            options: options,
            executor: localExecutor,
            eventBufferLimit: configuration.runEventBufferLimit
        )
    }

    private func startRemoteRun(
        _ query: InferenceQuery,
        resourceID: ResourceID,
        options: RunOptions
    ) async throws -> RunHandle {
        guard let sessionManager else {
            throw InferPeerError(code: .notPaired, isRetryable: false)
        }
        let connected = await resourcesRegistry.snapshots(.connected)
        guard connected.contains(where: { $0.id == resourceID }) else {
            throw InferPeerError(code: .resourceUnavailable, isRetryable: true)
        }
        do {
            let execution = try await sessionManager.run(
                query,
                resourceID: resourceID,
                options: options
            )
            try Self.validate(execution, resourceID: resourceID, requestID: options.requestID)
            return RunHandle(remote: execution)
        } catch {
            throw Self.publicError(error)
        }
    }

    private func prepareRemoteModel(_ model: ModelKey, resourceID: ResourceID) async throws {
        guard let sessionManager else {
            throw InferPeerError(code: .notPaired, isRetryable: false)
        }
        do {
            try await sessionManager.prepareModel(model, on: resourceID)
        } catch {
            throw Self.publicError(error)
        }
    }

    private func prepareLocalModel(_ model: ModelKey, resourceID: ResourceID) async throws {
        let executor = try requireLocalExecutor(resourceID)
        let attemptID = Self.makeID(AttemptID.self, prefix: "preparation")
        do {
            try await prepareBeforeDeadline(model, executor: executor, attemptID: attemptID)
        } catch is ModelPreparationDeadlineError {
            throw InferPeerError(code: .deadlineExceeded, isRetryable: true)
        } catch {
            throw Self.publicError(error)
        }
    }

    private func prepareBeforeDeadline(
        _ model: ModelKey,
        executor: LocalResourceExecutor,
        attemptID: AttemptID
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await executor.prepareModel(model, attemptID: attemptID)
            }
            group.addTask {
                try await Task.sleep(for: self.configuration.modelPreparationTimeout)
                await executor.cancel(attemptID)
                throw ModelPreparationDeadlineError()
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func acceptedRun(
        _ requestID: RequestID,
        specification: RunSpecification
    ) throws -> RunHandle? {
        guard let accepted = acceptedRuns[requestID] else { return nil }
        guard accepted.specification == specification else {
            throw InferPeerError(
                code: .requestConflict,
                message: "The request ID already identifies different immutable content",
                isRetryable: false
            )
        }
        return accepted.handle
    }

    private func requireLocalExecutor(_ resourceID: ResourceID) throws -> LocalResourceExecutor {
        guard resourceID == .local else {
            throw InferPeerError(code: .resourceUnavailable, isRetryable: true)
        }
        guard let localExecutor else {
            throw InferPeerError(
                code: .resourceUnavailable,
                message: "Local execution is not configured",
                isRetryable: false
            )
        }
        return localExecutor
    }

    private func validate(_ query: InferenceQuery) throws {
        do {
            try query.validate()
        } catch {
            throw Self.publicError(error)
        }
    }

    private static func validate(_ options: RunOptions) throws {
        guard options.totalTimeout > .zero else {
            throw InferPeerError(
                code: .invalidRequest,
                message: "The total timeout must be greater than zero",
                isRetryable: false
            )
        }
    }

    private static func validate(
        _ execution: RemoteRunExecution,
        resourceID: ResourceID,
        requestID: RequestID?
    ) throws {
        guard execution.resourceID == resourceID, execution.requestID == requestID else {
            throw InferPeerError(
                code: .protocolMismatch,
                message: "The remote run identity did not match the accepted request",
                isRetryable: false
            )
        }
    }

    private static func specification(
        _ query: InferenceQuery,
        resourceID: ResourceID,
        options: RunOptions
    ) -> RunSpecification {
        RunSpecification(
            query: query,
            resourceID: resourceID,
            queuePolicy: options.queuePolicy,
            missingModelPolicy: options.missingModelPolicy,
            disconnectPolicy: options.disconnectPolicy
        )
    }

    private static func acceptedOptions(_ options: RunOptions, requestID: RequestID) -> RunOptions {
        RunOptions(
            requestID: requestID,
            totalTimeout: options.totalTimeout,
            queuePolicy: options.queuePolicy,
            missingModelPolicy: options.missingModelPolicy,
            disconnectPolicy: options.disconnectPolicy
        )
    }
}

private struct ModelPreparationDeadlineError: Error {}
