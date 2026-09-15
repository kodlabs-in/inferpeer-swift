import InferPeerCore
import InferPeerInference
import InferPeerProtocol

/// Stable handle returned after a request is durably stored and sent.
public struct InferPeerRequestHandle: Hashable, Sendable {
    /// Caller-owned logical request identifier.
    public let requestID: RequestID
}

/// A command rejected before it could durably change coordinator state.
public struct InferPeerCommandRejection: Error, Equatable, Sendable {
    /// Stable public reason for rejection.
    public let error: InferPeerError

    /// Attempt that produced a retained successful result, when available.
    public let attemptID: AttemptID?

    /// Compact final result retained after detailed replay expired.
    public let retainedTerminalResult: GenerationResult?

    /// Creates a typed command rejection.
    public init(
        error: InferPeerError,
        attemptID: AttemptID?,
        retainedTerminalResult: GenerationResult?
    ) {
        self.error = error
        self.attemptID = attemptID
        self.retainedTerminalResult = retainedTerminalResult
    }
}

/// Replayable semantic payload delivered for one caller request.
public enum InferPeerRequestEventPayload: Equatable, Sendable {
    /// The coordinator durably accepted the request.
    case accepted(RequestState)

    /// The durable request lifecycle advanced.
    case stateChanged(state: RequestState, attemptNumber: UInt32)

    /// The active attempt emitted text or a completed result.
    case generation(GenerationEvent)

    /// An attempt ended and may be retried under a new attempt identifier.
    case interrupted(error: InferPeerError, willRetry: Bool)

    /// Durable cancellation progress changed.
    case cancellation(CancellationState)

    /// The request ended with a typed failure.
    case failed(InferPeerError)
}

/// One ordered coordinator event with attempt boundaries and a durable replay cursor.
public struct InferPeerRequestEvent: Equatable, Sendable {
    /// Logical request that owns the event.
    public let requestID: RequestID

    /// Attempt that produced the event, when applicable.
    public let attemptID: AttemptID?

    /// Coordinator-issued durable replay position.
    public let cursor: UInt64

    /// Semantic event content.
    public let payload: InferPeerRequestEventPayload
}

/// Current caller-local delivery, replay, and cancellation state.
public struct InferPeerCallerRequestStatus: Equatable, Sendable {
    /// Logical request identifier.
    public let requestID: RequestID

    /// Caller-side outbox and coordinator acceptance phase.
    public let phase: CallerRequestPhase

    /// Latest cancellation progress.
    public let cancellationState: CancellationState

    /// Highest coordinator cursor observed in this process.
    public let latestEventCursor: UInt64?

    /// Highest coordinator cursor acknowledged in this process.
    public let acknowledgedEventCursor: UInt64?
}

/// Bounded request-event stream. Overflow terminates with a typed facade error.
public typealias InferPeerRequestEventStream =
    AsyncThrowingStream<InferPeerRequestEvent, any Error>
