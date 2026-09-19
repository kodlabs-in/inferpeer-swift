import Foundation
import InferPeerCore
import InferPeerProtocol

/// Bounded JSON representation for a v2 direct-resource invitation.
public enum ResourcePairingInvitationCodec {
    /// Encodes one invitation for QR, nearby share, or explicit copy/paste transfer.
    public static func encode(
        _ invitation: ResourcePairingInvitation,
        configuration: PairingConfiguration = .standard
    ) throws -> Data {
        let data = try encoder().encode(EncodedResourceInvitation(invitation))
        guard data.count <= configuration.maximumEncodedInvitationBytes else {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
        return data
    }

    /// Decodes and structurally validates an invitation received out of band.
    public static func decode(
        _ data: Data,
        configuration: PairingConfiguration = .standard
    ) throws -> ResourcePairingInvitation {
        guard data.count <= configuration.maximumEncodedInvitationBytes else {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
        do {
            return try decoder().decode(EncodedResourceInvitation.self, from: data).value()
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
    }

    static func claims(_ invitation: ResourcePairingInvitation) throws -> Data {
        try encoder().encode(DirectInvitationClaims(invitation))
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

private struct EncodedResourceInvitation: Codable {
    static let currentVersion = 1

    let version: Int
    let invitationID: String
    let resourceID: String
    let host: String
    let port: UInt16
    let certificateFingerprint: Data
    let secret: Data
    let expiresAt: Date

    init(_ invitation: ResourcePairingInvitation) {
        version = Self.currentVersion
        invitationID = invitation.invitationID?.rawValue ?? ""
        resourceID = invitation.resourceID.rawValue
        host = invitation.endpoint.host
        port = invitation.endpoint.port
        certificateFingerprint = invitation.certificateFingerprint.bytes
        secret = invitation.secret
        expiresAt = invitation.expiresAt
    }

    func value() throws -> ResourcePairingInvitation {
        guard version == Self.currentVersion,
            let invitationID = InvitationID(rawValue: invitationID),
            expiresAt.timeIntervalSince1970.isFinite
        else {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
        do {
            return try ResourcePairingInvitation(
                protocolMajor: ResourcePairingInvitation.supportedProtocolMajor,
                invitationID: invitationID,
                resourceID: ResourceID(rawValue: resourceID),
                endpoint: PeerEndpoint(host: host, port: port),
                certificateFingerprint: CertificateFingerprint(
                    bytes: certificateFingerprint
                ),
                secret: secret,
                expiresAt: expiresAt
            )
        } catch {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
    }
}

private struct DirectInvitationClaims: Codable {
    static let currentVersion = 1

    let version: Int
    let invitationID: String
    let resourceID: String
    let host: String
    let port: UInt16
    let certificateFingerprint: Data
    let expiresAt: Date

    init(_ invitation: ResourcePairingInvitation) {
        version = Self.currentVersion
        invitationID = invitation.invitationID?.rawValue ?? ""
        resourceID = invitation.resourceID.rawValue
        host = invitation.endpoint.host
        port = invitation.endpoint.port
        certificateFingerprint = invitation.certificateFingerprint.bytes
        expiresAt = invitation.expiresAt
    }
}
