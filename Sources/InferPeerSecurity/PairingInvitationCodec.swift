import Foundation
import InferPeerCore
import InferPeerProtocol

/// A bounded, versioned JSON representation suitable for an out-of-band pairing channel.
public enum PairingInvitationCodec {
    /// Encodes one validated invitation without logging or interpreting its proof.
    public static func encode(
        _ invitation: PairingInvitation,
        configuration: PairingConfiguration = .standard
    ) throws -> Data {
        do {
            let data = try encoder().encode(EncodedPairingInvitation(invitation))
            guard data.count <= configuration.maximumEncodedInvitationBytes else {
                throw InferPeerSecurityError.invalidInvitationEncoding
            }
            return data
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
    }

    /// Decodes one bounded invitation and revalidates all public domain values.
    public static func decode(
        _ data: Data,
        configuration: PairingConfiguration = .standard
    ) throws -> PairingInvitation {
        guard data.count <= configuration.maximumEncodedInvitationBytes else {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
        do {
            let encoded = try decoder().decode(EncodedPairingInvitation.self, from: data)
            return try encoded.invitation()
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
    }

    static func encodeClaims(_ invitation: PairingInvitation) throws -> Data {
        try encoder().encode(PairingInvitationClaims(invitation))
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct EncodedPairingInvitation: Codable {
    static let currentVersion = 1

    let version: Int
    let invitationID: String
    let clusterID: String
    let coordinatorHost: String
    let coordinatorPort: UInt16
    let certificateFingerprint: Data
    let expiresAt: Date
    let proof: Data

    init(_ invitation: PairingInvitation) throws {
        guard invitation.expiresAt.timeIntervalSince1970.isFinite,
            invitation.proof.count == PairingInvitationAuthority.proofByteCount
        else {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
        version = Self.currentVersion
        invitationID = invitation.invitationID.rawValue
        clusterID = invitation.coordinator.clusterID.rawValue
        coordinatorHost = invitation.coordinator.endpoint.host
        coordinatorPort = invitation.coordinator.endpoint.port
        certificateFingerprint = invitation.coordinator.certificateFingerprint.bytes
        expiresAt = invitation.expiresAt
        proof = invitation.proof
    }

    func invitation() throws -> PairingInvitation {
        guard version == Self.currentVersion,
            expiresAt.timeIntervalSince1970.isFinite,
            proof.count == PairingInvitationAuthority.proofByteCount,
            let invitationID = InvitationID(rawValue: invitationID),
            let clusterID = ClusterID(rawValue: clusterID)
        else {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
        let endpoint = try PeerEndpoint(host: coordinatorHost, port: coordinatorPort)
        let fingerprint = try CertificateFingerprint(bytes: certificateFingerprint)
        return PairingInvitation(
            invitationID: invitationID,
            coordinator: PairingCoordinator(
                clusterID: clusterID,
                endpoint: endpoint,
                certificateFingerprint: fingerprint
            ),
            expiresAt: expiresAt,
            proof: proof
        )
    }
}

struct PairingInvitationClaims: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let invitationID: String
    let clusterID: String
    let coordinatorHost: String
    let coordinatorPort: UInt16
    let certificateFingerprint: Data
    let expiresAt: Date

    init(_ invitation: PairingInvitation) {
        version = Self.currentVersion
        invitationID = invitation.invitationID.rawValue
        clusterID = invitation.coordinator.clusterID.rawValue
        coordinatorHost = invitation.coordinator.endpoint.host
        coordinatorPort = invitation.coordinator.endpoint.port
        certificateFingerprint = invitation.coordinator.certificateFingerprint.bytes
        expiresAt = invitation.expiresAt
    }
}
