import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol

extension InferPeer {
    func makeRunHandle(
        execution: DirectRuntimeExecution,
        resourceID: ResourceID,
        options: RunOptions,
        executor: LocalResourceExecutor,
        eventBufferLimit: Int
    ) -> RunHandle {
        let pair = RunEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(eventBufferLimit)
        )
        let state = RunStateStore()
        let completion = Task<RunResult, any Error> {
            do {
                try Self.emit(.accepted(model: execution.model), to: pair.continuation)
                let result = try await Self.executeBeforeDeadline(
                    execution: execution,
                    options: options,
                    executor: executor,
                    state: state,
                    continuation: pair.continuation
                )
                await state.update(.completed)
                try Self.emit(.completed(result), to: pair.continuation)
                pair.continuation.finish()
                return result
            } catch {
                let publicError = Self.publicError(error)
                await Self.finish(
                    publicError,
                    state: state,
                    continuation: pair.continuation
                )
                throw publicError
            }
        }
        return RunHandle(
            requestID: execution.requestID,
            resourceID: resourceID,
            events: pair.stream,
            completion: completion,
            state: state,
            cancelOperation: { await executor.cancel(execution.attemptID) }
        )
    }

    static func finish(
        _ error: InferPeerError,
        state: RunStateStore,
        continuation: RunEventStream.Continuation
    ) async {
        if error.code == .cancelled {
            await state.update(.cancelled)
            _ = continuation.yield(.cancelled)
        } else if error.code == .deadlineExceeded {
            await state.update(.expired)
            _ = continuation.yield(.expired)
        } else if error.code == .interrupted {
            await state.update(.interrupted(error))
            _ = continuation.yield(.interrupted(error))
        } else {
            await state.update(.failed(error))
            _ = continuation.yield(.failed(error))
        }
        continuation.finish()
    }

    static func executeBeforeDeadline(
        execution: DirectRuntimeExecution,
        options: RunOptions,
        executor: LocalResourceExecutor,
        state: RunStateStore,
        continuation: RunEventStream.Continuation
    ) async throws -> RunResult {
        try await withThrowingTaskGroup(of: RunResult.self) { group in
            group.addTask {
                try await executor.execute(
                    execution,
                    options: options,
                    state: state,
                    emit: { try emit($0, to: continuation) }
                )
            }
            group.addTask {
                try await Task.sleep(for: options.totalTimeout)
                await executor.cancel(execution.attemptID)
                throw RunDeadlineError()
            }
            guard let result = try await group.next() else {
                throw InferPeerError(code: .internal, isRetryable: false)
            }
            group.cancelAll()
            return result
        }
    }

    static func emit(
        _ event: RunEvent,
        to continuation: RunEventStream.Continuation
    ) throws {
        if case .dropped = continuation.yield(event) {
            throw InferPeerError(
                code: .outputBackpressure,
                message: "Run output exceeded its bounded event buffer",
                isRetryable: false
            )
        }
    }

    static func publicError(_ error: any Error) -> InferPeerError {
        if let error = error as? InferPeerError {
            return error
        }
        if let error = error as? InferenceBackendError {
            return InferPeerError(backendError: error)
        }
        return lifecycleError(error)
    }

    private static func lifecycleError(_ error: any Error) -> InferPeerError {
        if error is CancellationError {
            return InferPeerError(code: .cancelled, isRetryable: false)
        }
        if error is RunDeadlineError {
            return InferPeerError(code: .deadlineExceeded, isRetryable: true)
        }
        if error is InferenceValidationError {
            return InferPeerError(code: .invalidRequest, isRetryable: false)
        }
        if let error = error as? InferenceQueryValidationError {
            let code: InferPeerErrorCode =
                error == .inputTooLarge ? .inputTooLarge : .invalidRequest
            return InferPeerError(code: code, isRetryable: false)
        }
        return InferPeerError(code: .internal, isRetryable: false)
    }

    static func makeID<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        prefix: String
    ) -> ProtocolIdentifier<Domain> {
        guard
            let id = ProtocolIdentifier<Domain>(
                rawValue: "\(prefix)-\(UUID().uuidString.lowercased())"
            )
        else {
            preconditionFailure("A UUID-backed identifier must be valid")
        }
        return id
    }
}

private struct RunDeadlineError: Error {}
