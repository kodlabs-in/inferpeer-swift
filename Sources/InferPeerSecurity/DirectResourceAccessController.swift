import Crypto
import Foundation
import InferPeerCore
import InferPeerProtocol

/// Stable failures for resource-host credential exchange and authorization.
public enum DirectResourceAccessError: Error, Equatable, Sendable {
    case maximumPairingsReached
    case invalidCredential
    case corruptCredentialStore
}

/// Opaque owner identity derived from a resource-scoped credential.
public struct DirectResourcePrincipal: RawRepresentable, Hashable, Sendable {
    /// Stable opaque identifier for one paired application owner.
    public let rawValue: String

    /// Creates an owner identity from its stored opaque value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Credential returned once after a successful invitation exchange.
public struct DirectResourceAccessGrant: Sendable {
    /// Owner identity bound to the new credential.
    public let principal: DirectResourcePrincipal
    /// Plaintext bearer credential returned once to the pairing client.
    public let credential: Data

    /// Creates a pairing grant returned after successful proof exchange.
    public init(principal: DirectResourcePrincipal, credential: Data) {
        self.principal = principal
        self.credential = credential
    }
}

/// Foreground-host access controller with durable, resource-scoped credentials.
public actor DirectResourceAccessController {
    private static let credentialByteCount = 32

    private let secretStore: any SecretStore
    private let invitations: DirectResourceInvitationAuthority
    private let maximumPairings: Int

    /// Creates an access controller sharing the host's device-local secret store.
    public init(
        secretStore: any SecretStore,
        invitations: DirectResourceInvitationAuthority,
        maximumPairings: Int = 16
    ) throws {
        guard maximumPairings > 0 else {
            throw InferPeerSecurityError.invalidConfiguration
        }
        self.secretStore = secretStore
        self.invitations = invitations
        self.maximumPairings = maximumPairings
    }

    /// Atomically consumes an invitation and creates one durable bearer credential.
    public func exchange(
        invitationID: InvitationID,
        secret: Data,
        expectedResourceID: ResourceID
    ) async throws -> DirectResourceAccessGrant {
        var records = try loadRecords()
        guard records.count < maximumPairings else {
            throw DirectResourceAccessError.maximumPairingsReached
        }
        _ = try await invitations.consume(
            invitationID: invitationID,
            secret: secret,
            expectedResourceID: expectedResourceID
        )
        let credential = try SecureRandom.data(count: Self.credentialByteCount)
        let digest = Self.digest(credential)
        let principal = DirectResourcePrincipal(rawValue: digest)
        records[digest] = DirectAccessRecord(principalID: principal.rawValue)
        try persist(records)
        return DirectResourceAccessGrant(principal: principal, credential: credential)
    }

    /// Validates one credential without retaining or logging its plaintext bytes.
    public func authorize(_ credential: Data) throws -> DirectResourcePrincipal {
        guard credential.count == Self.credentialByteCount,
            let record = try loadRecords()[Self.digest(credential)]
        else {
            throw DirectResourceAccessError.invalidCredential
        }
        return DirectResourcePrincipal(rawValue: record.principalID)
    }

    /// Revokes one paired application identity and its future sessions.
    public func revoke(_ principal: DirectResourcePrincipal) throws {
        var records = try loadRecords()
        records[principal.rawValue] = nil
        try persist(records)
    }

    /// Returns the number of retained paired identities without exposing credentials.
    public func pairingCount() throws -> Int {
        try loadRecords().count
    }

    private func loadRecords() throws -> [String: DirectAccessRecord] {
        guard let data = try secretStore.data(forKey: SecuritySecretKey.directResourceCredentials)
        else { return [:] }
        do {
            return try JSONDecoder().decode([String: DirectAccessRecord].self, from: data)
        } catch {
            throw DirectResourceAccessError.corruptCredentialStore
        }
    }

    private func persist(_ records: [String: DirectAccessRecord]) throws {
        guard !records.isEmpty else {
            try secretStore.removeData(forKey: SecuritySecretKey.directResourceCredentials)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try secretStore.setData(
                encoder.encode(records),
                forKey: SecuritySecretKey.directResourceCredentials
            )
        } catch let error as DirectResourceAccessError {
            throw error
        } catch {
            throw DirectResourceAccessError.corruptCredentialStore
        }
    }

    private static func digest(_ credential: Data) -> String {
        SHA256.hash(data: credential).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DirectAccessRecord: Codable, Sendable {
    let principalID: String
}
