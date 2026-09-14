import InferPeerCore
import InferPeerSecurity
import Testing

@Suite("Default identity provider")
struct DefaultIdentityProviderTests {
    @Test("Exposes its certificate-bound local identity")
    func exposesLocalIdentity() async throws {
        let components = try makeProvider()

        let identity = try await components.provider.localIdentity()
        let credentials = try await components.identityManager.credentials()

        #expect(identity == credentials.identity)
    }

    @Test("Requires approval of the exact certificate fingerprint")
    func recordsExactTrust() async throws {
        let components = try makeProvider(roles: [.caller, .worker])
        let identity = try makePresentedIdentity()

        #expect(try await components.provider.trustDecision(for: identity) == .unknown)
        try await components.provider.approve(identity)
        #expect(try await components.provider.trustDecision(for: identity) == .trusted)
        #expect(await components.repository.approvedRoleSet() == [.caller, .worker])

        let changedCertificate = try makePresentedIdentity(fingerprintByte: 0xC7)
        #expect(
            try await components.provider.trustDecision(for: changedCertificate) == .unknown
        )
    }

    @Test("Revocation overrides a previously trusted certificate")
    func revokesTrust() async throws {
        let components = try makeProvider()
        let identity = try makePresentedIdentity()
        try await components.provider.approve(identity)

        try await components.provider.revoke(peerID: identity.peerID)

        #expect(try await components.provider.trustDecision(for: identity) == .revoked)
    }

    @Test("Consumes pairing invitations through the provider")
    func consumesInvitation() async throws {
        let components = try makeProvider()
        let invitation = try await components.invitationAuthority.issue(
            for: makePairingCoordinator()
        )

        try await components.provider.consume(invitation)

        await #expect(throws: InferPeerSecurityError.invitationUnknownOrConsumed) {
            try await components.provider.consume(invitation)
        }
    }

    @Test("Rejects an approval policy without roles")
    func rejectsEmptyApprovalPolicy() {
        #expect(throws: InferPeerSecurityError.invalidConfiguration) {
            try makeProvider(roles: []).provider
        }
    }

    private func makeProvider(
        roles: Set<NodeRole> = [.worker]
    ) throws -> ProviderComponents {
        let secretStore = MemorySecretStore()
        let identityManager = DeviceIdentityManager(secretStore: secretStore)
        let invitationAuthority = PairingInvitationAuthority(secretStore: secretStore)
        let repository = MemoryTrustRepository()
        let provider = try DefaultIdentityProvider(
            identityManager: identityManager,
            invitationAuthority: invitationAuthority,
            trustRepository: repository,
            approvedRoles: roles
        )
        return ProviderComponents(
            provider: provider,
            identityManager: identityManager,
            invitationAuthority: invitationAuthority,
            repository: repository
        )
    }
}

private struct ProviderComponents {
    let provider: DefaultIdentityProvider
    let identityManager: DeviceIdentityManager
    let invitationAuthority: PairingInvitationAuthority
    let repository: MemoryTrustRepository
}
