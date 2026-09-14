import InferPeerSecurity
import Testing

@Suite("Security configuration")
struct SecurityConfigurationTests {
    @Test("Rejects unsafe lifetime and Keychain namespace values")
    func rejectsInvalidValues() {
        #expect(throws: InferPeerSecurityError.invalidConfiguration) {
            try DeviceIdentityConfiguration(
                certificateValidity: 0,
                clockSkewTolerance: 0
            )
        }
        #expect(throws: InferPeerSecurityError.invalidConfiguration) {
            try PairingConfiguration(
                invitationValidity: .infinity,
                maximumEncodedInvitationBytes: 4_096
            )
        }
        #expect(throws: InferPeerSecurityError.invalidConfiguration) {
            try KeychainSecretStore(service: " ")
        }
        #expect(throws: InferPeerSecurityError.invalidConfiguration) {
            try KeychainSecretStore(service: "dev.inferpeer", accessGroup: " ")
        }
    }
}
