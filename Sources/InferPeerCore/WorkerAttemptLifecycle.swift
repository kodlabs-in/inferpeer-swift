import InferPeerProtocol

/// The worker-local state of one leased execution attempt.
public enum WorkerAttemptState: String, Equatable, Sendable {
    /// The assignment has not yet passed resource admission.
    case offered

    /// The worker accepted and may execute the attempt.
    case running

    /// Cooperative cancellation has been requested.
    case cancellationRequested

    /// Generation completed before any competing terminal outcome.
    case completed

    /// The worker rejected the offer before generation.
    case rejected

    /// Cooperative cancellation completed.
    case cancelled

    /// The coordinator lease elapsed and execution must stop.
    case leaseExpired

    /// Whether this worker attempt has reached a terminal state.
    public var isTerminal: Bool {
        switch self {
        case .offered, .running, .cancellationRequested:
            false
        case .completed, .rejected, .cancelled, .leaseExpired:
            true
        }
    }
}

/// A rejected worker-attempt transition.
public enum WorkerAttemptTransitionError: Error, Equatable, Sendable {
    /// The current worker state does not permit the operation.
    case invalidState(expected: [WorkerAttemptState], actual: WorkerAttemptState)

    /// The assignment expired before worker acceptance.
    case leaseExpired

    /// A lease command came from a different coordinator process.
    case staleCoordinatorIncarnation

    /// A renewal did not move the lease deadline forward.
    case leaseNotExtended
}

/// A pure worker-side state machine for one coordinator-owned attempt.
public struct WorkerAttemptLifecycle: Equatable, Sendable {
    /// The leased attempt identifier.
    public let attemptID: AttemptID

    /// The coordinator process that owns this attempt.
    public let coordinatorIncarnationID: CoordinatorIncarnationID

    /// The current worker-local attempt state.
    public private(set) var state: WorkerAttemptState

    /// The monotonic time at which execution must stop without renewal.
    public private(set) var leaseDeadline: MonotonicInstant

    /// Whether an executing backend should stop at its next cancellation boundary.
    public var shouldStop: Bool {
        switch state {
        case .offered, .running:
            false
        case .cancellationRequested, .completed, .rejected, .cancelled, .leaseExpired:
            true
        }
    }

    /// Creates a worker-local attempt from a coordinator offer.
    public init(
        attemptID: AttemptID,
        coordinatorIncarnationID: CoordinatorIncarnationID,
        leaseDeadline: MonotonicInstant
    ) {
        self.attemptID = attemptID
        self.coordinatorIncarnationID = coordinatorIncarnationID
        self.leaseDeadline = leaseDeadline
        state = .offered
    }

    /// Accepts an unexpired offer and permits backend execution.
    public mutating func accept(at now: MonotonicInstant) throws {
        try requireState([.offered])
        guard now < leaseDeadline else {
            state = .leaseExpired
            throw WorkerAttemptTransitionError.leaseExpired
        }
        state = .running
    }

    /// Rejects an offer before generation begins.
    public mutating func reject() throws {
        try requireState([.offered])
        state = .rejected
    }

    /// Marks an offered or running attempt for cooperative cancellation.
    public mutating func requestCancellation() {
        guard state == .offered || state == .running else { return }
        state = .cancellationRequested
    }

    /// Confirms that cooperative cancellation stopped the attempt.
    public mutating func confirmCancellation() throws {
        try requireState([.cancellationRequested])
        state = .cancelled
    }

    /// Commits generation completion, including a completion racing cancellation.
    public mutating func complete() throws {
        try requireState([.running, .cancellationRequested])
        state = .completed
    }

    /// Extends the lease only for the coordinator process that issued it.
    public mutating func renewLease(
        until deadline: MonotonicInstant,
        coordinatorIncarnationID: CoordinatorIncarnationID
    ) throws {
        guard coordinatorIncarnationID == self.coordinatorIncarnationID else {
            throw WorkerAttemptTransitionError.staleCoordinatorIncarnation
        }
        try requireState([.running, .cancellationRequested])
        guard deadline > leaseDeadline else {
            throw WorkerAttemptTransitionError.leaseNotExtended
        }
        leaseDeadline = deadline
    }

    /// Expires an active offer or execution when its monotonic lease elapses.
    @discardableResult
    public mutating func expireIfNeeded(at now: MonotonicInstant) -> Bool {
        guard !state.isTerminal else { return false }
        guard now >= leaseDeadline else { return false }
        state = .leaseExpired
        return true
    }

    private func requireState(_ expected: [WorkerAttemptState]) throws {
        guard expected.contains(state) else {
            throw WorkerAttemptTransitionError.invalidState(expected: expected, actual: state)
        }
    }
}
