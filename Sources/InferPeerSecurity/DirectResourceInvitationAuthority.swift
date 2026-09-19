import Crypto
import Foundation
import InferPeerCore
import InferPeerProtocol

/// Issues and atomically consumes v2 resource invitations under a device-local key.
public actor DirectResourceInvitationAuthority {
    private static let authorityKeyByteCount = 32

    private let secretStore: any SecretStore
    private let configuration: PairingConfiguration
    private let dateProvider: any SecurityDateProvider

    /// Creates a stopped authority without reading device storage.
    public init(
        secretStore: any SecretStore,
        configuration: PairingConfiguration = .standard,
        dateProvider: any SecurityDateProvider = SystemSecurityDateProvider()
    ) {
        self.secretStore = secretStore
        self.configuration = configuration
        self.dateProvider = dateProvider
    }

    /// Issues one single-use, short-lived invitation for an already-bound endpoint.
    public func issue(
        resourceID: ResourceID,
        endpoint: PeerEndpoint,
        certificateFingerprint: CertificateFingerprint
    ) throws -> ResourcePairingInvitation {
        let invitationID = try makeInvitationID()
        let expiresAt = dateProvider.now().addingTimeInterval(configuration.invitationValidity)
        let unsigned = try ResourcePairingInvitation(
            protocolMajor: ResourcePairingInvitation.supportedProtocolMajor,
            invitationID: invitationID,
            resourceID: resourceID,
            endpoint: endpoint,
            certificateFingerprint: certificateFingerprint,
            secret: Data(repeating: 0, count: ResourcePairingInvitation.secretByteCount),
            expiresAt: expiresAt
        )
        let claims = try ResourcePairingInvitationCodec.claims(unsigned)
        let secret = try proof(for: claims)
        let invitation = try ResourcePairingInvitation(
            protocolMajor: unsigned.protocolMajor,
            invitationID: invitationID,
            resourceID: resourceID,
            endpoint: endpoint,
            certificateFingerprint: certificateFingerprint,
            secret: secret,
            expiresAt: expiresAt
        )
        try persist(invitation, claims: claims)
        return invitation
    }

    /// Consumes one matching invitation proof and returns its bound resource identity.
    public func consume(
        invitationID: InvitationID,
        secret: Data,
        expectedResourceID: ResourceID
    ) throws -> ResourceID {
        let stored = try activeRecord(for: invitationID)
        guard stored.record.resourceID == expectedResourceID.rawValue else {
            throw InferPeerSecurityError.invalidInvitationProof
        }
        try validate(secret, record: stored.record)
        guard try secretStore.removeData(forKey: stored.key, ifEqualTo: stored.data) else {
            throw InferPeerSecurityError.invitationUnknownOrConsumed
        }
        return expectedResourceID
    }

    private func makeInvitationID() throws -> InvitationID {
        guard let id = InvitationID(rawValue: try SecureRandom.identifier(prefix: "resource-"))
        else {
            throw InferPeerSecurityError.corruptPairingState
        }
        return id
    }

    private func proof(for claims: Data) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: claims, using: try authorityKey()))
    }

    private func authorityKey() throws -> SymmetricKey {
        if let data = try secretStore.data(forKey: SecuritySecretKey.directPairingAuthority) {
            guard data.count == Self.authorityKeyByteCount else {
                throw InferPeerSecurityError.corruptPairingState
            }
            return SymmetricKey(data: data)
        }
        let data = try SecureRandom.data(count: Self.authorityKeyByteCount)
        try secretStore.setData(data, forKey: SecuritySecretKey.directPairingAuthority)
        return SymmetricKey(data: data)
    }

    private func persist(_ invitation: ResourcePairingInvitation, claims: Data) throws {
        guard let invitationID = invitation.invitationID else {
            throw InferPeerSecurityError.invalidInvitationEncoding
        }
        let record = DirectInvitationRecord(
            version: DirectInvitationRecord.currentVersion,
            resourceID: invitation.resourceID.rawValue,
            claims: claims,
            claimsDigest: Data(SHA256.hash(data: claims)),
            expiresAt: invitation.expiresAt
        )
        let data = try ResourcePairingInvitationCodec.encoder().encode(record)
        try secretStore.setData(
            data,
            forKey: SecuritySecretKey.directInvitation(invitationID.rawValue)
        )
    }

    private func activeRecord(for id: InvitationID) throws -> StoredDirectInvitation {
        let key = SecuritySecretKey.directInvitation(id.rawValue)
        guard let data = try secretStore.data(forKey: key) else {
            throw InferPeerSecurityError.invitationUnknownOrConsumed
        }
        let record: DirectInvitationRecord
        do {
            record = try ResourcePairingInvitationCodec.decoder().decode(
                DirectInvitationRecord.self,
                from: data
            )
        } catch {
            throw InferPeerSecurityError.corruptPairingState
        }
        guard record.version == DirectInvitationRecord.currentVersion,
            record.claimsDigest == Data(SHA256.hash(data: record.claims))
        else {
            throw InferPeerSecurityError.corruptPairingState
        }
        guard dateProvider.now() < record.expiresAt else {
            try secretStore.removeData(forKey: key)
            throw InferPeerSecurityError.invitationExpired
        }
        return StoredDirectInvitation(key: key, data: data, record: record)
    }

    private func validate(_ secret: Data, record: DirectInvitationRecord) throws {
        guard secret.count == ResourcePairingInvitation.secretByteCount,
            HMAC<SHA256>.isValidAuthenticationCode(
                secret,
                authenticating: record.claims,
                using: try authorityKey()
            )
        else {
            throw InferPeerSecurityError.invalidInvitationProof
        }
    }
}

private struct StoredDirectInvitation: Sendable {
    let key: String
    let data: Data
    let record: DirectInvitationRecord
}

private struct DirectInvitationRecord: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let resourceID: String
    let claims: Data
    let claimsDigest: Data
    let expiresAt: Date
}
