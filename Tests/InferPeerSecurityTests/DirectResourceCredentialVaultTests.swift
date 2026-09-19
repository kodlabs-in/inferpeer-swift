import Foundation
import InferPeerCore
import InferPeerSecurity
import Testing

@Suite("Direct resource credential vault")
struct DirectResourceCredentialVaultTests {
    @Test("Round trips exact endpoint, pin, and credential and supports revocation")
    func roundTripAndRemove() async throws {
        let store = MemorySecretStore()
        let vault = DirectResourceCredentialVault(secretStore: store)
        let credential = try makeCredential()

        try await vault.save(credential)
        let restored = try await vault.credential(for: credential.resourceID)

        #expect(restored == credential)
        #expect(try await vault.resourceIDs() == [credential.resourceID])

        try await vault.removeCredential(for: credential.resourceID)
        #expect(try await vault.credential(for: credential.resourceID) == nil)
        #expect(try await vault.resourceIDs().isEmpty)
    }

    @Test("Rejects corrupt persisted credential material")
    func rejectsCorruptData() async throws {
        let store = MemorySecretStore()
        let vault = DirectResourceCredentialVault(secretStore: store)
        try await vault.save(makeCredential())
        store.replaceAllValues(with: Data("not-json".utf8))

        await #expect(throws: DirectResourceCredentialError.corruptCredential) {
            try await vault.resourceIDs()
        }
    }

    private func makeCredential() throws -> DirectResourceCredential {
        try DirectResourceCredential(
            resourceID: ResourceID(rawValue: "resource-1"),
            endpoint: PeerEndpoint(host: "192.168.1.20", port: 9443),
            certificateFingerprint: CertificateFingerprint(
                bytes: Data(repeating: 7, count: CertificateFingerprint.byteCount)
            ),
            credential: Data([1, 2, 3])
        )
    }
}
