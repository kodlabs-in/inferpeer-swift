import InferPeerProtocol

/// A conversation namespace scoped to one authenticated caller.
public struct ConversationKey: Hashable, Sendable {
    /// The caller that owns the conversation context.
    public let callerID: PeerID

    /// The caller-local conversation identifier.
    public let conversationID: ConversationID

    /// Creates a caller-scoped conversation key.
    public init(callerID: PeerID, conversationID: ConversationID) {
        self.callerID = callerID
        self.conversationID = conversationID
    }
}

/// One queued conversation revision ready for scheduling.
public struct ConversationTurn: Equatable, Sendable {
    /// The stable logical request identifier.
    public let requestID: RequestID

    /// The caller-assigned context revision.
    public let revision: UInt64

    /// Creates a queued conversation turn.
    public init(requestID: RequestID, revision: UInt64) {
        self.requestID = requestID
        self.revision = revision
    }
}

/// A rejected conversation-queue operation.
public enum ConversationSequenceError: Error, Equatable, Sendable {
    /// The stable request identifier was already queued previously.
    case duplicateRequest

    /// A new context revision did not increase monotonically.
    case revisionNotIncreasing

    /// The conversation has no active request to finish.
    case noActiveRequest

    /// A terminal event refers to a request other than the active request.
    case wrongActiveRequest(expected: RequestID, received: RequestID)
}

/// Caller-isolated queues enforcing one active generation per conversation.
public struct ConversationSequencer: Sendable {
    private var lanes: [ConversationKey: ConversationLane] = [:]
    private var knownRequestIDs: Set<RequestID> = []

    /// Creates an empty conversation sequencer.
    public init() {}

    /// Queues a strictly newer complete context revision.
    public mutating func enqueue(
        requestID: RequestID,
        conversation key: ConversationKey,
        revision: UInt64
    ) throws {
        guard !knownRequestIDs.contains(requestID) else {
            throw ConversationSequenceError.duplicateRequest
        }
        var lane = lanes[key, default: ConversationLane()]
        if let latestRevision = lane.latestRevision, revision <= latestRevision {
            throw ConversationSequenceError.revisionNotIncreasing
        }
        lane.pending.append(ConversationTurn(requestID: requestID, revision: revision))
        lane.latestRevision = revision
        lanes[key] = lane
        knownRequestIDs.insert(requestID)
    }

    /// Starts the next queued revision only when the conversation is idle.
    public mutating func beginNext(in key: ConversationKey) -> ConversationTurn? {
        guard var lane = lanes[key] else { return nil }
        guard lane.active == nil else { return nil }
        guard !lane.pending.isEmpty else { return nil }
        let next = lane.pending.removeFirst()
        lane.active = next
        lanes[key] = lane
        return next
    }

    /// Finishes the matching active request and leaves the next revision queued.
    public mutating func finish(requestID: RequestID, in key: ConversationKey) throws {
        guard var lane = lanes[key], let active = lane.active else {
            throw ConversationSequenceError.noActiveRequest
        }
        guard active.requestID == requestID else {
            throw ConversationSequenceError.wrongActiveRequest(
                expected: active.requestID,
                received: requestID
            )
        }
        lane.active = nil
        lanes[key] = lane
    }

    /// Returns the number of revisions waiting behind any active request.
    public func pendingCount(in key: ConversationKey) -> Int {
        lanes[key]?.pending.count ?? 0
    }
}

private struct ConversationLane: Sendable {
    var latestRevision: UInt64?
    var active: ConversationTurn?
    var pending: [ConversationTurn] = []
}
