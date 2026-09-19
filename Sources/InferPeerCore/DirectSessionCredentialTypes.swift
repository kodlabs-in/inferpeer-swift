import Foundation

/// Persisted authorization for reconnecting to one exact pinned resource endpoint.
public struct DirectResourceCredential: Hashable, Sendable {
    /// Paired resource identity.
    public let resourceID: ResourceID
    /// Exact endpoint authorized during pairing.
    public let endpoint: PeerEndpoint
    /// Certificate pin verified during every TLS connection.
    public let certificateFingerprint: CertificateFingerprint
    /// Opaque resource-issued authorization credential.
    public let credential: Data

    /// Creates a nonempty credential that cannot identify the local in-process resource.
    public init(
        resourceID: ResourceID,
        endpoint: PeerEndpoint,
        certificateFingerprint: CertificateFingerprint,
        credential: Data
    ) throws {
        guard resourceID != .local, !credential.isEmpty else {
            throw DirectResourceCredentialError.invalidCredential
        }
        self.resourceID = resourceID
        self.endpoint = endpoint
        self.certificateFingerprint = certificateFingerprint
        self.credential = credential
    }
}

/// Failures from device-local paired-resource credential persistence.
public enum DirectResourceCredentialError: Error, Equatable, Sendable {
    case invalidCredential
    case corruptCredential
}

/// Device-local, non-synchronizing persistence for paired resource credentials.
public protocol DirectResourceCredentialStoring: Sendable {
    /// Returns the credential for one exact resource, when paired.
    func credential(for resourceID: ResourceID) async throws -> DirectResourceCredential?

    /// Atomically adds or replaces one resource credential.
    func save(_ credential: DirectResourceCredential) async throws

    /// Revokes the local credential for one resource.
    func removeCredential(for resourceID: ResourceID) async throws

    /// Returns every paired resource identity known to this app installation.
    func resourceIDs() async throws -> [ResourceID]
}
