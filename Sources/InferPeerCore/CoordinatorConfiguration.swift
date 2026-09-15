import Foundation
import InferPeerProtocol

/// Bounded durability, scheduling, heartbeat, and retry settings for one coordinator.
public struct CoordinatorConfiguration: Sendable {
    /// Maximum number of maximum-sized application messages retained per stream.
    public static let maximumStreamBufferLimit = 4

    /// PRD demo defaults: 5/15-second heartbeats, 20-second leases, and two attempts.
    public static func standard(
        clusterID: ClusterID,
        coordinatorID: PeerID,
        incarnationID: CoordinatorIncarnationID
    ) -> Self {
        Self(
            validatedClusterID: clusterID,
            coordinatorID: coordinatorID,
            incarnationID: incarnationID,
            heartbeatInterval: .seconds(5),
            heartbeatTimeout: .seconds(15),
            attemptLease: .seconds(20),
            requestTimeout: .seconds(120),
            maintenanceInterval: .seconds(1),
            terminalRetention: .seconds(86_400),
            retentionSweepInterval: .seconds(3_600),
            maximumAttempts: 2,
            streamBufferLimit: maximumStreamBufferLimit,
            replayPageLimit: 1_000,
            recoveryLimit: 100
        )
    }

    /// Cluster served by this coordinator.
    public let clusterID: ClusterID

    /// Certificate-bound coordinator identity used in outbound metadata.
    public let coordinatorID: PeerID

    /// Fresh identifier for this coordinator process.
    public let incarnationID: CoordinatorIncarnationID

    /// Worker status transmission interval.
    public let heartbeatInterval: Duration

    /// Maximum worker heartbeat age before it becomes ineligible.
    public let heartbeatTimeout: Duration

    /// Renewable duration of an execution attempt.
    public let attemptLease: Duration

    /// Default lifetime when a request omits an explicit deadline.
    public let requestTimeout: Duration

    /// Frequency of deadline, heartbeat, and lease maintenance.
    public let maintenanceInterval: Duration

    /// Duration for which terminal jobs and replay events remain available.
    public let terminalRetention: Duration

    /// Interval between durable retention sweeps while the coordinator runs.
    public let retentionSweepInterval: Duration

    /// Maximum fresh attempts for one logical request.
    public let maximumAttempts: UInt32

    /// Per-session application stream bound.
    public let streamBufferLimit: Int

    /// Maximum replay events sent in one page.
    public let replayPageLimit: Int

    /// Maximum nonterminal requests restored during startup.
    public let recoveryLimit: Int

    /// Creates validated coordinator settings.
    public init(
        clusterID: ClusterID,
        coordinatorID: PeerID,
        incarnationID: CoordinatorIncarnationID,
        heartbeatInterval: Duration = .seconds(5),
        heartbeatTimeout: Duration = .seconds(15),
        attemptLease: Duration = .seconds(20),
        requestTimeout: Duration = .seconds(120),
        maintenanceInterval: Duration = .seconds(1),
        terminalRetention: Duration = .seconds(86_400),
        retentionSweepInterval: Duration = .seconds(3_600),
        maximumAttempts: UInt32 = 2,
        streamBufferLimit: Int = Self.maximumStreamBufferLimit,
        replayPageLimit: Int = 1_000,
        recoveryLimit: Int = 100
    ) throws {
        guard heartbeatInterval > .zero,
            heartbeatTimeout >= heartbeatInterval,
            attemptLease > heartbeatInterval,
            requestTimeout > .zero,
            maintenanceInterval > .zero,
            terminalRetention > .zero,
            retentionSweepInterval > .zero,
            retentionSweepInterval <= terminalRetention,
            maximumAttempts > 0,
            (1...Self.maximumStreamBufferLimit).contains(streamBufferLimit),
            replayPageLimit > 0,
            recoveryLimit > 0
        else {
            throw CoordinatorError.invalidConfiguration
        }
        self.init(
            validatedClusterID: clusterID,
            coordinatorID: coordinatorID,
            incarnationID: incarnationID,
            heartbeatInterval: heartbeatInterval,
            heartbeatTimeout: heartbeatTimeout,
            attemptLease: attemptLease,
            requestTimeout: requestTimeout,
            maintenanceInterval: maintenanceInterval,
            terminalRetention: terminalRetention,
            retentionSweepInterval: retentionSweepInterval,
            maximumAttempts: maximumAttempts,
            streamBufferLimit: streamBufferLimit,
            replayPageLimit: replayPageLimit,
            recoveryLimit: recoveryLimit
        )
    }

    private init(
        validatedClusterID: ClusterID,
        coordinatorID: PeerID,
        incarnationID: CoordinatorIncarnationID,
        heartbeatInterval: Duration,
        heartbeatTimeout: Duration,
        attemptLease: Duration,
        requestTimeout: Duration,
        maintenanceInterval: Duration,
        terminalRetention: Duration,
        retentionSweepInterval: Duration,
        maximumAttempts: UInt32,
        streamBufferLimit: Int,
        replayPageLimit: Int,
        recoveryLimit: Int
    ) {
        clusterID = validatedClusterID
        self.coordinatorID = coordinatorID
        self.incarnationID = incarnationID
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.attemptLease = attemptLease
        self.requestTimeout = requestTimeout
        self.maintenanceInterval = maintenanceInterval
        self.terminalRetention = terminalRetention
        self.retentionSweepInterval = retentionSweepInterval
        self.maximumAttempts = maximumAttempts
        self.streamBufferLimit = streamBufferLimit
        self.replayPageLimit = replayPageLimit
        self.recoveryLimit = recoveryLimit
    }

    var terminalRetentionTimeInterval: TimeInterval {
        let parts = terminalRetention.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Stable coordinator engine failures that are safe to expose to a host.
public enum CoordinatorError: Error, Equatable, Sendable {
    /// One or more coordinator limits are invalid.
    case invalidConfiguration

    /// The engine is already running.
    case alreadyStarted

    /// A command omitted or malformed a required request or attempt identifier.
    case invalidMessage

    /// A worker response targets an attempt it does not own.
    case staleAttempt

    /// A submission's absolute deadline had already elapsed.
    case requestDeadlineElapsed
}
