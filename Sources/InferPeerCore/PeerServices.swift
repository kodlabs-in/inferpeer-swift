import Foundation
import InferPeerInference
import InferPeerProtocol

/// A node role explicitly enabled by the host application.
public enum NodeRole: String, Hashable, Sendable {
    /// Submits inference requests and consumes events.
    case caller

    /// Owns the durable queue and worker scheduling.
    case coordinator

    /// Executes assigned inference attempts.
    case worker
}

/// A transport-independent LAN endpoint.
public struct PeerEndpoint: Hashable, Sendable {
    /// A host name or numeric LAN address supplied by discovery or the user.
    public let host: String

    /// The coordinator's TCP port.
    public let port: UInt16

    /// Creates a nonempty endpoint with a nonzero port.
    public init(host: String, port: UInt16) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port > 0 else {
            throw PeerServiceValidationError.invalidEndpoint
        }
        self.host = host
        self.port = port
    }
}

/// A SHA-256 certificate fingerprint used for out-of-band identity verification.
public struct CertificateFingerprint: Hashable, Sendable {
    /// The required SHA-256 byte count.
    public static let byteCount = 32

    /// The fingerprint bytes.
    public let bytes: Data

    /// Creates a fingerprint from exactly 32 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw PeerServiceValidationError.invalidCertificateFingerprint
        }
        self.bytes = bytes
    }
}

/// The local device identity visible to Core.
public struct LocalPeerIdentity: Hashable, Sendable {
    /// The stable device identity.
    public let peerID: PeerID

    /// The current certificate fingerprint.
    public let certificateFingerprint: CertificateFingerprint

    /// Creates a local peer identity.
    public init(peerID: PeerID, certificateFingerprint: CertificateFingerprint) {
        self.peerID = peerID
        self.certificateFingerprint = certificateFingerprint
    }
}

/// An authenticated remote certificate identity presented by a transport.
public struct PresentedPeerIdentity: Hashable, Sendable {
    /// The stable identity asserted after certificate verification.
    public let peerID: PeerID

    /// The verified certificate fingerprint.
    public let certificateFingerprint: CertificateFingerprint

    /// Creates a presented peer identity.
    public init(peerID: PeerID, certificateFingerprint: CertificateFingerprint) {
        self.peerID = peerID
        self.certificateFingerprint = certificateFingerprint
    }
}

/// The persisted trust state for a presented peer identity.
public enum PeerTrustDecision: String, Equatable, Sendable {
    /// The identity is explicitly approved for the cluster.
    case trusted

    /// The identity has not been approved.
    case unknown

    /// Previously granted access was explicitly revoked.
    case revoked
}

/// The coordinator identity pinned by a pairing invitation.
public struct PairingCoordinator: Hashable, Sendable {
    /// The target cluster.
    public let clusterID: ClusterID

    /// The coordinator LAN endpoint.
    public let endpoint: PeerEndpoint

    /// The expected coordinator certificate fingerprint.
    public let certificateFingerprint: CertificateFingerprint

    /// Creates a coordinator pairing target.
    public init(
        clusterID: ClusterID,
        endpoint: PeerEndpoint,
        certificateFingerprint: CertificateFingerprint
    ) {
        self.clusterID = clusterID
        self.endpoint = endpoint
        self.certificateFingerprint = certificateFingerprint
    }
}

/// Out-of-band information needed to identify and join one coordinator.
public struct PairingInvitation: Sendable {
    /// The single-use invitation identifier.
    public let invitationID: InvitationID

    /// The coordinator identity and endpoint pinned by this invitation.
    public let coordinator: PairingCoordinator

    /// The invitation expiry time.
    public let expiresAt: Date

    /// The opaque single-use proof verified by the security adapter.
    public let proof: Data

    /// Creates pairing invitation data without interpreting its proof.
    public init(
        invitationID: InvitationID,
        coordinator: PairingCoordinator,
        expiresAt: Date,
        proof: Data
    ) {
        self.invitationID = invitationID
        self.coordinator = coordinator
        self.expiresAt = expiresAt
        self.proof = proof
    }
}

/// Identity, approval, invitation, and revocation operations supplied by Security.
public protocol IdentityProvider: Sendable {
    /// Returns the current device-local identity.
    func localIdentity() async throws -> LocalPeerIdentity

    /// Returns persisted trust for an authenticated certificate identity.
    func trustDecision(for identity: PresentedPeerIdentity) async throws -> PeerTrustDecision

    /// Returns persisted trust for the exact identity and requested session role.
    func trustDecision(
        for identity: PresentedPeerIdentity,
        role: NodeRole
    ) async throws -> PeerTrustDecision

    /// Approves a presented identity after explicit host confirmation.
    func approve(_ identity: PresentedPeerIdentity) async throws

    /// Validates and consumes a single-use pairing invitation.
    func consume(_ invitation: PairingInvitation) async throws

    /// Consumes invitation credentials received by the issuing coordinator.
    func consume(invitationID: InvitationID, proof: Data) async throws

    /// Revokes future access and invalidates active trust for a peer.
    func revoke(peerID: PeerID) async throws
}

public extension IdentityProvider {
    /// Existing providers fail closed for role-scoped authorization until they implement it.
    func trustDecision(
        for identity: PresentedPeerIdentity,
        role: NodeRole
    ) async throws -> PeerTrustDecision {
        let decision = try await trustDecision(for: identity)
        return decision == .trusted ? .unknown : decision
    }

    /// Existing providers fail closed until coordinator-side proof consumption is implemented.
    func consume(invitationID: InvitationID, proof: Data) throws {
        throw IdentityProviderError.invitationProofUnsupported
    }
}

/// Identity-provider behavior unavailable from an older custom implementation.
public enum IdentityProviderError: Error, Equatable, Sendable {
    case invitationProofUnsupported
}

/// A discovery result that remains untrusted until identity verification succeeds.
public struct DiscoveredPeer: Hashable, Sendable {
    /// The discovery service instance name.
    public let serviceName: String

    /// The resolved LAN endpoint.
    public let endpoint: PeerEndpoint

    /// Creates an untrusted discovery candidate.
    public init(serviceName: String, endpoint: PeerEndpoint) {
        self.serviceName = serviceName
        self.endpoint = endpoint
    }
}

/// A change emitted by LAN discovery.
public enum DiscoveryUpdate: Sendable {
    /// A coordinator candidate appeared or changed.
    case found(DiscoveredPeer)

    /// A previously observed coordinator candidate disappeared.
    case lost(DiscoveredPeer)
}

/// An asynchronous stream of discovery changes.
public typealias DiscoveryUpdateStream = AsyncThrowingStream<DiscoveryUpdate, any Error>

/// Bonjour discovery plus explicit LAN-endpoint resolution.
public protocol PeerDiscovery: Sendable {
    /// Starts discovery and returns a bounded stream of untrusted candidates.
    func discover(bufferingLimit: Int) async throws -> DiscoveryUpdateStream

    /// Produces an untrusted candidate for an explicitly supplied endpoint.
    func candidate(for endpoint: PeerEndpoint) async throws -> DiscoveredPeer

    /// Stops browsing and releases discovery resources.
    func stop() async
}

/// Load state and known costs for one registered model.
public struct WorkerModelSnapshot: Equatable, Sendable {
    /// The exact registered model revision.
    public let model: ModelReference

    /// Whether the model is currently loaded.
    public let isLoaded: Bool

    /// Measured model memory, when available.
    public let measuredMemoryBytes: UInt64?

    /// Estimated load duration, when available.
    public let estimatedLoadDuration: Duration?

    /// Creates a model status snapshot.
    public init(
        model: ModelReference,
        isLoaded: Bool,
        measuredMemoryBytes: UInt64?,
        estimatedLoadDuration: Duration?
    ) throws {
        if let estimatedLoadDuration, estimatedLoadDuration < .zero {
            throw PeerServiceValidationError.negativeModelLoadDuration
        }
        self.model = model
        self.isLoaded = isLoaded
        self.measuredMemoryBytes = measuredMemoryBytes
        self.estimatedLoadDuration = estimatedLoadDuration
    }
}

/// A validated whole-number battery charge reported by the host platform.
public struct BatteryPercentage: Hashable, Sendable {
    /// The inclusive maximum valid percentage.
    public static let maximum: UInt32 = 100

    /// The percentage in the inclusive range `0...100`.
    public let value: UInt32

    /// Creates a validated battery percentage.
    public init(_ value: UInt32) throws {
        guard value <= Self.maximum else {
            throw PeerServiceValidationError.invalidBatteryPercentage(actual: value)
        }
        self.value = value
    }
}

/// Host-provided execution status before coordinator identity and heartbeat metadata.
public struct LocalWorkerStatus: Equatable, Sendable {
    /// Host and platform admission conditions.
    public let condition: WorkerCondition

    /// Current generation capacity and available memory.
    public let load: WorkerLoad

    /// Current battery charge, when the host can report it.
    public let batteryPercentage: BatteryPercentage?

    /// Registered model status.
    public let models: [WorkerModelSnapshot]

    /// Creates a local worker status snapshot.
    public init(
        condition: WorkerCondition,
        load: WorkerLoad,
        batteryPercentage: BatteryPercentage? = nil,
        models: [WorkerModelSnapshot]
    ) {
        self.condition = condition
        self.load = load
        self.batteryPercentage = batteryPercentage
        self.models = models
    }
}

/// An asynchronous stream of host worker-status changes.
public typealias WorkerStatusStream = AsyncStream<LocalWorkerStatus>

/// Supplies host lifecycle, thermal, power, memory, and model status.
public protocol StatusProvider: Sendable {
    /// Returns the current worker status.
    func currentStatus() async -> LocalWorkerStatus

    /// Returns a bounded stream of subsequent worker-status changes.
    func updates(bufferingLimit: Int) -> WorkerStatusStream
}

/// Invalid peer-service data rejected before reaching an adapter.
public enum PeerServiceValidationError: Error, Equatable, Sendable {
    /// A host was empty or a TCP port was zero.
    case invalidEndpoint

    /// A certificate fingerprint was not 32 bytes.
    case invalidCertificateFingerprint

    /// A battery percentage exceeded 100.
    case invalidBatteryPercentage(actual: UInt32)

    /// A model load estimate was negative.
    case negativeModelLoadDuration
}
