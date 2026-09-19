import Foundation
import InferPeerInference
import InferPeerProtocol

/// Byte and time bounds for same-process direct-run output replay.
public struct ReplayBufferConfiguration: Hashable, Sendable {
    /// The PRD defaults: 8 MiB per run, 64 MiB resource-wide, 30-second recovery.
    public static let standard = Self(
        perRunByteLimit: 8 * 1_024 * 1_024,
        resourceWideByteLimit: 64 * 1_024 * 1_024,
        disconnectGrace: .seconds(30),
        terminalRetention: .seconds(24 * 60 * 60)
    )

    /// Maximum retained bytes attributed to one run.
    public let perRunByteLimit: UInt64
    /// Maximum retained bytes attributed to all runs in this resource process.
    public let resourceWideByteLimit: UInt64
    /// Time allowed for a disconnected consumer to resume before cancellation is required.
    public let disconnectGrace: Duration
    /// Time to retain acknowledged terminal result content in this process.
    public let terminalRetention: Duration

    /// Creates explicit replay bounds. Zero byte limits intentionally disable buffering.
    public init(
        perRunByteLimit: UInt64,
        resourceWideByteLimit: UInt64,
        disconnectGrace: Duration,
        terminalRetention: Duration
    ) {
        self.perRunByteLimit = perRunByteLimit
        self.resourceWideByteLimit = resourceWideByteLimit
        self.disconnectGrace = disconnectGrace
        self.terminalRetention = terminalRetention
    }
}

/// The exact contiguous event range currently available for replay.
public struct RunReplayRange: Equatable, Sendable {
    /// Earliest retained event sequence.
    public let first: UInt64
    /// Latest retained event sequence.
    public let last: UInt64

    /// Creates a retained replay range.
    public init(first: UInt64, last: UInt64) {
        self.first = first
        self.last = last
    }
}

/// One run event after the resource assigns its stable replay sequence.
public struct SequencedRunEvent: Sendable {
    /// Stable logical request identity.
    public let requestID: RequestID
    /// Strictly increasing sequence within this request.
    public let sequence: UInt64
    /// Adapter-neutral public run event.
    public let event: RunEvent
    /// Exact encoded bytes charged to replay budgets by the transport adapter.
    public let retainedByteCount: UInt64

    /// Creates one sequenced event owned by the replay store.
    public init(
        requestID: RequestID,
        sequence: UInt64,
        event: RunEvent,
        retainedByteCount: UInt64
    ) {
        self.requestID = requestID
        self.sequence = sequence
        self.event = event
        self.retainedByteCount = retainedByteCount
    }
}

/// Stable terminal classification retained after result content expires.
public enum RunTerminalKind: Equatable, Sendable {
    case completed
    case failed
    case cancelled
    case expired
    case interrupted
}

/// Complete terminal content retained for bounded same-process recovery.
public enum RunTerminalOutcome: Equatable, Sendable {
    case completed(RunResult)
    case failed(InferPeerError)
    case cancelled
    case expired
    case interrupted(InferPeerError)

    /// Terminal classification that remains after content expiry.
    public var kind: RunTerminalKind {
        switch self {
        case .completed:
            .completed
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        case .expired:
            .expired
        case .interrupted:
            .interrupted
        }
    }
}

/// Terminal metadata and optionally retained terminal content.
public struct RunTerminalSnapshot: Equatable, Sendable {
    /// Sequence of the first terminal event that committed.
    public let sequence: UInt64
    /// Stable terminal classification.
    public let kind: RunTerminalKind
    /// Complete content while it remains within the configured retention window.
    public let outcome: RunTerminalOutcome?

    /// Whether a complete terminal replacement snapshot is still available.
    public var contentAvailable: Bool { outcome != nil }

    /// Creates a terminal recovery snapshot.
    public init(sequence: UInt64, kind: RunTerminalKind, outcome: RunTerminalOutcome?) {
        self.sequence = sequence
        self.kind = kind
        self.outcome = outcome
    }
}

/// Consumer connectivity relevant to replay grace enforcement.
public enum RunReplayConnection: Equatable, Sendable {
    case connected
    case disconnected(graceDeadline: MonotonicInstant)
    case cancellationRequired
}

/// Wire-ready `GetRun` view of one same-process replay buffer.
public struct DirectRunReplaySnapshot: Equatable, Sendable {
    /// Latest sequence ever assigned to this run, or zero before its first event.
    public let latestSequence: UInt64
    /// Highest contiguous sequence acknowledged by the consumer.
    public let acknowledgedThrough: UInt64
    /// Contiguous event range available for replay, if any events remain.
    public let replayRange: RunReplayRange?
    /// Bytes still charged to this run's replay budget.
    public let retainedByteCount: UInt64
    /// Current disconnect-grace state.
    public let connection: RunReplayConnection
    /// First committed terminal state, when present.
    public let terminal: RunTerminalSnapshot?
}

/// Replay budget that prevented assigning a new event sequence.
public enum ReplayBudgetScope: Equatable, Sendable {
    case perRun
    case resourceWide
}

/// Result of offering an event without suspending a runtime callback.
public enum ReplayAppendDisposition: Sendable {
    case appended(SequencedRunEvent)
    case alreadyTerminal(RunTerminalKind)
    case backpressured(ReplayBudgetScope)
    case cancellationRequired(InferPeerErrorCode)

    /// Assigned sequence when the event was retained.
    public var sequence: UInt64? {
        guard case .appended(let event) = self else { return nil }
        return event.sequence
    }
}

extension ReplayAppendDisposition: Equatable {
    /// Compares stable append outcomes without requiring `RunEvent` equality.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.appended(let lhs), .appended(let rhs)):
            lhs.requestID == rhs.requestID && lhs.sequence == rhs.sequence
        case (.alreadyTerminal(let lhs), .alreadyTerminal(let rhs)):
            lhs == rhs
        case (.backpressured(let lhs), .backpressured(let rhs)):
            lhs == rhs
        case (.cancellationRequired(let lhs), .cancellationRequired(let rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

/// Outcome of registering an immutable request identity.
public enum ReplayRunRegistration: Equatable, Sendable {
    case accepted
    case duplicate
}

/// One resource-side instruction to stop an unrecoverable disconnected run.
public struct ReplayCancellation: Equatable, Sendable {
    /// Run requiring cooperative cancellation.
    public let requestID: RequestID
    /// Stable public reason for stopping it.
    public let reason: InferPeerErrorCode

    /// Creates a replay-driven cancellation instruction.
    public init(requestID: RequestID, reason: InferPeerErrorCode) {
        self.requestID = requestID
        self.reason = reason
    }
}

/// Aggregate resource-wide replay usage.
public struct ReplayResourceUsage: Equatable, Sendable {
    /// Bytes retained across every registered run.
    public let retainedByteCount: UInt64
    /// Configured resource-wide byte limit.
    public let byteLimit: UInt64
    /// Number of request identities retained for deduplication.
    public let registeredRunCount: Int
}

/// Whether a received event sequence should be applied by a consumer.
public enum DirectRunCursorObservation: Equatable, Sendable {
    case applied
    case duplicate
}

/// Ordered consumer cursor that prevents duplicate application and detects gaps.
public struct DirectRunEventCursor: Equatable, Sendable {
    /// Highest contiguous sequence already applied to local result handling.
    public private(set) var lastAppliedSequence: UInt64

    /// Creates a fresh or resumed consumer cursor.
    public init(lastAppliedSequence: UInt64 = 0) {
        self.lastAppliedSequence = lastAppliedSequence
    }

    /// Applies one sequence, ignores old duplicates, and rejects silent gaps.
    public mutating func observe(sequence: UInt64) throws -> DirectRunCursorObservation {
        guard sequence > lastAppliedSequence else { return .duplicate }
        let expected = lastAppliedSequence + 1
        guard sequence == expected else {
            throw DirectRunReplayError.sequenceGap(expected: expected, received: sequence)
        }
        lastAppliedSequence = sequence
        return .applied
    }
}

/// Stable failures from adapter-neutral direct-run replay coordination.
public enum DirectRunReplayError: Error, Equatable, Sendable {
    case unknownRequest
    case invalidImmutableRequestDigest
    case requestConflict
    case invalidRetainedByteCount
    case sequenceExhausted
    case sequenceGap(expected: UInt64, received: UInt64)
    case eventAfterTerminal
    case replayExpired(earliestAvailable: UInt64?)
    case cursorAhead(latestAvailable: UInt64)
    case invalidAcknowledgement(latestAvailable: UInt64)
    case acknowledgementRegressed
    case backpressureRequired(ReplayBudgetScope)
    case cancellationRequired(InferPeerErrorCode)
}

extension RunEvent {
    var directTerminalOutcome: RunTerminalOutcome? {
        switch self {
        case .completed(let result):
            .completed(result)
        case .failed(let error):
            .failed(error)
        case .cancelled:
            .cancelled
        case .expired:
            .expired
        case .interrupted(let error):
            .interrupted(error)
        default:
            nil
        }
    }
}
