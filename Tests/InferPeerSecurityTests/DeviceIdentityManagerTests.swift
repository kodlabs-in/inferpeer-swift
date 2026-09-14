import Foundation
import InferPeerCore
import InferPeerSecurity
import Testing

@Suite("Device identity")
struct DeviceIdentityManagerTests {
    @Test("Creates one stable certificate-bound identity")
    func createsStableIdentity() async throws {
        let store = MemorySecretStore()
        let clock = MutableSecurityDateProvider()
        let firstManager = DeviceIdentityManager(secretStore: store, dateProvider: clock)
        let first = try await firstManager.credentials()
        let reloaded = try await DeviceIdentityManager(
            secretStore: store,
            dateProvider: clock
        ).credentials()

        #expect(reloaded == first)
        #expect(first.certificateDER != first.privateKeyDER)
        #expect(first.notValidBefore <= clock.now())
        #expect(first.notValidAfter > clock.now())
    }

    @Test("Verifies the certificate identity and its explicit pin")
    func verifiesCertificateAndPin() async throws {
        let clock = MutableSecurityDateProvider()
        let credentials = try await DeviceIdentityManager(
            secretStore: MemorySecretStore(),
            dateProvider: clock
        ).credentials()
        let verifier = CertificateIdentityVerifier()

        let presented = try verifier.verify(
            certificateDER: credentials.certificateDER,
            expectedFingerprint: credentials.identity.certificateFingerprint,
            at: clock.now()
        )

        #expect(presented.peerID == credentials.identity.peerID)
        #expect(presented.certificateFingerprint == credentials.identity.certificateFingerprint)
        #expect(throws: InferPeerSecurityError.certificateFingerprintMismatch) {
            try verifier.verify(
                certificateDER: credentials.certificateDER,
                expectedFingerprint: try CertificateFingerprint(
                    bytes: Data(repeating: 0xFF, count: CertificateFingerprint.byteCount)
                ),
                at: clock.now()
            )
        }
    }

    @Test("Rotates keys without changing the stable peer identifier")
    func rotatesCertificate() async throws {
        let manager = DeviceIdentityManager(secretStore: MemorySecretStore())
        let original = try await manager.credentials()
        let rotated = try await manager.rotateCertificate()

        #expect(rotated.identity.peerID == original.identity.peerID)
        #expect(rotated.identity.certificateFingerprint != original.identity.certificateFingerprint)
        #expect(rotated.privateKeyDER != original.privateKeyDER)
    }

    @Test("Reset creates a new identity")
    func resetsIdentity() async throws {
        let manager = DeviceIdentityManager(secretStore: MemorySecretStore())
        let original = try await manager.credentials()

        try await manager.resetIdentity()
        let replacement = try await manager.credentials()

        #expect(replacement.identity.peerID != original.identity.peerID)
    }

    @Test("Rejects expired and corrupted stored credentials")
    func rejectsInvalidStoredCredentials() async throws {
        let store = MemorySecretStore()
        let clock = MutableSecurityDateProvider()
        let configuration = try DeviceIdentityConfiguration(
            certificateValidity: 60,
            clockSkewTolerance: 0
        )
        let manager = DeviceIdentityManager(
            secretStore: store,
            configuration: configuration,
            dateProvider: clock
        )
        _ = try await manager.credentials()

        clock.advance(by: 61)
        await #expect(throws: InferPeerSecurityError.certificateNotCurrentlyValid) {
            try await manager.credentials()
        }

        store.replaceAllValues(with: Data("not credentials".utf8))
        await #expect(throws: InferPeerSecurityError.corruptCredentials) {
            try await manager.credentials()
        }
    }

    @Test("Rejects malformed certificate bytes")
    func rejectsMalformedCertificate() {
        #expect(throws: InferPeerSecurityError.invalidCertificate) {
            try CertificateIdentityVerifier().verify(certificateDER: Data([0x00]))
        }
    }
}
