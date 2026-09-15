import Foundation
import InferPeerInference
import InferPeerProtocol

/// Validated heartbeat, stream, and lease settings for a connected worker role.
public struct WorkerSessionConfiguration: Sendable {
    /// Target cluster.
    public let clusterID: ClusterID

    /// Authenticated local worker identity.
    public let workerID: PeerID

    /// Periodic status and lease-renewal interval.
    public let heartbeatInterval: Duration

    /// Lease duration requested while an attempt remains active.
    public let requestedLease: Duration

    /// Application stream bound.
    public let streamBufferLimit: Int

    /// Creates validated worker session settings using PRD defaults.
    public init(
        clusterID: ClusterID,
        workerID: PeerID,
        heartbeatInterval: Duration = .seconds(5),
        requestedLease: Duration = .seconds(20),
        streamBufferLimit: Int = CoordinatorConfiguration.maximumStreamBufferLimit
    ) throws {
        guard heartbeatInterval > .zero,
            requestedLease > heartbeatInterval,
            (1...CoordinatorConfiguration.maximumStreamBufferLimit).contains(streamBufferLimit)
        else {
            throw CoordinatorError.invalidConfiguration
        }
        self.clusterID = clusterID
        self.workerID = workerID
        self.heartbeatInterval = heartbeatInterval
        self.requestedLease = requestedLease
        self.streamBufferLimit = streamBufferLimit
    }
}

/// Lifecycle used by the integration facade for its joined worker role.
public protocol WorkerSessionServing: Sendable {
    /// Starts status, assignment, execution, cancellation, and lease processing.
    func start(session: any WorkerTransportSession) async throws

    /// Stops the active attempt and session.
    func stop() async
}

struct WorkerAssignmentContext: Sendable {
    let requestID: RequestID
    let attemptID: AttemptID
}

struct PreparedWorkerAssignment: Sendable {
    let context: WorkerAssignmentContext
    let execution: InferenceExecution
    let workerAssignment: WorkerExecutionAssignment
    let activeAssignment: WorkerSessionService.ActiveAssignment
}
