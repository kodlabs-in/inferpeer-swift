import Crypto
import Foundation
import InferPeerCore
import InferPeerProtocol

/// Issues and atomically consumes short-lived invitation proofs under a device-local secret.
public actor PairingInvitationAuthority {
    static let proofByteCount = 32
    private static let authorityKeyByteCount = 32

    private let secretStore: any SecretStore
    private let configuration: PairingConfiguration
    private let dateProvider: any SecurityDateProvider

    /// Creates an invitation authority without loading or generating secrets yet.
    public init(
        secretStore: any SecretStore,
        configuration: PairingConfiguration = .standard,
        dateProvider: any SecurityDateProvider = SystemSecurityDateProvider()
    ) {
        self.secretStore = secretStore
        self.configuration = configuration
        self.dateProvider = dateProvider
    }

    /// Creates and persists one single-use invitation before returning its proof.
    public func issue(for coordinator: PairingCoordinator) throws -> PairingInvitation {
        let invitationID = try makeInvitationID()
        let unsigned = PairingInvitation(
            invitationID: invitationID,
            coordinator: coordinator,
            expiresAt: dateProvider.now().addingTimeInterval(configuration.invitationValidity),
            proof: Data()
        )
        let claims = try PairingInvitationCodec.encodeClaims(unsigned)
        let proof = try makeProof(for: claims)
        let invitation = PairingInvitation(
            invitationID: invitationID,
            coordinator: coordinator,
            expiresAt: unsigned.expiresAt,
            proof: proof
        )
        try persistInvitation(invitation, claims: claims)
        return invitation
    }

    /// Verifies and removes an invitation so no later session can replay it.
    public func consume(_ invitation: PairingInvitation) throws {
        let storageKey = SecuritySecretKey.invitation(invitation.invitationID.rawValue)
        guard let data = try secretStore.data(forKey: storageKey) else {
            throw InferPeerSecurityError.invitationUnknownOrConsumed
        }
        let record = try decodeRecord(data)
        guard dateProvider.now() < record.expiresAt else {
            try secretStore.removeData(forKey: storageKey)
            throw InferPeerSecurityError.invitationExpired
        }
        let claims = try PairingInvitationCodec.encodeClaims(invitation)
        try validate(invitation, claims: claims, record: record)
        try secretStore.removeData(forKey: storageKey)
    }

    /// Replaces the authority key, invalidating every outstanding proof.
    public func rotateAuthorityKey() throws {
        try secretStore.setData(
            SecureRandom.data(count: Self.authorityKeyByteCount),
            forKey: SecuritySecretKey.pairingAuthority
        )
    }

    private func makeInvitationID() throws -> InvitationID {
        guard
            let identifier = InvitationID(
                rawValue: try SecureRandom.identifier(prefix: "invitation-")
            )
        else {
            throw InferPeerSecurityError.corruptPairingState
        }
        return identifier
    }

    private func makeProof(for claims: Data) throws -> Data {
        let key = SymmetricKey(data: try authorityKey())
        return Data(HMAC<SHA256>.authenticationCode(for: claims, using: key))
    }

    private func authorityKey() throws -> Data {
        if let key = try secretStore.data(forKey: SecuritySecretKey.pairingAuthority) {
            guard key.count == Self.authorityKeyByteCount else {
                throw InferPeerSecurityError.corruptPairingState
            }
            return key
        }
        let key = try SecureRandom.data(count: Self.authorityKeyByteCount)
        try secretStore.setData(key, forKey: SecuritySecretKey.pairingAuthority)
        return key
    }

    private func persistInvitation(_ invitation: PairingInvitation, claims: Data) throws {
        let record = IssuedInvitationRecord(
            version: IssuedInvitationRecord.currentVersion,
            claimsDigest: Data(SHA256.hash(data: claims)),
            expiresAt: invitation.expiresAt
        )
        let data = try PairingInvitationCodec.encoder().encode(record)
        try secretStore.setData(
            data,
            forKey: SecuritySecretKey.invitation(invitation.invitationID.rawValue)
        )
    }

    private func decodeRecord(_ data: Data) throws -> IssuedInvitationRecord {
        do {
            let record = try PairingInvitationCodec.decoder().decode(
                IssuedInvitationRecord.self,
                from: data
            )
            guard record.version == IssuedInvitationRecord.currentVersion,
                record.claimsDigest.count == SHA256.Digest.byteCount
            else {
                throw InferPeerSecurityError.corruptPairingState
            }
            return record
        } catch let error as InferPeerSecurityError {
            throw error
        } catch {
            throw InferPeerSecurityError.corruptPairingState
        }
    }

    private func validate(
        _ invitation: PairingInvitation,
        claims: Data,
        record: IssuedInvitationRecord
    ) throws {
        guard Data(SHA256.hash(data: claims)) == record.claimsDigest else {
            throw InferPeerSecurityError.invalidInvitationProof
        }
        let key = SymmetricKey(data: try authorityKey())
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                invitation.proof,
                authenticating: claims,
                using: key
            )
        else {
            throw InferPeerSecurityError.invalidInvitationProof
        }
    }
}

private struct IssuedInvitationRecord: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let claimsDigest: Data
    let expiresAt: Date
}
