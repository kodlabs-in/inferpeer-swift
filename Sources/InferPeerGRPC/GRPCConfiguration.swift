import Darwin
import Foundation
import InferPeerCore
import InferPeerProtocol

/// DER-encoded identity material exported by the security adapter for mutual TLS.
public struct GRPCDeviceCredentials: Hashable, Sendable {
    /// The stable peer identifier and certificate fingerprint.
    public let identity: LocalPeerIdentity
    /// The self-signed leaf certificate encoded as X.509 DER.
    public let certificateDER: Data
    /// The matching private key encoded as DER.
    public let privateKeyDER: Data

    /// Creates nonempty credentials; the TLS backend validates their cryptographic consistency.
    public init(
        identity: LocalPeerIdentity,
        certificateDER: Data,
        privateKeyDER: Data
    ) throws {
        guard !certificateDER.isEmpty, !privateKeyDER.isEmpty else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        self.identity = identity
        self.certificateDER = certificateDER
        self.privateKeyDER = privateKeyDER
    }
}

/// The optional single-use invitation proof sent only in the first session message.
public struct GRPCInvitationCredentials: Hashable, Sendable {
    /// The invitation identifier issued by the coordinator.
    public let invitationID: InvitationID
    /// The opaque, single-use invitation proof.
    public let proof: Data

    /// Creates invitation credentials with a nonempty proof.
    public init(invitationID: InvitationID, proof: Data) throws {
        guard !proof.isEmpty else { throw InferPeerGRPCError.invalidConfiguration }
        self.invitationID = invitationID
        self.proof = proof
    }
}

/// Pins a coordinator certificate fingerprint to one exact approved endpoint.
public struct GRPCCoordinatorPin: Hashable, Sendable {
    /// The exact numeric endpoint selected for the coordinator.
    public let endpoint: PeerEndpoint
    /// The coordinator certificate's expected SHA-256 fingerprint.
    public let certificateFingerprint: CertificateFingerprint

    /// Creates an endpoint-specific certificate pin.
    public init(endpoint: PeerEndpoint, certificateFingerprint: CertificateFingerprint) {
        self.endpoint = endpoint
        self.certificateFingerprint = certificateFingerprint
    }
}

/// Validates an InferPeer identity certificate during the TLS handshake.
///
/// The closure must validate the certificate signature, validity, InferPeer identity extensions,
/// and `expectedFingerprint` when non-`nil`. Throwing rejects the handshake.
public struct GRPCCertificateVerifier: Sendable {
    private let operation: @Sendable (Data, CertificateFingerprint?) throws -> PresentedPeerIdentity

    /// Creates a verifier backed by the host's security adapter.
    public init(
        _ operation:
            @escaping @Sendable (
                Data,
                CertificateFingerprint?
            ) throws -> PresentedPeerIdentity
    ) {
        self.operation = operation
    }

    func verify(
        certificateDER: Data,
        expectedFingerprint: CertificateFingerprint?
    ) throws -> PresentedPeerIdentity {
        try operation(certificateDER, expectedFingerprint)
    }
}

/// Authorizes a certificate-bound peer and its first session message.
public struct GRPCSessionAuthorizer: Sendable {
    private let operation:
        @Sendable (PresentedPeerIdentity, InferPeer_V1_SessionHello, NodeRole) async throws -> Void

    /// Creates an authorizer; returning normally grants the requested session role.
    public init(
        _ operation:
            @escaping @Sendable (
                PresentedPeerIdentity,
                InferPeer_V1_SessionHello,
                NodeRole
            ) async throws -> Void
    ) {
        self.operation = operation
    }

    func authorize(
        identity: PresentedPeerIdentity,
        hello: InferPeer_V1_SessionHello,
        role: NodeRole
    ) async throws {
        try await operation(identity, hello, role)
    }
}

/// A fail-closed socket policy for one explicitly approved local interface and endpoint set.
public struct GRPCNetworkPolicy: Hashable, Sendable {
    /// The interface to which every transport socket is bound.
    public let interfaceName: String
    /// The complete set of endpoints this transport instance may use.
    public let allowedEndpoints: Set<PeerEndpoint>
    let interfaceIndex: UInt32

    /// Production hosts must supply a validated Wi-Fi interface. Numeric endpoints prevent DNS
    /// redirection outside the approved route; loopback is useful only for local tests.
    public init(interfaceName: String, allowedEndpoints: Set<PeerEndpoint>) throws {
        let index = if_nametoindex(interfaceName)
        guard index > 0, !allowedEndpoints.isEmpty else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        guard allowedEndpoints.allSatisfy(Self.isNumericNonWildcardEndpoint) else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        self.interfaceName = interfaceName
        self.allowedEndpoints = allowedEndpoints
        interfaceIndex = index
    }

    func validate(_ endpoint: PeerEndpoint) throws {
        guard allowedEndpoints.contains(endpoint) else {
            throw InferPeerGRPCError.endpointNotAllowed
        }
    }

    private static func isNumericNonWildcardEndpoint(_ endpoint: PeerEndpoint) -> Bool {
        guard endpoint.host != "0.0.0.0", endpoint.host != "::" else { return false }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return endpoint.host.withCString { address in
            inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1
        }
    }
}

/// Immutable policy and identity inputs for one concrete gRPC transport adapter.
public struct GRPCTransportConfiguration: Sendable {
    /// Default maximum uncompressed Protobuf message size: one MiB.
    public static let defaultMaximumMessageBytes = 1_048_576
    /// Default number of retained messages per bounded application stream.
    public static let defaultStreamBufferLimit = 64

    /// The only cluster identifier accepted by the adapter.
    public let clusterID: ClusterID
    /// The local mutual-TLS identity material.
    public let credentials: GRPCDeviceCredentials
    /// Roles explicitly enabled by the host application.
    public let enabledRoles: Set<NodeRole>
    /// The current coordinator process identity, required when listening.
    public let coordinatorIncarnationID: CoordinatorIncarnationID?
    /// The versions and capabilities advertised during session negotiation.
    public let protocolSupport: InferPeer_V1_ProtocolSupport
    /// Optional single-use invitation data sent during outbound session handshakes.
    public let invitation: GRPCInvitationCredentials?
    /// Maximum retained elements for each application stream.
    public let streamBufferLimit: Int
    /// Maximum uncompressed bytes accepted for one Protobuf message.
    public let maximumMessageBytes: Int

    let certificateVerifier: GRPCCertificateVerifier
    let sessionAuthorizer: GRPCSessionAuthorizer
    let networkPolicy: GRPCNetworkPolicy
    private let coordinatorPins: [PeerEndpoint: CertificateFingerprint]

    /// Creates a transport configuration without permissive security or network defaults.
    public init(
        clusterID: ClusterID,
        credentials: GRPCDeviceCredentials,
        enabledRoles: Set<NodeRole>,
        coordinatorIncarnationID: CoordinatorIncarnationID? = nil,
        protocolSupport: InferPeer_V1_ProtocolSupport = InferPeerProtocolVersion.supported,
        invitation: GRPCInvitationCredentials? = nil,
        coordinatorPins: [GRPCCoordinatorPin],
        certificateVerifier: GRPCCertificateVerifier,
        sessionAuthorizer: GRPCSessionAuthorizer,
        networkPolicy: GRPCNetworkPolicy,
        streamBufferLimit: Int = Self.defaultStreamBufferLimit,
        maximumMessageBytes: Int = Self.defaultMaximumMessageBytes
    ) throws {
        let pins = try Self.makePins(coordinatorPins)
        try Self.validateIdentity(
            roles: enabledRoles,
            coordinatorIncarnationID: coordinatorIncarnationID,
            protocolSupport: protocolSupport
        )
        try Self.validateLimits(
            pinCount: pins.count,
            suppliedPinCount: coordinatorPins.count,
            streamBufferLimit: streamBufferLimit,
            maximumMessageBytes: maximumMessageBytes
        )
        self.clusterID = clusterID
        self.credentials = credentials
        self.enabledRoles = enabledRoles
        self.coordinatorIncarnationID = coordinatorIncarnationID
        self.protocolSupport = protocolSupport
        self.invitation = invitation
        self.coordinatorPins = pins
        self.certificateVerifier = certificateVerifier
        self.sessionAuthorizer = sessionAuthorizer
        self.networkPolicy = networkPolicy
        self.streamBufferLimit = streamBufferLimit
        self.maximumMessageBytes = maximumMessageBytes
    }

    func coordinatorFingerprint(for endpoint: PeerEndpoint) throws -> CertificateFingerprint {
        guard let fingerprint = coordinatorPins[endpoint] else {
            throw InferPeerGRPCError.coordinatorPinMissing
        }
        return fingerprint
    }

    private static func validateIdentity(
        roles: Set<NodeRole>,
        coordinatorIncarnationID: CoordinatorIncarnationID?,
        protocolSupport: InferPeer_V1_ProtocolSupport
    ) throws {
        let current = InferPeerProtocolVersion.current
        guard !roles.isEmpty, protocolSupport.major == current.major else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        guard protocolSupport.minimumMinor <= current.minor,
            protocolSupport.maximumMinor == current.minor
        else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        guard !roles.contains(.coordinator) || coordinatorIncarnationID != nil else {
            throw InferPeerGRPCError.invalidConfiguration
        }
    }

    private static func validateLimits(
        pinCount: Int,
        suppliedPinCount: Int,
        streamBufferLimit: Int,
        maximumMessageBytes: Int
    ) throws {
        guard pinCount == suppliedPinCount, streamBufferLimit > 0, maximumMessageBytes > 0 else {
            throw InferPeerGRPCError.invalidConfiguration
        }
    }

    private static func makePins(
        _ pins: [GRPCCoordinatorPin]
    ) throws -> [PeerEndpoint: CertificateFingerprint] {
        var result: [PeerEndpoint: CertificateFingerprint] = [:]
        for pin in pins {
            guard result.updateValue(pin.certificateFingerprint, forKey: pin.endpoint) == nil else {
                throw InferPeerGRPCError.invalidConfiguration
            }
        }
        return result
    }
}
