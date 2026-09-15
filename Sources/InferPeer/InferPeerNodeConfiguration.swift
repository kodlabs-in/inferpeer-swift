import InferPeerCore

/// Invalid facade configuration or lifecycle operation.
public enum InferPeerNodeError: Error, Equatable, Sendable {
    /// At least one role must be explicitly enabled.
    case noRolesEnabled

    /// A coordinator role requires a listener endpoint.
    case coordinatorEndpointRequired

    /// A stream capacity was zero or negative.
    case invalidStreamBufferingLimit

    /// The caller recovery batch size was zero or negative.
    case invalidCallerOutboxRecoveryLimit

    /// The node was started more than once.
    case alreadyStarted

    /// The requested operation requires a started node.
    case notStarted

    /// The requested operation requires a role the host did not enable.
    case roleNotEnabled(NodeRole)

    /// The node already joined a coordinator.
    case alreadyJoined

    /// The operation requires an authenticated caller session.
    case callerSessionUnavailable

    /// No durable caller outbox was injected by the host.
    case callerOutboxUnavailable

    /// The request is not tracked by this facade instance.
    case requestNotTracked

    /// A second live event subscription was requested for the same request.
    case requestAlreadySubscribed

    /// A coordinator response omitted required identifiers or cursor metadata.
    case invalidCoordinatorResponse

    /// A request event stream could not retain every text fragment.
    case eventStreamOverflow

    /// The session sequence cannot advance without reconnecting.
    case sequenceExhausted

    /// No inference backend was injected by the host.
    case inferenceBackendUnavailable

    /// A coordinator role was configured without its durable engine.
    case coordinatorServiceUnavailable

    /// No durable model registry was injected by the host.
    case modelRegistryUnavailable

    /// The requested model has not been registered locally.
    case modelNotRegistered
}

/// Explicit roles, listener address, and stream bound for one facade instance.
public struct InferPeerNodeConfiguration: Sendable {
    /// Roles enabled by the host application.
    public let roles: Set<NodeRole>

    /// Listener endpoint used when the coordinator role is enabled.
    public let coordinatorEndpoint: PeerEndpoint?

    /// Default pending-element capacity for facade-provided streams.
    public let streamBufferingLimit: Int

    /// Maximum durable caller requests restored during one join.
    public let callerOutboxRecoveryLimit: Int

    /// Creates validated node configuration without starting resources.
    public init(
        roles: Set<NodeRole>,
        coordinatorEndpoint: PeerEndpoint? = nil,
        streamBufferingLimit: Int = CoordinatorConfiguration.maximumStreamBufferLimit,
        callerOutboxRecoveryLimit: Int = 100
    ) throws {
        guard !roles.isEmpty else { throw InferPeerNodeError.noRolesEnabled }
        guard
            (1...CoordinatorConfiguration.maximumStreamBufferLimit)
                .contains(streamBufferingLimit)
        else {
            throw InferPeerNodeError.invalidStreamBufferingLimit
        }
        guard callerOutboxRecoveryLimit > 0 else {
            throw InferPeerNodeError.invalidCallerOutboxRecoveryLimit
        }
        if roles.contains(.coordinator), coordinatorEndpoint == nil {
            throw InferPeerNodeError.coordinatorEndpointRequired
        }
        self.roles = roles
        self.coordinatorEndpoint = coordinatorEndpoint
        self.streamBufferingLimit = streamBufferingLimit
        self.callerOutboxRecoveryLimit = callerOutboxRecoveryLimit
    }
}

/// Observable lifecycle of an InferPeer facade.
public enum InferPeerNodeState: String, Equatable, Sendable {
    /// No network resources are owned.
    case stopped

    /// Configured roles may perform work.
    case started
}
