import InferPeerProtocol

/// The durable state of one logical inference request.
public enum RequestState: String, Hashable, Sendable {
    /// The request is durably accepted and waiting for an eligible worker.
    case queued

    /// An attempt has been offered to one worker.
    case assigned

    /// The assigned worker accepted and may generate output.
    case running

    /// One active attempt committed the final result.
    case completed

    /// The request terminated with a typed failure.
    case failed

    /// Cancellation won the terminal-state race.
    case cancelled

    /// The request deadline elapsed.
    case expired

    /// Whether no further request-state transition may be committed.
    public var isTerminal: Bool {
        switch self {
        case .queued, .assigned, .running:
            false
        case .completed, .failed, .cancelled, .expired:
            true
        }
    }
}

/// The durable progress of a cancellation request.
public enum CancellationState: String, Hashable, Sendable {
    /// No cancellation has been requested.
    case notRequested

    /// Cancellation is durable but an assigned worker has not confirmed it.
    case pending

    /// Cancellation became the request's terminal outcome.
    case confirmed

    /// Another terminal outcome committed before cancellation.
    case tooLate
}

/// One active, coordinator-owned execution lease.
public struct ActiveAttempt: Hashable, Sendable {
    /// The unique attempt identifier.
    public let attemptID: AttemptID

    /// The selected worker.
    public let workerID: PeerID

    /// The one-based attempt number for this logical request.
    public let number: UInt32

    /// The coordinator process that issued the lease.
    public let coordinatorIncarnationID: CoordinatorIncarnationID

    /// The local monotonic deadline after which this lease is invalid.
    public let leaseDeadline: MonotonicInstant
}

/// The result of racing a terminal request transition against an earlier terminal commit.
public enum TerminalCommitResult: Equatable, Sendable {
    /// This operation committed the terminal state.
    case committed

    /// A prior operation already committed the reported terminal state.
    case alreadyTerminal(RequestState)
}

/// A rejected request-state transition.
public enum RequestTransitionError: Error, Equatable, Sendable {
    /// The current state does not permit the requested operation.
    case invalidState(expected: [RequestState], actual: RequestState)

    /// The operation requires an active attempt, but none exists.
    case missingActiveAttempt

    /// The command refers to an old or unrelated attempt.
    case staleAttempt(expected: AttemptID, received: AttemptID)

    /// The one-based attempt counter cannot be incremented again.
    case attemptNumberExhausted

    /// Cancellation must be pending before a worker can confirm it.
    case cancellationNotPending
}

/// The authoritative pure state machine for one coordinator-owned request.
public struct RequestLifecycle: Equatable, Sendable {
    /// The current durable request state.
    public private(set) var state: RequestState

    /// The number of attempts assigned so far.
    public private(set) var attemptNumber: UInt32

    /// The currently leased attempt, if any.
    public private(set) var activeAttempt: ActiveAttempt?

    /// The latest cancellation outcome.
    public private(set) var cancellationState: CancellationState

    /// Creates a newly accepted, queued request.
    public init() {
        state = .queued
        attemptNumber = 0
        activeAttempt = nil
        cancellationState = .notRequested
    }

    /// Assigns the queued request to one worker under a new attempt lease.
    public mutating func assign(
        attemptID: AttemptID,
        workerID: PeerID,
        coordinatorIncarnationID: CoordinatorIncarnationID,
        leaseDeadline: MonotonicInstant
    ) throws -> ActiveAttempt {
        try requireState([.queued])
        guard attemptNumber < UInt32.max else {
            throw RequestTransitionError.attemptNumberExhausted
        }

        attemptNumber += 1
        let attempt = ActiveAttempt(
            attemptID: attemptID,
            workerID: workerID,
            number: attemptNumber,
            coordinatorIncarnationID: coordinatorIncarnationID,
            leaseDeadline: leaseDeadline
        )
        activeAttempt = attempt
        state = .assigned
        return attempt
    }

    /// Records worker acceptance and permits generation to begin.
    public mutating func accept(attemptID: AttemptID) throws {
        try requireActiveAttempt(attemptID, in: [.assigned])
        state = .running
    }

    /// Returns an interrupted request to the queue or terminates it as failed.
    public mutating func interrupt(attemptID: AttemptID, willRetry: Bool) throws {
        try requireActiveAttempt(attemptID, in: [.assigned, .running])
        activeAttempt = nil
        state = willRetry ? .queued : .failed
    }

    /// Durably requests cancellation and reports its current progress.
    @discardableResult
    public mutating func requestCancellation() -> CancellationState {
        switch state {
        case .queued:
            state = .cancelled
            cancellationState = .confirmed
        case .assigned, .running:
            cancellationState = .pending
        case .completed, .failed, .cancelled, .expired:
            cancellationState = .tooLate
        }
        return cancellationState
    }

    /// Commits worker-confirmed cancellation unless another terminal state won first.
    public mutating func confirmCancellation(
        attemptID: AttemptID
    ) throws -> TerminalCommitResult {
        if state.isTerminal {
            return .alreadyTerminal(state)
        }
        try requireActiveAttempt(attemptID, in: [.assigned, .running])
        guard cancellationState == .pending else {
            throw RequestTransitionError.cancellationNotPending
        }
        state = .cancelled
        cancellationState = .confirmed
        activeAttempt = nil
        return .committed
    }

    /// Commits an active attempt's completed result unless another terminal state won first.
    public mutating func complete(attemptID: AttemptID) throws -> TerminalCommitResult {
        if state.isTerminal {
            return .alreadyTerminal(state)
        }
        try requireActiveAttempt(attemptID, in: [.running])
        state = .completed
        activeAttempt = nil
        if cancellationState == .pending {
            cancellationState = .tooLate
        }
        return .committed
    }

    /// Expires a nonterminal request, preserving an earlier terminal outcome.
    public mutating func expire() -> TerminalCommitResult {
        guard !state.isTerminal else {
            return .alreadyTerminal(state)
        }
        state = .expired
        activeAttempt = nil
        if cancellationState == .pending {
            cancellationState = .tooLate
        }
        return .committed
    }

    private func requireState(_ expected: [RequestState]) throws {
        guard expected.contains(state) else {
            throw RequestTransitionError.invalidState(expected: expected, actual: state)
        }
    }

    private func requireActiveAttempt(
        _ attemptID: AttemptID,
        in expectedStates: [RequestState]
    ) throws {
        try requireState(expectedStates)
        guard let activeAttempt else {
            throw RequestTransitionError.missingActiveAttempt
        }
        guard activeAttempt.attemptID == attemptID else {
            throw RequestTransitionError.staleAttempt(
                expected: activeAttempt.attemptID,
                received: attemptID
            )
        }
    }
}
