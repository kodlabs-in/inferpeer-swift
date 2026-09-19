import InferPeerCore
import InferPeerInference
import InferPeerProtocol

actor DirectRemoteRunState {
    fileprivate enum TerminalResolution: Sendable {
        case success(RunResult)
        case failure(InferPeerError)
    }

    nonisolated let events: RunEventStream
    private let continuation: RunEventStream.Continuation
    private var cursor = DirectRunEventCursor()
    private var currentStatus: RunStatus
    private var terminal: TerminalResolution?
    private var resultWaiters: [CheckedContinuation<RunResult, any Error>] = []

    init(initialStatus: RunStatus, eventBufferLimit: Int) {
        currentStatus = initialStatus
        let pair = RunEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(eventBufferLimit)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func apply(sequence: UInt64, event: RunEvent) throws -> UInt64 {
        let observation = try cursor.observe(sequence: sequence)
        guard observation == .applied else { return cursor.lastAppliedSequence }
        guard case .enqueued = continuation.yield(event) else {
            let error = InferPeerError(code: .outputBackpressure, isRetryable: false)
            resolve(.failure(error))
            throw error
        }
        updateStatus(event)
        return cursor.lastAppliedSequence
    }

    func applyTerminalReplacement(sequence: UInt64, event: RunEvent) throws {
        guard event.isTerminal else {
            throw InferPeerError(code: .protocolMismatch, isRetryable: false)
        }
        guard sequence > cursor.lastAppliedSequence else { return }
        updateStatus(event)
    }

    func latestSequence() -> UInt64 { cursor.lastAppliedSequence }

    func status() -> RunStatus { currentStatus }

    func result() async throws -> RunResult {
        if let terminal { return try terminal.value() }
        return try await withCheckedThrowingContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    func fail(_ error: InferPeerError) {
        guard terminal == nil else { return }
        currentStatus = .interrupted(error)
        resolve(.failure(error))
    }

    private func updateStatus(_ event: RunEvent) {
        switch event {
        case .accepted(let model):
            currentStatus = .accepted
            _ = model
        case .queued(let position):
            currentStatus = .queued(position: position)
        case .loadingModel(let model):
            currentStatus = .loadingModel(model)
        case .started(let model):
            currentStatus = .running(model)
        case .completed(let result):
            currentStatus = .completed
            resolve(.success(result))
        case .failed(let error):
            currentStatus = .failed(error)
            resolve(.failure(error))
        case .cancelled:
            currentStatus = .cancelled
            resolve(.failure(InferPeerError(code: .cancelled, isRetryable: false)))
        case .expired:
            currentStatus = .expired
            resolve(.failure(InferPeerError(code: .deadlineExceeded, isRetryable: false)))
        case .interrupted(let error):
            currentStatus = .interrupted(error)
            resolve(.failure(error))
        case .preprocessing, .textDelta, .transcriptSegment, .audioChunk, .usage:
            break
        }
    }

    private func resolve(_ resolution: TerminalResolution) {
        guard terminal == nil else { return }
        terminal = resolution
        continuation.finish()
        let waiters = resultWaiters
        resultWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: resolution.result)
        }
    }
}

private extension DirectRemoteRunState.TerminalResolution {
    var result: Result<RunResult, any Error> {
        switch self {
        case .success(let result): .success(result)
        case .failure(let error): .failure(error)
        }
    }

    func value() throws -> RunResult {
        try result.get()
    }
}

private extension RunEvent {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired, .interrupted:
            true
        default:
            false
        }
    }
}
