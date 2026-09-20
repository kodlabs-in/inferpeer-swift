import InferPeerCore
import InferPeerInference
import InferPeerProtocol

/// A cancellable direct-resource run whose result does not consume its event stream.
public struct RunHandle: Sendable {
    /// Stable logical request identity.
    public let requestID: RequestID

    /// Exact resource selected by the host app.
    public let resourceID: ResourceID

    /// Single ordered, bounded event sequence.
    public let events: RunEventStream

    private let completion: Task<RunResult, any Error>
    private let cancellationStarted: @Sendable () async -> Void
    private let cancellationFinished: @Sendable () async -> Void
    private let cancelOperation: @Sendable () async -> Void
    private let statusOperation: @Sendable () async -> RunStatus

    init(
        requestID: RequestID,
        resourceID: ResourceID,
        events: RunEventStream,
        completion: Task<RunResult, any Error>,
        state: RunStateStore,
        cancelOperation: @escaping @Sendable () async -> Void
    ) {
        self.requestID = requestID
        self.resourceID = resourceID
        self.events = events
        self.completion = completion
        cancellationStarted = { await state.update(.cancelling) }
        cancellationFinished = { await state.update(.cancelled) }
        self.cancelOperation = cancelOperation
        statusOperation = { await state.current() }
    }

    init(remote execution: RemoteRunExecution) {
        requestID = execution.requestID
        resourceID = execution.resourceID
        events = execution.events
        completion = Task { try await execution.result() }
        cancellationStarted = {}
        cancellationFinished = {}
        cancelOperation = { await execution.cancel() }
        statusOperation = { await execution.status() }
    }

    /// Awaits terminal success independently of event consumption.
    public func result() async throws -> RunResult {
        try await completion.value
    }

    /// Cooperatively cancels work on the already selected resource.
    public func cancel() async {
        await cancellationStarted()
        await cancelOperation()
        await cancellationFinished()
        completion.cancel()
    }

    /// Returns the latest run state known by this process.
    public func status() async -> RunStatus {
        await statusOperation()
    }
}

actor RunStateStore {
    private var value: RunStatus = .accepted

    func update(_ status: RunStatus) {
        guard !value.isTerminal else { return }
        if case .cancelling = value, status.isTerminal {
            value = .cancelled
            return
        }
        value = status
    }

    func current() -> RunStatus {
        value
    }
}

private extension RunStatus {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .expired, .interrupted:
            true
        case .accepted, .queued, .loadingModel, .running, .cancelling:
            false
        }
    }
}
