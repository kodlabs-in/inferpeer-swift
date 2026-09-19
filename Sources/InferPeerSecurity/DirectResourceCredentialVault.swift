import Foundation
import InferPeerCore

/// Non-synchronizing paired-resource credentials stored through the host's secret store.
public actor DirectResourceCredentialVault: DirectResourceCredentialStoring {
    private struct StoredCredential: Codable {
        let endpointHost: String
        let endpointPort: UInt16
        let certificateFingerprint: Data
        let credential: Data
    }

    private static let storageKey = "direct-resource-credentials-v1"
    private let secretStore: any SecretStore

    /// Creates an isolated credential vault, typically backed by the device-only Keychain.
    public init(secretStore: any SecretStore) {
        self.secretStore = secretStore
    }

    /// Returns the credential for one exact resource, when paired.
    public func credential(for resourceID: ResourceID) throws -> DirectResourceCredential? {
        guard let stored = try records()[resourceID.rawValue] else { return nil }
        return try Self.restore(stored, resourceID: resourceID)
    }

    /// Atomically adds or replaces one resource credential.
    public func save(_ credential: DirectResourceCredential) throws {
        var records = try records()
        records[credential.resourceID.rawValue] = StoredCredential(
            endpointHost: credential.endpoint.host,
            endpointPort: credential.endpoint.port,
            certificateFingerprint: credential.certificateFingerprint.bytes,
            credential: credential.credential
        )
        try persist(records)
    }

    /// Revokes the local credential for one resource.
    public func removeCredential(for resourceID: ResourceID) throws {
        var records = try records()
        records[resourceID.rawValue] = nil
        try persist(records)
    }

    /// Returns paired resource identities in stable lexical order.
    public func resourceIDs() throws -> [ResourceID] {
        try records().keys.map(ResourceID.init(rawValue:)).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    private func records() throws -> [String: StoredCredential] {
        guard let data = try secretStore.data(forKey: Self.storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: StoredCredential].self, from: data)
        } catch {
            throw DirectResourceCredentialError.corruptCredential
        }
    }

    private func persist(_ records: [String: StoredCredential]) throws {
        guard !records.isEmpty else {
            try secretStore.removeData(forKey: Self.storageKey)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try secretStore.setData(try encoder.encode(records), forKey: Self.storageKey)
        } catch let error as DirectResourceCredentialError {
            throw error
        } catch {
            throw error
        }
    }

    private static func restore(
        _ stored: StoredCredential,
        resourceID: ResourceID
    ) throws -> DirectResourceCredential {
        do {
            return try DirectResourceCredential(
                resourceID: resourceID,
                endpoint: PeerEndpoint(host: stored.endpointHost, port: stored.endpointPort),
                certificateFingerprint: CertificateFingerprint(
                    bytes: stored.certificateFingerprint
                ),
                credential: stored.credential
            )
        } catch {
            throw DirectResourceCredentialError.corruptCredential
        }
    }
}
