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
    /// Whether loopback endpoints are permitted for local test harnesses.
    public let allowsLoopback: Bool
    let interfaceIndex: UInt32

    /// Production hosts must supply a validated Wi-Fi interface. Loopback requires explicit opt-in.
    public init(
        interfaceName: String,
        allowedEndpoints: Set<PeerEndpoint>,
        allowsLoopback: Bool = false
    ) throws {
        let index = if_nametoindex(interfaceName)
        guard index > 0, !allowedEndpoints.isEmpty else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        guard
            allowedEndpoints.allSatisfy({
                Self.isLocalEndpoint(
                    $0,
                    interfaceName: interfaceName,
                    allowsLoopback: allowsLoopback
                )
            })
        else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        self.interfaceName = interfaceName
        self.allowedEndpoints = allowedEndpoints
        self.allowsLoopback = allowsLoopback
        interfaceIndex = index
    }

    func validate(_ endpoint: PeerEndpoint) throws {
        guard allowedEndpoints.contains(endpoint) else {
            throw InferPeerGRPCError.endpointNotAllowed
        }
    }

    private static func isLocalEndpoint(
        _ endpoint: PeerEndpoint,
        interfaceName: String,
        allowsLoopback: Bool
    ) -> Bool {
        guard let host = unscopedHost(endpoint.host, matching: interfaceName) else { return false }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return isLocalIPv4(ipv4, allowsLoopback: allowsLoopback)
        }
        var ipv6 = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        return isLocalIPv6(ipv6, allowsLoopback: allowsLoopback)
    }

    private static func unscopedHost(_ host: String, matching interfaceName: String) -> String? {
        let components = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count > 1 else { return host }
        guard components.count == 2, components[1] == Substring(interfaceName) else { return nil }
        return String(components[0])
    }

    private static func isLocalIPv4(_ address: in_addr, allowsLoopback: Bool) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let first = UInt8((value >> 24) & 0xFF)
        let second = UInt8((value >> 16) & 0xFF)
        if first == 10 || (first == 172 && (16...31).contains(second)) { return true }
        if first == 192 && second == 168 { return true }
        if first == 169 && second == 254 { return true }
        return allowsLoopback && first == 127
    }

    private static func isLocalIPv6(_ address: in6_addr, allowsLoopback: Bool) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        return allowsLoopback && bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1
    }
}

/// Immutable policy and identity inputs for one concrete gRPC transport adapter.
public struct GRPCTransportConfiguration: Sendable {
    /// Hard maximum uncompressed Protobuf message size: 256 KiB.
    public static let defaultMaximumMessageBytes = InferPeerProtocolLimits.maximumMessageBytes
    /// Hard maximum retained application payload: one MiB per stream.
    public static let maximumBufferedBytes = 1_024 * 1_024
    /// Default number of retained maximum-sized messages per application stream.
    public static let defaultStreamBufferLimit = 4
    /// Default maximum duration for the peer's first authenticated session response.
    public static let defaultHandshakeTimeout = Duration.seconds(10)

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
    /// Maximum time allowed for session negotiation after connecting.
    public let handshakeTimeout: Duration

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
        maximumMessageBytes: Int = Self.defaultMaximumMessageBytes,
        handshakeTimeout: Duration = Self.defaultHandshakeTimeout
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
            maximumMessageBytes: maximumMessageBytes,
            handshakeTimeout: handshakeTimeout
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
        self.handshakeTimeout = handshakeTimeout
    }

    func coordinatorFingerprint(for endpoint: PeerEndpoint) throws -> CertificateFingerprint {
        guard let fingerprint = coordinatorPins[endpoint] else {
            throw InferPeerGRPCError.coordinatorPinMissing
        }
        return fingerprint
    }

    func applying(_ invitation: PairingInvitation, to endpoint: PeerEndpoint) throws -> Self {
        guard invitation.coordinator.endpoint == endpoint else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        guard invitation.expiresAt > Date() else {
            throw InferPeerGRPCError.invitationExpired
        }
        try networkPolicy.validate(endpoint)
        let invitationCredentials = try GRPCInvitationCredentials(
            invitationID: invitation.invitationID,
            proof: invitation.proof
        )
        return try Self(
            clusterID: invitation.coordinator.clusterID,
            credentials: credentials,
            enabledRoles: enabledRoles,
            coordinatorIncarnationID: coordinatorIncarnationID,
            protocolSupport: protocolSupport,
            invitation: invitationCredentials,
            coordinatorPins: [
                GRPCCoordinatorPin(
                    endpoint: endpoint,
                    certificateFingerprint: invitation.coordinator.certificateFingerprint
                )
            ],
            certificateVerifier: certificateVerifier,
            sessionAuthorizer: sessionAuthorizer,
            networkPolicy: networkPolicy,
            streamBufferLimit: streamBufferLimit,
            maximumMessageBytes: maximumMessageBytes,
            handshakeTimeout: handshakeTimeout
        )
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
        maximumMessageBytes: Int,
        handshakeTimeout: Duration
    ) throws {
        guard maximumMessageBytes > 0 else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        let maximumElements = maximumBufferedBytes / maximumMessageBytes
        guard pinCount == suppliedPinCount,
            streamBufferLimit > 1,
            maximumMessageBytes <= defaultMaximumMessageBytes,
            streamBufferLimit <= maximumElements,
            handshakeTimeout > .zero
        else {
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
