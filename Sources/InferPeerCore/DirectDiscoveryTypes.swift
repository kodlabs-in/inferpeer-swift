import Foundation

/// Ephemeral identity for an untrusted discovery result.
public struct CandidateID: RawRepresentable, Hashable, Sendable {
    /// Opaque candidate value. It is never a trusted resource identity.
    public let rawValue: String

    /// Creates a candidate identity.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One untrusted endpoint observed by direct-resource discovery.
public struct DiscoveryCandidate: Hashable, Sendable {
    /// Ephemeral identity scoped to the current browser session.
    public let id: CandidateID

    /// Non-authoritative service label.
    public let serviceName: String

    /// Resolved local-network endpoint hint.
    public let endpoint: PeerEndpoint

    /// Advertised direct-protocol major version.
    public let protocolMajor: UInt32

    /// Bounded opaque installation hint from Bonjour. It is not trusted identity.
    public let installationHint: Data

    /// Advertised capability-catalog revision hint.
    public let capabilityVersion: UInt32

    /// Creates an untrusted discovery candidate.
    public init(
        id: CandidateID,
        serviceName: String,
        endpoint: PeerEndpoint,
        protocolMajor: UInt32,
        installationHint: Data = Data(),
        capabilityVersion: UInt32 = 0
    ) {
        self.id = id
        self.serviceName = serviceName
        self.endpoint = endpoint
        self.protocolMajor = protocolMajor
        self.installationHint = installationHint
        self.capabilityVersion = capabilityVersion
    }
}

/// Host-visible events from direct-resource discovery.
public enum DiscoveryEvent: Sendable {
    case candidateFound(DiscoveryCandidate)
    case candidateRemoved(CandidateID)
    case permissionRequired
    case permissionDenied
    case discoveryUnavailable
}

/// Bounded discovery behavior for one subscription.
public struct DiscoveryOptions: Hashable, Sendable {
    /// Default browser behavior.
    public static let `default` = Self()

    /// Maximum pending source events and per-subscriber events.
    public let eventBufferLimit: Int

    /// Whether already-paired resources may reconnect automatically.
    public let reconnectPairedResources: Bool

    /// Creates discovery options without starting a browser.
    public init(eventBufferLimit: Int = 32, reconnectPairedResources: Bool = true) {
        self.eventBufferLimit = eventBufferLimit
        self.reconnectPairedResources = reconnectPairedResources
    }
}

/// Events produced by a direct-resource browser.
public typealias DiscoveryEventStream = AsyncThrowingStream<DiscoveryEvent, any Error>

/// Injectable direct-resource browser. Construction must not start browsing.
public protocol ResourceDiscovery: Sendable {
    /// Starts the underlying event source.
    func start(options: DiscoveryOptions) async throws -> DiscoveryEventStream

    /// Stops the underlying event source.
    func stop() async
}

/// One independent reference-counted subscription to discovery events.
public struct DiscoveryHandle: Sendable {
    /// Events for this subscription only.
    public let events: DiscoveryEventStream

    private let stopOperation: @Sendable () async -> Void

    package init(
        events: DiscoveryEventStream,
        stopOperation: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.stopOperation = stopOperation
    }

    /// Stops this subscription. The final subscription also stops the browser.
    public func stop() async {
        await stopOperation()
    }
}
