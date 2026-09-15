import Foundation
import InferPeerInference
import InferPeerProtocol

/// The SHA-256 digest of a request's immutable input snapshot.
public struct RequestContentDigest: Hashable, Sendable {
    /// The required byte count for SHA-256.
    public static let byteCount = 32

    /// The digest bytes.
    public let bytes: Data

    /// Creates a request digest from exactly 32 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw RequestPersistenceError.invalidDigestLength(actual: bytes.count)
        }
        self.bytes = bytes
    }
}

/// A caller-authenticated immutable request ready for durable admission.
public struct RequestSubmission: Hashable, Sendable {
    /// The stable logical request identifier.
    public let requestID: RequestID

    /// The caller identity bound to the authenticated session.
    public let callerID: PeerID

    /// The complete immutable inference request.
    public let request: TextGenerationRequest

    /// The digest used to distinguish retry from identifier conflict.
    public let contentDigest: RequestContentDigest

    /// Creates a request submission.
    public init(
        requestID: RequestID,
        callerID: PeerID,
        request: TextGenerationRequest,
        contentDigest: RequestContentDigest
    ) {
        self.requestID = requestID
        self.callerID = callerID
        self.request = request
        self.contentDigest = contentDigest
    }
}

/// A durable request aggregate loaded from a job store.
public struct StoredRequest: Sendable {
    /// The immutable accepted submission.
    public let submission: RequestSubmission

    /// The current authoritative request lifecycle.
    public let lifecycle: RequestLifecycle

    /// The optimistic-concurrency revision assigned by the store.
    public let revision: UInt64

    /// Diagnostic wall-clock time at which the coordinator first accepted the request.
    public let acceptedAt: Date

    /// Creates a stored request snapshot.
    public init(
        submission: RequestSubmission,
        lifecycle: RequestLifecycle,
        revision: UInt64,
        acceptedAt: Date
    ) {
        self.submission = submission
        self.lifecycle = lifecycle
        self.revision = revision
        self.acceptedAt = acceptedAt
    }
}

/// The atomic admission result for a stable request identifier.
public enum RequestAcceptance: Sendable {
    /// A new logical request was committed before acknowledgement.
    case accepted(StoredRequest)

    /// The same identifier and immutable content were committed previously.
    case duplicate(StoredRequest)
}

/// A replayable semantic event associated with one request.
public enum RequestEventPayload: Sendable {
    /// The coordinator durably accepted the request.
    case accepted(RequestState)

    /// The request entered a new durable state and attempt number.
    case stateChanged(state: RequestState, attemptNumber: UInt32)

    /// The active attempt emitted inference progress or completion.
    case generation(GenerationEvent)

    /// An attempt ended and may be retried as a fresh attempt.
    case interrupted(error: InferPeerError, willRetry: Bool)

    /// Cancellation progress changed.
    case cancellation(CancellationState)

    /// The logical request failed terminally.
    case failed(InferPeerError)
}

/// An event awaiting atomic persistence with a request mutation.
public struct PendingRequestEvent: Sendable {
    /// The attempt that produced the event, when applicable.
    public let attemptID: AttemptID?

    /// The semantic event payload.
    public let payload: RequestEventPayload

    /// Creates a pending durable event.
    public init(attemptID: AttemptID? = nil, payload: RequestEventPayload) {
        self.attemptID = attemptID
        self.payload = payload
    }
}

/// A coordinator event assigned a durable replay cursor by the store.
public struct PersistedRequestEvent: Sendable {
    /// The monotonically increasing coordinator event cursor.
    public let cursor: UInt64

    /// The stable logical request identifier.
    public let requestID: RequestID

    /// The producing attempt, when applicable.
    public let attemptID: AttemptID?

    /// The semantic event payload.
    public let payload: RequestEventPayload

    /// Diagnostic wall-clock commit time.
    public let committedAt: Date

    /// Creates a persisted replay event.
    public init(
        cursor: UInt64,
        requestID: RequestID,
        attemptID: AttemptID?,
        payload: RequestEventPayload,
        committedAt: Date
    ) {
        self.cursor = cursor
        self.requestID = requestID
        self.attemptID = attemptID
        self.payload = payload
        self.committedAt = committedAt
    }
}

/// Compact successful result retained after detailed replay events expire.
public struct RetainedTerminalResult: Equatable, Sendable {
    /// Attempt that produced the accepted terminal result.
    public let attemptID: AttemptID?

    /// Final generation result, including the model revision actually used.
    public let result: GenerationResult

    /// Creates a compact retained terminal result.
    public init(attemptID: AttemptID?, result: GenerationResult) {
        self.attemptID = attemptID
        self.result = result
    }
}

/// An optimistic, atomic request-state and replay-event commit.
public struct RequestMutation: Sendable {
    /// The request being changed.
    public let requestID: RequestID

    /// The authenticated caller that owns the request.
    public let callerID: PeerID

    /// The exact store revision on which this change is based.
    public let expectedRevision: UInt64

    /// The new lifecycle to commit.
    public let lifecycle: RequestLifecycle

    /// Events committed in the same transaction as the lifecycle.
    public let events: [PendingRequestEvent]

    /// Creates an atomic request mutation.
    public init(
        requestID: RequestID,
        callerID: PeerID,
        expectedRevision: UInt64,
        lifecycle: RequestLifecycle,
        events: [PendingRequestEvent]
    ) {
        self.requestID = requestID
        self.callerID = callerID
        self.expectedRevision = expectedRevision
        self.lifecycle = lifecycle
        self.events = events
    }
}

/// A durable-store contract failure.
public enum RequestPersistenceError: Error, Equatable, Sendable {
    /// A request digest was not 32 bytes.
    case invalidDigestLength(actual: Int)

    /// A stable request identifier was reused with different immutable content.
    case requestConflict

    /// A conversation context revision did not advance for its authenticated caller.
    case conversationRevisionNotIncreasing

    /// The request does not exist or is no longer retained.
    case requestNotFound

    /// The authenticated caller does not own the request.
    case accessDenied

    /// Another mutation committed after the caller's loaded revision.
    case staleRevision

    /// Durable storage cannot admit more data safely.
    case resourceExhausted

    /// The requested replay cursor predates retained event history.
    case replayExpired(RetainedTerminalResult?)
}

/// Durable job, attempt, deduplication, replay, and acknowledgement storage.
public protocol JobStore: Sendable {
    /// Atomically admits a new request or returns an identical existing request.
    func accept(_ submission: RequestSubmission) async throws -> RequestAcceptance

    /// Loads a request only for its authenticated owner.
    func request(requestID: RequestID, callerID: PeerID) async throws -> StoredRequest?

    /// Returns a bounded deterministic snapshot of every nonterminal request for recovery.
    func nonterminalRequests(limit: Int) async throws -> [StoredRequest]

    /// Atomically commits a lifecycle revision and its replay events.
    func commit(_ mutation: RequestMutation) async throws -> StoredRequest

    /// Returns a bounded ordered replay page after an optional durable cursor.
    func replay(
        requestID: RequestID,
        callerID: PeerID,
        after cursor: UInt64?,
        limit: Int
    ) async throws -> [PersistedRequestEvent]

    /// Durably records the caller's replay position.
    func acknowledge(requestID: RequestID, callerID: PeerID, through cursor: UInt64) async throws

    /// Removes terminal data older than the configured retention boundary.
    func pruneTerminalRequests(before date: Date) async throws
}
