import Foundation
import InferPeerCore
import InferPeerProtocol

struct HandshakeResult: Sendable {
    let remoteIdentity: PresentedPeerIdentity
    let negotiatedProtocol: InferPeer_V1_NegotiatedProtocol
}

struct OrderedMetadataValidator: Sendable {
    let clusterID: ClusterID
    let senderID: PeerID
    let protocolVersion: InferPeer_V1_ProtocolVersion
    private var nextSequence: UInt64

    init(
        clusterID: ClusterID,
        senderID: PeerID,
        protocolVersion: InferPeer_V1_ProtocolVersion,
        nextSequence: UInt64
    ) {
        self.clusterID = clusterID
        self.senderID = senderID
        self.protocolVersion = protocolVersion
        self.nextSequence = nextSequence
    }

    mutating func validate(_ metadata: InferPeer_V1_MessageMetadata) throws {
        guard metadata.hasProtocolVersion, metadata.protocolVersion == protocolVersion else {
            throw InferPeerGRPCError.invalidMessage
        }
        guard metadata.clusterID == clusterID.rawValue else {
            throw InferPeerGRPCError.invalidMessage
        }
        guard metadata.authenticatedSenderID == senderID.rawValue else {
            throw InferPeerGRPCError.unauthenticated
        }
        guard MessageID(rawValue: metadata.messageID) != nil else {
            throw InferPeerGRPCError.invalidMessage
        }
        guard metadata.sequence == nextSequence else {
            throw InferPeerGRPCError.sequenceViolation
        }
        guard nextSequence < .max else { throw InferPeerGRPCError.sequenceViolation }
        nextSequence += 1
    }
}

struct ServerHandshakeValidator: Sendable {
    let configuration: GRPCTransportConfiguration

    func validate(
        metadata: InferPeer_V1_MessageMetadata,
        hello: InferPeer_V1_SessionHello,
        identity: PresentedPeerIdentity,
        role: NodeRole
    ) async throws -> InferPeer_V1_NegotiatedProtocol {
        let negotiated = try negotiate(hello.protocolSupport)
        try validateInitialMetadata(metadata, remote: hello.protocolSupport, identity: identity)
        try validateHello(hello, identity: identity, role: role)
        try await configuration.sessionAuthorizer.authorize(
            identity: identity,
            hello: hello,
            role: role
        )
        return negotiated
    }

    private func validateInitialMetadata(
        _ metadata: InferPeer_V1_MessageMetadata,
        remote: InferPeer_V1_ProtocolSupport,
        identity: PresentedPeerIdentity
    ) throws {
        guard metadata.hasProtocolVersion, metadata.protocolVersion.major == remote.major else {
            throw InferPeerGRPCError.invalidMessage
        }
        guard (remote.minimumMinor...remote.maximumMinor).contains(metadata.protocolVersion.minor)
        else {
            throw InferPeerGRPCError.invalidMessage
        }
        guard metadata.clusterID == configuration.clusterID.rawValue else {
            throw InferPeerGRPCError.invalidMessage
        }
        guard metadata.authenticatedSenderID == identity.peerID.rawValue else {
            throw InferPeerGRPCError.unauthenticated
        }
        guard MessageID(rawValue: metadata.messageID) != nil, metadata.sequence == 1 else {
            throw InferPeerGRPCError.invalidMessage
        }
    }

    private func negotiate(
        _ remote: InferPeer_V1_ProtocolSupport
    ) throws -> InferPeer_V1_NegotiatedProtocol {
        do {
            return try ProtocolNegotiator.negotiate(
                local: configuration.protocolSupport,
                remote: remote
            )
        } catch {
            throw InferPeerGRPCError.protocolMismatch
        }
    }

    private func validateHello(
        _ hello: InferPeer_V1_SessionHello,
        identity: PresentedPeerIdentity,
        role: NodeRole
    ) throws {
        guard hello.hasProtocolSupport else { throw InferPeerGRPCError.invalidMessage }
        guard hello.certificateFingerprintSha256 == identity.certificateFingerprint.bytes else {
            throw InferPeerGRPCError.unauthenticated
        }
        guard hello.roles.contains(role.wireValue) else {
            throw InferPeerGRPCError.permissionDenied
        }
    }
}

struct ClientHandshakeValidator: Sendable {
    let configuration: GRPCTransportConfiguration

    func validateAccepted(
        _ response: InferPeer_V1_ClientSessionResponse,
        identity: PresentedPeerIdentity
    ) throws -> HandshakeResult {
        guard case .sessionAccepted(let accepted) = response.payload else {
            throw rejection(from: response)
        }
        try validateNegotiatedProtocol(accepted.negotiatedProtocol)
        try validateMetadata(
            response.metadata,
            identity: identity,
            protocolVersion: accepted.negotiatedProtocol.version
        )
        guard CoordinatorIncarnationID(rawValue: accepted.coordinatorIncarnationID) != nil else {
            throw InferPeerGRPCError.invalidMessage
        }
        return HandshakeResult(
            remoteIdentity: identity,
            negotiatedProtocol: accepted.negotiatedProtocol
        )
    }

    func validateAccepted(
        _ response: InferPeer_V1_WorkerSessionResponse,
        identity: PresentedPeerIdentity
    ) throws -> HandshakeResult {
        guard case .sessionAccepted(let accepted) = response.payload else {
            throw rejection(from: response)
        }
        try validateNegotiatedProtocol(accepted.negotiatedProtocol)
        try validateMetadata(
            response.metadata,
            identity: identity,
            protocolVersion: accepted.negotiatedProtocol.version
        )
        guard CoordinatorIncarnationID(rawValue: accepted.coordinatorIncarnationID) != nil else {
            throw InferPeerGRPCError.invalidMessage
        }
        return HandshakeResult(
            remoteIdentity: identity,
            negotiatedProtocol: accepted.negotiatedProtocol
        )
    }

    private func validateNegotiatedProtocol(
        _ negotiated: InferPeer_V1_NegotiatedProtocol
    ) throws {
        let local = configuration.protocolSupport
        guard negotiated.hasVersion, negotiated.version.major == local.major else {
            throw InferPeerGRPCError.protocolMismatch
        }
        guard (local.minimumMinor...local.maximumMinor).contains(negotiated.version.minor) else {
            throw InferPeerGRPCError.protocolMismatch
        }
        let supportedCapabilities = Set(local.capabilities.map(\.rawValue))
        guard negotiated.capabilities.allSatisfy({ supportedCapabilities.contains($0.rawValue) })
        else {
            throw InferPeerGRPCError.protocolMismatch
        }
    }

    private func validateMetadata(
        _ metadata: InferPeer_V1_MessageMetadata,
        identity: PresentedPeerIdentity,
        protocolVersion: InferPeer_V1_ProtocolVersion
    ) throws {
        var validator = OrderedMetadataValidator(
            clusterID: configuration.clusterID,
            senderID: identity.peerID,
            protocolVersion: protocolVersion,
            nextSequence: 1
        )
        try validator.validate(metadata)
    }

    private func rejection(
        from response: InferPeer_V1_ClientSessionResponse
    ) -> InferPeerGRPCError {
        guard case .sessionRejected(let rejected) = response.payload else {
            return .invalidMessage
        }
        return .handshakeRejected(InferPeerError(wireValue: rejected.error))
    }

    private func rejection(
        from response: InferPeer_V1_WorkerSessionResponse
    ) -> InferPeerGRPCError {
        guard case .sessionRejected(let rejected) = response.payload else {
            return .invalidMessage
        }
        return .handshakeRejected(InferPeerError(wireValue: rejected.error))
    }
}

enum HandshakeMessageFactory {
    static func callerHello(
        configuration: GRPCTransportConfiguration
    ) -> InferPeer_V1_ClientSessionRequest {
        InferPeer_V1_ClientSessionRequest.with {
            $0.metadata = metadata(configuration: configuration, sequence: 1)
            $0.hello = hello(configuration: configuration, role: .caller)
        }
    }

    static func workerHello(
        configuration: GRPCTransportConfiguration
    ) -> InferPeer_V1_WorkerSessionRequest {
        InferPeer_V1_WorkerSessionRequest.with {
            $0.metadata = metadata(configuration: configuration, sequence: 1)
            $0.hello = hello(configuration: configuration, role: .worker)
        }
    }

    static func callerAccepted(
        configuration: GRPCTransportConfiguration,
        negotiated: InferPeer_V1_NegotiatedProtocol
    ) throws -> InferPeer_V1_ClientSessionResponse {
        let incarnationID = try coordinatorIncarnationID(configuration)
        return InferPeer_V1_ClientSessionResponse.with {
            $0.metadata = metadata(
                configuration: configuration,
                protocolVersion: negotiated.version,
                sequence: 1
            )
            $0.sessionAccepted.negotiatedProtocol = negotiated
            $0.sessionAccepted.coordinatorIncarnationID = incarnationID.rawValue
        }
    }

    static func workerAccepted(
        configuration: GRPCTransportConfiguration,
        negotiated: InferPeer_V1_NegotiatedProtocol
    ) throws -> InferPeer_V1_WorkerSessionResponse {
        let incarnationID = try coordinatorIncarnationID(configuration)
        return InferPeer_V1_WorkerSessionResponse.with {
            $0.metadata = metadata(
                configuration: configuration,
                protocolVersion: negotiated.version,
                sequence: 1
            )
            $0.sessionAccepted.negotiatedProtocol = negotiated
            $0.sessionAccepted.coordinatorIncarnationID = incarnationID.rawValue
        }
    }

    static func callerRejected(
        configuration: GRPCTransportConfiguration,
        error: any Error
    ) -> InferPeer_V1_ClientSessionResponse {
        InferPeer_V1_ClientSessionResponse.with {
            $0.metadata = metadata(configuration: configuration, sequence: 1)
            $0.sessionRejected.error = protocolError(from: error)
        }
    }

    static func workerRejected(
        configuration: GRPCTransportConfiguration,
        error: any Error
    ) -> InferPeer_V1_WorkerSessionResponse {
        InferPeer_V1_WorkerSessionResponse.with {
            $0.metadata = metadata(configuration: configuration, sequence: 1)
            $0.sessionRejected.error = protocolError(from: error)
        }
    }

    private static func coordinatorIncarnationID(
        _ configuration: GRPCTransportConfiguration
    ) throws -> CoordinatorIncarnationID {
        guard let id = configuration.coordinatorIncarnationID else {
            throw InferPeerGRPCError.invalidConfiguration
        }
        return id
    }

    private static func hello(
        configuration: GRPCTransportConfiguration,
        role: NodeRole
    ) -> InferPeer_V1_SessionHello {
        InferPeer_V1_SessionHello.with {
            $0.protocolSupport = configuration.protocolSupport
            $0.roles = [role.wireValue]
            $0.certificateFingerprintSha256 =
                configuration.credentials.identity.certificateFingerprint.bytes
            if let invitation = configuration.invitation {
                $0.invitationID = invitation.invitationID.rawValue
                $0.invitationProof = invitation.proof
            }
        }
    }

    private static func metadata(
        configuration: GRPCTransportConfiguration,
        protocolVersion: InferPeer_V1_ProtocolVersion? = nil,
        sequence: UInt64
    ) -> InferPeer_V1_MessageMetadata {
        InferPeer_V1_MessageMetadata.with {
            $0.protocolVersion = protocolVersion ?? InferPeerProtocolVersion.current
            $0.clusterID = configuration.clusterID.rawValue
            $0.authenticatedSenderID = configuration.credentials.identity.peerID.rawValue
            $0.messageID = UUID().uuidString.lowercased()
            $0.sequence = sequence
        }
    }

    private static func protocolError(from error: any Error) -> InferPeer_V1_ProtocolError {
        if let error = error as? InferPeerError {
            return error.wireValue
        }
        let grpcError = GRPCErrorMapper.publicError(from: error)
        let code: InferPeerErrorCode
        switch grpcError {
        case .unauthenticated: code = .unauthenticated
        case .permissionDenied: code = .permissionDenied
        case .protocolMismatch: code = .protocolMismatch
        case .bufferExhausted: code = .resourceExhausted
        default: code = .invalidRequest
        }
        return InferPeerError(code: code, isRetryable: false).wireValue
    }
}

extension NodeRole {
    fileprivate var wireValue: InferPeer_V1_NodeRole {
        switch self {
        case .caller: .caller
        case .coordinator: .coordinator
        case .worker: .worker
        }
    }
}
