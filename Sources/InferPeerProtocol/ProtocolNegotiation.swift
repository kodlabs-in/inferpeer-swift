/// Identifies which peer supplied invalid version support information.
public enum ProtocolNegotiationPeer: Equatable, Sendable {
    /// The node performing negotiation.
    case local

    /// The connecting node.
    case remote
}

/// An error encountered while negotiating an InferPeer protocol version.
public enum ProtocolNegotiationError: Error, Equatable, Sendable {
    /// A peer advertised protocol major version zero.
    case invalidMajor(peer: ProtocolNegotiationPeer)

    /// A peer advertised a minimum minor version greater than its maximum.
    case invalidMinorRange(peer: ProtocolNegotiationPeer)

    /// The peers support different major versions.
    case incompatibleMajor(local: UInt32, remote: UInt32)

    /// The peers have no overlapping minor version.
    case noSharedMinorVersion
}

/// Negotiates the highest mutually supported protocol version and shared known capabilities.
public enum ProtocolNegotiator {
    /// Negotiates a session between local and remote protocol support declarations.
    public static func negotiate(
        local: InferPeer_V1_ProtocolSupport,
        remote: InferPeer_V1_ProtocolSupport
    ) throws -> InferPeer_V1_NegotiatedProtocol {
        try validate(local, peer: .local)
        try validate(remote, peer: .remote)

        guard local.major == remote.major else {
            throw ProtocolNegotiationError.incompatibleMajor(
                local: local.major,
                remote: remote.major
            )
        }

        let minimumMinor = max(local.minimumMinor, remote.minimumMinor)
        let maximumMinor = min(local.maximumMinor, remote.maximumMinor)
        guard minimumMinor <= maximumMinor else {
            throw ProtocolNegotiationError.noSharedMinorVersion
        }

        return InferPeer_V1_NegotiatedProtocol.with {
            $0.version.major = local.major
            $0.version.minor = maximumMinor
            $0.capabilities = sharedKnownCapabilities(local: local, remote: remote)
        }
    }

    private static let knownCapabilitiesByRawValue: [Int: InferPeer_V1_Capability] = [
        InferPeer_V1_Capability.sessionResumption.rawValue: .sessionResumption,
        InferPeer_V1_Capability.eventReplay.rawValue: .eventReplay,
        InferPeer_V1_Capability.durableCancellation.rawValue: .durableCancellation,
        InferPeer_V1_Capability.attemptLeases.rawValue: .attemptLeases,
        InferPeer_V1_Capability.boundedStreaming.rawValue: .boundedStreaming,
        InferPeer_V1_Capability.allowedWorkers.rawValue: .allowedWorkers,
        InferPeer_V1_Capability.modelRevisionSelection.rawValue: .modelRevisionSelection,
    ]

    private static func validate(
        _ support: InferPeer_V1_ProtocolSupport,
        peer: ProtocolNegotiationPeer
    ) throws {
        guard support.major > 0 else {
            throw ProtocolNegotiationError.invalidMajor(peer: peer)
        }
        guard support.minimumMinor <= support.maximumMinor else {
            throw ProtocolNegotiationError.invalidMinorRange(peer: peer)
        }
    }

    private static func sharedKnownCapabilities(
        local: InferPeer_V1_ProtocolSupport,
        remote: InferPeer_V1_ProtocolSupport
    ) -> [InferPeer_V1_Capability] {
        let localValues = Set(local.capabilities.map(\.rawValue))
        let remoteValues = Set(remote.capabilities.map(\.rawValue))

        return
            localValues
            .intersection(remoteValues)
            .sorted()
            .compactMap { knownCapabilitiesByRawValue[$0] }
    }
}
