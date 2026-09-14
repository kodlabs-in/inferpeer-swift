import InferPeerCore
import InferPeerDiscovery
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import InferPeerTelemetry

/// Abstracts durable model registration for facade composition and testing.
public protocol InferPeerModelRegistry: Sendable {
    /// Registers one verified local artifact idempotently.
    func register(_ artifact: LocalModelArtifact) async throws -> ModelRegistrationResult

    /// Loads one exact local registration.
    func model(reference: ModelReference) async throws -> StoredModelRegistration?
}

extension SQLiteModelStore: InferPeerModelRegistry {}

/// Abstracts the durable caller outbox used before coordinator acceptance.
public protocol InferPeerCallerOutbox: Sendable {
    /// Persists one immutable submission idempotently.
    func enqueue(_ submission: RequestSubmission) async throws -> OutboxEnqueueResult

    /// Removes a request only after acceptance or local pre-submit cancellation.
    func remove(requestID: RequestID, callerID: PeerID) async throws
}

extension SQLiteOutboxStore: InferPeerCallerOutbox {}

/// Optional coordinator advertisement lifecycle used by the facade.
public protocol InferPeerAdvertisement: Sendable {
    /// Starts publishing an already-running coordinator listener.
    func start() async throws

    /// Stops publication.
    func stop() async
}

/// Bridges the Bonjour advertiser into facade-managed lifecycle.
public struct BonjourCoordinatorAdvertisement: InferPeerAdvertisement {
    private let advertiser: BonjourServiceAdvertiser

    /// Wraps a configured Bonjour service advertiser.
    public init(advertiser: BonjourServiceAdvertiser) {
        self.advertiser = advertiser
    }

    /// Publishes the current InferPeer protocol version.
    public func start() async throws {
        try await advertiser.start()
    }

    /// Stops Bonjour publication.
    public func stop() async {
        await advertiser.stop()
    }
}

/// Optional adapters that are only needed by worker or coordinator hosts.
public struct InferPeerOptionalServices: Sendable {
    /// Durable verified-model registry.
    public let modelRegistry: (any InferPeerModelRegistry)?

    /// Durable caller outbox.
    public let callerOutbox: (any InferPeerCallerOutbox)?

    /// Explicitly injected backend; MLX is never linked by the umbrella target.
    public let inferenceBackend: (any InferenceBackend)?

    /// Coordinator advertisement lifecycle.
    public let advertisement: (any InferPeerAdvertisement)?

    /// Creates optional facade services.
    public init(
        modelRegistry: (any InferPeerModelRegistry)? = nil,
        callerOutbox: (any InferPeerCallerOutbox)? = nil,
        inferenceBackend: (any InferenceBackend)? = nil,
        advertisement: (any InferPeerAdvertisement)? = nil
    ) {
        self.modelRegistry = modelRegistry
        self.callerOutbox = callerOutbox
        self.inferenceBackend = inferenceBackend
        self.advertisement = advertisement
    }
}

/// Required and role-specific services injected into one facade instance.
public struct InferPeerDependencies: Sendable {
    /// Certificate-bound identity and trust operations.
    public let identity: any IdentityProvider

    /// Authenticated transport adapter.
    public let transport: any PeerTransport

    /// Bonjour and explicit-endpoint discovery adapter.
    public let discovery: any PeerDiscovery

    /// Host-controlled worker status adapter.
    public let status: any WorkerStatusControlling

    /// Role-specific services.
    public let optional: InferPeerOptionalServices

    /// Creates an explicit dependency graph with no global state or hidden startup.
    public init(
        identity: any IdentityProvider,
        transport: any PeerTransport,
        discovery: any PeerDiscovery,
        status: any WorkerStatusControlling,
        optional: InferPeerOptionalServices = .init()
    ) {
        self.identity = identity
        self.transport = transport
        self.discovery = discovery
        self.status = status
        self.optional = optional
    }
}
