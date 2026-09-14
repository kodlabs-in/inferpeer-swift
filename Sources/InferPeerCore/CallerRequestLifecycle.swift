import InferPeerProtocol

/// The caller-local delivery and coordinator state of one request.
public enum CallerRequestPhase: Equatable, Sendable {
    /// The immutable request remains in the caller's durable outbox.
    case pendingOutbox

    /// The request was sent but has not been durably accepted by the coordinator.
    case awaitingAcceptance

    /// The coordinator accepted the request in a nonterminal state.
    case accepted(RequestState)

    /// The coordinator or local pre-submit cancellation reached a terminal state.
    case terminal(RequestState)
}

/// Whether an observed replay cursor advances caller state.
public enum ReplayObservation: Equatable, Sendable {
    /// The event cursor was not observed previously.
    case new

    /// The event was already observed and must not be applied twice.
    case duplicate
}

/// A rejected caller-side request transition.
public enum CallerRequestTransitionError: Error, Equatable, Sendable {
    /// The request is not in the required local delivery phase.
    case invalidPhase

    /// An acknowledgement refers to an event the caller has not observed.
    case cursorNotObserved

    /// An acknowledgement moved behind the caller's durable replay position.
    case acknowledgedCursorRegressed

    /// A new coordinator event arrived after a terminal event.
    case eventAfterTerminal
}

/// A pure caller-side state machine for durable submission and replay progress.
public struct CallerRequestLifecycle: Equatable, Sendable {
    /// The stable logical request identifier.
    public let requestID: RequestID

    /// The current caller-local phase.
    public private(set) var phase: CallerRequestPhase

    /// The highest coordinator event cursor observed, if any.
    public private(set) var latestEventCursor: UInt64?

    /// The highest replay cursor durably acknowledged by the caller, if any.
    public private(set) var acknowledgedEventCursor: UInt64?

    /// The latest cancellation state visible to the caller.
    public private(set) var cancellationState: CancellationState

    /// Whether durable coordinator acceptance permits removing the outbox payload.
    public var canRemoveFromOutbox: Bool {
        switch phase {
        case .pendingOutbox, .awaitingAcceptance:
            false
        case .accepted, .terminal:
            true
        }
    }

    /// Creates a request that remains durably pending in the caller outbox.
    public init(requestID: RequestID) {
        self.requestID = requestID
        phase = .pendingOutbox
        latestEventCursor = nil
        acknowledgedEventCursor = nil
        cancellationState = .notRequested
    }

    /// Records that the caller sent the durable outbox entry.
    public mutating func markSubmitted() throws {
        guard phase == .pendingOutbox else {
            throw CallerRequestTransitionError.invalidPhase
        }
        phase = .awaitingAcceptance
    }

    /// Records the coordinator's post-commit acceptance acknowledgement.
    public mutating func accept(coordinatorState: RequestState) throws {
        guard phase == .awaitingAcceptance else {
            throw CallerRequestTransitionError.invalidPhase
        }
        phase = Self.phase(for: coordinatorState)
    }

    /// Applies a previously unseen coordinator request-state event.
    @discardableResult
    public mutating func observe(
        coordinatorState: RequestState,
        eventCursor: UInt64
    ) throws -> ReplayObservation {
        if let latestEventCursor, eventCursor <= latestEventCursor {
            return .duplicate
        }
        guard canRemoveFromOutbox else {
            throw CallerRequestTransitionError.invalidPhase
        }
        guard !Self.isTerminal(phase) else {
            throw CallerRequestTransitionError.eventAfterTerminal
        }

        latestEventCursor = eventCursor
        phase = Self.phase(for: coordinatorState)
        return .new
    }

    /// Advances the caller's durable replay position through an observed cursor.
    public mutating func acknowledge(through eventCursor: UInt64) throws {
        guard let latestEventCursor, eventCursor <= latestEventCursor else {
            throw CallerRequestTransitionError.cursorNotObserved
        }
        if let acknowledgedEventCursor, eventCursor < acknowledgedEventCursor {
            throw CallerRequestTransitionError.acknowledgedCursorRegressed
        }
        acknowledgedEventCursor = eventCursor
    }

    /// Applies cancellation progress reported by the coordinator.
    public mutating func applyCancellation(_ state: CancellationState) throws {
        guard canRemoveFromOutbox else { throw CallerRequestTransitionError.invalidPhase }
        cancellationState = state
        if state == .confirmed {
            phase = .terminal(.cancelled)
        }
    }

    /// Requests cancellation locally or marks a submitted request as pending cancellation.
    @discardableResult
    public mutating func requestCancellation() -> CancellationState {
        switch phase {
        case .pendingOutbox:
            phase = .terminal(.cancelled)
            cancellationState = .confirmed
        case .awaitingAcceptance, .accepted:
            cancellationState = .pending
        case .terminal:
            cancellationState = .tooLate
        }
        return cancellationState
    }

    private static func phase(for state: RequestState) -> CallerRequestPhase {
        state.isTerminal ? .terminal(state) : .accepted(state)
    }

    private static func isTerminal(_ phase: CallerRequestPhase) -> Bool {
        if case .terminal = phase {
            return true
        }
        return false
    }
}
