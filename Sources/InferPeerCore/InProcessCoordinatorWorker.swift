import InferPeerInference
import InferPeerProtocol

/// A coordinator-local worker using the same lease and execution semantics as a remote worker.
public protocol CoordinatorLocalWorker: Sendable {
    /// Certificate-bound identity used by scheduling and allowed-worker policy.
    var peerID: PeerID { get }

    /// Returns current host, capacity, and model availability.
    func status() async -> LocalWorkerStatus

    /// Accepts and starts one leased assignment.
    func start(_ assignment: WorkerExecutionAssignment) async throws -> GenerationEventStream

    /// Renews the active assignment lease.
    func renewLease(
        attemptID: AttemptID,
        until deadline: MonotonicInstant,
        coordinatorIncarnationID: CoordinatorIncarnationID
    ) async throws

    /// Requests cooperative cancellation.
    func cancel(attemptID: AttemptID) async

    /// Records successful backend completion.
    func complete(attemptID: AttemptID) async throws
}

/// Default in-process worker adapter around a status provider and backend controller.
public struct InProcessCoordinatorWorker: CoordinatorLocalWorker, Sendable {
    /// Local peer identity.
    public let peerID: PeerID

    private let statusProvider: any StatusProvider
    private let controller: WorkerController

    /// Creates one serialized local execution slot.
    public init(
        peerID: PeerID,
        statusProvider: any StatusProvider,
        backend: any InferenceBackend,
        clock: any CoreClock
    ) {
        self.peerID = peerID
        self.statusProvider = statusProvider
        controller = WorkerController(backend: backend, clock: clock)
    }

    /// Returns current local status.
    public func status() async -> LocalWorkerStatus {
        await statusProvider.currentStatus()
    }

    /// Starts the backend only after lease admission succeeds.
    public func start(
        _ assignment: WorkerExecutionAssignment
    ) async throws -> GenerationEventStream {
        try await controller.start(assignment)
    }

    /// Extends the matching active lease.
    public func renewLease(
        attemptID: AttemptID,
        until deadline: MonotonicInstant,
        coordinatorIncarnationID: CoordinatorIncarnationID
    ) async throws {
        try await controller.renewLease(
            for: attemptID,
            until: deadline,
            coordinatorIncarnationID: coordinatorIncarnationID
        )
    }

    /// Cancels the matching attempt when it is still active.
    public func cancel(attemptID: AttemptID) async {
        try? await controller.cancelAndConfirm(for: attemptID)
    }

    /// Commits worker-local completion.
    public func complete(attemptID: AttemptID) async throws {
        try await controller.complete(attemptID)
    }
}
