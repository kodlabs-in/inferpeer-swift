import InferPeerInference
import InferPeerProtocol

/// A backend execution plus the coordinator lease that owns it.
public struct WorkerExecutionAssignment: Hashable, Sendable {
    /// The exact request, attempt, and model sent to the inference backend.
    public let execution: InferenceExecution

    /// The coordinator process that issued the assignment.
    public let coordinatorIncarnationID: CoordinatorIncarnationID

    /// The initial monotonic lease deadline.
    public let leaseDeadline: MonotonicInstant

    /// Creates a leased backend execution assignment.
    public init(
        execution: InferenceExecution,
        coordinatorIncarnationID: CoordinatorIncarnationID,
        leaseDeadline: MonotonicInstant
    ) {
        self.execution = execution
        self.coordinatorIncarnationID = coordinatorIncarnationID
        self.leaseDeadline = leaseDeadline
    }
}

/// A worker controller operation that cannot be applied to its active attempt.
public enum WorkerControllerError: Error, Equatable, Sendable {
    /// A different nonterminal attempt already occupies the worker slot.
    case busy(activeAttemptID: AttemptID)

    /// No attempt is currently tracked.
    case noActiveAttempt

    /// A command targeted an attempt other than the active attempt.
    case attemptMismatch(expected: AttemptID, actual: AttemptID)
}

/// Serializes one worker slot across lease tracking and an inference backend.
public actor WorkerController {
    private let backend: any InferenceBackend
    private let clock: any CoreClock
    private var activeLifecycle: WorkerAttemptLifecycle?

    /// Creates a worker slot around a backend and monotonic clock.
    public init(backend: any InferenceBackend, clock: any CoreClock) {
        self.backend = backend
        self.clock = clock
    }

    /// Accepts an unexpired assignment and begins backend generation.
    ///
    /// The consumer must commit either completion or cancellation after consuming the stream.
    public func start(_ assignment: WorkerExecutionAssignment) async throws
        -> GenerationEventStream
    {
        if let activeLifecycle, !activeLifecycle.state.isTerminal {
            throw WorkerControllerError.busy(activeAttemptID: activeLifecycle.attemptID)
        }
        var lifecycle = WorkerAttemptLifecycle(
            attemptID: assignment.execution.attemptID,
            coordinatorIncarnationID: assignment.coordinatorIncarnationID,
            leaseDeadline: assignment.leaseDeadline
        )
        try lifecycle.accept(at: clock.now())
        activeLifecycle = lifecycle

        do {
            return try await backend.generate(assignment.execution)
        } catch {
            activeLifecycle = nil
            throw error
        }
    }

    /// Extends the active attempt lease for its owning coordinator process.
    public func renewLease(
        for attemptID: AttemptID,
        until deadline: MonotonicInstant,
        coordinatorIncarnationID: CoordinatorIncarnationID
    ) throws {
        var lifecycle = try requireActiveLifecycle(for: attemptID)
        try lifecycle.renewLease(
            until: deadline,
            coordinatorIncarnationID: coordinatorIncarnationID
        )
        activeLifecycle = lifecycle
    }

    /// Requests cooperative backend cancellation for the active attempt.
    public func requestCancellation(for attemptID: AttemptID) async throws {
        var lifecycle = try requireActiveLifecycle(for: attemptID)
        lifecycle.requestCancellation()
        activeLifecycle = lifecycle
        await backend.cancel(attemptID: attemptID)
    }

    /// Records that cooperative cancellation stopped the active attempt.
    public func confirmCancellation(for attemptID: AttemptID) throws {
        var lifecycle = try requireActiveLifecycle(for: attemptID)
        try lifecycle.confirmCancellation()
        activeLifecycle = lifecycle
    }

    /// Records backend completion, including completion racing cancellation.
    public func complete(_ attemptID: AttemptID) throws {
        var lifecycle = try requireActiveLifecycle(for: attemptID)
        try lifecycle.complete()
        activeLifecycle = lifecycle
    }

    /// Stops the backend when the active monotonic lease has elapsed.
    @discardableResult
    public func expireLeaseIfNeeded() async -> AttemptID? {
        guard var lifecycle = activeLifecycle else { return nil }
        guard lifecycle.expireIfNeeded(at: clock.now()) else { return nil }
        activeLifecycle = lifecycle
        await backend.cancel(attemptID: lifecycle.attemptID)
        return lifecycle.attemptID
    }

    /// Returns the worker-local lifecycle snapshot for diagnostics and status reporting.
    public func lifecycle() -> WorkerAttemptLifecycle? {
        activeLifecycle
    }

    private func requireActiveLifecycle(
        for attemptID: AttemptID
    ) throws -> WorkerAttemptLifecycle {
        guard let activeLifecycle else {
            throw WorkerControllerError.noActiveAttempt
        }
        guard activeLifecycle.attemptID == attemptID else {
            throw WorkerControllerError.attemptMismatch(
                expected: activeLifecycle.attemptID,
                actual: attemptID
            )
        }
        return activeLifecycle
    }
}
