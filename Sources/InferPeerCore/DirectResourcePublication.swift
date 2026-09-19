/// Whether a resource is actively executing inference or idle.
public enum DirectResourceActivity: Hashable, Sendable {
    case active
    case idle
}

/// Invalid telemetry publication timing rejected before polling starts.
public enum DirectPublicationScheduleError: Error, Equatable, Sendable {
    case invalidInterval
    case invalidMissedHeartbeatLimit
}

/// Sampling, heartbeat, and freshness defaults for a resource publication stream.
public struct DirectPublicationSchedule: Hashable, Sendable {
    /// PRD defaults: 2/15-second samples, 5/15-second heartbeats, three missed intervals.
    public static let standard = Self(
        activeSamplingInterval: .seconds(2),
        idleSamplingInterval: .seconds(15),
        activeHeartbeatInterval: .seconds(5),
        idleHeartbeatInterval: .seconds(15),
        missedHeartbeatLimit: 3,
        validated: ()
    )

    /// Polling cadence while the resource is executing work.
    public let activeSamplingInterval: Duration

    /// Polling cadence while the observed resource is idle.
    public let idleSamplingInterval: Duration

    /// Liveness cadence while the resource is executing work.
    public let activeHeartbeatInterval: Duration

    /// Liveness cadence while the observed resource is idle.
    public let idleHeartbeatInterval: Duration

    /// Number of consecutive missed heartbeat intervals that marks a resource stale.
    public let missedHeartbeatLimit: Int

    /// Creates a validated publication schedule.
    public init(
        activeSamplingInterval: Duration = .seconds(2),
        idleSamplingInterval: Duration = .seconds(15),
        activeHeartbeatInterval: Duration = .seconds(5),
        idleHeartbeatInterval: Duration = .seconds(15),
        missedHeartbeatLimit: Int = 3
    ) throws {
        guard activeSamplingInterval > .zero,
            idleSamplingInterval > .zero,
            activeHeartbeatInterval > .zero,
            idleHeartbeatInterval > .zero
        else {
            throw DirectPublicationScheduleError.invalidInterval
        }
        guard missedHeartbeatLimit > 0 else {
            throw DirectPublicationScheduleError.invalidMissedHeartbeatLimit
        }
        self.activeSamplingInterval = activeSamplingInterval
        self.idleSamplingInterval = idleSamplingInterval
        self.activeHeartbeatInterval = activeHeartbeatInterval
        self.idleHeartbeatInterval = idleHeartbeatInterval
        self.missedHeartbeatLimit = missedHeartbeatLimit
    }

    /// Returns the optional-counter polling interval for the current activity.
    public func samplingInterval(for activity: DirectResourceActivity) -> Duration {
        switch activity {
        case .active: activeSamplingInterval
        case .idle: idleSamplingInterval
        }
    }

    /// Returns the liveness heartbeat interval for the current activity.
    public func heartbeatInterval(for activity: DirectResourceActivity) -> Duration {
        switch activity {
        case .active: activeHeartbeatInterval
        case .idle: idleHeartbeatInterval
        }
    }

    private init(
        activeSamplingInterval: Duration,
        idleSamplingInterval: Duration,
        activeHeartbeatInterval: Duration,
        idleHeartbeatInterval: Duration,
        missedHeartbeatLimit: Int,
        validated _: Void
    ) {
        self.activeSamplingInterval = activeSamplingInterval
        self.idleSamplingInterval = idleSamplingInterval
        self.activeHeartbeatInterval = activeHeartbeatInterval
        self.idleHeartbeatInterval = idleHeartbeatInterval
        self.missedHeartbeatLimit = missedHeartbeatLimit
    }
}

/// A revisioned replacement snapshot following one exact base revision.
public struct DirectResourceDelta: Sendable {
    /// Stable identity of the resource whose state changed.
    public let resourceID: ResourceID

    /// Exact revision the receiver must already hold.
    public let baseRevision: UInt64

    /// New revision after applying this delta.
    public let revision: UInt64

    /// Complete replacement state for this revision.
    public let changedSnapshot: ResourceSnapshot

    /// Creates a delta whose structural invariants are checked by consumers.
    public init(
        resourceID: ResourceID,
        baseRevision: UInt64,
        revision: UInt64,
        changedSnapshot: ResourceSnapshot
    ) {
        self.resourceID = resourceID
        self.baseRevision = baseRevision
        self.revision = revision
        self.changedSnapshot = changedSnapshot
    }
}

/// Resource publication payload sent after authentication.
public enum DirectResourcePublication: Sendable {
    /// Complete state used for initial delivery and resynchronization.
    case snapshot(ResourceSnapshot)

    /// A replacement state advancing one exact known base revision.
    case delta(DirectResourceDelta)

    /// Liveness for the currently published revision.
    case heartbeat(resourceID: ResourceID, revision: UInt64)
}

/// Result of applying one publication to a receiver's local state.
public enum DirectPublicationApplyResult: Equatable, Sendable {
    /// A complete snapshot replaced receiver-local state.
    case appliedSnapshot

    /// A delta advanced receiver-local state by one revision.
    case appliedDelta

    /// A heartbeat matched the receiver-local revision.
    case heartbeat

    /// A publication older than receiver-local state was ignored.
    case ignoredStale

    /// The receiver cannot safely apply the publication and must request a full snapshot.
    case resyncRequired(expectedBase: UInt64?, receivedBase: UInt64)
}

/// Consumer-side revision guard that detects gaps before replacing visible state.
public struct DirectResourcePublicationAccumulator: Sendable {
    /// Latest complete receiver-local snapshot.
    public private(set) var snapshot: ResourceSnapshot?

    /// Creates an accumulator with no trusted base revision.
    public init(snapshot: ResourceSnapshot? = nil) {
        self.snapshot = snapshot
    }

    /// Applies a full snapshot, exact delta, or heartbeat with fail-closed gap handling.
    public mutating func apply(
        _ publication: DirectResourcePublication
    ) -> DirectPublicationApplyResult {
        switch publication {
        case .snapshot(let incoming):
            applySnapshot(incoming)
        case .delta(let delta):
            applyDelta(delta)
        case .heartbeat(let resourceID, let revision):
            applyHeartbeat(resourceID: resourceID, revision: revision)
        }
    }
}

extension DirectResourcePublicationAccumulator {
    private mutating func applySnapshot(_ incoming: ResourceSnapshot)
        -> DirectPublicationApplyResult
    {
        if let snapshot,
            snapshot.id == incoming.id,
            incoming.revision < snapshot.revision
        {
            return .ignoredStale
        }
        snapshot = incoming
        return .appliedSnapshot
    }

    private mutating func applyDelta(_ delta: DirectResourceDelta) -> DirectPublicationApplyResult {
        guard let snapshot else {
            return .resyncRequired(expectedBase: nil, receivedBase: delta.baseRevision)
        }
        let nextRevision = delta.baseRevision.addingReportingOverflow(1)
        guard !nextRevision.overflow,
            snapshot.id == delta.resourceID,
            delta.changedSnapshot.id == delta.resourceID,
            snapshot.revision == delta.baseRevision,
            delta.revision == nextRevision.partialValue,
            delta.changedSnapshot.revision == delta.revision
        else {
            return .resyncRequired(
                expectedBase: snapshot.revision,
                receivedBase: delta.baseRevision
            )
        }
        self.snapshot = delta.changedSnapshot
        return .appliedDelta
    }

    private func applyHeartbeat(
        resourceID: ResourceID,
        revision: UInt64
    ) -> DirectPublicationApplyResult {
        guard let snapshot else {
            return .resyncRequired(expectedBase: nil, receivedBase: revision)
        }
        guard snapshot.id == resourceID else {
            return .resyncRequired(expectedBase: snapshot.revision, receivedBase: revision)
        }
        if revision < snapshot.revision { return .ignoredStale }
        if revision > snapshot.revision {
            return .resyncRequired(expectedBase: snapshot.revision, receivedBase: revision)
        }
        return .heartbeat
    }
}

/// Receiver-side liveness classification.
public enum DirectResourceFreshness: Hashable, Sendable {
    /// Publications are arriving within the expected heartbeat window.
    case fresh

    /// The resource missed the configured heartbeat window.
    case stale

    /// The transport reported immediate failure.
    case disconnected
}

/// Freshness plus the connection state a resource list should expose.
public struct DirectResourceFreshnessAssessment: Equatable, Sendable {
    /// Receiver-side freshness classification.
    public let freshness: DirectResourceFreshness

    /// Connection state that the public resource view should expose.
    public let connection: ConnectionState

    /// Creates a receiver-side freshness assessment.
    public init(freshness: DirectResourceFreshness, connection: ConnectionState) {
        self.freshness = freshness
        self.connection = connection
    }
}

/// Classifies liveness using monotonic receipt time and negotiated heartbeat cadence.
public struct DirectResourceFreshnessClassifier: Sendable {
    /// Heartbeat cadence and missed-interval limit used for classification.
    public let schedule: DirectPublicationSchedule

    /// Creates a classifier using the standard cadence by default.
    public init(schedule: DirectPublicationSchedule = .standard) {
        self.schedule = schedule
    }

    /// Missing three expected intervals marks stale and disconnects; transport errors act now.
    public func assess(
        lastReceivedAt: MonotonicInstant,
        now: MonotonicInstant,
        activity: DirectResourceActivity,
        transportFailed: Bool = false
    ) -> DirectResourceFreshnessAssessment {
        if transportFailed {
            return .init(freshness: .disconnected, connection: .disconnected)
        }
        let deadline = missedHeartbeatDeadline(from: lastReceivedAt, activity: activity)
        guard now >= deadline else {
            return .init(freshness: .fresh, connection: .connected)
        }
        return .init(freshness: .stale, connection: .disconnected)
    }

    private func missedHeartbeatDeadline(
        from instant: MonotonicInstant,
        activity: DirectResourceActivity
    ) -> MonotonicInstant {
        let interval = schedule.heartbeatInterval(for: activity)
        return (0..<schedule.missedHeartbeatLimit).reduce(instant) { deadline, _ in
            deadline.advanced(by: interval)
        }
    }
}
